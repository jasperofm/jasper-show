import SwiftUI
import ReelCore

/// Month, week, day and list views of every post. Drag a post to move it.
struct CalendarView: View {
    @EnvironmentObject var app: AppState
    @State private var mode: Mode = .month
    @State private var anchor = Date()
    @State private var accountFilter: UUID?
    @State private var showGaps = false

    enum Mode: String, CaseIterable, Identifiable {
        case month = "Month", week = "Week", day = "Day", list = "List"
        var id: String { rawValue }
    }

    private var cal: Calendar { Calendar.current }

    private var visibleJobs: [PostJob] {
        app.jobs.filter { $0.calendarDate != nil && (accountFilter == nil || $0.accountID == accountFilter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .month: MonthGrid(anchor: anchor, jobs: visibleJobs, gapDays: gapDays, onPickDay: { anchor = $0; mode = .day })
            case .week: HourGrid(days: CalendarMath.week(containing: anchor, calendar: cal), jobs: visibleJobs, gapDays: gapDays)
            case .day: HourGrid(days: [cal.startOfDay(for: anchor)], jobs: visibleJobs, gapDays: gapDays)
            case .list: CalendarList(jobs: visibleJobs)
            }
        }
    }

    /// Days in view where at least one (filtered) account has nothing planned.
    private var gapDays: Set<Date> {
        guard showGaps else { return [] }
        let accounts = app.accounts.filter { accountFilter == nil || $0.id == accountFilter }
        let gaps = GapFinder.gaps(jobs: app.jobs, accounts: accounts, from: Date(), days: 42, calendar: cal)
        return Set(gaps.map(\.day))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Account", selection: $accountFilter) {
                Text("All accounts").tag(UUID?.none)
                ForEach(app.accounts) { a in Text("\(a.platform.displayName) \(a.handle)").tag(UUID?.some(a.id)) }
            }
            .fixedSize()
            Toggle("Show gaps", isOn: $showGaps)
                .toggleStyle(.checkbox)
                .help("Highlight days in the next 6 weeks where an account has nothing planned")
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).fixedSize()
            if mode != .list {
                ControlGroup {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { anchor = Date() }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                }
                .fixedSize()
            }
            Menu {
                Button("Posting Slots…") { app.showSlots = true }
                Button("Fill Slots with Approved Posts (\(app.unscheduledApproved.count))…") {
                    app.fillSlotsJobs = app.unscheduledApproved.map(\.id)
                }
                .disabled(app.unscheduledApproved.isEmpty)
                Divider()
                Button("Export to Calendar (.ics)…") { app.exportSchedule(asICS: true) }
                Button("Export Spreadsheet (.csv)…") { app.exportSchedule(asICS: false) }
            } label: { Label("Plan", systemImage: "wand.and.stars") }
                .fixedSize()
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var title: String {
        switch mode {
        case .month: return anchor.formatted(.dateTime.month(.wide).year())
        case .week:
            let w = CalendarMath.week(containing: anchor, calendar: cal)
            guard let f = w.first, let l = w.last else { return "" }
            return "\(f.formatted(.dateTime.month(.abbreviated).day())) – \(l.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .day: return anchor.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .list: return "Upcoming"
        }
    }

    private var subtitle: String {
        let tz = TimeZone.current
        let zone = tz.localizedName(for: tz.isDaylightSavingTime() ? .shortDaylightSaving : .shortStandard, locale: .current) ?? tz.identifier
        return "Times shown in \(zone). Drag a post to move it."
    }

    private func step(_ n: Int) {
        let unit: Calendar.Component = mode == .month ? .month : mode == .week ? .weekOfYear : .day
        anchor = cal.date(byAdding: unit, value: n, to: anchor) ?? anchor
    }
}

// MARK: Post chip

/// A post on the calendar. Approved, not-yet-published posts can be dragged.
struct CalendarChip: View {
    @EnvironmentObject var app: AppState
    let job: PostJob
    var showTime = true
    @State private var showDetail = false

    private var movable: Bool { job.isApproved && [.scheduled, .held, .failed, .pending].contains(job.status) }

    var body: some View {
        let account = app.account(id: job.accountID)
        let tint = account?.platform.color ?? .gray
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            if showTime, let d = job.calendarDate {
                Text(d.formatted(date: .omitted, time: .shortened)).monospacedDigit()
            }
            Text(account?.handle ?? "?").lineLimit(1)
            if job.isOverdue() { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
            if job.status == .posted { Image(systemName: "checkmark").foregroundStyle(.green) }
            if job.status == .held { Image(systemName: "hand.raised.fill").foregroundStyle(.yellow) }
        }
        .font(.caption2)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(job.status == .posted ? 0.08 : 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(job.isOverdue() ? Color.red : .clear))
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) { PostDetailPopover(job: job) }
        .modifier(DraggableIf(enabled: movable, payload: job.id.uuidString))
        .help("\(app.variation(id: job.variationID)?.name ?? "Video") · \(job.stateLabel)")
    }
}

private struct DraggableIf: ViewModifier {
    let enabled: Bool
    let payload: String
    func body(content: Content) -> some View {
        if enabled { content.draggable(payload) } else { content }
    }
}

struct PostDetailPopover: View {
    @EnvironmentObject var app: AppState
    let job: PostJob
    @State private var newDate = Date()

    var body: some View {
        let current = app.jobs.first { $0.id == job.id } ?? job
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let a = app.account(id: current.accountID) {
                    PlatformBadge(platform: a.platform, size: 22)
                    Text(a.handle).font(.headline)
                }
                Spacer()
                StatusPill(job: current)
            }
            Text(app.variation(id: current.variationID)?.name ?? "Video").font(.callout)
            if !current.caption.isEmpty {
                Text(current.caption).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            if let why = current.holdReason, current.status == .held {
                Label(why, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
            }
            if let e = current.lastError, current.status == .failed {
                Label(e, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if current.isOverdue() {
                Label("Overdue: it was due \(current.scheduledAt?.formatted(.relative(presentation: .named)) ?? "").",
                      systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
            if current.isApproved && !current.status.isTerminal && !current.status.isActive {
                DatePicker("Time", selection: $newDate, in: Date()...)
                HStack {
                    Button("Move Here") { app.reschedule(current, to: newDate) }
                    if [.scheduled, .held].contains(current.status) {
                        Button("Unschedule") { app.unschedule(current) }
                    }
                }
                .controlSize(.small)
            } else if !current.isApproved && current.status == .pending {
                Button("Approve") { app.approve([current]) }.controlSize(.small)
            }
            if let url = current.remoteURL.flatMap(URL.init(string:)) { Link("Open post", destination: url).font(.caption) }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { newDate = current.scheduledAt.map { max($0, Date().addingTimeInterval(60)) } ?? Date().addingTimeInterval(3600) }
    }
}

// MARK: Month

struct MonthGrid: View {
    @EnvironmentObject var app: AppState
    let anchor: Date
    let jobs: [PostJob]
    let gapDays: Set<Date>
    let onPickDay: (Date) -> Void
    private var cal: Calendar { Calendar.current }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

    var body: some View {
        let days = CalendarMath.monthGrid(containing: anchor, calendar: cal)
        let byDay = Dictionary(grouping: jobs) { cal.startOfDay(for: $0.calendarDate ?? .distantPast) }
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 4)
                }
            }
            GeometryReader { geo in
                let rowHeight = max(70, (geo.size.height - 6) / 6)
                LazyVGrid(columns: columns, spacing: 1) {
                    ForEach(days, id: \.self) { day in
                        DayCell(day: day, inMonth: cal.isDate(day, equalTo: anchor, toGranularity: .month),
                                jobs: (byDay[day] ?? []).sorted { ($0.calendarDate ?? .distantPast) < ($1.calendarDate ?? .distantPast) },
                                isGap: gapDays.contains(day), height: rowHeight, onPick: { onPickDay(day) })
                    }
                }
                .background(Color.secondary.opacity(0.15))
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var weekdaySymbols: [String] {
        let s = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(s[first...] + s[..<first])
    }
}

struct DayCell: View {
    @EnvironmentObject var app: AppState
    let day: Date
    let inMonth: Bool
    let jobs: [PostJob]
    let isGap: Bool
    let height: CGFloat
    let onPick: () -> Void
    @State private var targeted = false

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let isPast = day < Calendar.current.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(day.formatted(.dateTime.day()))
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(isToday ? Color.accentColor : .clear))
                Spacer()
                if isGap && !isPast {
                    Image(systemName: "circle.dashed").font(.caption2).foregroundStyle(.orange).help("An account has nothing planned this day")
                }
            }
            let maxChips = max(1, Int((height - 24) / 18))
            ForEach(jobs.prefix(maxChips)) { j in CalendarChip(job: j) }
            if jobs.count > maxChips {
                Button("+\(jobs.count - maxChips) more", action: onPick).buttonStyle(.link).font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPick)
        .dropDestination(for: String.self) { items, _ in
            move(items)
        } isTargeted: { targeted = $0 }
    }

    private var background: Color {
        if targeted { return Color.accentColor.opacity(0.25) }
        if isGap && day >= Calendar.current.startOfDay(for: Date()) { return Color.orange.opacity(0.07) }
        return inMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor)
    }

    private func move(_ items: [String]) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), let job = app.jobs.first(where: { $0.id == id }) else { return false }
        let base = job.scheduledAt ?? Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
        app.reschedule(job, to: CalendarMath.move(base, toDay: day, calendar: .current))
        return true
    }
}

// MARK: Week and day

struct HourGrid: View {
    @EnvironmentObject var app: AppState
    let days: [Date]
    let jobs: [PostJob]
    let gapDays: Set<Date>
    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                Color.clear.frame(width: 52)
                ForEach(days, id: \.self) { d in
                    VStack(spacing: 0) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        Text(d.formatted(.dateTime.day())).font(.title3.weight(cal.isDateInToday(d) ? .bold : .regular))
                            .foregroundStyle(cal.isDateInToday(d) ? Color.accentColor : .primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(gapDays.contains(d) ? Color.orange.opacity(0.08) : .clear)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            HStack(alignment: .top, spacing: 1) {
                                Text(hourLabel(hour)).font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing).padding(.trailing, 4)
                                ForEach(days, id: \.self) { d in
                                    HourCell(day: d, hour: hour, jobs: jobs(on: d, hour: hour))
                                }
                            }
                            .id(hour)
                            Divider()
                        }
                    }
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
        .padding(.horizontal, 12)
    }

    private func jobs(on day: Date, hour: Int) -> [PostJob] {
        jobs.filter { j in
            guard let d = j.calendarDate else { return false }
            return cal.isDate(d, inSameDayAs: day) && cal.component(.hour, from: d) == hour
        }
        .sorted { ($0.calendarDate ?? .distantPast) < ($1.calendarDate ?? .distantPast) }
    }

    private func hourLabel(_ h: Int) -> String {
        let d = cal.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

struct HourCell: View {
    @EnvironmentObject var app: AppState
    let day: Date
    let hour: Int
    let jobs: [PostJob]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(jobs) { CalendarChip(job: $0) }
        }
        .padding(2)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .background(targeted ? Color.accentColor.opacity(0.2)
                    : PublishGate.isInLikelySleepWindow(time) ? Color.secondary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), let job = app.jobs.first(where: { $0.id == id }) else { return false }
            app.reschedule(job, to: CalendarMath.move(job.scheduledAt ?? time, toDay: day, hour: hour, calendar: .current))
            return true
        } isTargeted: { targeted = $0 }
        .help(PublishGate.isInLikelySleepWindow(time) ? "Your Mac may be asleep at this hour" : "")
    }

    private var time: Date { Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day }
}

// MARK: List

struct CalendarList: View {
    @EnvironmentObject var app: AppState
    let jobs: [PostJob]

    var body: some View {
        let cal = Calendar.current
        let upcoming = jobs.filter { ($0.calendarDate ?? .distantPast) >= cal.startOfDay(for: Date()) || $0.isOverdue() }
        let byDay = Dictionary(grouping: upcoming) { cal.startOfDay(for: $0.calendarDate ?? Date()) }
        if upcoming.isEmpty {
            EmptyState(icon: "calendar", title: "Nothing coming up",
                       message: "Approve posts and schedule them, or set posting slots and use Fill Slots.",
                       actionTitle: "Posting Slots", action: { app.showSlots = true })
        } else {
            List {
                ForEach(byDay.keys.sorted(), id: \.self) { day in
                    Section(day.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                        ForEach(byDay[day]!.sorted { ($0.calendarDate ?? .distantPast) < ($1.calendarDate ?? .distantPast) }) { j in
                            HStack {
                                JobLine(job: j, date: j.calendarDate)
                                if j.isOverdue() { Text("Overdue").font(.caption.bold()).foregroundStyle(.red) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Slots

/// Weekly posting slots, per account or for all accounts, with templates.
struct SlotsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var schedule = SlotSchedule()
    @State private var target: UUID?
    @State private var newWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var newTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    private var cal: Calendar { schedule.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Posting Slots").font(.title2.weight(.bold))
            Text("The times each account usually posts. Fill Slots puts approved posts into the next free slots, within your limits. Slots follow the chosen time zone, including daylight saving changes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("For", selection: $target) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(app.accounts) { a in Text("\(a.platform.displayName) \(a.handle)").tag(UUID?.some(a.id)) }
                }
                .fixedSize()
                Spacer()
                Picker("Time zone", selection: $schedule.timeZoneID) {
                    ForEach(zoneChoices, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 260)
            }
            GroupBox("Add") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { d in
                            Toggle(cal.veryShortWeekdaySymbols[d - 1], isOn: Binding(
                                get: { newWeekdays.contains(d) },
                                set: { if $0 { newWeekdays.insert(d) } else { newWeekdays.remove(d) } }))
                                .toggleStyle(.button)
                        }
                        DatePicker("", selection: $newTime, displayedComponents: .hourAndMinute).labelsHidden()
                        Button("Add Slots") { addSlots() }.disabled(newWeekdays.isEmpty)
                    }
                    HStack {
                        Text("Or use a template:").font(.caption)
                        Menu("Templates") {
                            ForEach(SlotTemplate.allCases) { t in
                                Button(t.title) { schedule.slots += t.slots(accountID: target) }
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(4)
            }
            List {
                let mine = schedule.slots.filter { $0.accountID == target }
                    .sorted { ($0.weekday, $0.minute) < ($1.weekday, $1.minute) }
                if mine.isEmpty {
                    Text("No slots yet for \(targetName).").foregroundStyle(.secondary)
                }
                ForEach(mine) { s in
                    HStack {
                        Text(cal.weekdaySymbols[s.weekday - 1]).frame(width: 110, alignment: .leading)
                        Text(s.timeLabel).monospacedDigit()
                        if PublishGate.isInLikelySleepWindow(cal.date(bySettingHour: s.minute / 60, minute: s.minute % 60, second: 0, of: Date()) ?? Date(), calendar: cal) {
                            Image(systemName: "moon.zzz").foregroundStyle(.orange).help("Your Mac may be asleep at this time")
                        }
                        Spacer()
                        Button { schedule.slots.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 180)
            HStack {
                Text("\(schedule.slots.count) slot\(schedule.slots.count == 1 ? "" : "s") in total").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { app.saveSlots(schedule); dismiss() }
                    .buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600, height: 560)
        .onAppear { schedule = app.slotSchedule }
    }

    private var targetName: String {
        target.flatMap { app.account(id: $0) }.map(\.handle) ?? "all accounts"
    }

    private var zoneChoices: [String] {
        var ids = ["UTC", TimeZone.current.identifier, schedule.timeZoneID,
                   "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
                   "Europe/London", "Europe/Berlin", "Asia/Dubai", "Asia/Kolkata", "Asia/Tokyo", "Australia/Sydney"]
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        return ids
    }

    private func addSlots() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: newTime)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        for d in newWeekdays.sorted() where !schedule.slots.contains(where: { $0.accountID == target && $0.weekday == d && $0.minute == minute }) {
            schedule.slots.append(PostingSlot(accountID: target, weekday: d, minute: minute))
        }
    }
}

/// Preview of where approved posts would go, then schedules exactly that.
struct FillSlotsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let jobIDs: [UUID]
    @State private var start = Date()
    @State private var plan: [SlotPlanner.Planned] = []

    var body: some View {
        let placed = plan.filter { $0.date != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Fill Slots").font(.title2.weight(.bold))
            Text("Approved posts go into each account's next free slot, keeping your daily limits, gaps, posting hours and quiet hours. Nothing is scheduled until you click Schedule.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DatePicker("Starting from", selection: $start, in: Date()...)
                .onChange(of: start) { _ in replan() }
            if app.slotSchedule.slots.isEmpty {
                Label("You haven't set any posting slots yet.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Set Up Posting Slots…") { dismiss(); app.showSlots = true }
            }
            List(plan, id: \.jobID) { p in
                let job = app.jobs.first { $0.id == p.jobID }
                HStack {
                    if let a = job.flatMap({ app.account(id: $0.accountID) }) {
                        PlatformBadge(platform: a.platform, size: 18)
                        Text(a.handle)
                    }
                    Text(job.flatMap { app.variation(id: $0.variationID) }?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let d = p.date {
                        if PublishGate.isInLikelySleepWindow(d) { Image(systemName: "moon.zzz").foregroundStyle(.orange) }
                        Text(d.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                    } else {
                        Text(p.problem ?? "No slot").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .frame(minHeight: 220)
            if placed.contains(where: { $0.date.map { PublishGate.isInLikelySleepWindow($0) } ?? false }) { SleepWarning() }
            HStack {
                Text("\(placed.count) of \(plan.count) will be scheduled").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Schedule \(placed.count)") { app.apply(plan); dismiss() }
                    .buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(placed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620, height: 540)
        .onAppear(perform: replan)
    }

    private func replan() { plan = app.planSlots(for: jobIDs, from: start) }
}
