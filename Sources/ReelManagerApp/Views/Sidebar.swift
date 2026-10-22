import SwiftUI
import ReelCore

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @State private var confirmRemove: Account?

    var body: some View {
        List(selection: Binding(get: { app.section }, set: { if let s = $0 { app.section = s } })) {
            Section {
                row("Dashboard", "square.grid.2x2", .dashboard)
                row("Library", "film.stack", .library)
                row("Calendar", "calendar", .calendar)
                row("Schedule", "calendar.badge.clock", .schedule, badge: scheduledCount)
                row("Analytics", "chart.bar.xaxis", .analytics)
            } header: {
                BrandHeader().padding(.bottom, 6)
            }

            ForEach(Platform.allCases) { p in
                let list = app.accounts.filter { $0.platform == p }
                if !list.isEmpty {
                    Section(p.displayName) {
                        ForEach(list) { a in
                            AccountRow(account: a)
                                .tag(AppState.SidebarSection.account(a.id))
                                .dropDestination(for: String.self) { items, _ in
                                    dropVariation(items, on: a)
                                }
                                .contextMenu { menu(for: a) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if app.accounts.isEmpty {
                    Text("No accounts yet").font(.caption).foregroundStyle(.secondary)
                }
                Button { app.showAddAccount = true } label: {
                    Label("Add Account", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
            }
            .padding(12)
        }
        .confirmationDialog("Remove \(confirmRemove?.handle ?? "")?", isPresented: .init(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let a = confirmRemove { app.disconnect(a, remove: true) } }
        } message: {
            Text("Its sign-in is deleted from your Mac and its posts are removed from the tracker.")
        }
    }

    private var scheduledCount: Int { app.jobs.filter { $0.status == .scheduled }.count }

    private func row(_ title: String, _ icon: String, _ s: AppState.SidebarSection, badge: Int = 0) -> some View {
        Label(title, systemImage: icon)
            .badge(badge)
            .tag(s)
    }

    @ViewBuilder
    private func menu(for a: Account) -> some View {
        if a.status != .connected {
            Button("Log In Again") { app.connect(a.platform, reconnecting: a) }
        } else {
            Button("Post to This Account…") { app.openCompose(accounts: [a.id]) }
            Button("Check Connection") { Task { await app.accountService.sync(a); app.reloadAccounts() } }
            Button("Log Out") { app.disconnect(a, remove: false) }
        }
        Divider()
        Button("Remove Account…", role: .destructive) { confirmRemove = a }
    }

    /// Dropping a variation (dragged from the Library) on an account opens
    /// Compose with both chosen.
    private func dropVariation(_ items: [String], on account: Account) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), let v = app.variation(id: id) else { return false }
        app.openCompose(v, accounts: [account.id])
        return true
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Theme.brand)
                Image(systemName: "play.square.stack.fill").foregroundStyle(.white).font(.system(size: 15, weight: .bold))
            }
            .frame(width: 30, height: 30)
            Text("Reel Manager").font(.headline).foregroundStyle(.primary)
        }
        .textCase(nil)
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 10) {
            PlatformBadge(platform: account.platform, size: 26)
                .overlay(alignment: .bottomTrailing) { StatusDot(status: account.status).offset(x: 2, y: 2) }
            VStack(alignment: .leading, spacing: 1) {
                Text(account.handle).lineLimit(1)
                Text(subtitle).font(.caption)
                    .foregroundStyle(account.status == .error ? .red : account.isPaused ? .orange : .secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(account.pauseReason ?? account.statusMessage ?? account.status.rawValue.capitalized)
    }

    private var subtitle: String {
        if account.isPaused { return "Paused" }
        switch account.status {
        case .error: return account.statusMessage ?? "Needs attention"
        case .disconnected: return "Logged out"
        case .pending: return "Connecting…"
        case .connected:
            return account.lastSyncAt.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? "Connected"
        }
    }
}
