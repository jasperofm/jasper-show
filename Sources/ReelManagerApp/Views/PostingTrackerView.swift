import SwiftUI
import ReelCore

/// Bottom panel: every assignment of a variation to an account, its status,
/// timestamps and attempt log.
struct PostingTrackerView: View {
    @EnvironmentObject var app: AppState
    @State private var filter: Filter = .all
    @State private var logJob: PostJob?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Pending & Active", failed = "Failed", posted = "Posted"
        var id: String { rawValue }
    }

    private var rows: [PostJob] {
        app.jobs.filter { j in
            if let acc = app.selectedAccountFilter, j.accountID != acc { return false }
            switch filter {
            case .all: return j.status != .cancelled
            case .active: return [.pending, .scheduled, .uploading, .processing].contains(j.status)
            case .failed: return j.status == .failed
            case .posted: return j.status == .posted
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Posting Tracker").font(.headline)
                summary
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                let failed = rows.filter { $0.status == .failed }
                Button("Retry Failed (\(failed.count))") { app.post(failed) }
                    .disabled(failed.isEmpty)
            }
            .padding(8)
            Divider()

            Table(rows) {
                TableColumn("Video") { j in
                    let v = app.variation(id: j.variationID)
                    Text("\(v.flatMap { app.asset(id: $0.assetID)?.title } ?? "?") · \(v?.name ?? "?")").lineLimit(1)
                }
                TableColumn("Account") { j in
                    if let a = app.account(id: j.accountID) {
                        Label(a.username, systemImage: a.platform.symbolName).lineLimit(1)
                    }
                }
                TableColumn("Status") { j in StatusCell(job: j, stage: app.uploadProgress[j.id]) }
                    .width(min: 120, ideal: 160)
                TableColumn("Updated") { j in
                    Text((j.postedAt ?? j.updatedAt).formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Attempts") { j in Text("\(j.attemptCount)").monospacedDigit() }
                    .width(60)
                TableColumn("") { j in actions(j) }
                    .width(min: 150, ideal: 170)
            }
        }
        .sheet(item: $logJob) { AttemptLogSheet(job: $0) }
    }

    private var summary: some View {
        let all = app.jobs.filter { $0.status != .cancelled }
        let posted = all.filter { $0.status == .posted }.count
        return HStack(spacing: 6) {
            if !all.isEmpty {
                ProgressView(value: Double(posted), total: Double(all.count)).frame(width: 90)
                Text("\(posted)/\(all.count) posted").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ j: PostJob) -> some View {
        HStack(spacing: 6) {
            switch j.status {
            case .pending, .scheduled:
                Button("Post") { app.post([j]) }
                Button("Cancel") { app.cancel(j) }
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
                case .uploading(let p):
                    ProgressView(value: p).frame(width: 60)
                    Text("Uploading")
                case .processing:
                    ProgressView().controlSize(.small)
                    Text("Processing")
                }
            } else {
                Image(systemName: icon).foregroundStyle(color)
                Text(job.status.rawValue.capitalized)
            }
        }
        .help(job.lastError ?? "")
    }

    private var icon: String {
        switch job.status {
        case .pending: return "circle.dashed"
        case .scheduled: return "clock"
        case .uploading, .processing: return "arrow.up.circle"
        case .posted: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var color: Color {
        switch job.status {
        case .posted: return .green
        case .failed: return .red
        case .uploading, .processing: return .blue
        default: return .secondary
        }
    }
}

struct AttemptLogSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let job: PostJob

    var body: some View {
        VStack(alignment: .leading) {
            Text("Attempt Log").font(.title3.bold())
            if let e = job.lastError { Text(e).foregroundStyle(.red).font(.callout) }
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
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18)
        .frame(width: 520, height: 380)
    }
}
