//
//  StreamingChecksumTests.swift
//  ButteryUpdaterTests
//
//  Verifies streaming SHA-256 matches one-shot SHA-256 across small and
//  larger-than-chunk-size inputs.
//

import Crypto
import Foundation
import XCTest
@testable import ButteryUpdater

final class StreamingChecksumTests: XCTestCase {
	private var tempDir: URL!

	override func setUp() {
		super.setUp()
		tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("ButteryUpdater-checksum-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	override func tearDown() {
		try? FileManager.default.removeItem(at: tempDir)
		super.tearDown()
	}

	private func write(_ data: Data) throws -> URL {
		let url = tempDir.appendingPathComponent(UUID().uuidString)
		try data.write(to: url)
		return url
	}

	private func oneShotHex(_ data: Data) -> String {
		SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
	}

	func test_emptyFile() async throws {
		let data = Data()
		let url = try write(data)
		let service = AppUpdateService(serverBaseURL: "http://localhost", appName: "test")
		let actual = try await service.streamingSHA256Hex(of: url)
		XCTAssertEqual(actual, oneShotHex(data))
	}

	func test_smallFile() async throws {
		let data = Data("hello world".utf8)
		let url = try write(data)
		let service = AppUpdateService(serverBaseURL: "http://localhost", appName: "test")
		let actual = try await service.streamingSHA256Hex(of: url)
		XCTAssertEqual(actual, oneShotHex(data))
	}

	func test_largerThanChunk_8MB() async throws {
		// Larger than the 1 MB streaming chunk, with a non-multiple tail.
		let total = 8 * 1024 * 1024 + 7
		var data = Data(count: total)
		// Fill deterministically so the hash is stable across runs.
		data.withUnsafeMutableBytes { buf in
			let p = buf.bindMemory(to: UInt8.self)
			for i in 0..<total { p[i] = UInt8((i * 31 + 7) & 0xFF) }
		}
		let url = try write(data)

		let service = AppUpdateService(serverBaseURL: "http://localhost", appName: "test")
		let actual = try await service.streamingSHA256Hex(of: url)
		XCTAssertEqual(actual, oneShotHex(data))
	}
}
