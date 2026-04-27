//
//  ProgressThrottle.swift
//  ButteryUpdater
//
//  Filter for high-frequency progress callbacks. URLSession's download
//  delegate fires per-write (often thousands of times per download). Hopping
//  each event to the main actor would burn Tasks; this lets the @Sendable
//  callback decide whether the change is worth reporting before scheduling
//  any work.
//

import Foundation

/// Drops progress updates that don't move the needle by at least `threshold`.
/// Always reports the terminal `>= 1.0` event and the first event after init.
public final class ProgressThrottle: @unchecked Sendable {
	private let lock = NSLock()
	private var last: Double = -1.0
	private let threshold: Double

	public init(threshold: Double = 0.005) {
		self.threshold = threshold
	}

	public func shouldReport(_ value: Double) -> Bool {
		lock.lock(); defer { lock.unlock() }
		if value >= 1.0 || abs(value - last) >= threshold {
			last = value
			return true
		}
		return false
	}
}
