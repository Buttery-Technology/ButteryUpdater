//
//  UpdateAlertModifier.swift
//  ButteryUpdaterUI
//
//  SwiftUI view modifier that shows an update alert and download progress overlay.
//

import ButteryUpdater
import SwiftUI

/// View modifier that attaches an update alert and software-update window.
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
				isPresented: $updateManager.showUpdateAlert,
				presenting: updateManager.updateResult
			) { _ in
				Button("View Update") {
					updateManager.showUpdateAlert = false
					updateManager.showUpdateWindow = true
				}
				Button("Later", role: .cancel) {
					updateManager.dismissUpdate()
				}
			} message: { result in
				Text(message(for: result))
			}
	}

	private func message(for result: UpdateCheckResult) -> String {
		var lines: [String] = [
			"\(result.latestVersion) is available (you have \(updateManager.currentVersion))."
		]
		if let changelog = result.changelog, !changelog.isEmpty {
			lines.append(changelog)
		}
		return lines.joined(separator: "\n\n")
	}
}

extension View {
	/// Attach an update alert and software-update window driven by the given manager.
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
