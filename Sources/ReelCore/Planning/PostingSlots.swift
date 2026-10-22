import Foundation

/// A recurring time an account posts: a weekday and a time of day, in a
/// chosen time zone. Slots are what "Fill Slots" assigns approved posts to.
public struct PostingSlot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Nil = applies to every account.
    public var accountID: UUID?
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    public var weekday: Int
    /// Minutes after local midnight.
    public var minute: Int

    public init(id: UUID = UUID(), accountID: UUID? = nil, weekday: Int, minute: Int) {
        self.id = id; self.accountID = accountID
        self.weekday = max(1, min(7, weekday)); self.minute = max(0, min(1439, minute))
    }

    public var timeLabel: String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

/// Every slot plus the time zone they're written in. Stored in settings.
public struct SlotSchedule: Codable, Equatable, Sendable {
    public var slots: [PostingSlot] = []
    /// IANA identifier. Slots follow this zone's clock across DST changes.
    public var timeZoneID: String = TimeZone.current.identifier

    public init(slots: [PostingSlot] = [], timeZoneID: String = TimeZone.current.identifier) {
        self.slots = slots; self.timeZoneID = timeZoneID
    }

    public static let settingsKey = "calendar.slots"

    public static func load(from store: LibraryStore) -> SlotSchedule {
        store.setting(settingsKey, as: SlotSchedule.self) ?? SlotSchedule()
    }

    public func save(to store: LibraryStore) throws {
        try store.setSetting(Self.settingsKey, encoding: self)
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Slots that apply to an account: its own, plus the "all accounts" ones.
    public func slots(for accountID: UUID) -> [PostingSlot] {
        slots.filter { $0.accountID == nil || $0.accountID == accountID }
    }

    /// Slot times for an account in [from, to), in order. DST-safe: each time
    /// is built from the local date and clock time, so 18:00 stays 18:00.
    /// A time that doesn't exist on a spring-forward day moves to the next valid minute.
    public func occurrences(for accountID: UUID, from: Date, to: Date) -> [Date] {
        let mine = slots(for: accountID)
        guard !mine.isEmpty, from < to else { return [] }
        let cal = calendar
        var out: [Date] = []
        var day = cal.startOfDay(for: from)
        while day < to {
            let wd = cal.component(.weekday, from: day)
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            for s in mine where s.weekday == wd {
                var c = comps
                c.hour = s.minute / 60
                c.minute = s.minute % 60
                if let d = cal.date(from: c), d >= from, d < to { out.append(d) }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Array(Set(out)).sorted()
    }
}

/// Ready-made weekly patterns ("calendar templates").
public enum SlotTemplate: String, CaseIterable, Identifiable, Sendable {
    case dailyEvening, twiceDaily, weekdaysNoon, threeAWeek, weekends

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dailyEvening: return "Every day at 6 pm"
        case .twiceDaily: return "Twice a day (9 am and 7 pm)"
        case .weekdaysNoon: return "Weekdays at noon"
        case .threeAWeek: return "Mon, Wed, Fri at 5 pm"
        case .weekends: return "Sat and Sun at 11 am"
        }
    }

    public func slots(accountID: UUID?) -> [PostingSlot] {
        func make(_ days: [Int], _ times: [(Int, Int)]) -> [PostingSlot] {
            days.flatMap { d in times.map { PostingSlot(accountID: accountID, weekday: d, minute: $0.0 * 60 + $0.1) } }
        }
        switch self {
        case .dailyEvening: return make(Array(1...7), [(18, 0)])
        case .twiceDaily: return make(Array(1...7), [(9, 0), (19, 0)])
        case .weekdaysNoon: return make([2, 3, 4, 5, 6], [(12, 0)])
        case .threeAWeek: return make([2, 4, 6], [(17, 0)])
        case .weekends: return make([1, 7], [(11, 0)])
        }
    }
}
