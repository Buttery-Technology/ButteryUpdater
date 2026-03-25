//
//  UpdateCheckResult.swift
//  ButteryUpdater
//

import Foundation

/// The result of checking for an available update.
public struct UpdateCheckResult: Sendable {
	/// Whether a newer version is available.
	public let updateAvailable: Bool
	/// The version the client is currently running.
	public let currentVersion: String
	/// The latest available version on the server.
	public let latestVersion: String
	/// Release notes / changelog for the latest version.
	public let changelog: String?
	/// Direct download URL for the binary (GCS).
	public let downloadURL: String?
	/// Expected SHA-256 hex checksum of the binary.
	public let expectedChecksum: String?
	/// Expected file size in bytes.
	public let expectedSize: Int?
	/// Whether this update is mandatory (security patch, breaking change).
	public let mandatory: Bool
	/// Minimum version that can upgrade directly to this release.
	public let minVersion: String?

	public init(
		updateAvailable: Bool,
		currentVersion: String,
		latestVersion: String,
		changelog: String? = nil,
		downloadURL: String? = nil,
		expectedChecksum: String? = nil,
		expectedSize: Int? = nil,
		mandatory: Bool = false,
		minVersion: String? = nil
	) {
		self.updateAvailable = updateAvailable
		self.currentVersion = currentVersion
		self.latestVersion = latestVersion
		self.changelog = changelog
		self.downloadURL = downloadURL
		self.expectedChecksum = expectedChecksum
		self.expectedSize = expectedSize
		self.mandatory = mandatory
		self.minVersion = minVersion
	}
}
