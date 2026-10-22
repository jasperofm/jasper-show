import SwiftUI
import ReelCore

struct DashboardView: View {
    @EnvironmentObject var app: AppState
    private let grid = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                PublishingBanner()

                LazyVGrid(columns: grid, spacing: 12) {
                    StatTile(title: "Videos", value: "\(app.assets.count)", icon: "film", tint: .purple)
                    StatTile(title: "Variations", value: "\(app.variations.count)", icon: "square.stack.3d.up", tint: .pink)
                    StatTile(title: "Accounts", value: "\(app.accounts.count)", icon: "person.2", tint: .blue)
                    StatTile(title: "Scheduled", value: "\(count(.scheduled))", icon: "calendar.badge.clock", tint: .orange)
                    StatTile(title: "Posted", value: "\(count(.posted))", icon: "checkmark.seal", tint: .green)
                    StatTile(title: "Failed", value: "\(count(.failed))", icon: "exclamationmark.triangle", tint: .red)
                }

                if app.accounts.isEmpty || app.assets.isEmpty {
                    gettingStarted
                }

                HStack(alignment: .top, spacing: 16) {
                    upcoming
                    recent
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func count(_ s: PostStatus) -> Int { app.jobs.filter { $0.status == s }.count }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.largeTitle.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.openCompose() } label: { Label("Compose", systemImage: "square.and.pencil") }
                .buttonStyle(BrandButtonStyle())
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private var subtitle: String {
        if let next = app.nextScheduledRun {
            return "Next post goes out \(next.formatted(.relative(presentation: .named)))."
        }
        return "Nothing scheduled right now."
    }

    private var gettingStarted: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get started").font(.headline)
            step(done: !app.accounts.isEmpty, "Connect your accounts", "Instagram, Facebook, TikTok and YouTube.",
                 action: "Add Account") { app.showAddAccount = true }
            step(done: !app.assets.isEmpty, "Import a video", "Drag it onto the Library or press ⌘I.",
                 action: "Import") { app.presentImportPanel() }
            step(done: !app.postableVariations.isEmpty, "Make and export a variation", "Crop, lighting, cuts, speed, on-screen text.",
                 action: "Open Library") { app.section = .library }
            step(done: !app.jobs.isEmpty, "Compose your first post", "Pick accounts, write captions, post or schedule.",
                 action: "Compose") { app.openCompose() }
        }
        .card()
    }

    private func step(done: Bool, _ title: String, _ detail: String, action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading) {
                Text(title).font(.callout.weight(.semibold)).strikethrough(done, color: .secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done { Button(action, action: run).controlSize(.small) }
        }
    }

    private var upcoming: some View {
        let list = app.jobs.filter { $0.status == .scheduled }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
            .prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Up next").font(.headline)
                Spacer()
                Button("See all") { app.section = .schedule }.buttonStyle(.link)
            }
            if list.isEmpty {
                Text("Scheduled posts show up here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(Array(list)) { j in JobLine(job: j, date: j.scheduledAt) }
        }
        .card()
        .frame(maxWidth: .infinity)
    }

    private var recent: some View {
        let list = app.jobs.filter { $0.status == .posted || $0.status == .failed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Recent activity").font(.headline)
            if list.isEmpty {
                Text("Posts you send show up here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            ForEach(Array(list)) { j in JobLine(job: j, date: j.postedAt ?? j.updatedAt) }
        }
        .card()
        .frame(maxWidth: .infinity)
    }
}

/// One post as a compact line: platform, account, video, status, time.
struct JobLine: View {
    @EnvironmentObject var app: AppState
    let job: PostJob
    let date: Date?

    var body: some View {
        HStack(spacing: 10) {
            if let a = app.account(id: job.accountID) { PlatformBadge(platform: a.platform, size: 24) }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.variation(id: job.variationID)?.name ?? "Video").font(.callout).lineLimit(1)
                Text(app.account(id: job.accountID)?.handle ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(job: job)
            if let date {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
            }
        }
    }
}

struct StatusPill: View {
    let job: PostJob
    private var status: PostStatus { job.status }
    var body: some View {
        Text(job.stateLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
    var color: Color {
        switch status {
        case .posted: return .green
        case .failed: return .red
        case .scheduled: return .orange
        case .uploading, .processing: return .blue
        case .pending: return job.isApproved ? .teal : .purple
        case .held: return .yellow
        case .cancelled: return .gray
        }
    }
}
