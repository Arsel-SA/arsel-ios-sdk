import XCTest
@testable import Arsel

/// Pin the jitter so the curve itself can be asserted.
private let noJitter: () -> Double = { 0 }
private let maxJitter: () -> Double = { 0.999999 }

final class RetryPolicyTests: XCTestCase {
    func testDoublesFromTheBase() {
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 1, retryAfterMs: nil, random: noJitter),
            RetryPolicy.baseBackoffMs)
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 2, retryAfterMs: nil, random: noJitter),
            RetryPolicy.baseBackoffMs * 2)
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 3, retryAfterMs: nil, random: noJitter),
            RetryPolicy.baseBackoffMs * 4)
    }

    func testCapsRatherThanGrowingWithoutBound() {
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 50, retryAfterMs: nil, random: noJitter),
            RetryPolicy.maxBackoffMs)
    }

    /// The whole point: foreground and reachability fire on every device at
    /// once, so an exact curve returns a synchronized fleet to the server.
    func testAddsJitterAndNeverSubtracts() {
        let base = RetryPolicy.baseBackoffMs
        let jittered = RetryPolicy.backoffMs(attempt: 1, retryAfterMs: nil, random: maxJitter)

        XCTAssertGreaterThan(jittered, base)
        XCTAssertLessThanOrEqual(jittered, base + base / 2)
    }

    /// A 60s window reset must not be retried at 5s just because that is where
    /// the curve starts.
    func testRetryAfterIsAFloorNotACeiling() {
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 1, retryAfterMs: 60_000, random: noJitter),
            60_000)
    }

    func testKeepsTheLongerOfTheCurveAndRetryAfter() {
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 6, retryAfterMs: 1_000, random: noJitter),
            RetryPolicy.baseBackoffMs * 32)
    }

    /// Every device throttled inside one window gets the SAME `Retry-After`.
    func testJittersRetryAfterToo() {
        XCTAssertGreaterThan(
            RetryPolicy.backoffMs(attempt: 1, retryAfterMs: 60_000, random: maxJitter),
            60_000)
    }

    func testTreatsNonPositiveAttemptAsTheFirst() {
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: 0, retryAfterMs: nil, random: noJitter),
            RetryPolicy.baseBackoffMs)
        XCTAssertEqual(
            RetryPolicy.backoffMs(attempt: -3, retryAfterMs: nil, random: noJitter),
            RetryPolicy.baseBackoffMs)
    }
}
