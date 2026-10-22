import Foundation

/// Phase 2 seam. A scheduler implements this and is ticked by a timer (and
/// on wake from sleep). Everything it needs already exists:
///
/// - `PostJob.scheduledAt` / `.status = .scheduled` for timed and staggered posts
///   (staggering is just assigning increasing `scheduledAt` across a `batchID`).
/// - `LibraryStore.dueJobs(now:)` returns scheduled jobs that are due and
///   failed jobs whose `nextAttemptAt` has passed.
/// - `PostingService.send(jobID:)` runs a job, logs the attempt, and,
///   with `automaticRetry = true`, sets `nextAttemptAt` from `RetryPolicy`
///   (1, 5, 15 minutes, honoring Retry-After).
/// - `RateLimiter` is shared, so scheduled and manual posts can't overrun limits.
@MainActor
public protocol PostScheduling: AnyObject {
    /// Runs every job that is due at `now`, one at a time.
    func tick(now: Date) async
}
