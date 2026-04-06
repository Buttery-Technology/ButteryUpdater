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
			.sheet(isPresented: $updateManager.showUpdateWindow) {
				SoftwareUpdateView(manager: updateManager)
			}
			.alert(
				"Update Available",
				isPresented: $updateManager.showUpdateAlert
			) {
				Button("View Update") {
					updateManager.showUpdateAlert = false
					updateManager.showUpdateWindow = true
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
