//
//  AppUpdateState.swift
//  ButteryUpdater
//

import Foundation

/// Represents the current state of the update lifecycle.
public enum AppUpdateState: Sendable {
	case idle
	case checking
	case updateAvailable(UpdateCheckResult)
	case downloading(progress: Double)
	case verifying
	case readyToInstall(localPath: URL)
	case installing
	case failed(String)
}
