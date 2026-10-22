import Foundation
import AppKit

/// Spreads posts over time: post i goes out at start + i × interval.
public enum StaggerPlanner {
    public static func dates(count: Int, start: Date, interval: TimeInterval) -> [Date] {
        (0..<max(0, count)).map { start.addingTimeInterval(Double($0) * max(0, interval)) }
    }
}

/// Something worth telling the user about, raised by the scheduler.
public enum PublisherAlert: Sendable {
    case morningDigest(String)
    case queueRunningLow(String)
    case signInExpiring(String)
}

/// Runs scheduled posts and automatic retries, in the app or in the
/// background publisher.
///
/// Wakes every 20 seconds (and right after the Mac wakes from sleep). Only
/// the process holding the `PublisherLock` publishes. For each due,
/// approved post it asks `PublishGate` whether the rules allow it now; if
/// so it sends it through `PostingService`, otherwise it marks it held with
/// the reason and when to look again. While anything is scheduled it holds
/// an activity assertion so macOS doesn't idle-sleep, but it never wakes a
/// sleeping Mac.
@MainActor
public final class PostScheduler: PostScheduling {
    private let store: LibraryStore
    private let posting: PostingService
    private let conditions: SystemConditions?
    public let lock: PublisherLock
    private var loop: Task<Void, Never>?
    private var ticking = false
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    public var interval: TimeInterval = 20
    public var calendar = Calendar.current
    public private(set) var isRunning = false
    public private(set) var nextWake: Date?
    /// True while this process is the one publishing.
    public private(set) var isPublisher = false
    public var onStateChange: (() -> Void)?
    public var onAlert: ((PublisherAlert) -> Void)?

    public init(store: LibraryStore, posting: PostingService, conditions: SystemConditions? = nil,
                lock: PublisherLock? = nil) {
        self.store = store
        self.posting = posting
        self.conditions = conditions
        self.lock = lock ?? PublisherLock(directory: store.root)
    }

    /// - Parameter observeWake: tick right after the Mac wakes. The headless
    ///   background publisher passes false and relies on its timer.
    public func start(observeWake: Bool = true) {
        guard loop == nil else { return }
        isRunning = true
        if observeWake {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.tick(now: Date()) }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(now: Date())
                let wait = self?.interval ?? 20
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        onStateChange?()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        isRunning = false
        lock.release()
        isPublisher = false
        updateActivity(hasWork: false)
        onStateChange?()
    }

    public func tick(now: Date) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        if !isPublisher {
            guard lock.tryAcquire() else {
                // The other process is publishing; just keep the display fresh.
                nextWake = try? store.nextWakeDate()
                onStateChange?()
                return
            }
            isPublisher = true
            // Anything left mid-upload by a crash is retried (after a platform check).
            try? store.resetInterruptedJobs(now: now, staleAfter: 30 * 60)
            store.log(.system, "Publisher started (pid \(ProcessInfo.processInfo.processIdentifier)).")
            try? store.pruneEvents(now: now)
        }

        let due = (try? store.dueJobs(now: now)) ?? []
        for job in due {
            if Task.isCancelled { break }
            await runIfAllowed(job, now: Date())
        }
        checkAlerts(now: now)
        nextWake = try? store.nextWakeDate()
        updateActivity(hasWork: nextWake != nil)
        onStateChange?()
    }

    private func runIfAllowed(_ job: PostJob, now: Date) async {
        guard let account = try? store.account(id: job.accountID) else { return }
        let rules = PublishRules.load(from: store)
        let decision = PublishGate.evaluate(job: job, account: account, rules: rules, history: history(for: account, now: now),
                                            system: conditions?.snapshot() ?? SystemSnapshot(), now: now, calendar: calendar)
        switch decision {
        case .allow:
            await posting.send(jobID: job.id)
        case .hold(let reason, let until):
            try? posting.hold(job, reason: reason, until: until ?? now.addingTimeInterval(PublishGate.recheckInterval))
        }
    }

    public func history(for account: Account, now: Date) -> PublishHistory {
        let dayStart = calendar.startOfDay(for: now)
        let accounts = (try? store.accounts()) ?? []
        let samePlatform = accounts.filter { $0.platform == account.platform }
        let platformCount = samePlatform.reduce(0) { $0 + ((try? store.postedCount(accountID: $1.id, since: dayStart)) ?? 0) }
        return PublishHistory(accountPostsToday: (try? store.postedCount(accountID: account.id, since: dayStart)) ?? 0,
                              platformPostsToday: platformCount,
                              globalPostsToday: (try? store.postedCount(since: dayStart)) ?? 0,
                              accountLastPostedAt: try? store.lastPostedAt(accountID: account.id))
    }

    // MARK: Alerts

    /// Morning digest (once a day after 8 am), queue runway and sign-in
    /// expiry warnings (each at most once a day).
    private func checkAlerts(now: Date) {
        let today = Self.dayKey(now, calendar: calendar)
        let hour = calendar.component(.hour, from: now)
        let jobs = (try? store.jobs()) ?? []

        if hour >= 8, (try? store.setting("alert.digest")) != today {
            try? store.setSetting("alert.digest", today)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let upcoming = jobs.filter { [.scheduled, .held].contains($0.status) && ($0.scheduledAt ?? .distantFuture) < dayEnd }.count
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
            let posted = jobs.filter { ($0.postedAt ?? .distantPast) >= yesterday && ($0.postedAt ?? .distantPast) < calendar.startOfDay(for: now) }.count
            let failed = jobs.filter { $0.status == .failed }.count
            let held = jobs.filter { $0.status == .held }.count
            var parts = ["\(upcoming) post\(upcoming == 1 ? "" : "s") scheduled today", "\(posted) published yesterday"]
            if failed > 0 { parts.append("\(failed) need attention") }
            if held > 0 { parts.append("\(held) held by your rules") }
            onAlert?(.morningDigest(parts.joined(separator: ", ") + "."))
        }

        let queued = jobs.filter { $0.isApproved && [.scheduled, .held].contains($0.status) }
        if !queued.isEmpty || jobs.contains(where: { $0.status == .posted }) {
            let last = queued.compactMap(\.scheduledAt).max()
            let runway = (last ?? now).timeIntervalSince(now)
            if runway < 24 * 3600, (try? store.setting("alert.runway")) != today {
                try? store.setSetting("alert.runway", today)
                let msg = queued.isEmpty ? "Nothing is scheduled. Approve and schedule more posts to keep going."
                    : "The queue runs out in about \(max(1, Int(runway / 3600))) hours."
                onAlert?(.queueRunningLow(msg))
            }
        }

        let soon = ((try? store.accounts()) ?? []).filter {
            guard let exp = $0.tokenExpiresAt, $0.status == .connected else { return false }
            return exp.timeIntervalSince(now) < 3 * 24 * 3600
        }
        if !soon.isEmpty, (try? store.setting("alert.signin")) != today {
            try? store.setSetting("alert.signin", today)
            onAlert?(.signInExpiring("Sign-in expires soon for \(soon.map(\.handle).joined(separator: ", ")). Reconnect to keep posting."))
        }
    }

    static func dayKey(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func updateActivity(hasWork: Bool) {
        if hasWork, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Reel Manager has scheduled posts")
        } else if !hasWork, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
}
