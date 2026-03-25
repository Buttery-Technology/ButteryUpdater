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
	case installFailed(String)

	public var errorDescription: String? {
		switch self {
		case .checkFailed(let msg): "Update check failed: \(msg)"
		case .invalidURL(let url): "Invalid download URL: \(url)"
		case .downloadFailed(let msg): "Download failed: \(msg)"
		case .sizeMismatch(let expected, let actual): "File size mismatch: expected \(expected), got \(actual)"
		case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), got \(actual)"
		case .installFailed(let msg): "Install failed: \(msg)"
		}
	}
}
