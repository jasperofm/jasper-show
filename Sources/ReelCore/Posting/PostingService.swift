import Foundation

public enum PostingError: Error, LocalizedError {
    case notExported, exportMissing, accountNotConnected(String), alreadyRunning, alreadyPosted, notFound

    public var errorDescription: String? {
        switch self {
        case .notExported: return "Export this variation (with its latest edits) before posting."
        case .exportMissing: return "The exported file is missing. Export the variation again."
        case .accountNotConnected(let n): return "\(n) isn't connected. Reconnect it from the sidebar."
        case .alreadyRunning: return "This post is already uploading."
        case .alreadyPosted: return "This variation was already posted to this account."
        case .notFound: return "Post not found."
        }
    }
}

/// Runs post jobs against the platform clients and records every attempt.
///
/// Phase 1 calls `send` when the user clicks Post. Phase 2's scheduler calls
/// the same `send` for jobs returned by `LibraryStore.dueJobs()`, so manual,
/// scheduled and retried posts share one code path, one rate limiter and one
/// attempt log.
@MainActor
public final class PostingService {
    private let store: LibraryStore
    private let accounts: AccountService
    private let limiter: RateLimiter
    public let retryPolicy: RetryPolicy
    /// Off in Phase 1: failures wait for a manual retry. Phase 2 turns it on
    /// and the scheduler picks up `nextAttemptAt`.
    public var automaticRetry: Bool
    /// Longest we'll hold a manual send for the rate limiter before failing it instead.
    public var maxInlineWait: TimeInterval = 90

    private var running: Set<UUID> = []
    public var onChange: (() -> Void)?
    public var onProgress: ((UUID, PublishStage) -> Void)?

    public init(store: LibraryStore, accounts: AccountService, limiter: RateLimiter = RateLimiter(),
                retryPolicy: RetryPolicy = RetryPolicy(), automaticRetry: Bool = false) {
        self.store = store; self.accounts = accounts; self.limiter = limiter
        self.retryPolicy = retryPolicy; self.automaticRetry = automaticRetry
    }

    public func isRunning(_ jobID: UUID) -> Bool { running.contains(jobID) }

    /// Assigns a variation to accounts. Existing assignments are reused, so
    /// assigning twice doesn't create duplicate jobs.
    @discardableResult
    public func assign(variation: Variation, to targets: [Account], caption: String, title: String = "",
                       privacy: PostPrivacy = .publicAudience, batchID: UUID? = nil) throws -> [PostJob] {
        let existing = try store.jobs().filter { $0.variationID == variation.id }
        var out: [PostJob] = []
        for account in targets {
            if var j = existing.first(where: { $0.accountID == account.id && $0.status != .cancelled }) {
                if j.status != .posted && !j.status.isActive {
                    j.caption = caption
                    j.title = title
                    j.privacy = privacy
                    j.updatedAt = Date()
                    try store.upsert(j)
                }
                out.append(j)
            } else {
                let j = PostJob(variationID: variation.id, accountID: account.id, caption: caption,
                                title: title, privacy: privacy, batchID: batchID)
                try store.upsert(j)
                out.append(j)
            }
        }
        onChange?()
        return out
    }

    public func cancel(_ job: PostJob) throws {
        guard !running.contains(job.id) else { throw PostingError.alreadyRunning }
        var j = job
        j.status = .cancelled
        j.nextAttemptAt = nil
        j.updatedAt = Date()
        try store.upsert(j)
        onChange?()
    }

    /// Sends one job now. Never throws: the outcome is written to the job
    /// (status, lastError) and the attempt log, and the updated job returned.
    @discardableResult
    public func send(jobID: UUID) async -> PostJob? {
        guard var job = try? store.job(id: jobID) else { return nil }
        if running.contains(jobID) { return job }
        running.insert(jobID)
        defer { running.remove(jobID); onChange?() }

        let attemptID = try? store.beginAttempt(jobID: jobID)
        func fail(_ error: Error) -> PostJob {
            let pe = error as? PlatformError
            job.attemptCount += 1
            job.status = .failed
            job.lastError = error.localizedDescription
            job.nextAttemptAt = automaticRetry
                ? retryPolicy.nextAttempt(afterFailureNumber: job.attemptCount, error: pe)
                : nil
            job.updatedAt = Date()
            try? store.upsert(job)
            if let attemptID {
                try? store.finishAttempt(id: attemptID, succeeded: false, httpStatus: pe?.httpStatus,
                                         message: error.localizedDescription)
            }
            return job
        }

        do {
            if job.status == .posted { throw PostingError.alreadyPosted }
            guard let variation = try store.variation(id: job.variationID) else { throw PostingError.notFound }
            guard let account = try store.accounts().first(where: { $0.id == job.accountID }) else { throw PostingError.notFound }
            guard account.status == .connected else { throw PostingError.accountNotConnected(account.username) }
            guard let exportPath = variation.exportPath, !variation.needsExport else { throw PostingError.notExported }
            let fileURL = store.url(forRelative: exportPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw PostingError.exportMissing }

            let wait = await limiter.waitTime(for: account)
            if wait > maxInlineWait {
                throw PlatformError(platform: account.platform, httpStatus: 429,
                                    message: "Rate limited; try again in \(Int(wait / 60) + 1) min.", retryAfter: wait)
            }
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

            let tokens = try await accounts.validTokens(for: account)
            job.status = .uploading
            job.updatedAt = Date()
            try store.upsert(job)
            onChange?()

            await limiter.recordCall(for: account)
            let request = PublishRequest(videoURL: fileURL, caption: job.caption,
                                         title: job.title.isEmpty ? variation.name : job.title,
                                         privacy: job.privacy, account: account)
            let client = accounts.client(for: account.platform)
            let result: PublishResult
            do {
                result = try await client.publish(request, tokens: tokens) { stage in
                    Task { @MainActor in self.onProgress?(jobID, stage) }
                }
            } catch let e as PlatformError {
                if let ra = e.retryAfter ?? (e.httpStatus == 429 ? 900 : nil) { await limiter.block(account, for: ra) }
                if e.requiresReauth { try? accounts.mark(account, .error, "Sign-in expired. Reconnect this account.") }
                throw e
            }

            job.attemptCount += 1
            job.status = .posted
            job.remotePostID = result.remotePostID
            job.remoteURL = result.url
            job.lastError = nil
            job.nextAttemptAt = nil
            job.postedAt = Date()
            job.updatedAt = Date()
            try store.upsert(job)
            if let attemptID {
                try? store.finishAttempt(id: attemptID, succeeded: true, httpStatus: 200,
                                         message: "Posted \(result.remotePostID)")
            }
            return job
        } catch {
            return fail(error)
        }
    }
}
