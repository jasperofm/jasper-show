import SwiftUI
import ReelCore

/// Assign a variation to accounts and post it now.
struct PostSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let variation: Variation

    @State private var selected: Set<UUID> = []
    @State private var caption = ""
    @State private var title = ""
    @State private var privacy: PostPrivacy?

    private var connected: [Account] { app.accounts.filter { $0.status == .connected } }
    private var alreadyPosted: Set<UUID> {
        Set(app.jobs(for: variation.id).filter { $0.status == .posted }.map(\.accountID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Post \(variation.name)").font(.title3.bold())

            Text("Accounts").font(.headline)
            if connected.isEmpty {
                Text("Connect an account from the sidebar first.").foregroundStyle(.secondary)
            }
            ForEach(connected) { a in
                Toggle(isOn: Binding(get: { selected.contains(a.id) },
                                     set: { if $0 { selected.insert(a.id) } else { selected.remove(a.id) } })) {
                    HStack {
                        Label(a.username, systemImage: a.platform.symbolName)
                        if alreadyPosted.contains(a.id) {
                            Text("already posted").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(alreadyPosted.contains(a.id))
            }

            if selected.contains(where: { app.account(id: $0)?.platform == .youtube }) {
                TextField("YouTube title (defaults to variation name)", text: $title)
            }
            Text("Caption").font(.headline)
            TextEditor(text: $caption).frame(height: 80).border(.quaternary)

            // TikTok's Direct Post rules require the user to choose privacy
            // explicitly each time, with no preselected value.
            Picker("Who can see it", selection: $privacy) {
                Text("Choose…").tag(PostPrivacy?.none)
                ForEach(PostPrivacy.allCases, id: \.self) { Text($0.label).tag(PostPrivacy?.some($0)) }
            }
            Text("Instagram follows the account's own privacy. Unaudited TikTok and YouTube apps can only post privately.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Tracker") { submit(postNow: false) }
                    .disabled(selected.isEmpty || privacy == nil)
                Button("Post Now") { submit(postNow: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || privacy == nil || variation.needsExport)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit(postNow: Bool) {
        guard let privacy else { return }
        let jobs = app.assign(variation, to: Array(selected), caption: caption, title: title, privacy: privacy)
        if postNow { app.post(jobs.filter { $0.status != .posted }) }
        dismiss()
    }
}
