//
//  AppUpdateService.swift
//  ButteryUpdater
//
//  Core update service: check for updates, download binaries from GCS,
//  verify SHA-256 checksums, perform atomic binary replacement, and relaunch.
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
/// Usage:
/// ```swift
/// let updater = AppUpdateService(
///     serverBaseURL: "https://server.butteryai.com",
///     appName: "dais"
/// )
/// let result = try await updater.checkForUpdates()
/// if result.updateAvailable, let url = result.downloadURL {
///     let path = try await updater.downloadUpdate(from: url, ...)
///     try updater.installUpdate(from: path)
///     updater.relaunch()
/// }
/// ```
public actor AppUpdateService {
	private let serverBaseURL: String
	private let appName: String
	private let currentVersion: String
	private let platform: String
	private let hostIdentifier: String
	private let logger: Logger

	/// Create an update service for a specific app.
	///
	/// - Parameters:
	///   - serverBaseURL: Base URL of the ButteryAI server (e.g. `https://server.butteryai.com`)
	///   - appName: App identifier matching the server's release system (`butteryai`, `sous`, `server`, `dais`)
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
		self.logger = Logger(label: "ButteryUpdater.\(appName)")
		self.platform = platform ?? Self.detectPlatform()
		self.hostIdentifier = hostIdentifier ?? Self.generateHostIdentifier()
	}

	// MARK: - Check for Updates

	/// Check the server for available updates.
	///
	/// Sends the current version, platform, and host identifier to the server.
	/// The server records the check-in for instance tracking.
	public func checkForUpdates() async throws -> UpdateCheckResult {
		let url = URL(string: "\(serverBaseURL)/api/releases/check/\(appName)")!
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
			logger.info("Update available: \(manifest.version ?? "unknown") (current: \(currentVersion))")
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
			minVersion: manifest.minVersion
		)
	}

	// MARK: - Download Update

	/// Download a binary from the given URL with progress reporting.
	///
	/// Verifies file size and SHA-256 checksum after download.
	/// Returns the local file URL of the verified binary.
	public func downloadUpdate(
		from urlString: String,
		expectedChecksum: String?,
		expectedSize: Int?,
		onProgress: @Sendable @escaping (Double) -> Void
	) async throws -> URL {
		guard let url = URL(string: urlString) else {
			throw AppUpdateError.invalidURL(urlString)
		}

		logger.info("Downloading update from: \(urlString)")

		let tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("buttery-updates-\(appName)", isDirectory: true)
		try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

		let tempFile = tempDir.appendingPathComponent("\(appName)-update-\(UUID().uuidString)")

		let (downloadedURL, response) = try await URLSession.shared.download(
			for: URLRequest(url: url),
			delegate: DownloadProgressDelegate(onProgress: onProgress)
		)

		guard let httpResponse = response as? HTTPURLResponse,
			  (200...299).contains(httpResponse.statusCode) else {
			let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
			throw AppUpdateError.downloadFailed("Server returned status \(statusCode)")
		}

		if FileManager.default.fileExists(atPath: tempFile.path) {
			try FileManager.default.removeItem(at: tempFile)
		}
		try FileManager.default.moveItem(at: downloadedURL, to: tempFile)
		logger.info("Download complete: \(tempFile.path)")

		// Verify file size
		if let expectedSize {
			let attributes = try FileManager.default.attributesOfItem(atPath: tempFile.path)
			let actualSize = attributes[.size] as? Int ?? 0
			guard actualSize == expectedSize else {
				logger.error("Size mismatch: expected \(expectedSize), got \(actualSize)")
				try? FileManager.default.removeItem(at: tempFile)
				throw AppUpdateError.sizeMismatch(expected: expectedSize, actual: actualSize)
			}
			logger.info("Size verified: \(actualSize) bytes")
		}

		// Verify SHA-256 checksum
		if let expectedChecksum {
			logger.info("Verifying SHA-256 checksum...")
			let data = try Data(contentsOf: tempFile)
			let digest = SHA256.hash(data: data)
			let actualChecksum = digest.compactMap { String(format: "%02x", $0) }.joined()

			guard actualChecksum == expectedChecksum else {
				logger.error("Checksum mismatch: expected \(expectedChecksum), got \(actualChecksum)")
				try? FileManager.default.removeItem(at: tempFile)
				throw AppUpdateError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
			}
			logger.info("Checksum verified: \(actualChecksum)")
		}

		return tempFile
	}

	// MARK: - Install Update

	/// Atomically replace the running binary with the downloaded update.
	///
	/// Creates a backup of the current binary, moves the new one into place,
	/// and sets executable permissions. Rolls back on failure.
	public func installUpdate(from downloadedBinary: URL) throws {
		logger.info("Installing update from \(downloadedBinary.path)...")
		let currentExecutable = Bundle.main.executableURL!
		let appBundle = Bundle.main.bundleURL
		let executableName = currentExecutable.lastPathComponent

		let targetPath: URL
		if appBundle.pathExtension == "app" {
			targetPath = appBundle.appendingPathComponent("Contents/MacOS/\(executableName)")
		} else {
			targetPath = currentExecutable
		}

		let parentDir = targetPath.deletingLastPathComponent()
		let backupPath = parentDir.appendingPathComponent("\(executableName).backup")

		if FileManager.default.fileExists(atPath: backupPath.path) {
			try FileManager.default.removeItem(at: backupPath)
		}

		try FileManager.default.moveItem(at: targetPath, to: backupPath)

		do {
			try FileManager.default.moveItem(at: downloadedBinary, to: targetPath)
		} catch {
			try? FileManager.default.moveItem(at: backupPath, to: targetPath)
			throw AppUpdateError.installFailed("Failed to move new binary: \(error.localizedDescription)")
		}

		try FileManager.default.setAttributes(
			[.posixPermissions: 0o755],
			ofItemAtPath: targetPath.path
		)

		try? FileManager.default.removeItem(at: backupPath)

		logger.info("Update installed at \(targetPath.path)")
	}

	// MARK: - Relaunch

	/// Relaunch the app after an update.
	///
	/// On macOS, launches a shell process that waits 1 second then opens the app bundle.
	/// On Linux, simply exits (assumes a process supervisor will restart).
	public nonisolated func relaunch() {
		logger.info("Relaunching app...")
		#if os(macOS)
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/bin/sh")
		task.arguments = ["-c", "sleep 1 && open \"\(Bundle.main.bundleURL.path)\""]
		try? task.run()

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
			kIOMasterPortDefault,
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

	struct PlatformInfo: Decodable {
		let url: String
		let sha256: String?
		let size: Int?
	}
}

// MARK: - Download Progress Delegate

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
	let onProgress: @Sendable (Double) -> Void

	init(onProgress: @Sendable @escaping (Double) -> Void) {
		self.onProgress = onProgress
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard totalBytesExpectedToWrite > 0 else { return }
		onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
	}

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		// Handled by the async download call
	}
}
