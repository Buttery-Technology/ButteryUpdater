//
//  AppUpdateInstallerTests.swift
//  ButteryUpdaterTests
//

import Crypto
import Foundation
import Logging
import XCTest
@testable import ButteryUpdater

final class AppUpdateInstallerTests: XCTestCase {
	private var appName: String = ""
	private var installer: AppUpdateInstaller!
	private var sandboxRoot: URL!

	override func setUp() {
		super.setUp()
		appName = "buttery-test-\(UUID().uuidString)"
		installer = AppUpdateInstaller(appName: appName, logger: Logger(label: "test"))
		sandboxRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("ButteryUpdaterTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: sandboxRoot)
		// Clean any marker that may have been written.
		UpdateMarker.clear(appName: appName)
		// Best-effort cleanup of working directory (may not exist).
		let working = installer.workingDirectory
		try? FileManager.default.removeItem(at: working)
		super.tearDown()
	}

	// MARK: - Translocation guard

	func test_ensureNotTranslocated_acceptsApplicationsPath() throws {
		let bundle = URL(fileURLWithPath: "/Applications/ButteryAI.app")
		XCTAssertNoThrow(try installer.ensureNotTranslocated(currentBundle: bundle))
	}

	func test_ensureNotTranslocated_rejectsTranslocationPath() {
		let bundle = URL(fileURLWithPath: "/private/var/folders/ab/cd/T/AppTranslocation/UUID/d/ButteryAI.app")
		XCTAssertThrowsError(try installer.ensureNotTranslocated(currentBundle: bundle)) { error in
			guard case AppUpdateError.translocated = error else {
				XCTFail("Expected .translocated error, got \(error)")
				return
			}
		}
	}

	// MARK: - Marker round-trip

	func test_marker_writeReadClear() throws {
		let marker = UpdateMarker(
			appName: appName,
			expectedVersion: "1.2.3",
			backupPath: "/tmp/old-bundle.app.backup",
			installedAt: Date()
		)
		try marker.write()

		let read = try XCTUnwrap(UpdateMarker.read(appName: appName))
		XCTAssertEqual(read.appName, marker.appName)
		XCTAssertEqual(read.expectedVersion, marker.expectedVersion)
		XCTAssertEqual(read.backupPath, marker.backupPath)
		XCTAssertEqual(
			read.installedAt.timeIntervalSinceReferenceDate,
			marker.installedAt.timeIntervalSinceReferenceDate,
			accuracy: 1.0
		)

		UpdateMarker.clear(appName: appName)
		XCTAssertNil(UpdateMarker.read(appName: appName))
	}

	// MARK: - Bundle install (unprivileged path)

	/// Build a stand-in `.app` bundle directory containing a marker file so
	/// we can verify post-swap which side is which.
	private func makeFakeBundle(at url: URL, marker: String) throws {
		try? FileManager.default.removeItem(at: url)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		try marker.write(to: url.appendingPathComponent("which.txt"), atomically: true, encoding: .utf8)
	}

	func test_installBundle_unprivileged_swapsAndPreservesBackup() throws {
		let target = sandboxRoot.appendingPathComponent("ButteryAI.app", isDirectory: true)
		let staged = sandboxRoot.appendingPathComponent("staged/ButteryAI.app", isDirectory: true)
		try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)

		try makeFakeBundle(at: target, marker: "old")
		try makeFakeBundle(at: staged, marker: "new")

		try installer.installBundle(staged: staged, target: target, expectedVersion: "9.9.9")

		// Target now contains the new bundle's marker.
		let installedMarker = try String(contentsOf: target.appendingPathComponent("which.txt"), encoding: .utf8)
		XCTAssertEqual(installedMarker, "new")

		// Marker file was written.
		let updateMarker = try XCTUnwrap(UpdateMarker.read(appName: appName))
		XCTAssertEqual(updateMarker.expectedVersion, "9.9.9")

		// Backup exists at the recorded path and contains the OLD bundle.
		let backup = URL(fileURLWithPath: updateMarker.backupPath)
		XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "Backup missing at \(backup.path)")
		let backupMarker = try String(contentsOf: backup.appendingPathComponent("which.txt"), encoding: .utf8)
		XCTAssertEqual(backupMarker, "old")
	}

	func test_confirmRunningVersion_clearsBackupOnVersionMatch() throws {
		let target = sandboxRoot.appendingPathComponent("ButteryAI.app", isDirectory: true)
		let staged = sandboxRoot.appendingPathComponent("staged/ButteryAI.app", isDirectory: true)
		try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
		try makeFakeBundle(at: target, marker: "old")
		try makeFakeBundle(at: staged, marker: "new")

		try installer.installBundle(staged: staged, target: target, expectedVersion: "1.0.0")

		let recorded = try XCTUnwrap(UpdateMarker.read(appName: appName))
		let backup = URL(fileURLWithPath: recorded.backupPath)
		XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

		installer.confirmRunningVersion("1.0.0")

		XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "Backup should be removed on version match")
		XCTAssertNil(UpdateMarker.read(appName: appName), "Marker should be cleared on version match")
	}

	func test_confirmRunningVersion_keepsBackupOnVersionMismatch() throws {
		let target = sandboxRoot.appendingPathComponent("ButteryAI.app", isDirectory: true)
		let staged = sandboxRoot.appendingPathComponent("staged/ButteryAI.app", isDirectory: true)
		try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
		try makeFakeBundle(at: target, marker: "old")
		try makeFakeBundle(at: staged, marker: "new")

		try installer.installBundle(staged: staged, target: target, expectedVersion: "2.0.0")

		let recorded = try XCTUnwrap(UpdateMarker.read(appName: appName))
		let backup = URL(fileURLWithPath: recorded.backupPath)

		installer.confirmRunningVersion("1.0.0") // mismatch

		XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "Backup should remain on version mismatch")
		XCTAssertNotNil(UpdateMarker.read(appName: appName), "Marker should not be cleared on mismatch")

		// Cleanup
		try? FileManager.default.removeItem(at: backup)
	}
}
