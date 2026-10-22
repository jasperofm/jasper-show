import SwiftUI
import ReelCore

struct AccountSidebar: View {
    @EnvironmentObject var app: AppState
    @State private var confirmRemove: Account?

    var body: some View {
        List(selection: $app.selectedAccountFilter) {
            Section("Accounts") {
                if app.accounts.isEmpty {
                    Text("No accounts yet").foregroundStyle(.secondary)
                }
                ForEach(app.accounts) { a in
                    AccountRow(account: a)
                        .tag(a.id as UUID?)
                        .contextMenu {
                            if a.status != .connected {
                                Button("Reconnect") { app.connect(a.platform, reconnecting: a) }
                            } else {
                                Button("Sync") { Task { await app.accountService.sync(a); app.reloadAccounts() } }
                                Button("Disconnect") { app.disconnect(a, remove: false) }
                            }
                            Divider()
                            Button("Remove Account…", role: .destructive) { confirmRemove = a }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    ForEach(Platform.allCases) { p in
                        Button { app.connect(p) } label: { Label(p.displayName, systemImage: p.symbolName) }
                    }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                if app.selectedAccountFilter != nil {
                    Button("Show All") { app.selectedAccountFilter = nil }.buttonStyle(.link)
                }
            }
            .padding(10)
        }
        .confirmationDialog("Remove \(confirmRemove?.username ?? "")?", isPresented: .init(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = confirmRemove { app.disconnect(a, remove: true) }
            }
        } message: {
            Text("Its sign-in is deleted from the Keychain and its posts are removed from the tracker.")
        }
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.platform.symbolName)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.username).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Circle().fill(color).frame(width: 8, height: 8)
                .help(account.statusMessage ?? account.status.rawValue.capitalized)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if account.status == .error { return account.statusMessage ?? "Error" }
        let sync = account.lastSyncAt.map { "synced \($0.formatted(.relative(presentation: .named)))" } ?? "never synced"
        return "\(account.platform.displayName) · \(sync)"
    }

    private var color: Color {
        switch account.status {
        case .connected: return .green
        case .pending: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}
