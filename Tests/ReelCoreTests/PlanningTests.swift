import XCTest
@testable import ReelCore

final class PlanningTests: XCTestCase {
    let ny = TimeZone(identifier: "America/New_York")!
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ny
        return c
    }
    let acc = Account(platform: .instagram, username: "me", status: .connected)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func approved(_ n: Int) -> [PostJob] {
        (0..<n).map { i in PostJob(variationID: UUID(), accountID: acc.id, approvedAt: Date(), createdAt: Date(timeIntervalSince1970: Double(i))) }
    }

    func testOccurrencesKeepLocalTimeAcrossDST() {
        // US DST starts Sunday 10 March 2024.
        let s = SlotSchedule(slots: SlotTemplate.dailyEvening.slots(accountID: nil), timeZoneID: ny.identifier)
        let times = s.occurrences(for: acc.id, from: date(2024, 3, 8), to: date(2024, 3, 12))
        XCTAssertEqual(times.count, 4)
        for t in times { XCTAssertEqual(cal.component(.hour, from: t), 18) }
        // 23 hours between Saturday and Sunday evenings? No: 24 local hours, 23 real ones.
        XCTAssertEqual(times[2].timeIntervalSince(times[1]), 23 * 3600)
    }

    func testAccountSlotsAndSharedSlots() {
        let other = UUID()
        let s = SlotSchedule(slots: [PostingSlot(accountID: nil, weekday: 2, minute: 600),
                                     PostingSlot(accountID: other, weekday: 2, minute: 700)], timeZoneID: ny.identifier)
        XCTAssertEqual(s.slots(for: acc.id).count, 1)
        XCTAssertEqual(s.slots(for: other).count, 2)
    }

    func testPlannerFillsNextFreeSlotsAndSkipsDrafts() {
        let s = SlotSchedule(slots: SlotTemplate.twiceDaily.slots(accountID: acc.id), timeZoneID: ny.identifier)
        var rules = PublishRules()
        rules.perAccountDailyCap = 10
        rules.minGapMinutes = 0
        var jobs = approved(3)
        jobs.append(PostJob(variationID: UUID(), accountID: acc.id)) // draft
        let from = date(2024, 5, 1, 10, 0)
        let plan = SlotPlanner.plan(jobs, existing: jobs, accounts: [acc], schedule: s, rules: rules, from: from)
        XCTAssertEqual(plan[0].date, date(2024, 5, 1, 19))
        XCTAssertEqual(plan[1].date, date(2024, 5, 2, 9))
        XCTAssertEqual(plan[2].date, date(2024, 5, 2, 19))
        XCTAssertNil(plan[3].date)
        XCTAssertNotNil(plan[3].problem)
    }

    func testPlannerRespectsDailyCapGapAndExisting() {
        let s = SlotSchedule(slots: SlotTemplate.twiceDaily.slots(accountID: nil), timeZoneID: ny.identifier)
        var rules = PublishRules()
        rules.perAccountDailyCap = 1
        let from = date(2024, 5, 1, 0, 0)
        let existing = PostJob(variationID: UUID(), accountID: acc.id, status: .scheduled,
                               scheduledAt: date(2024, 5, 1, 9), approvedAt: Date())
        let jobs = approved(2)
        let plan = SlotPlanner.plan(jobs, existing: jobs + [existing], accounts: [acc], schedule: s, rules: rules, from: from)
        // 1 May already has a post, so one a day from 2 May.
        XCTAssertEqual(plan[0].date, date(2024, 5, 2, 9))
        XCTAssertEqual(plan[1].date, date(2024, 5, 3, 9))
    }

    func testPlannerAvoidsQuietHours() {
        let s = SlotSchedule(slots: [PostingSlot(weekday: 4, minute: 23 * 60 + 30), PostingSlot(weekday: 4, minute: 20 * 60)],
                             timeZoneID: ny.identifier)
        var rules = PublishRules()
        rules.blackoutWindows = [DailyWindow(start: (23, 0), end: (7, 0))]
        let plan = SlotPlanner.plan(approved(1), existing: [], accounts: [acc], schedule: s, rules: rules, from: date(2024, 5, 1))
        XCTAssertEqual(plan[0].date, date(2024, 5, 1, 20)) // 1 May 2024 is a Wednesday
    }

    func testNoSlotsGivesProblem() {
        let plan = SlotPlanner.plan(approved(1), existing: [], accounts: [acc], schedule: SlotSchedule(), rules: PublishRules(), from: Date())
        XCTAssertNil(plan[0].date)
        XCTAssertNotNil(plan[0].problem)
    }

    func testGapFinder() {
        let from = date(2024, 5, 1, 8)
        let j = PostJob(variationID: UUID(), accountID: acc.id, status: .scheduled, scheduledAt: date(2024, 5, 2, 12), approvedAt: Date())
        let gaps = GapFinder.gaps(jobs: [j], accounts: [acc], from: from, days: 3, calendar: cal)
        XCTAssertEqual(gaps.map(\.day), [date(2024, 5, 1), date(2024, 5, 3)])
    }

    func testOverdue() {
        let now = Date()
        let late = PostJob(variationID: UUID(), accountID: acc.id, status: .scheduled, scheduledAt: now.addingTimeInterval(-600), approvedAt: now)
        let soon = PostJob(variationID: UUID(), accountID: acc.id, status: .scheduled, scheduledAt: now.addingTimeInterval(600), approvedAt: now)
        let done = PostJob(variationID: UUID(), accountID: acc.id, status: .posted, scheduledAt: now.addingTimeInterval(-600), approvedAt: now)
        XCTAssertTrue(late.isOverdue(now: now))
        XCTAssertFalse(soon.isOverdue(now: now))
        XCTAssertFalse(done.isOverdue(now: now))
    }

    func testMonthGridAndMove() {
        let grid = CalendarMath.monthGrid(containing: date(2024, 5, 15), calendar: cal)
        XCTAssertEqual(grid.count, 42)
        XCTAssertTrue(grid.contains(date(2024, 5, 1)))
        XCTAssertTrue(grid.contains(date(2024, 5, 31)))
        XCTAssertEqual(CalendarMath.week(containing: date(2024, 5, 15), calendar: cal).count, 7)
        let moved = CalendarMath.move(date(2024, 3, 9, 18, 30), toDay: date(2024, 3, 12), calendar: cal)
        XCTAssertEqual(moved, date(2024, 3, 12, 18, 30))
        XCTAssertEqual(CalendarMath.move(date(2024, 3, 9, 18, 30), toDay: date(2024, 3, 12), hour: 7, calendar: cal),
                       date(2024, 3, 12, 7, 30))
    }

    func testExports() {
        let j = PostJob(variationID: UUID(), accountID: acc.id, caption: "Hi, \"you\"; new\nline", status: .scheduled,
                        scheduledAt: Date(timeIntervalSince1970: 1_714_564_800), approvedAt: Date())
        let row = ScheduleExport.Row(job: j, accountName: "@me", platform: "Instagram", videoName: "Clip")
        let ics = ScheduleExport.ics([row])
        XCTAssertTrue(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("DTSTART:20240501T120000Z"))
        XCTAssertTrue(ics.contains("UID:\(j.id.uuidString)@reelmanager"))
        for line in ics.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75) }
        let csv = ScheduleExport.csv([row], timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(csv.contains("2024-05-01 12:00,Instagram,@me,Clip,Scheduled,\"Hi, \"\"you\"\"; new\nline\","))
    }

    func testSlotScheduleRoundTripsThroughSettings() throws {
        let store = try LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let s = SlotSchedule(slots: SlotTemplate.threeAWeek.slots(accountID: acc.id), timeZoneID: "Europe/London")
        try s.save(to: store)
        XCTAssertEqual(SlotSchedule.load(from: store), s)
    }
}
