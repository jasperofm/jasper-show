import SwiftUI
import ReelCore

/// Engagement per account and per post, pulled from each platform's API.
struct AnalyticsView: View {
    @EnvironmentObject var app: AppState

    private var posted: [PostJob] { app.jobs.filter { $0.status == .posted } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Analytics").font(.largeTitle.weight(.bold))
                        Text(lastSync).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await app.syncStats() }
                    } label: {
                        if app.isSyncingStats { ProgressView().controlSize(.small) }
                        else { Label("Refresh Stats", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(app.isSyncingStats || posted.isEmpty)
                }

                if posted.isEmpty {
                    EmptyState(icon: "chart.bar.xaxis", title: "No posts yet",
                               message: "Once you've posted, views, likes and comments for every account show up here.")
                        .frame(height: 320)
                } else {
                    totals
                    perAccount
                    perPost
                }
            }
            .padding(24)
        }
    }

    private var lastSync: String {
        guard let d = app.stats.values.map(\.fetchedAt).max() else { return "Click Refresh Stats to load numbers." }
        return "Updated \(d.formatted(.relative(presentation: .named)))"
    }

    private func sum(_ jobs: [PostJob], _ kp: KeyPath<PostStats, Int?>) -> Int {
        jobs.compactMap { app.stats[$0.id]?[keyPath: kp] }.reduce(0, +)
    }

    private var totals: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            StatTile(title: "Posts", value: "\(posted.count)", icon: "checkmark.seal", tint: .green)
            StatTile(title: "Views", value: compactNumber(sum(posted, \.views)), icon: "eye", tint: .blue)
            StatTile(title: "Likes", value: compactNumber(sum(posted, \.likes)), icon: "heart", tint: .pink)
            StatTile(title: "Comments", value: compactNumber(sum(posted, \.comments)), icon: "bubble.left", tint: .purple)
            StatTile(title: "Shares", value: compactNumber(sum(posted, \.shares)), icon: "arrowshape.turn.up.right", tint: .orange)
        }
    }

    private var perAccount: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By account").font(.headline)
            let maxViews = max(1, app.accounts.map { a in sum(posted.filter { $0.accountID == a.id }, \.views) }.max() ?? 1)
            ForEach(app.accounts) { a in
                let jobs = posted.filter { $0.accountID == a.id }
                if !jobs.isEmpty {
                    let views = sum(jobs, \.views)
                    HStack(spacing: 10) {
                        PlatformBadge(platform: a.platform, size: 22)
                        Text(a.handle).frame(width: 170, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(a.platform.color.opacity(0.8))
                                .frame(width: max(4, g.size.width * CGFloat(views) / CGFloat(maxViews)))
                        }
                        .frame(height: 12)
                        Text("\(compactNumber(views)) views").font(.caption.monospacedDigit()).frame(width: 90, alignment: .trailing)
                        Text("\(compactNumber(jobs.compactMap { app.stats[$0.id]?.engagement }.reduce(0, +))) eng.")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        if let best = bestVariation(for: jobs) {
                            Text("Best: \(best)").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
                        }
                    }
                }
            }
        }
        .card()
    }

    private func bestVariation(for jobs: [PostJob]) -> String? {
        jobs.max { (app.stats[$0.id]?.views ?? -1) < (app.stats[$1.id]?.views ?? -1) }
            .flatMap { app.stats[$0.id]?.views == nil ? nil : app.variation(id: $0.variationID)?.name }
    }

    private var perPost: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By post").font(.headline)
            ForEach(posted.sorted { (app.stats[$0.id]?.views ?? -1) > (app.stats[$1.id]?.views ?? -1) }) { j in
                let s = app.stats[j.id]
                HStack(spacing: 10) {
                    if let a = app.account(id: j.accountID) { PlatformBadge(platform: a.platform, size: 20) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.variation(id: j.variationID)?.name ?? "Video").lineLimit(1)
                        Text(app.account(id: j.accountID)?.handle ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    metric("eye", s?.views)
                    metric("heart", s?.likes)
                    metric("bubble.left", s?.comments)
                    metric("arrowshape.turn.up.right", s?.shares)
                    if let e = s?.error {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).help(e)
                    }
                    if let url = j.remoteURL.flatMap(URL.init(string:)) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    }
                }
                Divider()
            }
        }
        .card()
    }

    private func metric(_ icon: String, _ v: Int?) -> some View {
        Label(compactNumber(v), systemImage: icon)
            .font(.caption.monospacedDigit())
            .frame(width: 72, alignment: .trailing)
            .foregroundStyle(v == nil ? .tertiary : .primary)
    }
}
