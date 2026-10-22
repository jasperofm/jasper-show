import Foundation

public enum PostingError: Error, LocalizedError {
    case notExported, exportMissing, accountNotConnected(String), alreadyRunning, alreadyPosted, notFound
    case notApproved, paused(String)

    public var errorDescription: String? {
        switch self {
        case .notExported: return "Export this variation (with its latest edits) before posting."
        case .exportMissing: return "The exported file is missing. Export the variation again."
        case .accountNotConnected(let n): return "\(n) isn't connected. Reconnect it from the sidebar."
        case .alreadyRunning: return "This post is already uploading."
        case .alreadyPosted: return "This variation was already posted to this account."
        case .notFound: return "Post not found."
        case .notApproved: return "Approve this post before it can be scheduled or published."
        case .paused(let why): return why
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
    /// Called when repeated failures pause an account.
    public var onAccountPaused: ((Account) -> Void)?

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
                    // Edited content needs approving again.
                    if j.caption != caption || j.title != title || j.privacy != privacy || j.overlay != overlay {
                        j.approvedAt = nil
                        if j.status == .scheduled || j.status == .held {
                            j.status = .pending
                            j.scheduledAt = nil
                            j.nextAttemptAt = nil
                            j.holdReason = nil
                        }
                    }
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
            guard var j = try store.job(id: job.id), j.isApproved, j.status != .posted, !j.status.isActive,
                  !running.contains(j.id) else { continue }
            j.status = .scheduled
            j.holdReason = nil
            j.scheduledAt = date
            j.nextAttemptAt = nil
            j.batchID = batch
            j.updatedAt = Date()
            try store.upsert(j)
            store.log(.schedule, "Scheduled for \(date.formatted(date: .abbreviated, time: .shortened)).",
                      jobID: j.id, accountID: j.accountID)
        }
        onChange?()
        return batch
    }

    /// Marks drafts as approved. Only approved posts can be scheduled or
    /// published; AI-written or queued drafts always need this step.
    public func approve(_ jobs: [PostJob], now: Date = Date()) throws {
        for job in jobs {
            guard var j = try store.job(id: job.id), !j.isApproved, !j.status.isTerminal else { continue }
            j.approvedAt = now
            j.updatedAt = now
            try store.upsert(j)
            store.log(.approval, "Approved for posting.", jobID: j.id, accountID: j.accountID)
        }
        onChange?()
    }

    /// Takes approval back; a scheduled post returns to draft.
    public func unapprove(_ job: PostJob) throws {
        guard var j = try store.job(id: job.id), !j.status.isActive, !j.status.isTerminal else { return }
        j.approvedAt = nil
        j.status = .pending
        j.scheduledAt = nil
        j.nextAttemptAt = nil
        j.holdReason = nil
        j.updatedAt = Date()
        try store.upsert(j)
        onChange?()
    }

    /// A rule or condition is keeping a due post back. Rechecked at `until`.
    public func hold(_ job: PostJob, reason: String, until: Date) throws {
        guard var j = try store.job(id: job.id), !j.status.isActive, !j.status.isTerminal else { return }
        let changed = j.status != .held || j.holdReason != reason
        j.status = .held
        j.holdReason = reason
        j.nextAttemptAt = until
        j.updatedAt = Date()
        try store.upsert(j)
        if changed { store.log(.hold, "Held: \(reason)", jobID: j.id, accountID: j.accountID) }
        if changed { onChange?() }
    }

    /// Forgets where an earlier attempt got to, so the next try starts a
    /// fresh upload. Only for when the user has checked the account and the
    /// post isn't there.
    public func startOver(_ job: PostJob) throws {
        guard !running.contains(job.id) else { throw PostingError.alreadyRunning }
        try store.saveCheckpoint(nil, jobID: job.id)
        store.log(.system, "Starting over: the earlier attempt was checked and discarded.", jobID: job.id, accountID: job.accountID)
        onChange?()
    }

    /// Takes a job off the schedule; it goes back to pending.
    public func unschedule(_ job: PostJob) throws {
        guard var j = try store.job(id: job.id), [.scheduled, .failed, .held].contains(j.status) else { return }
        j.status = .pending
        j.holdReason = nil
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
    /// (status, lastError), the attempt log and the event log, and the
    /// updated job returned.
    ///
    /// Safety: only approved jobs are sent; the kill switch and account
    /// pauses always apply; the job is claimed atomically in the database so
    /// two processes can't send it at once; and a job with a checkpoint is
    /// checked against the platform before anything is uploaded again.
    @discardableResult
    public func send(jobID: UUID) async -> PostJob? {
        guard var job = try? store.job(id: jobID) else { return nil }
        if running.contains(jobID) || job.status == .cancelled || job.status == .posted { return job }
        guard job.isApproved else {
            job.lastError = PostingError.notApproved.localizedDescription
            return job
        }
        let rules = PublishRules.load(from: store)
        let account = try? store.account(id: job.accountID)
        if rules.killSwitch || account?.isPaused == true {
            let why = rules.killSwitch ? "All publishing is paused (kill switch)."
                : "\(account?.handle ?? "This account") is paused" + (account?.pauseReason.map { ": \($0)" } ?? ".")
            try? hold(job, reason: why, until: Date().addingTimeInterval(PublishGate.recheckInterval))
            return try? store.job(id: jobID)
        }
        guard (try? store.claim(jobID: jobID)) == true else { return job }
        running.insert(jobID)
        defer {
            running.remove(jobID)
            onChange?()
            if let done = try? store.job(id: jobID) { onFinished?(done) }
        }
        onChange?()

        let attemptID = try? store.beginAttempt(jobID: jobID)
        func fail(_ error: Error) -> PostJob {
            let pe = error as? PlatformError
            job.attemptCount += 1
            job.status = .failed
            job.holdReason = nil
            job.lastError = Redactor.redact(error.localizedDescription)
            job.nextAttemptAt = automaticRetry
                ? retryPolicy.nextAttempt(afterFailureNumber: job.attemptCount, error: pe)
                : nil
            job.checkpoint = (try? store.job(id: jobID))?.checkpoint
            job.updatedAt = Date()
            try? store.upsert(job)
            if let attemptID {
                try? store.finishAttempt(id: attemptID, succeeded: false, httpStatus: pe?.httpStatus,
                                         message: error.localizedDescription)
            }
            store.log(.failure, "Attempt \(job.attemptCount) failed: \(error.localizedDescription)",
                      jobID: jobID, accountID: job.accountID)
            if pe != nil { recordFailure(accountID: job.accountID, rules: rules, error: pe) }
            return job
        }

        do {
            guard let variation = try store.variation(id: job.variationID) else { throw PostingError.notFound }
            guard let account else { throw PostingError.notFound }
            guard account.status == .connected else { throw PostingError.accountNotConnected(account.handle) }
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
            job.checkpoint = (try? store.job(id: jobID))?.checkpoint
            try store.upsert(job)
            onChange?()

            await limiter.recordCall(for: account)
            let store = self.store
            let request = PublishRequest(videoURL: fileURL, caption: job.caption,
                                         title: job.title.isEmpty ? variation.name : job.title,
                                         privacy: job.privacy, account: account, resume: job.checkpoint,
                                         coverTimeMs: variation.settings.coverTime.map { Int($0 * 1000) },
                                         onCheckpoint: { cp in try? store.saveCheckpoint(cp, jobID: jobID) })
            if job.checkpoint != nil {
                store.log(.system, "Resuming: checking \(account.platform.displayName) for the earlier attempt first.",
                          jobID: jobID, accountID: account.id)
            }
            let client = accounts.client(for: account.platform)
            let result: PublishResult
            do {
                result = try await client.publish(request, tokens: tokens) { stage in
                    Task { @MainActor in self.onProgress?(jobID, stage) }
                }
            } catch let e as PlatformError {
                if let ra = e.retryAfter ?? (e.httpStatus == 429 ? 900 : nil) { await limiter.block(account, for: ra) }
                if e.requiresReauth {
                    try? accounts.pauseForSignIn(account, "Sign-in expired. Reconnect this account.")
                }
                throw e
            }

            job.attemptCount += 1
            job.status = .posted
            job.remotePostID = result.remotePostID
            job.remoteURL = result.url
            job.lastError = nil
            job.holdReason = nil
            job.nextAttemptAt = nil
            job.checkpoint = nil
            job.postedAt = Date()
            job.updatedAt = Date()
            try store.upsert(job)
            if let attemptID {
                try? store.finishAttempt(id: attemptID, succeeded: true, httpStatus: 200,
                                         message: "Posted \(result.remotePostID)")
            }
            store.log(.publish, "Published to \(account.handle) on \(account.platform.displayName).",
                      jobID: jobID, accountID: account.id)
            if var a = try? store.account(id: account.id), a.consecutiveFailures != 0 {
                a.consecutiveFailures = 0
                try? store.upsert(a)
            }
            return job
        } catch {
            return fail(error)
        }
    }

    /// Failure breaker: after `rules.failureLimit` platform failures in a
    /// row, the account is paused until the user resumes it.
    private func recordFailure(accountID: UUID, rules: PublishRules, error: PlatformError?) {
        guard var a = try? store.account(id: accountID) else { return }
        a.consecutiveFailures += 1
        if !a.isPaused, rules.failureLimit > 0, a.consecutiveFailures >= rules.failureLimit {
            a.isPaused = true
            a.pauseReason = "\(a.consecutiveFailures) failed attempts in a row. Check the account, then resume it."
            try? store.upsert(a)
            store.log(.pause, "Paused \(a.handle) after \(a.consecutiveFailures) failures in a row.", accountID: a.id)
            onAccountPaused?(a)
        } else {
            try? store.upsert(a)
        }
    }
}
