//
//  CancellableSHATests.swift
//  ButteryUpdaterTests
//
//  Verifies streamingSHA256Hex(of:) honours Task cancellation by aborting
//  mid-stream rather than hashing the full file.
//

import Foundation
import XCTest
@testable import ButteryUpdater

final class CancellableSHATests: XCTestCase {

	private var tempFile: URL!

	override func setUp() {
		super.setUp()
		tempFile = FileManager.default.temporaryDirectory
			.appendingPathComponent("buttery-cancel-sha-\(UUID().uuidString).bin")
		// 64 MB so the full hash is meaningfully slower than an abort.
		let total = 64 * 1024 * 1024
		var data = Data(count: total)
		data.withUnsafeMutableBytes { buf in
			let p = buf.bindMemory(to: UInt8.self)
			for i in 0..<total { p[i] = UInt8((i * 17 + 5) & 0xFF) }
		}
		try? data.write(to: tempFile)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tempFile)
		super.tearDown()
	}

	func test_cancellation_throwsCancellationError() async throws {
		let service = AppUpdateService(serverBaseURL: "http://localhost", appName: "test")
		let fileURL = self.tempFile! // hoist out of the @Sendable Task closure

		// AsyncStream-backed signal so the test can await the thrown error
		// without capturing self/XCTestCase in a Sendable closure.
		let (stream, cont) = AsyncStream.makeStream(of: Result<Void, Error>.self)
		let task = Task<Void, Never> {
			do {
				_ = try await service.streamingSHA256Hex(of: fileURL)
				cont.yield(.success(()))
			} catch {
				cont.yield(.failure(error))
			}
			cont.finish()
		}

		// Cancel quickly; the chunk loop checks Task.isCancelled at the top of
		// each 1 MB pass, so cancellation should be observed within ~1 chunk.
		try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
		task.cancel()

		var observed: Result<Void, Error>?
		for await event in stream {
			observed = event
			break
		}

		switch observed {
		case .failure(let err) where err is CancellationError:
			break // expected
		case .failure(let err):
			XCTFail("Expected CancellationError, got \(err)")
		case .success:
			XCTFail("Expected cancellation, got success")
		case .none:
			XCTFail("Stream ended without an event")
		}
	}

	func test_uncancelled_completesNormally() async throws {
		let service = AppUpdateService(serverBaseURL: "http://localhost", appName: "test")
		let hex = try await service.streamingSHA256Hex(of: tempFile)
		XCTAssertEqual(hex.count, 64) // 256 bits → 64 hex chars
	}
}
