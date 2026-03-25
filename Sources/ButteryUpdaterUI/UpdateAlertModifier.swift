//
//  UpdateAlertModifier.swift
//  ButteryUpdaterUI
//
//  SwiftUI view modifier that shows an update alert and download progress overlay.
//

import SwiftUI

/// View modifier that attaches an update alert and download progress overlay.
public struct UpdateAlertModifier: ViewModifier {
	@Bindable var updateManager: AppUpdateManager

	public init(updateManager: AppUpdateManager) {
		self.updateManager = updateManager
	}

	public func body(content: Content) -> some View {
		content
			.alert(
				"Update Available",
				isPresented: $updateManager.showUpdateAlert
			) {
				Button("Update Now") {
					Task { await updateManager.downloadAndInstall() }
				}
				Button("Later", role: .cancel) {
					updateManager.dismissUpdate()
				}
			} message: {
				VStack {
					if let version = updateManager.updateVersion {
						Text("\(version) is available (you have \(updateManager.currentVersion)).")
					}
					if let changelog = updateManager.updateChangelog {
						Text(changelog)
					}
				}
			}
			.overlay {
				if updateManager.showDownloadProgress {
					VStack(spacing: 12) {
						ProgressView(value: updateManager.downloadProgress)
							.frame(width: 200)
						Text("Downloading update... \(Int(updateManager.downloadProgress * 100))%")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					.padding(24)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
				}
			}
	}
}

extension View {
	/// Attach an update alert and download progress overlay driven by the given manager.
	public func appUpdateAlert(manager: AppUpdateManager) -> some View {
		modifier(UpdateAlertModifier(updateManager: manager))
	}

	/// Conditionally attach the update overlay if a manager is provided.
	@ViewBuilder
	public func appUpdateOverlay(manager: AppUpdateManager?) -> some View {
		if let manager {
			modifier(UpdateAlertModifier(updateManager: manager))
		} else {
			self
		}
	}
}
