import SwiftUI
import AppKit

struct ReelManagerApp: App {
    @StateObject private var app = AppState()

    init() {
        // Needed when launched with `swift run` (no app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Reel Manager", id: "main") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Videos…") { app.presentImportPanel() }
                    .keyboardShortcut("i", modifiers: [.command])
                Button("New Variation") { app.newVariation() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(app.selectedAssetID == nil)
                Button("Compose Post…") { app.openCompose() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
            }
            CommandGroup(replacing: .undoRedo) {
                // ⌘Z / ⇧⌘Z drive the variation editor's undo stack.
                Button("Undo Edit") { app.editor?.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(app.editor == nil)
                Button("Redo Edit") { app.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(app.editor == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Variation") { app.editor?.save() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(app.editor == nil)
            }
            CommandMenu("Accounts") {
                Button("Add Account…") { app.showAddAccount = true }
                Button("Check All Connections") { Task { await app.syncAccounts() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Stats") { Task { await app.syncStats() } }
                Divider()
                Toggle("Pause All Publishing", isOn: Binding(get: { app.rules.killSwitch }, set: { app.setKillSwitch($0) }))
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Activity Log") { app.showActivity = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Reel Manager Help") { app.showHelp = true }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }

        // Kill switch and status in the menu bar. Stays while the app runs,
        // even after its window is closed.
        MenuBarExtra {
            PublisherMenu().environmentObject(app)
        } label: {
            Image(systemName: app.rules.killSwitch ? "pause.circle.fill" : "paperplane.circle")
        }
    }
}
