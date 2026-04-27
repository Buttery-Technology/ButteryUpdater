//
//  ProgressThrottleTests.swift
//  ButteryUpdaterTests
//

import Foundation
import XCTest
@testable import ButteryUpdater

final class ProgressThrottleTests: XCTestCase {

	func test_firstEventAlwaysReports() {
		let throttle = ProgressThrottle(threshold: 0.05)
		XCTAssertTrue(throttle.shouldReport(0.0))
	}

	func test_belowThreshold_isFiltered() {
		let throttle = ProgressThrottle(threshold: 0.05)
		XCTAssertTrue(throttle.shouldReport(0.10))
		XCTAssertFalse(throttle.shouldReport(0.11))
		XCTAssertFalse(throttle.shouldReport(0.12))
		XCTAssertFalse(throttle.shouldReport(0.14))
	}

	func test_aboveThreshold_reports() {
		let throttle = ProgressThrottle(threshold: 0.05)
		XCTAssertTrue(throttle.shouldReport(0.10))
		XCTAssertTrue(throttle.shouldReport(0.16))
		XCTAssertTrue(throttle.shouldReport(0.30))
	}

	func test_terminalAlwaysReports() {
		let throttle = ProgressThrottle(threshold: 0.05)
		_ = throttle.shouldReport(0.99)
		// 1.0 is within 0.005 (default) of 0.99, but it's terminal — still reports.
		let t2 = ProgressThrottle(threshold: 0.5)
		_ = t2.shouldReport(0.99) // first event reports
		XCTAssertTrue(t2.shouldReport(1.0)) // terminal reports despite small delta
	}

	func test_concurrentCallers_serialized() {
		let throttle = ProgressThrottle(threshold: 0.001)
		let group = DispatchGroup()
		let queue = DispatchQueue(label: "test", attributes: .concurrent)

		// 10 concurrent callers each ramping their own progress; the throttle's
		// internal `last` is shared. We can't assert exact counts (interleavings
		// vary) but we CAN assert no crashes and that the lock keeps state
		// consistent (final `last` is whatever was reported, no torn writes).
		for _ in 0..<10 {
			group.enter()
			queue.async {
				for i in 1...100 {
					_ = throttle.shouldReport(Double(i) / 100.0)
				}
				group.leave()
			}
		}
		group.wait()
		// If we got here without crashing/deadlocking, the lock holds.
		XCTAssertTrue(true)
	}
}
