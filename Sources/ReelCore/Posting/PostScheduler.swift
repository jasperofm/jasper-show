import Foundation
import AppKit

/// Spreads posts over time: post i goes out at start + i × interval.
public enum StaggerPlanner {
    public static func dates(count: Int, start: Date, interval: TimeInterval) -> [Date] {
        (0..<max(0, count)).map { start.addingTimeInterval(Double($0) * max(0, interval)) }
    }
}

/// Runs scheduled posts and automatic retries while the app is open.
///
/// Wakes every 20 seconds (and right after the Mac wakes from sleep), asks
/// the store for due jobs and sends them one at a time through
/// `PostingService`, which logs each attempt and sets the next retry.
/// While anything is scheduled it holds an activity assertion so macOS
/// doesn't put the Mac to idle sleep and miss a post.
@MainActor
public final class PostScheduler: PostScheduling {
    private let store: LibraryStore
    private let posting: PostingService
    private var loop: Task<Void, Never>?
    private var ticking = false
    private var activity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    public var interval: TimeInterval = 20
    public private(set) var isRunning = false
    public private(set) var nextWake: Date?
    public var onStateChange: (() -> Void)?

    public init(store: LibraryStore, posting: PostingService) {
        self.store = store
        self.posting = posting
    }

    public func start() {
        guard loop == nil else { return }
        isRunning = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick(now: Date()) }
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
        updateActivity(hasWork: false)
        onStateChange?()
    }

    public func tick(now: Date) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        let due = (try? store.dueJobs(now: now)) ?? []
        for job in due {
            if Task.isCancelled { break }
            await posting.send(jobID: job.id)
        }
        nextWake = try? store.nextWakeDate()
        updateActivity(hasWork: nextWake != nil)
        onStateChange?()
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
