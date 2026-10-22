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
/// "Post now" and the `PostScheduler` both call `send`, so manual, scheduled
/// and retried posts share one code path, one rate limiter and one attempt log.
@MainActor
public final class PostingService {
    private let store: LibraryStore
    private let accounts: AccountService
    private let limiter: RateLimiter
    public let retryPolicy: RetryPolicy
    /// When on, a failed post gets a `nextAttemptAt` from `retryPolicy`
    /// (1, 5, 15 min) and the scheduler retries it. After the last retry it
    /// waits in the tracker for a manual retry.
    public var automaticRetry: Bool
    /// Longest we'll hold a manual send for the rate limiter before failing it instead.
    public var maxInlineWait: TimeInterval = 90

    private var running: Set<UUID> = []
    public var onChange: (() -> Void)?
    public var onProgress: ((UUID, PublishStage) -> Void)?
    /// Called after every attempt with the updated job.
    public var onFinished: ((PostJob) -> Void)?

    public init(store: LibraryStore, accounts: AccountService, limiter: RateLimiter = RateLimiter(),
                retryPolicy: RetryPolicy = RetryPolicy(), automaticRetry: Bool = true) {
        self.store = store; self.accounts = accounts; self.limiter = limiter
        self.retryPolicy = retryPolicy; self.automaticRetry = automaticRetry
    }

    public func isRunning(_ jobID: UUID) -> Bool { running.contains(jobID) }

    /// Assigns a variation to accounts. Existing assignments are reused, so
    /// assigning twice doesn't create duplicate jobs.
    @discardableResult
    public func assign(variation: Variation, to targets: [Account], caption: String, title: String = "",
                       privacy: PostPrivacy = .publicAudience, overlay: TextOverlay? = nil,
                       batchID: UUID? = nil) throws -> [PostJob] {
        let existing = try store.jobs().filter { $0.variationID == variation.id }
        var out: [PostJob] = []
        for account in targets {
            if var j = existing.first(where: { $0.accountID == account.id && $0.status != .cancelled }) {
                if j.status != .posted && !j.status.isActive {
                    j.caption = caption
                    j.title = title
                    j.privacy = privacy
                    j.overlay = overlay
                    j.updatedAt = Date()
                    try store.upsert(j)
                }
                out.append(j)
            } else {
                let j = PostJob(variationID: variation.id, accountID: account.id, caption: caption,
                                title: title, privacy: privacy, overlay: overlay, batchID: batchID)
                try store.upsert(j)
                out.append(j)
            }
        }
        onChange?()
        return out
    }

    /// Schedules jobs: `dates[i]` is when `jobs[i]` goes out. Jobs already
    /// posted or uploading are skipped. All scheduled jobs share one batch id.
    @discardableResult
    public func schedule(_ jobs: [PostJob], at dates: [Date]) throws -> UUID {
        let batch = UUID()
        for (job, date) in zip(jobs, dates) {
            guard var j = try store.job(id: job.id), j.status != .posted, !running.contains(j.id) else { continue }
            j.status = .scheduled
            j.scheduledAt = date
            j.nextAttemptAt = nil
            j.batchID = batch
            j.updatedAt = Date()
            try store.upsert(j)
        }
        onChange?()
        return batch
    }

    /// Takes a job off the schedule; it goes back to pending.
    public func unschedule(_ job: PostJob) throws {
        guard var j = try store.job(id: job.id), j.status == .scheduled || j.status == .failed else { return }
        j.status = .pending
        j.scheduledAt = nil
        j.nextAttemptAt = nil
        j.updatedAt = Date()
        try store.upsert(j)
        onChange?()
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

    /// Renders this account's copy of the variation with its own on-screen
    /// text. Reuses the file if neither the job nor the variation changed since.
    private func renderWithOverlay(job: PostJob, variation: Variation, overlay: TextOverlay) async throws -> URL {
        guard let asset = try store.asset(id: variation.assetID) else { throw PostingError.notFound }
        let out = store.url(forRelative: "Exports/job-\(job.id.uuidString).mp4")
        let fm = FileManager.default
        if let made = (try? fm.attributesOfItem(atPath: out.path))?[.modificationDate] as? Date,
           made > job.updatedAt, made > (variation.exportedAt ?? .distantPast) {
            return out
        }
        var settings = variation.settings
        settings.overlay = overlay
        let jobID = job.id
        onProgress?(jobID, .rendering(0))
        try await VideoExporter().export(sourceURL: store.url(forRelative: asset.relativePath), settings: settings,
                                         preset: variation.exportPreset ?? .high, to: out) { p in
            Task { @MainActor in self.onProgress?(jobID, .rendering(p)) }
        }
        return out
    }

    /// Sends one job now. Never throws: the outcome is written to the job
    /// (status, lastError) and the attempt log, and the updated job returned.
    @discardableResult
    public func send(jobID: UUID) async -> PostJob? {
        guard var job = try? store.job(id: jobID) else { return nil }
        if running.contains(jobID) || job.status == .cancelled { return job }
        running.insert(jobID)
        defer {
            running.remove(jobID)
            onChange?()
            if let done = try? store.job(id: jobID) { onFinished?(done) }
        }

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
            var fileURL = store.url(forRelative: exportPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw PostingError.exportMissing }
            if let overlay = job.overlay, !overlay.isEmpty {
                fileURL = try await renderWithOverlay(job: job, variation: variation, overlay: overlay)
            }

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
