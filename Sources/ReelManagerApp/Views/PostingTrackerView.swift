import SwiftUI
import ReelCore

/// Full-page schedule: summary, queue actions, and the tracker table.
struct ScheduleView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedule").font(.largeTitle.weight(.bold))
                    Text(app.nextScheduledRun.map { "Next post \($0.formatted(.relative(presentation: .named)))" }
                         ?? "Nothing scheduled. Compose a post or schedule your queue.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.showActivity = true } label: { Label("Activity", systemImage: "list.bullet.clipboard") }
                Button { app.showScheduleAll = true } label: {
                    Label("Schedule Queue (\(app.schedulableJobs.count))", systemImage: "calendar.badge.plus")
                }
                .disabled(app.schedulableJobs.isEmpty)
                Button { app.openCompose() } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .buttonStyle(BrandButtonStyle())
            }
            .padding(24)
            PostingTrackerView(compact: false)
        }
    }
}

/// Every post: status, timing, attempts and actions.
struct PostingTrackerView: View {
    @EnvironmentObject var app: AppState
    var compact: Bool
    @State private var filter: Filter = .all
    @State private var logJob: PostJob?
    @State private var search = ""
    @State private var accountFilter: UUID?
    @State private var platformFilter: Platform?
    @State private var selection: Set<UUID> = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", drafts = "Drafts", queued = "Queued", scheduled = "Scheduled", overdue = "Overdue", failed = "Failed", posted = "Posted"
        var id: String { rawValue }
    }

    private var rows: [PostJob] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return app.jobs.filter { j in
            if let accountFilter, j.accountID != accountFilter { return false }
            if let platformFilter, app.account(id: j.accountID)?.platform != platformFilter { return false }
            if !q.isEmpty {
                let hay = [j.caption, j.title, app.variation(id: j.variationID)?.name ?? "", app.account(id: j.accountID)?.handle ?? "",
                           j.overlay?.text ?? ""].joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            switch filter {
            case .overdue: return j.isOverdue()
            case .all: return j.status != .cancelled
            case .drafts: return j.status == .pending && !j.isApproved
            case .queued: return (j.status == .pending && j.isApproved) || j.status.isActive
            case .scheduled: return j.status == .scheduled || j.status == .held
            case .failed: return j.status == .failed
            case .posted: return j.status == .posted
            }
        }
        .sorted { sortDate($0) > sortDate($1) }
    }

    private func sortDate(_ j: PostJob) -> Date { j.scheduledAt ?? j.postedAt ?? j.updatedAt }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if compact { Text("Posts").font(.headline) }
                summary
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                let drafts = app.drafts
                if !drafts.isEmpty {
                    Button("Approve Drafts (\(drafts.count))") { app.approve(drafts) }
                        .help("Approved posts can be scheduled. Nothing is published without approval.")
                }
                let failed = app.jobs.filter { $0.status == .failed }
                Button("Retry Failed (\(failed.count))") { app.post(failed) }
                    .disabled(failed.isEmpty)
            }
            .padding(.horizontal, compact ? 10 : 24).padding(.vertical, 8)
            if !compact {
                HStack {
                    TextField("Search captions, videos, accounts", text: $search)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    Picker("Platform", selection: $platformFilter) {
                        Text("All platforms").tag(Platform?.none)
                        ForEach(Platform.allCases) { Text($0.displayName).tag(Platform?.some($0)) }
                    }
                    .fixedSize()
                    Picker("Account", selection: $accountFilter) {
                        Text("All accounts").tag(UUID?.none)
                        ForEach(app.accounts) { a in Text("\(a.platform.displayName) \(a.handle)").tag(UUID?.some(a.id)) }
                    }
                    .fixedSize()
                    Spacer()
                    let overdue = app.jobs.filter { $0.isOverdue() }.count
                    if overdue > 0 {
                        Button { filter = .overdue } label: {
                            Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 8)
                if !selected.isEmpty { bulkBar }
            }
            Divider()

            if rows.isEmpty {
                EmptyState(icon: "tray", title: "No posts here",
                           message: "Posts you create in Compose appear here with their status.",
                           actionTitle: compact ? nil : "Compose", action: compact ? nil : { app.openCompose() })
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Video") { j in
                        let v = app.variation(id: j.variationID)
                        HStack(spacing: 6) {
                            Text(v?.name ?? "?").lineLimit(1)
                            if let o = j.overlay, !o.isEmpty {
                                Image(systemName: "textformat").foregroundStyle(.secondary).help("On-screen text: \(o.text)")
                            }
                        }
                    }
                    TableColumn("Account") { j in
                        if let a = app.account(id: j.accountID) {
                            HStack(spacing: 6) {
                                PlatformBadge(platform: a.platform, size: 16)
                                Text(a.handle).lineLimit(1)
                            }
                        }
                    }
                    TableColumn("Status") { j in StatusCell(job: j, stage: app.uploadProgress[j.id]) }
                        .width(min: 130, ideal: 170)
                    TableColumn("When") { j in
                        if j.isOverdue() {
                            Text("Overdue · " + whenText(j)).foregroundStyle(.red)
                        } else {
                            Text(whenText(j)).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Tries") { j in Text("\(j.attemptCount)").monospacedDigit() }
                        .width(44)
                    TableColumn("") { j in actions(j) }
                        .width(min: 170, ideal: 190)
                }
            }
        }
        .sheet(item: $logJob) { AttemptLogSheet(job: $0) }
    }

    private var selected: [PostJob] { app.jobs.filter { selection.contains($0.id) } }

    /// Actions for every selected post at once.
    private var bulkBar: some View {
        let sel = selected
        let drafts = sel.filter { $0.status == .pending && !$0.isApproved }
        let approvedUnscheduled = sel.filter { $0.status == .pending && $0.isApproved }
        let scheduled = sel.filter { [.scheduled, .held].contains($0.status) }
        let failed = sel.filter { $0.status == .failed }
        let cancellable = sel.filter { !$0.status.isTerminal && !$0.status.isActive }
        return HStack(spacing: 8) {
            Text("\(sel.count) selected").font(.callout.weight(.semibold))
            if !drafts.isEmpty { Button("Approve \(drafts.count)") { app.approve(drafts) } }
            if !approvedUnscheduled.isEmpty {
                Button("Fill Slots (\(approvedUnscheduled.count))…") { app.fillSlotsJobs = approvedUnscheduled.map(\.id) }
            }
            if !scheduled.isEmpty { Button("Unschedule \(scheduled.count)") { scheduled.forEach { app.unschedule($0) } } }
            if !failed.isEmpty { Button("Retry \(failed.count)") { app.post(failed) } }
            if !cancellable.isEmpty { Button("Cancel \(cancellable.count)", role: .destructive) { cancellable.forEach { app.cancel($0) } } }
            Spacer()
            Button("Clear Selection") { selection = [] }.buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 24).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    private func whenText(_ j: PostJob) -> String {
        switch j.status {
        case .scheduled: return j.scheduledAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "–"
        case .held: return j.nextAttemptAt.map { "Recheck \($0.formatted(date: .omitted, time: .shortened))" } ?? "Held"
        case .failed:
            if let n = j.nextAttemptAt { return "Retry \(n.formatted(date: .omitted, time: .shortened))" }
            return j.updatedAt.formatted(date: .abbreviated, time: .shortened)
        case .posted: return (j.postedAt ?? j.updatedAt).formatted(date: .abbreviated, time: .shortened)
        default: return j.updatedAt.formatted(date: .abbreviated, time: .shortened)
        }
    }

    private var summary: some View {
        let all = app.jobs.filter { $0.status != .cancelled }
        let posted = all.filter { $0.status == .posted }.count
        return HStack(spacing: 6) {
            if !all.isEmpty {
                ProgressView(value: Double(posted), total: Double(all.count)).frame(width: 90).tint(.green)
                Text("\(posted)/\(all.count) posted").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ j: PostJob) -> some View {
        HStack(spacing: 6) {
            switch j.status {
            case .pending where !j.isApproved:
                Button("Approve") { app.approve([j]) }
                Button("Cancel") { app.cancel(j) }
            case .pending:
                Button("Post") { app.post([j]) }
                Button("Unapprove") { app.unapprove(j) }
            case .scheduled, .held:
                Button("Post Now") { app.post([j]) }
                Button("Unschedule") { app.unschedule(j) }
            case .failed:
                Button("Retry") { app.post([j]) }
                Button("Cancel") { app.cancel(j) }
            case .posted:
                if let url = j.remoteURL.flatMap(URL.init(string:)) { Link("Open", destination: url) }
            case .uploading, .processing, .cancelled:
                EmptyView()
            }
            Button { logJob = j } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless)
                .help("Attempt log")
        }
        .controlSize(.small)
    }
}

struct StatusCell: View {
    let job: PostJob
    let stage: PublishStage?

    var body: some View {
        HStack(spacing: 6) {
            if let stage {
                switch stage {
                case .rendering(let p):
                    ProgressView(value: p).frame(width: 50)
                    Text("Adding text")
                case .uploading(let p):
                    ProgressView(value: p).frame(width: 50)
                    Text("Uploading")
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Processing")
                }
            } else {
                StatusPill(job: job)
                if job.status == .held, let why = job.holdReason {
                    Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(job.holdReason ?? job.lastError ?? "")
    }
}

struct AttemptLogSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let job: PostJob
    @State private var confirmStartOver = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Attempt Log").font(.title3.bold())
            if let cp = job.checkpoint {
                Text("An earlier attempt reached “\(cp.step.label)” at \(cp.savedAt.formatted(date: .abbreviated, time: .shortened)). The next try checks the platform first, so it won't post twice.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = job.lastError { Text(e).foregroundStyle(.red).font(.callout) }
            if !job.caption.isEmpty { Text("Caption: \(job.caption)").font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            List((try? app.store.attempts(for: job.id)) ?? []) { a in
                HStack(alignment: .top) {
                    Image(systemName: a.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(a.succeeded ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(a.startedAt.formatted(date: .abbreviated, time: .standard))
                        Text(a.message.isEmpty ? "In progress" : a.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s = a.httpStatus { Text("HTTP \(s)").font(.caption.monospacedDigit()) }
                }
            }
            .frame(minHeight: 220)
            HStack {
                if job.checkpoint != nil && job.status == .failed {
                    Button("Start Over…") { confirmStartOver = true }
                        .help("Forget the earlier attempt and upload again. Only do this after checking the post isn't on the account.")
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 400)
        .confirmationDialog("Start this post over?", isPresented: $confirmStartOver) {
            Button("Start Over") { app.startOver(job); dismiss() }
        } message: {
            Text("Open the account and make sure the post isn't there. If it is, starting over would post it twice.")
        }
    }
}

/// "Schedule All": spreads every queued post over time, one after another.
struct ScheduleAllSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var start = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9), matchingPolicy: .nextTime) ?? Date()
    @State private var intervalHours = 4.0

    var body: some View {
        let jobs = app.schedulableJobs
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule your queue").font(.title2.weight(.bold))
            Text("\(jobs.count) queued post\(jobs.count == 1 ? "" : "s") will go out one after another, oldest first.")
                .foregroundStyle(.secondary)
            DatePicker("First post", selection: $start, in: Date()...)
            HStack {
                Text("Then one every")
                TextField("", value: $intervalHours, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("hours")
            }
            let dates = StaggerPlanner.dates(count: jobs.count, start: start, interval: intervalHours * 3600)
            List(Array(zip(jobs, dates)), id: \.0.id) { pair in
                HStack {
                    if let a = app.account(id: pair.0.accountID) {
                        PlatformBadge(platform: a.platform, size: 18)
                        Text(a.handle)
                    }
                    Text(app.variation(id: pair.0.variationID)?.name ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Text(pair.1.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
            }
            .frame(minHeight: 200)
            if dates.contains(where: { PublishGate.isInLikelySleepWindow($0) }) {
                SleepWarning()
            }
            if !app.drafts.isEmpty {
                Text("\(app.drafts.count) draft\(app.drafts.count == 1 ? " isn't" : "s aren't") included. Approve drafts first on the Schedule page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Schedule All") {
                    app.schedule(jobs, start: start, interval: max(0.0167, intervalHours) * 3600)
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(jobs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }
}
