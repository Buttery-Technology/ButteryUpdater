//
//  AppUpdateService.swift
//  ButteryUpdater
//
//  Core update service. Coordinates: check → download → verify → stage →
//  install → relaunch. Bundle-based install with rollback marker. Streaming
//  SHA-256 verification. Cancellable downloads via a dedicated URLSession.
//

import Crypto
import Foundation
import Logging
#if canImport(AppKit)
import AppKit
#endif
#if canImport(IOKit)
import IOKit
#endif

/// Actor-based service that handles the full app update lifecycle.
///
/// Higher-level callers (typically `AppUpdateManager`) drive each phase:
/// 1. `checkForUpdates()` → `UpdateCheckResult`
/// 2. `downloadFile(...)` → URL of zip on disk
/// 3. `verifyChecksum(...)`
/// 4. `stageBundle(...)` → URL of extracted `.app`
/// 5. `installBundle(...)` (atomic swap, escalates if needed, writes marker)
/// 6. `relaunch()`
///
/// On the next launch, `confirmRunningVersion()` clears the rollback backup.
public actor AppUpdateService {
	private let serverBaseURL: String
	private let appName: String
	private let currentVersion: String
	private let platform: String
	private let hostIdentifier: String
	private let logger: Logger
	private let installer: AppUpdateInstaller

	/// Dedicated session — kept alive for the lifetime of the service so
	/// progress delegates, redirects, and cancellation behave predictably.
	private let downloadSession: URLSession
	private let downloadDelegate: DownloadProgressDelegate

	/// Currently-active download task, exposed for cancellation. Reset to nil
	/// when the download completes (success or failure).
	private var activeDownloadTask: URLSessionDownloadTask?

	/// Create an update service for a specific app.
	///
	/// - Parameters:
	///   - serverBaseURL: Base URL of the ButteryAI server (e.g. `https://server.butteryai.com`).
	///   - appName: App identifier matching the server's release system (`butteryai`, `sous`, `server`, `dais`).
	///   - currentVersion: Override the current version. Defaults to `CFBundleShortVersionString`.
	///   - platform: Override the platform identifier. Defaults to auto-detected value.
	///   - hostIdentifier: Override the host ID for instance tracking. Defaults to hardware UUID (macOS) or machine-id (Linux).
	public init(
		serverBaseURL: String,
		appName: String,
		currentVersion: String? = nil,
		platform: String? = nil,
		hostIdentifier: String? = nil
	) {
		self.serverBaseURL = serverBaseURL
		self.appName = appName
		self.currentVersion = currentVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
		let logger = Logger(label: "ButteryUpdater.\(appName)")
		self.logger = logger
		self.platform = platform ?? Self.detectPlatform()
		self.hostIdentifier = hostIdentifier ?? Self.generateHostIdentifier()
		self.installer = AppUpdateInstaller(appName: appName, logger: logger)

		let delegate = DownloadProgressDelegate()
		self.downloadDelegate = delegate
		let config = URLSessionConfiguration.default
		config.allowsCellularAccess = true
		config.waitsForConnectivity = true
		config.timeoutIntervalForRequest = 60
		config.timeoutIntervalForResource = 60 * 60 // 1h cap for huge bundles
		self.downloadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
	}

	// MARK: - Check for Updates

	/// Check the server for available updates.
	///
	/// Sends the current version, platform, and host identifier to the server.
	/// The server records the check-in for instance tracking.
	public func checkForUpdates() async throws -> UpdateCheckResult {
		guard let url = URL(string: "\(serverBaseURL)/api/releases/check/\(appName)") else {
			throw AppUpdateError.invalidURL("\(serverBaseURL)/api/releases/check/\(appName)")
		}
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue(currentVersion, forHTTPHeaderField: "X-App-Version")
		request.setValue(platform, forHTTPHeaderField: "X-App-Platform")
		request.setValue(hostIdentifier, forHTTPHeaderField: "X-Host-ID")

		logger.info("Checking for updates: \(url.absoluteString) (version: \(currentVersion), platform: \(self.platform))")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let httpResponse = response as? HTTPURLResponse,
			  (200...299).contains(httpResponse.statusCode) else {
			let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
			logger.error("Update check failed: server returned \(statusCode)")
			throw AppUpdateError.checkFailed("Server returned status \(statusCode)")
		}

		let manifest = try JSONDecoder().decode(ManifestResponse.self, from: data)
		let platformInfo = manifest.platforms[self.platform]

		if manifest.updateAvailable {
			logger.info("Update available: \(manifest.version) (current: \(currentVersion))")
			if let info = platformInfo {
				logger.info("Download URL: \(info.url), size: \(info.size ?? 0) bytes")
			} else {
				logger.warning("No platform binary available for \(self.platform)")
			}
		} else {
			logger.info("App is up to date (\(currentVersion))")
		}

		return UpdateCheckResult(
			updateAvailable: manifest.updateAvailable,
			currentVersion: currentVersion,
			latestVersion: manifest.version,
			changelog: manifest.changelog,
			downloadURL: platformInfo?.url,
			expectedChecksum: platformInfo?.sha256,
			expectedSize: platformInfo?.size,
			mandatory: false,
			minVersion: manifest.minVersion,
			dockerImage: manifest.dockerImage
		)
	}

	// MARK: - Download

	/// Download a file. Verifies file size if `expectedSize` is provided, but
	/// does **not** verify the checksum — call `verifyChecksum(at:expected:)`
	/// for that. Splitting these keeps the manager's UI state machine honest.
	///
	/// Cancel the in-progress download via `cancelActiveDownload()`.
	public func downloadFile(
		from urlString: String,
		expectedSize: Int?,
		onProgress: @Sendable @escaping (Double) -> Void
	) async throws -> URL {
		guard let url = URL(string: urlString) else {
			throw AppUpdateError.invalidURL(urlString)
		}

		logger.info("Downloading update from: \(urlString)")

		let workingDir = try installer.ensureWorkingDirectory()
		let downloadDir = workingDir.appendingPathComponent("download", isDirectory: true)
		// Wipe any leftover zips from prior runs (success or failure). Each
		// download writes a UUID-named file; without this, the dir grows
		// without bound on repeated update cycles. Actor serialization
		// guarantees no concurrent download is reading from this directory.
		try? FileManager.default.removeItem(at: downloadDir)
		try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
		let tempFile = downloadDir.appendingPathComponent("update-\(UUID().uuidString).zip")

		// Configure the delegate's progress callback for this download.
		downloadDelegate.setProgressHandler(onProgress)
		defer { downloadDelegate.setProgressHandler(nil) }

		let task = downloadSession.downloadTask(with: URLRequest(url: url))
		self.activeDownloadTask = task
		defer { self.activeDownloadTask = nil }

		do {
			let (downloadedURL, response) = try await downloadDelegate.run(task: task)

			guard let httpResponse = response as? HTTPURLResponse,
				  (200...299).contains(httpResponse.statusCode) else {
				let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
				throw AppUpdateError.downloadFailed("Server returned status \(statusCode)")
			}

			if FileManager.default.fileExists(atPath: tempFile.path) {
				try FileManager.default.removeItem(at: tempFile)
			}
			try FileManager.default.moveItem(at: downloadedURL, to: tempFile)

			if let expectedSize {
				let attributes = try FileManager.default.attributesOfItem(atPath: tempFile.path)
				let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
				guard actualSize == expectedSize else {
					try? FileManager.default.removeItem(at: tempFile)
					throw AppUpdateError.sizeMismatch(expected: expectedSize, actual: actualSize)
				}
				logger.info("Size verified: \(actualSize) bytes")
			}

			logger.info("Download complete: \(tempFile.path)")
			return tempFile
		} catch is CancellationError {
			task.cancel()
			throw AppUpdateError.userCancelled
		} catch let urlError as URLError where urlError.code == .cancelled {
			throw AppUpdateError.userCancelled
		}
	}

	/// Cancel the currently-running download, if any. The corresponding
	/// `downloadFile(...)` call will throw `AppUpdateError.userCancelled`.
	public func cancelActiveDownload() {
		activeDownloadTask?.cancel()
		activeDownloadTask = nil
	}

	// MARK: - Verify

	/// Verify a file's SHA-256 against `expected` using a streaming hasher
	/// (1 MB chunks). Avoids loading multi-GB bundles into memory.
	public func verifyChecksum(at fileURL: URL, expected: String) throws {
		logger.info("Verifying SHA-256 checksum...")
		let actual = try streamingSHA256Hex(of: fileURL)
		guard actual == expected else {
			logger.error("Checksum mismatch: expected \(expected), got \(actual)")
			throw AppUpdateError.checksumMismatch(expected: expected, actual: actual)
		}
		logger.info("Checksum verified.")
	}

	/// Compute the streaming SHA-256 hex digest of a file. Public for tests.
	///
	/// Cancellation: each chunk iteration checks `Task.isCancelled` so that
	/// cancelling the surrounding install Task aborts within ~1 MB of work
	/// instead of hashing through the whole file.
	public func streamingSHA256Hex(of fileURL: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: fileURL)
		defer { try? handle.close() }

		var hasher = SHA256()
		let chunkSize = 1 * 1024 * 1024 // 1 MB
		while true {
			if Task.isCancelled { throw CancellationError() }
			let chunk: Data
			do {
				chunk = try handle.read(upToCount: chunkSize) ?? Data()
			} catch {
				throw AppUpdateError.installFailed("Read failed during checksum: \(error.localizedDescription)")
			}
			if chunk.isEmpty { break }
			hasher.update(data: chunk)
		}
		return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
	}

	// MARK: - Stage + Install (delegate to installer)

	/// Translocation guard. Throws `.translocated` if the running bundle is
	/// served from `/AppTranslocation/`.
	public func ensureNotTranslocated() throws {
		let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
		try installer.ensureNotTranslocated(currentBundle: bundle)
	}

	/// Extract the downloaded zip and validate the resulting `.app`.
	///
	/// Returns the URL of the staged `.app` bundle, ready to install.
	public func stageBundle(zipPath: URL) throws -> URL {
		let currentBundleName = Bundle.main.bundleURL.lastPathComponent
		let staged = try installer.stageBundle(from: zipPath, expectedBundleName: currentBundleName)
		try installer.stripQuarantine(at: staged)
		try installer.verifySignature(at: staged, matchingBundle: Bundle.main.bundleURL)
		return staged
	}

	/// Install the staged bundle by atomically swapping it into the running
	/// bundle's location. Writes a rollback marker; escalates to admin
	/// privileges if the parent directory is not user-writable.
	public func installBundle(staged: URL, expectedVersion: String) throws {
		let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
		try installer.installBundle(staged: staged, target: target, expectedVersion: expectedVersion)
		// Stale download is no longer needed; staging dir is consumed by the swap.
		installer.cleanupStaging()
	}

	// MARK: - Confirmation

	/// Called on the next successful launch to clear the rollback backup
	/// once we've verified we're running the new version.
	public func confirmRunningVersion() {
		installer.confirmRunningVersion(currentVersion)
	}

	// MARK: - Relaunch

	/// Relaunch the app after an update. Errors are surfaced via
	/// `AppUpdateError.relaunchFailed`. Does **not** call `terminate` if
	/// the relaunch helper failed to start, so the user is left with a
	/// running (old) app rather than a closed one.
	public nonisolated func relaunch() throws {
		logger.info("Relaunching app...")
		#if os(macOS)
		let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()

		// `open -n` forces a fresh instance even if launchd thinks one is
		// already running. The trailing fallback to plain `open` is for the
		// rare case where -n is rejected by an entitlement-restricted bundle.
		//
		// Single-quote the path: /bin/sh interprets `\` inside double quotes,
		// so a path like `/Volumes/My\Drive/App.app` would be munged. Single
		// quotes are literal except for `'` itself, which we escape via the
		// canonical `'\''` (close quote, literal `'`, reopen quote) pattern.
		let quotedPath = "'" + bundleURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
		let command = "/bin/sleep 2 && /usr/bin/open -n \(quotedPath) || /usr/bin/open \(quotedPath)"

		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/bin/sh")
		task.arguments = ["-c", command]

		do {
			try task.run()
		} catch {
			logger.error("Relaunch helper failed to start: \(error.localizedDescription)")
			throw AppUpdateError.relaunchFailed(error.localizedDescription)
		}

		#if canImport(AppKit)
		DispatchQueue.main.async {
			NSApplication.shared.terminate(NSApplication.shared)
		}
		#endif
		#elseif os(Linux)
		Foundation.exit(0)
		#endif
	}

	// MARK: - Platform Detection

	/// Auto-detect the current platform identifier.
	public static func detectPlatform() -> String {
		#if arch(arm64)
			#if os(macOS)
			return "macos-arm64"
			#else
			return "linux-arm64"
			#endif
		#else
			#if os(macOS)
			return "macos-x86_64"
			#else
			return "linux-x86_64"
			#endif
		#endif
	}

	// MARK: - Host Identifier

	/// Generate a stable host identifier for instance tracking.
	public static func generateHostIdentifier() -> String {
		#if os(macOS) && canImport(IOKit)
		let platformExpert = IOServiceGetMatchingService(
			kIOMainPortDefault,
			IOServiceMatching("IOPlatformExpertDevice")
		)
		defer { IOObjectRelease(platformExpert) }

		if let cfString = IORegistryEntryCreateCFProperty(
			platformExpert,
			kIOPlatformUUIDKey as CFString,
			kCFAllocatorDefault,
			0
		) {
			return (cfString.takeUnretainedValue() as? String) ?? ProcessInfo.processInfo.hostName
		}
		#endif

		#if os(Linux)
		if let id = try? String(contentsOfFile: "/etc/machine-id", encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
			return id
		}
		#endif

		return ProcessInfo.processInfo.hostName
	}
}

// MARK: - Manifest Response

struct ManifestResponse: Decodable {
	let app: String
	let version: String
	let minVersion: String?
	let changelog: String?
	let platforms: [String: PlatformInfo]
	let updateAvailable: Bool
	let dockerImage: String?

	struct PlatformInfo: Decodable {
		let url: String
		let sha256: String?
		let size: Int?
	}
}

// MARK: - Download Progress Delegate

/// URLSession delegate that:
/// - Forwards write progress to a settable handler.
/// - Resolves a `(downloadedURL, response)` pair via continuation when the
///   download finishes, so the actor can `await` the result.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	private let lock = NSLock()
	private var progressHandler: (@Sendable (Double) -> Void)?
	private var continuation: CheckedContinuation<(URL, URLResponse?), Error>?
	private var savedFileURL: URL?

	override init() { super.init() }

	func setProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
		lock.lock(); defer { lock.unlock() }
		progressHandler = handler
	}

	/// Resume the task and await its completion.
	func run(task: URLSessionDownloadTask) async throws -> (URL, URLResponse?) {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, URLResponse?), Error>) in
				lock.lock()
				continuation = cont
				lock.unlock()
				task.resume()
			}
		} onCancel: {
			task.cancel()
		}
	}

	// MARK: URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard totalBytesExpectedToWrite > 0 else { return }
		let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
		lock.lock()
		let handler = progressHandler
		lock.unlock()
		handler?(progress)
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		// Move file out of the URLSession-managed location into our own temp
		// path before we return — the system deletes `location` as soon as
		// this delegate method returns.
		let tmp = FileManager.default.temporaryDirectory
			.appendingPathComponent("buttery-updater-\(UUID().uuidString).bin")
		do {
			try FileManager.default.moveItem(at: location, to: tmp)
			lock.lock()
			savedFileURL = tmp
			lock.unlock()
		} catch {
			lock.lock()
			let cont = continuation
			continuation = nil
			lock.unlock()
			cont?.resume(throwing: error)
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		lock.lock()
		let cont = continuation
		continuation = nil
		let saved = savedFileURL
		savedFileURL = nil
		lock.unlock()

		guard let cont else { return }
		if let error {
			cont.resume(throwing: error)
			return
		}
		guard let saved else {
			cont.resume(throwing: AppUpdateError.downloadFailed("No file produced by download"))
			return
		}
		cont.resume(returning: (saved, task.response))
	}
}
