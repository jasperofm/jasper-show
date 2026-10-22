import Foundation

/// Assigns approved, unscheduled posts to the next free posting slots,
/// without breaking the user's rules. Pure, so the preview the user sees is
/// exactly what gets scheduled. It never approves anything: drafts are skipped.
public enum SlotPlanner {
    public struct Planned: Equatable, Sendable {
        public var jobID: UUID
        public var date: Date?
        /// Why no slot was found, when `date` is nil.
        public var problem: String?
    }

    /// - Parameters:
    ///   - jobs: posts to place, in priority order.
    ///   - existing: every other job (used for what's already scheduled or posted).
    ///   - horizonDays: how far ahead to look for free slots.
    public static func plan(_ jobs: [PostJob], existing: [PostJob], accounts: [Account], schedule: SlotSchedule,
                            rules: PublishRules, from: Date, horizonDays: Int = 60) -> [Planned] {
        let cal = schedule.calendar
        let to = cal.date(byAdding: .day, value: horizonDays, to: from) ?? from
        let accountByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let placing = Set(jobs.map(\.id))

        // Times already taken, per account, plus every taken time for the global cap.
        var taken: [UUID: [Date]] = [:]
        var all: [Date] = []
        for j in existing where !placing.contains(j.id) {
            let t: Date?
            switch j.status {
            case .scheduled, .held, .uploading, .processing: t = j.scheduledAt
            case .posted: t = j.postedAt
            default: t = nil
            }
            guard let t else { continue }
            taken[j.accountID, default: []].append(t)
            all.append(t)
        }

        var out: [Planned] = []
        for job in jobs {
            guard job.isApproved else {
                out.append(Planned(jobID: job.id, date: nil, problem: "Draft: approve it first."))
                continue
            }
            guard let account = accountByID[job.accountID] else {
                out.append(Planned(jobID: job.id, date: nil, problem: "Account not found."))
                continue
            }
            let candidates = schedule.occurrences(for: account.id, from: from, to: to)
            if candidates.isEmpty {
                out.append(Planned(jobID: job.id, date: nil, problem: "\(account.handle) has no posting slots."))
                continue
            }
            let mine = taken[account.id] ?? []
            let pick = candidates.first { t in
                fits(t, accountTimes: mine, allTimes: all, rules: rules, platform: account.platform,
                     platformTimes: platformTimes(account.platform, taken: taken, accounts: accountByID), calendar: cal)
            }
            if let pick {
                taken[account.id, default: []].append(pick)
                all.append(pick)
                out.append(Planned(jobID: job.id, date: pick, problem: nil))
            } else {
                out.append(Planned(jobID: job.id, date: nil,
                                   problem: "No free slot for \(account.handle) in the next \(horizonDays) days within your limits."))
            }
        }
        return out
    }

    private static func platformTimes(_ p: Platform, taken: [UUID: [Date]], accounts: [UUID: Account]) -> [Date] {
        taken.filter { accounts[$0.key]?.platform == p }.flatMap(\.value)
    }

    /// Whether a post at `t` keeps every cadence rule: caps per day, the gap
    /// between posts on one account, posting window and quiet hours.
    public static func fits(_ t: Date, accountTimes: [Date], allTimes: [Date], rules: PublishRules,
                            platform: Platform, platformTimes: [Date], calendar cal: Calendar) -> Bool {
        if rules.blackoutWindows.contains(where: { $0.contains(t, calendar: cal) }) { return false }
        if let w = rules.postingWindow, !w.contains(t, calendar: cal) { return false }
        if accountTimes.contains(where: { abs($0.timeIntervalSince(t)) < 60 }) { return false }
        if rules.minGapMinutes > 0,
           accountTimes.contains(where: { abs($0.timeIntervalSince(t)) < Double(rules.minGapMinutes) * 60 }) { return false }
        func sameDay(_ d: Date) -> Bool { cal.isDate(d, inSameDayAs: t) }
        if rules.perAccountDailyCap > 0, accountTimes.filter(sameDay).count >= rules.perAccountDailyCap { return false }
        if rules.globalDailyCap > 0, allTimes.filter(sameDay).count >= rules.globalDailyCap { return false }
        if let cap = rules.platformDailyCaps[platform], cap > 0, platformTimes.filter(sameDay).count >= cap { return false }
        return true
    }
}

/// Days with nothing planned, per account, so the user can see where the
/// calendar has holes.
public enum GapFinder {
    public struct Gap: Hashable, Sendable {
        public var accountID: UUID
        public var day: Date
    }

    public static func gaps(jobs: [PostJob], accounts: [Account], from: Date, days: Int, calendar cal: Calendar) -> [Gap] {
        let start = cal.startOfDay(for: from)
        var out: [Gap] = []
        for a in accounts where a.status == .connected && !a.isPaused {
            let dates = jobs.filter { $0.accountID == a.id && $0.status != .cancelled }
                .compactMap { $0.status == .posted ? $0.postedAt : $0.scheduledAt }
            for i in 0..<max(0, days) {
                guard let day = cal.date(byAdding: .day, value: i, to: start) else { continue }
                if !dates.contains(where: { cal.isDate($0, inSameDayAs: day) }) {
                    out.append(Gap(accountID: a.id, day: day))
                }
            }
        }
        return out
    }
}

extension PostJob {
    /// When this post shows on the calendar.
    public var calendarDate: Date? {
        switch status {
        case .posted: return postedAt ?? scheduledAt
        case .cancelled: return nil
        default: return scheduledAt
        }
    }

    /// Scheduled more than five minutes ago and still not out.
    public func isOverdue(now: Date = Date()) -> Bool {
        guard let t = scheduledAt, [.scheduled, .held, .failed].contains(status) else { return false }
        return t < now.addingTimeInterval(-5 * 60)
    }
}
