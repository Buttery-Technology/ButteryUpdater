//
//  SoftwareUpdateView.swift
//  ButteryUpdaterUI
//

import ButteryUpdater
import SwiftUI

/// A window-style view for checking, downloading, and installing software updates.
public struct SoftwareUpdateView: View {
	@Bindable var manager: AppUpdateManager

	public init(manager: AppUpdateManager) {
		self.manager = manager
	}

	public var body: some View {
		VStack(spacing: 0) {
			// App icon + version header
			header
				.padding(.bottom, 16)

			Divider()

			// State-driven content area
			stateContent
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.padding(.vertical, 16)

			Divider()

			// Action buttons
			actionBar
				.padding(.top, 12)
		}
		.padding(24)
		.frame(width: 380, height: 280)
	}

	// MARK: - Header

	private var header: some View {
		HStack(spacing: 14) {
			appIcon
				.frame(width: 56, height: 56)

			VStack(alignment: .leading, spacing: 4) {
				Text("Software Update")
					.font(.system(size: 16, weight: .semibold))

				Text("Current version: \(manager.currentVersion)")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}

			Spacer()
		}
	}

	@ViewBuilder
	private var appIcon: some View {
		// `NSApp?.applicationIconImage` chains through an implicitly-unwrapped
		// `NSImage!` property; without an explicit `NSImage?` annotation the
		// optional chain leaks an implicit-unwrap, and `Image(nsImage:)` would
		// crash if the icon is missing (rare but observed in test rigs).
		let icon: NSImage? = NSApp?.applicationIconImage
		if let icon {
			Image(nsImage: icon)
				.resizable()
		} else {
			Image(systemName: "app.dashed")
				.resizable()
				.foregroundStyle(.secondary)
		}
	}

	// MARK: - State Content

	@ViewBuilder
	private var stateContent: some View {
		switch manager.state {
		case .idle:
			VStack(spacing: 8) {
				Image(systemName: "checkmark.circle")
					.font(.system(size: 28))
					.foregroundStyle(.green)
				Text("App is up to date.")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .checking:
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.regular)
				Text("Checking for updates…")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .updateAvailable(let result):
			VStack(alignment: .leading, spacing: 10) {
				HStack(spacing: 6) {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 18))
						.foregroundStyle(.blue)
					Text("A new version is available!")
						.font(.system(size: 13, weight: .medium))
				}

				HStack(spacing: 16) {
					Label(manager.currentVersion, systemImage: "app.badge")
					Image(systemName: "arrow.right")
						.foregroundStyle(.secondary)
					Label(result.latestVersion, systemImage: "app.badge.fill")
						.foregroundStyle(.blue)
				}
				.font(.system(size: 12))

				if let changelog = result.changelog, !changelog.isEmpty {
					ScrollView {
						Text(changelog)
							.font(.system(size: 11))
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(maxHeight: 80)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

		case .downloading(let progress):
			VStack(spacing: 10) {
				ProgressView(value: progress)
					.frame(maxWidth: .infinity)
				Text("Downloading update… \(Int(progress * 100))%")
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 8)

		case .verifying:
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.regular)
				Text("Verifying update…")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .staging:
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.regular)
				Text("Preparing update…")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .installing, .readyToInstall:
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.regular)
				Text("Installing update…")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .relaunching:
			VStack(spacing: 10) {
				ProgressView()
					.controlSize(.regular)
				Text("Relaunching…")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .cancelled:
			VStack(spacing: 8) {
				Image(systemName: "xmark.circle")
					.font(.system(size: 28))
					.foregroundStyle(.secondary)
				Text("Update cancelled.")
					.font(.system(size: 13))
					.foregroundStyle(.secondary)
			}

		case .failed(let message):
			VStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle")
					.font(.system(size: 28))
					.foregroundStyle(.orange)
				Text("Update failed")
					.font(.system(size: 13, weight: .medium))
				Text(message)
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		}
	}

	// MARK: - Action Bar

	private var actionBar: some View {
		HStack {
			switch manager.state {
			case .checking:
				Spacer()
				Button("Cancel") {
					manager.cancelCheck()
				}
				.keyboardShortcut(.cancelAction)

			case .updateAvailable:
				Button("Later") {
					manager.dismissUpdate()
					manager.showUpdateWindow = false
				}
				.keyboardShortcut(.cancelAction)

				Spacer()

				Button("Update Now") {
					manager.downloadAndInstall()
				}
				.keyboardShortcut(.defaultAction)

			case .downloading, .verifying, .staging:
				Spacer()
				Button("Cancel") {
					Task { await manager.cancelInProgressUpdate() }
				}
				.keyboardShortcut(.cancelAction)

			case .installing, .readyToInstall, .relaunching:
				// Bundle swap is fast and atomic; relaunch is in-flight.
				// No safe abort path.
				Spacer()

			case .cancelled:
				Spacer()
				Button("Close") {
					manager.showUpdateWindow = false
					manager.state = .idle
				}
				.keyboardShortcut(.cancelAction)

			case .failed:
				Spacer()
				Button("Retry") {
					manager.openAndCheck()
				}
				Button("Close") {
					manager.showUpdateWindow = false
					manager.state = .idle
				}
				.keyboardShortcut(.cancelAction)

			case .idle:
				Spacer()
				Button("Close") {
					manager.showUpdateWindow = false
				}
				.keyboardShortcut(.cancelAction)
			}
		}
	}
}
