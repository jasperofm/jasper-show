import Foundation

/// When to try a failed post again. Phase 1 only uses it to show "retry
/// available"; the Phase 2 scheduler reads `nextAttempt` to retry on its own.
public struct RetryPolicy: Sendable, Equatable {
    /// Delay before automatic attempt n+1 after n failures (1-based).
    public var delays: [TimeInterval]

    public init(delays: [TimeInterval] = [60, 300, 900]) { self.delays = delays }

    public var maxAutomaticRetries: Int { delays.count }

    /// Time for the next automatic retry, or nil when the job should wait
    /// for the user (non-retryable error, or retries used up).
    /// A server's Retry-After is honored when it is longer than our delay.
    public func nextAttempt(afterFailureNumber n: Int, error: PlatformError?, now: Date = Date()) -> Date? {
        if let error, !error.isRetryable { return nil }
        guard n >= 1, n <= delays.count else { return nil }
        let delay = max(delays[n - 1], error?.retryAfter ?? 0)
        return now.addingTimeInterval(delay)
    }
}

/// Per-account spacing between API calls plus a block set by 429 responses.
/// Shared by manual posting now and the scheduler later, so both respect
/// the same limits.
public actor RateLimiter {
    private var lastCall: [UUID: Date] = [:]
    private var blockedUntil: [UUID: Date] = [:]
    private let minSpacing: [Platform: TimeInterval]

    public init(minSpacing: [Platform: TimeInterval] = [.instagram: 30, .tiktok: 30, .youtube: 30]) {
        self.minSpacing = minSpacing
    }

    /// Seconds the caller must wait before posting to `account`.
    public func waitTime(for account: Account, now: Date = Date()) -> TimeInterval {
        var wait: TimeInterval = 0
        if let last = lastCall[account.id] {
            wait = max(wait, (minSpacing[account.platform] ?? 0) - now.timeIntervalSince(last))
        }
        if let blocked = blockedUntil[account.id] { wait = max(wait, blocked.timeIntervalSince(now)) }
        return max(0, wait)
    }

    public func recordCall(for account: Account, at now: Date = Date()) { lastCall[account.id] = now }

    public func block(_ account: Account, for seconds: TimeInterval, now: Date = Date()) {
        blockedUntil[account.id] = now.addingTimeInterval(seconds)
    }
}
