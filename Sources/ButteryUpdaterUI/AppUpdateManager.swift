//
//  AppUpdateManager.swift
//  ButteryUpdaterUI
//
//  Observable manager for SwiftUI apps. Coordinates the update lifecycle
//  and provides UI state for alerts and progress overlays.
//

import ButteryUpdater
import SwiftUI

/// Observable manager that drives the update UI in SwiftUI apps.
///
/// Usage:
/// ```swift
/// let service = AppUpdateService(serverBaseURL: "...", appName: "sous")
/// let manager = AppUpdateManager(service: service)
///
/// // Check on launch:
/// await manager.checkForUpdates()
///
/// // In your view:
/// .appUpdateOverlay(manager: manager)
/// ```
@Observable
public final class AppUpdateManager: @unchecked Sendable {
	public var state: AppUpdateState = .idle
	public var showUpdateAlert: Bool = false
	public var showDownloadProgress: Bool = false
	public var downloadProgress: Double = 0

	private var updateResult: UpdateCheckResult?
	private let service: AppUpdateService

	public init(service: AppUpdateService) {
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

	/// Check the server for updates. If available, sets `showUpdateAlert` to true.
	public func checkForUpdates() async {
		state = .checking
		do {
			let result = try await service.checkForUpdates()
			if result.updateAvailable {
				updateResult = result
				state = .updateAvailable(result)
				showUpdateAlert = true
			} else {
				state = .idle
			}
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	// MARK: - Download + Verify + Install

	/// Download the update, verify integrity, install, and relaunch.
	public func downloadAndInstall() async {
		guard let result = updateResult,
			  let downloadURL = result.downloadURL else {
			state = .failed("No download URL available")
			return
		}

		showDownloadProgress = true
		downloadProgress = 0
		state = .downloading(progress: 0)

		do {
			let localPath = try await service.downloadUpdate(
				from: downloadURL,
				expectedChecksum: result.expectedChecksum,
				expectedSize: result.expectedSize,
				onProgress: { @Sendable progress in
					Task { @MainActor [weak self] in
						self?.downloadProgress = progress
						self?.state = .downloading(progress: progress)
					}
				}
			)

			state = .verifying
			showDownloadProgress = false

			state = .readyToInstall(localPath: localPath)
			state = .installing

			try await service.installUpdate(from: localPath)

			service.relaunch()
		} catch {
			showDownloadProgress = false
			state = .failed(error.localizedDescription)
		}
	}

	/// Dismiss the update alert without updating.
	public func dismissUpdate() {
		showUpdateAlert = false
		state = .idle
		updateResult = nil
	}
}
