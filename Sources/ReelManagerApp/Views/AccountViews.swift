import SwiftUI
import ReelCore

struct AccountDetailView: View {
    @EnvironmentObject var app: AppState
    let account: Account

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    PlatformBadge(platform: account.platform, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.handle).font(.title.weight(.bold))
                        HStack(spacing: 6) {
                            StatusDot(status: account.status)
                            Text(statusText).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if account.status == .connected {
                        Button { app.openCompose(accounts: [account.id]) } label: { Label("Post Here", systemImage: "square.and.pencil") }
                            .buttonStyle(BrandButtonStyle())
                    } else {
                        Button("Log In Again") { app.connect(account.platform, reconnecting: account) }
                            .buttonStyle(BrandButtonStyle())
                    }
                    Button(account.isPaused ? "Resume" : "Pause") { app.setPaused(account, !account.isPaused) }
                        .help(account.isPaused ? "Let scheduled posts go out to this account again" : "Hold every post to this account until you resume it")
                    Menu {
                        Button("Check Connection") { Task { await app.accountService.sync(account); app.reloadAccounts() } }
                        Button("Log Out") { app.disconnect(account, remove: false) }
                        Button("Remove Account", role: .destructive) { app.disconnect(account, remove: true) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }

                if account.isPaused {
                    Label("Paused. \(account.pauseReason ?? "") Scheduled posts for this account are held until you resume it.",
                          systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .card()
                }

                let jobs = app.jobs(for: account)
                let stats = jobs.compactMap { app.stats[$0.id] }
                HStack(spacing: 12) {
                    StatTile(title: "Posted", value: "\(jobs.filter { $0.status == .posted }.count)", icon: "checkmark.seal", tint: .green)
                    StatTile(title: "Scheduled", value: "\(jobs.filter { $0.status == .scheduled }.count)", icon: "calendar", tint: .orange)
                    StatTile(title: "Views", value: compactNumber(stats.compactMap(\.views).reduce(0, +)), icon: "eye", tint: .blue)
                    StatTile(title: "Engagement", value: compactNumber(stats.map(\.engagement).reduce(0, +)), icon: "heart", tint: .pink)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Posts").font(.headline)
                    if jobs.isEmpty {
                        Text("Nothing posted here yet. Drag a variation from the Library onto this account, or click Post Here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(jobs.sorted { $0.updatedAt > $1.updatedAt }) { j in
                        JobLine(job: j, date: j.postedAt ?? j.scheduledAt ?? j.updatedAt)
                    }
                }
                .card()

                Text(PlatformSpec.spec(for: account.platform).note)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var statusText: String {
        switch account.status {
        case .connected: return "Connected · \(account.platform.displayName)"
        case .error: return account.statusMessage ?? "Needs attention"
        case .disconnected: return "Logged out"
        case .pending: return "Connecting"
        }
    }
}

/// Pick a platform to add. Goes straight to the login window when the
/// platform is set up, otherwise to the setup wizard.
struct AddAccountSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an account").font(.title2.weight(.bold))
            Text("Add as many accounts as you like. Each one logs in through the platform's own sign-in page; your password never touches this app.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Platform.allCases) { p in
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { app.connect(p) }
                    } label: {
                        HStack(spacing: 12) {
                            PlatformBadge(platform: p, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName).font(.headline)
                                Text(app.accountService.isConfigured(p) ? "Log in" : "Set up, then log in")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .card(padding: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0

    private let pages: [(String, String, String)] = [
        ("play.square.stack.fill", "Welcome to Reel Manager",
         "Edit your videos into variations, then post and schedule them across all your accounts from one place."),
        ("wand.and.stars", "Make variations",
         "Crop and reframe, adjust lighting and color, trim, change speed and add on-screen text. Undo anything with ⌘Z."),
        ("person.2.badge.gearshape", "Connect every account",
         "Log in to as many Instagram, Facebook, TikTok and YouTube accounts as you want. A guided setup walks you through it."),
        ("calendar.badge.clock", "Post, schedule, automate",
         "Write a caption and on-screen text per account, post now or spread posts out over time. Failed posts retry automatically."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            let p = pages[page]
            ZStack {
                RoundedRectangle(cornerRadius: 28).fill(Theme.brand).frame(width: 110, height: 110)
                Image(systemName: p.0).font(.system(size: 48, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.top, 10)
            Text(p.1).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            Text(p.2).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Capsule().fill(i == page ? Theme.accent : Color.secondary.opacity(0.3))
                        .frame(width: i == page ? 20 : 8, height: 8)
                }
            }
            HStack {
                if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                Spacer()
                Button(page == pages.count - 1 ? "Get Started" : "Next") {
                    if page == pages.count - 1 { done() } else { withAnimation { page += 1 } }
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 600, height: 480)
    }
}
