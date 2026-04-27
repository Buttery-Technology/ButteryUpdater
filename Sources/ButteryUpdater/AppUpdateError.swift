//
//  AppUpdateError.swift
//  ButteryUpdater
//

import Foundation

/// Errors that can occur during the update process.
public enum AppUpdateError: Error, LocalizedError {
	case checkFailed(String)
	case invalidURL(String)
	case downloadFailed(String)
	case sizeMismatch(expected: Int, actual: Int)
	case checksumMismatch(expected: String, actual: String)
	case stagingFailed(String)
	case extractionFailed(String)
	case signatureInvalid(String)
	case translocated(String)
	case permissionDenied(String)
	case userCancelled
	case installFailed(String)
	case relaunchFailed(String)

	public var errorDescription: String? {
		switch self {
		case .checkFailed(let msg): "Update check failed: \(msg)"
		case .invalidURL(let url): "Invalid download URL: \(url)"
		case .downloadFailed(let msg): "Download failed: \(msg)"
		case .sizeMismatch(let expected, let actual): "File size mismatch: expected \(expected), got \(actual)"
		case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), got \(actual)"
		case .stagingFailed(let msg): "Staging failed: \(msg)"
		case .extractionFailed(let msg): "Extraction failed: \(msg)"
		case .signatureInvalid(let msg): "Code signature invalid: \(msg)"
		case .translocated(let path): "Cannot update from a translocated location: \(path). Move the app to /Applications and relaunch."
		case .permissionDenied(let msg): "Permission denied: \(msg)"
		case .userCancelled: "Update cancelled."
		case .installFailed(let msg): "Install failed: \(msg)"
		case .relaunchFailed(let msg): "Relaunch failed: \(msg)"
		}
	}
}
