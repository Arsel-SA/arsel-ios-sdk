import Foundation

/// Retry pacing, mirrored deliberately in the web and Android SDKs so a fleet
/// behaves the same whichever platform it is on.
///
/// The jitter is the point. Every drain trigger this SDK has — app foreground,
/// reachability, a scheduled retry — fires on every device at the same instant
/// when a network comes back or a backend recovers. An unjittered curve turns
/// that into a synchronized wall of requests precisely when the server is least
/// able to take it, and each rejection re-synchronizes the fleet for the next
/// round.
enum RetryPolicy {
    static let baseBackoffMs: Int64 = 5_000
    static let maxBackoffMs: Int64 = 5 * 60_000

    /// Doubling stops here; `5s << 6` is already past the 5-minute ceiling.
    private static let maxDoublings = 6

    /// How long to wait before retrying, given the attempt number (1-based) and
    /// whatever the server asked for.
    ///
    /// `Retry-After` is a floor, never a ceiling: the server knows when its
    /// window rolls and we must not come back before it. But it is jittered on
    /// top of, because a whole fleet rate-limited inside one window receives the
    /// *same* `Retry-After` and would otherwise return in lockstep the moment it
    /// expires.
    static func backoffMs(
        attempt: Int,
        retryAfterMs: Int64?,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> Int64 {
        let doublings = min(max(attempt, 1) - 1, maxDoublings)
        let exponential = min(baseBackoffMs << doublings, maxBackoffMs)
        let floor = max(retryAfterMs ?? 0, exponential)
        return floor + Int64(random() * Double(floor / 2))
    }
}
