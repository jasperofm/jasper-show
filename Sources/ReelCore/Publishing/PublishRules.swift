import Foundation

/// The user's limits for unattended publishing. Stored in the database
/// (`settings` table) so the app and the background publisher share them.
public struct PublishRules: Codable, Equatable, Sendable {
    /// Global kill switch: nothing is published while this is on.
    public var killSwitch = false
    /// Most posts per account per day (the user's local day). 0 = no limit.
    public var perAccountDailyCap = 3
    /// Most posts across all accounts per day. 0 = no limit.
    public var globalDailyCap = 20
    /// Minimum minutes between two posts on the same account.
    public var minGapMinutes = 60
    /// Optional per-platform daily limits, on top of the platform's own.
    public var platformDailyCaps: [Platform: Int] = [:]
    /// Platforms paused as a whole.
    public var pausedPlatforms: Set<Platform> = []
    /// Only publish inside this daily window (local time). Nil = any time.
    public var postingWindow: DailyWindow? = nil
    /// Never publish inside these windows (local time), e.g. overnight.
    public var blackoutWindows: [DailyWindow] = []
    /// Pause an account after this many failed attempts in a row.
    public var failureLimit = 3
    public var pauseOnLowBattery = true
    /// Battery percentage below which publishing waits (when not charging).
    public var lowBatteryPercent = 20
    public var pauseWhenOffline = true
    /// Free disk space (GB) below which publishing waits.
    public var minFreeDiskGB = 2.0

    public init() {}

    /// Missing keys keep their defaults, so rules saved by an older version
    /// still load after new rules are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        let d = PublishRules()
        killSwitch = v(.killSwitch, d.killSwitch)
        perAccountDailyCap = v(.perAccountDailyCap, d.perAccountDailyCap)
        globalDailyCap = v(.globalDailyCap, d.globalDailyCap)
        minGapMinutes = v(.minGapMinutes, d.minGapMinutes)
        platformDailyCaps = v(.platformDailyCaps, d.platformDailyCaps)
        pausedPlatforms = v(.pausedPlatforms, d.pausedPlatforms)
        postingWindow = v(.postingWindow, d.postingWindow)
        blackoutWindows = v(.blackoutWindows, d.blackoutWindows)
        failureLimit = v(.failureLimit, d.failureLimit)
        pauseOnLowBattery = v(.pauseOnLowBattery, d.pauseOnLowBattery)
        lowBatteryPercent = v(.lowBatteryPercent, d.lowBatteryPercent)
        pauseWhenOffline = v(.pauseWhenOffline, d.pauseWhenOffline)
        minFreeDiskGB = v(.minFreeDiskGB, d.minFreeDiskGB)
    }

    public static let settingsKey = "publish.rules"

    public static func load(from store: LibraryStore) -> PublishRules {
        store.setting(settingsKey, as: PublishRules.self) ?? PublishRules()
    }

    public func save(to store: LibraryStore) throws {
        try store.setSetting(Self.settingsKey, encoding: self)
    }
}

/// A time-of-day range in minutes after local midnight. If `end < start`
/// the window crosses midnight (e.g. 23:00–06:00).
public struct DailyWindow: Codable, Equatable, Hashable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = max(0, min(1439, startMinute))
        self.endMinute = max(0, min(1440, endMinute))
    }

    public init(start: (Int, Int), end: (Int, Int)) {
        self.init(startMinute: start.0 * 60 + start.1, endMinute: end.0 * 60 + end.1)
    }

    public var crossesMidnight: Bool { endMinute < startMinute }

    public func contains(minute m: Int) -> Bool {
        crossesMidnight ? (m >= startMinute || m < endMinute) : (m >= startMinute && m < endMinute)
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        contains(minute: Self.minuteOfDay(date, calendar: calendar))
    }

    /// Next moment at or after `date` when the window ends (if inside) or
    /// starts (if outside).
    public func nextBoundary(after date: Date, edge: Edge, calendar: Calendar) -> Date {
        let target = edge == .start ? startMinute : endMinute % 1440
        let day = calendar.startOfDay(for: date)
        var candidate = calendar.date(byAdding: .minute, value: target, to: day) ?? date
        if candidate <= date { candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? date }
        return candidate
    }

    public enum Edge { case start, end }

    public var label: String {
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
        return "\(hm(startMinute))–\(hm(endMinute))"
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// What the Mac is doing right now, as far as publishing cares.
public struct SystemSnapshot: Equatable, Sendable {
    public var batteryPercent: Int?
    public var onBattery: Bool
    public var online: Bool
    public var freeDiskGB: Double?

    public init(batteryPercent: Int? = nil, onBattery: Bool = false, online: Bool = true, freeDiskGB: Double? = nil) {
        self.batteryPercent = batteryPercent; self.onBattery = onBattery
        self.online = online; self.freeDiskGB = freeDiskGB
    }
}

/// Counts the gate needs, read from the store.
public struct PublishHistory: Sendable {
    public var accountPostsToday: Int
    public var platformPostsToday: Int
    public var globalPostsToday: Int
    public var accountLastPostedAt: Date?

    public init(accountPostsToday: Int = 0, platformPostsToday: Int = 0, globalPostsToday: Int = 0,
                accountLastPostedAt: Date? = nil) {
        self.accountPostsToday = accountPostsToday; self.platformPostsToday = platformPostsToday
        self.globalPostsToday = globalPostsToday; self.accountLastPostedAt = accountLastPostedAt
    }
}

/// Decides whether a due, approved post may go out now. Pure: no I/O, so it
/// is fully unit-tested. When it says hold, it gives a reason the user can
/// read and, where it can know, when to look again.
public enum PublishGate {
    public enum Decision: Equatable {
        case allow
        case hold(reason: String, until: Date?)

        public var isAllowed: Bool { self == .allow }
    }

    /// How long to wait before rechecking a hold that has no known end
    /// (a pause, offline, low battery).
    public static let recheckInterval: TimeInterval = 5 * 60

    public static func evaluate(job: PostJob, account: Account, rules: PublishRules, history: PublishHistory,
                                system: SystemSnapshot, now: Date, calendar: Calendar = .current) -> Decision {
        guard job.isApproved else { return .hold(reason: "Not approved yet.", until: nil) }
        if rules.killSwitch { return .hold(reason: "All publishing is paused (kill switch).", until: nil) }
        if account.isPaused {
            return .hold(reason: "\(account.handle) is paused" + (account.pauseReason.map { ": \($0)" } ?? "."), until: nil)
        }
        if account.status != .connected {
            return .hold(reason: "\(account.handle) needs to be reconnected.", until: nil)
        }
        if rules.pausedPlatforms.contains(account.platform) {
            return .hold(reason: "\(account.platform.displayName) is paused.", until: nil)
        }

        // System conditions.
        if rules.pauseWhenOffline && !system.online {
            return .hold(reason: "Waiting for an internet connection.", until: now.addingTimeInterval(recheckInterval))
        }
        if rules.pauseOnLowBattery, system.onBattery, let pct = system.batteryPercent, pct < rules.lowBatteryPercent {
            return .hold(reason: "Battery is low (\(pct)%). Plug in to keep publishing.", until: now.addingTimeInterval(recheckInterval))
        }
        if let free = system.freeDiskGB, free < rules.minFreeDiskGB {
            return .hold(reason: String(format: "Disk space is low (%.1f GB free).", free), until: now.addingTimeInterval(recheckInterval))
        }

        // Time windows.
        for b in rules.blackoutWindows where b.contains(now, calendar: calendar) {
            return .hold(reason: "Inside a quiet window (\(b.label)).",
                         until: b.nextBoundary(after: now, edge: .end, calendar: calendar))
        }
        if let w = rules.postingWindow, !w.contains(now, calendar: calendar) {
            return .hold(reason: "Outside the posting window (\(w.label)).",
                         until: w.nextBoundary(after: now, edge: .start, calendar: calendar))
        }

        // Caps and spacing.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        if rules.globalDailyCap > 0, history.globalPostsToday >= rules.globalDailyCap {
            return .hold(reason: "Daily limit for all accounts reached (\(rules.globalDailyCap)).", until: tomorrow)
        }
        if let cap = rules.platformDailyCaps[account.platform], cap > 0, history.platformPostsToday >= cap {
            return .hold(reason: "Daily \(account.platform.displayName) limit reached (\(cap)).", until: tomorrow)
        }
        if rules.perAccountDailyCap > 0, history.accountPostsToday >= rules.perAccountDailyCap {
            return .hold(reason: "\(account.handle) reached its daily limit (\(rules.perAccountDailyCap)).", until: tomorrow)
        }
        if rules.minGapMinutes > 0, let last = history.accountLastPostedAt {
            let next = last.addingTimeInterval(Double(rules.minGapMinutes) * 60)
            if next > now {
                return .hold(reason: "Keeping \(rules.minGapMinutes) min between posts on \(account.handle).", until: next)
            }
        }
        return .allow
    }

    /// Posts scheduled when the Mac is likely asleep (1–6 am local) may be
    /// late: the app never wakes the Mac by itself.
    public static func isInLikelySleepWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let h = calendar.component(.hour, from: date)
        return h >= 1 && h < 6
    }
}
