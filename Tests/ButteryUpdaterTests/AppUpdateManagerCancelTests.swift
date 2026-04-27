//
//  AppUpdateManagerCancelTests.swift
//  ButteryUpdaterTests
//
//  Verifies cancelInProgressUpdate's phase guard: only .downloading /
//  .verifying / .staging actually cancel; everything else is a no-op so a
//  late click can't clobber a terminal state.
//

import Foundation
import XCTest
@testable import ButteryUpdater
@testable import ButteryUpdaterUI

@MainActor
final class AppUpdateManagerCancelTests: XCTestCase {

	private func makeManager() -> AppUpdateManager {
		// Service URL is irrelevant — these tests never trigger the network.
		let service = AppUpdateService(
			serverBaseURL: "http://127.0.0.1",
			appName: "cancel-test-\(UUID().uuidString)"
		)
		return AppUpdateManager(service: service)
	}

	// MARK: - Cancellable phases

	func test_cancel_appliesDuringDownloading() async {
		let manager = makeManager()
		manager.state = .downloading(progress: 0.5)
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "cancelled")
	}

	func test_cancel_appliesDuringVerifying() async {
		let manager = makeManager()
		manager.state = .verifying
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "cancelled")
	}

	func test_cancel_appliesDuringStaging() async {
		let manager = makeManager()
		manager.state = .staging
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "cancelled")
	}

	// MARK: - Non-cancellable phases

	func test_cancel_noopsWhenIdle() async {
		let manager = makeManager()
		manager.state = .idle
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "idle")
	}

	func test_cancel_noopsWhenInstalling() async {
		let manager = makeManager()
		manager.state = .installing
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "installing")
	}

	func test_cancel_noopsWhenRelaunching() async {
		let manager = makeManager()
		manager.state = .relaunching
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "relaunching")
	}

	func test_cancel_noopsWhenReadyToInstall() async {
		let manager = makeManager()
		let path = URL(fileURLWithPath: "/tmp/staged.app")
		manager.state = .readyToInstall(localPath: path)
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "readyToInstall")
	}

	func test_cancel_noopsWhenFailed() async {
		let manager = makeManager()
		manager.state = .failed("network down")
		await manager.cancelInProgressUpdate()
		XCTAssertEqual(stateName(manager.state), "failed")
	}

	// MARK: - Helpers

	private func stateName(_ state: AppUpdateState) -> String {
		switch state {
		case .idle: "idle"
		case .checking: "checking"
		case .updateAvailable: "updateAvailable"
		case .downloading: "downloading"
		case .verifying: "verifying"
		case .staging: "staging"
		case .readyToInstall: "readyToInstall"
		case .installing: "installing"
		case .relaunching: "relaunching"
		case .cancelled: "cancelled"
		case .failed: "failed"
		}
	}
}
