//
//  SignatureValidationTests.swift
//  ButteryUpdaterTests
//
//  Verifies that an unsigned reference bundle causes verifySignature to skip
//  strict validation, so dev builds can install unsigned updates without
//  needing a code-signing identity.
//

import Foundation
import Logging
import XCTest
@testable import ButteryUpdater

final class SignatureValidationTests: XCTestCase {

	private var sandbox: URL!

	override func setUp() {
		super.setUp()
		sandbox = FileManager.default.temporaryDirectory
			.appendingPathComponent("ButteryUpdater-sig-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: sandbox)
		super.tearDown()
	}

	private func makeBundle(at url: URL) throws {
		// Minimal fake .app structure. SecStaticCodeCreateWithPath will succeed
		// (any directory is acceptable), and the validity check will return
		// errSecCSUnsigned — exactly the condition we want isSigned() to detect.
		try FileManager.default.createDirectory(
			at: url.appendingPathComponent("Contents/MacOS", isDirectory: true),
			withIntermediateDirectories: true
		)
		try Data("fake".utf8).write(to: url.appendingPathComponent("Contents/MacOS/fake"))
	}

	func test_isSigned_returnsFalseForUnsignedBundle() throws {
		let bundle = sandbox.appendingPathComponent("Unsigned.app", isDirectory: true)
		try makeBundle(at: bundle)

		let installer = AppUpdateInstaller(appName: "test", logger: Logger(label: "test"))
		XCTAssertFalse(installer.isSigned(at: bundle))
	}

	func test_verifySignature_skipsWhenReferenceIsUnsigned() throws {
		let staged = sandbox.appendingPathComponent("Staged.app", isDirectory: true)
		let reference = sandbox.appendingPathComponent("Reference.app", isDirectory: true)
		try makeBundle(at: staged)
		try makeBundle(at: reference)

		let installer = AppUpdateInstaller(appName: "test", logger: Logger(label: "test"))
		// Reference is unsigned → verifySignature should return without throwing
		// even though the staged bundle is also unsigned. This is the dev-build
		// install path.
		XCTAssertNoThrow(try installer.verifySignature(at: staged, matchingBundle: reference))
	}
}
