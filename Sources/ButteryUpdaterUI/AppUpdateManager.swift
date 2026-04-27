//
//  AppUpdateManager.swift
//  ButteryUpdaterUI
//
//  @MainActor-isolated observable manager that drives the update UI for
//  SwiftUI apps and orchestrates the service phases (download → verify →
//  stage → install → relaunch). Cancellable; alerts are guarded against
//  null-result presentation.
//

import ButteryUpdater
import Foundation
import SwiftUI

/// Observable manager that drives the update UI in SwiftUI apps.
@Observable
@MainActor
public final class AppUpdateManager {
	public var state: AppUpdateState = .idle
	public var showUpdateAlert: Bool = false
	public var showUpdateWindow: Bool = false
	public var downloadProgress: Double = 0

	private(set) public var updateResult: UpdateCheckResult?

	private let service: AppUpdateService
	private var checkTask: Task<Void, Never>?
	private var installTask: Task<Void, Never>?

	public nonisolated init(service: AppUpdateService) {
		self.service = service
	}

	/// The app's current version from the main bundle.
	public var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
	}

	/// The version available for update, if any.
	public var updateVersion: String? {
		updateResult?.latestVersion
	}

	/// Changelog for the available update, if any.
	public var updateChangelog: String? {
		updateResult?.changelog
	}

	// MARK: - Check

	/// Check the server for updates. If available, sets `showUpdateAlert` true.
	public func checkForUpdates() async {
		state = .checking
		do {
			let result = try await service.checkForUpdates()
			if Task.isCancelled {
				state = .cancelled
				return
			}
			if result.updateAvailable {
				updateResult = result
				state = .updateAvailable(result)
				showUpdateAlert = true
			} else {
				state = .idle
			}
		} catch {
			handleError(error)
		}
	}

	/// Open the update window and begin checking for updates.
	public func openAndCheck() {
		showUpdateWindow = true
		checkTask?.cancel()
		checkTask = Task { [weak self] in
			await self?.checkForUpdates()
		}
	}

	/// Cancel an in-progress update check.
	public func cancelCheck() {
		checkTask?.cancel()
		checkTask = nil
		state = .idle
		showUpdateWindow = false
	}

	// MARK: - Confirm running version (next launch hook)

	/// Call once the new version is up and running (e.g. after the main UI
	/// has loaded). Removes the rollback backup if the running version
	/// matches what the marker expected.
	public func confirmRunningVersion() async {
		await service.confirmRunningVersion()
	}

	// MARK: - Download → Verify → Stage → Install → Relaunch

	/// Run the full install pipeline. Cancellable via `cancelInProgressUpdate()`.
	public func downloadAndInstall() {
		installTask?.cancel()
		installTask = Task { [weak self] in
			await self?.runInstallPipeline()
		}
	}

	private func runInstallPipeline() async {
		guard let result = updateResult, let downloadURL = result.downloadURL else {
			state = .failed("No download URL available")
			return
		}

		// Translocation guard: refuse early so the user knows what to do.
		do {
			try await service.ensureNotTranslocated()
		} catch {
			handleError(error)
			return
		}

		downloadProgress = 0
		state = .downloading(progress: 0)

		// One throttle per install. The @Sendable callback fires on the
		// URLSession's delegate queue thousands of times per download; we
		// gate before spawning a Task to avoid hammering the main actor.
		let throttle = ProgressThrottle()

		let zipPath: URL
		do {
			zipPath = try await service.downloadFile(
				from: downloadURL,
				expectedSize: result.expectedSize,
				onProgress: { @Sendable progress in
					guard throttle.shouldReport(progress) else { return }
					Task { @MainActor [weak self] in
						guard let self else { return }
						self.downloadProgress = progress
						if case .downloading = self.state {
							self.state = .downloading(progress: progress)
						}
					}
				}
			)
		} catch {
			handleError(error)
			return
		}

		guard !Task.isCancelled else {
			state = .cancelled
			return
		}

		state = .verifying
		do {
			if let expected = result.expectedChecksum {
				try await service.verifyChecksum(at: zipPath, expected: expected)
			}
		} catch {
			handleError(error)
			return
		}

		guard !Task.isCancelled else {
			state = .cancelled
			return
		}

		state = .staging
		let staged: URL
		do {
			staged = try await service.stageBundle(zipPath: zipPath)
		} catch {
			handleError(error)
			return
		}

		state = .readyToInstall(localPath: staged)

		guard !Task.isCancelled else {
			state = .cancelled
			return
		}

		state = .installing
		do {
			try await service.installBundle(staged: staged, expectedVersion: result.latestVersion)
		} catch {
			handleError(error)
			return
		}

		state = .relaunching
		do {
			try service.relaunch()
		} catch {
			state = .failed("Update installed but relaunch failed: \(error.localizedDescription). Quit and reopen the app to use the new version.")
		}
	}

	/// Cancel an in-progress install. Only honours cancel during the
	/// `.downloading` / `.verifying` / `.staging` phases — once the bundle
	/// swap has begun the operation is atomic and `.relaunching` is
	/// fire-and-forget, so there's no safe abort point. Calling outside the
	/// cancellable phases is a no-op so it can't clobber a successful end
	/// state with `.cancelled`.
	public func cancelInProgressUpdate() async {
		switch state {
		case .downloading, .verifying, .staging:
			break // proceed with cancellation
		case .idle, .checking, .updateAvailable, .readyToInstall,
			 .installing, .relaunching, .cancelled, .failed:
			return
		}
		installTask?.cancel()
		await service.cancelActiveDownload()
		installTask = nil
		state = .cancelled
	}

	// MARK: - Dismiss

	/// Dismiss the update alert without updating.
	public func dismissUpdate() {
		showUpdateAlert = false
		state = .idle
		updateResult = nil
	}

	// MARK: - Error handling

	/// Map any thrown error from the update pipeline to a state. Cancellation
	/// of any flavour (`CancellationError`, `Task.isCancelled`, or our typed
	/// `.userCancelled`) collapses to `.cancelled`; everything else is
	/// `.failed`.
	private func handleError(_ error: Error) {
		if error is CancellationError {
			state = .cancelled
		} else if case AppUpdateError.userCancelled = error {
			state = .cancelled
		} else if Task.isCancelled {
			state = .cancelled
		} else {
			state = .failed(error.localizedDescription)
		}
	}
}
