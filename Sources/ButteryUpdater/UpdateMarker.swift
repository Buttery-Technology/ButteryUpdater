//
//  UpdateMarker.swift
//  ButteryUpdater
//
//  Marker file recording an in-progress / just-installed update so the
//  next launch can confirm success and remove the rollback backup.
//

import Foundation

/// On-disk record of a pending update install.
///
/// Written immediately before the bundle swap and the relaunch. The next
/// launch reads it and — if the running version matches `expectedVersion` —
/// removes `backupPath` and clears the marker.
public struct UpdateMarker: Codable, Sendable, Equatable {
	public let appName: String
	public let expectedVersion: String
	public let backupPath: String
	public let installedAt: Date

	public init(appName: String, expectedVersion: String, backupPath: String, installedAt: Date) {
		self.appName = appName
		self.expectedVersion = expectedVersion
		self.backupPath = backupPath
		self.installedAt = installedAt
	}

	/// Path to the marker file for the given app.
	public static func location(for appName: String) -> URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base
			.appendingPathComponent("ButteryUpdater", isDirectory: true)
			.appendingPathComponent(appName, isDirectory: true)
			.appendingPathComponent("pending-update.json")
	}

	public static func read(appName: String) -> UpdateMarker? {
		let url = location(for: appName)
		guard let data = try? Data(contentsOf: url) else { return nil }
		return try? JSONDecoder.iso8601().decode(UpdateMarker.self, from: data)
	}

	public func write() throws {
		let url = Self.location(for: appName)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		let data = try JSONEncoder.iso8601().encode(self)
		try data.write(to: url, options: .atomic)
	}

	public static func clear(appName: String) {
		let url = location(for: appName)
		try? FileManager.default.removeItem(at: url)
	}
}

private extension JSONEncoder {
	static func iso8601() -> JSONEncoder {
		let e = JSONEncoder()
		e.dateEncodingStrategy = .iso8601
		return e
	}
}

private extension JSONDecoder {
	static func iso8601() -> JSONDecoder {
		let d = JSONDecoder()
		d.dateDecodingStrategy = .iso8601
		return d
	}
}
