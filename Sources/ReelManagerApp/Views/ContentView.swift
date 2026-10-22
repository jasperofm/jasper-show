import SwiftUI
import ReelCore

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @AppStorage("didFinishOnboarding") private var didFinishOnboarding = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.presentImportPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import videos (⌘I)")
                Button { app.showComparison = true } label: { Label("Compare", systemImage: "rectangle.split.3x1") }
                    .disabled(app.selectedAssetID == nil || app.variations(of: app.selectedAssetID!).isEmpty)
                    .help("Compare variations side by side")
                Button { Task { await app.syncAccounts() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Check every account's connection")
                Button { app.openCompose() } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .help("Post or schedule to your accounts")
            }
        }
        .sheet(isPresented: $app.showComparison) {
            if let asset = app.selectedAsset { ComparisonView(asset: asset) }
        }
        .sheet(item: $app.compose) { req in ComposeView(request: req) }
        .sheet(isPresented: $app.showAddAccount) { AddAccountSheet() }
        .sheet(item: $app.wizardPlatform) { p in SetupWizard(platform: p) }
        .sheet(isPresented: $app.showScheduleAll) { ScheduleAllSheet() }
        .sheet(isPresented: $app.showHelp) { HelpView() }
        .sheet(isPresented: $app.showActivity) { ActivityLogSheet() }
        .sheet(isPresented: $app.showSlots) { SlotsSheet() }
        .sheet(isPresented: Binding(get: { app.fillSlotsJobs != nil }, set: { if !$0 { app.fillSlotsJobs = nil } })) {
            FillSlotsSheet(jobIDs: app.fillSlotsJobs ?? [])
        }
        .sheet(isPresented: Binding(get: { !didFinishOnboarding }, set: { if !$0 { didFinishOnboarding = true } })) {
            OnboardingView { didFinishOnboarding = true }
        }
        .alert(item: $app.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .overlay(alignment: .bottom) {
            if let p = app.connecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in to \(p.displayName) in the window that opened…")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.section {
        case .dashboard: DashboardView()
        case .library: LibraryWorkspace()
        case .calendar: CalendarView()
        case .schedule: ScheduleView()
        case .analytics: AnalyticsView()
        case .account(let id):
            if let a = app.account(id: id) { AccountDetailView(account: a) } else { DashboardView() }
        }
    }
}


/// Library grid + editor, with the posting tracker underneath.
struct LibraryWorkspace: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VSplitView {
            HSplitView {
                LibraryView()
                    .frame(minWidth: 280, idealWidth: 340)
                Group {
                    if let editor = app.editor {
                        EditorView(editor: editor, preview: editor.preview)
                            .id(editor.variation.id)
                    } else if app.selectedAsset == nil {
                        EmptyState(icon: "film.stack", title: "Pick a video",
                                   message: "Import a video, then select it to start making variations.",
                                   actionTitle: "Import Videos") { app.presentImportPanel() }
                    } else {
                        EmptyState(icon: "wand.and.stars", title: "Make a variation",
                                   message: "Variations are edited versions of this video: crop, lighting, cuts, speed and on-screen text.",
                                   actionTitle: "New Variation") { app.newVariation() }
                    }
                }
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 420)
            PostingTrackerView(compact: true)
                .frame(minHeight: 150, idealHeight: 200)
        }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Reel Manager works").font(.title2.bold())
            Group {
                Label("Import videos with ⌘I or by dropping files on the Library.", systemImage: "1.circle.fill")
                Label("Select a video and make variations (⌘N). Edits save automatically; ⌘Z undoes.", systemImage: "2.circle.fill")
                Label("Export a variation, then click Compose to pick accounts, captions and on-screen text.", systemImage: "3.circle.fill")
                Label("Post now, schedule it, or spread posts out. Failed posts retry after 1, 5 and 15 minutes.", systemImage: "4.circle.fill")
                Label("Keep the app open for scheduled posts. It keeps your Mac awake while posts are waiting.", systemImage: "5.circle.fill")
            }
            .font(.callout)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 540)
    }
}
