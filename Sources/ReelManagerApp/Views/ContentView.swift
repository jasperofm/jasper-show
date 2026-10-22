import SwiftUI
import ReelCore

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            AccountSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VSplitView {
                HSplitView {
                    LibraryView()
                        .frame(minWidth: 280, idealWidth: 340)
                    Group {
                        if let editor = app.editor {
                            EditorView(editor: editor, preview: editor.preview)
                                .id(editor.variation.id)
                        } else {
                            EmptyEditorView()
                        }
                    }
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 420)
                PostingTrackerView()
                    .frame(minHeight: 150, idealHeight: 210)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.presentImportPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                Button { app.showComparison = true } label: { Label("Compare", systemImage: "rectangle.split.3x1") }
                    .disabled(app.selectedAssetID == nil || app.variations(of: app.selectedAssetID!).isEmpty)
                Button { Task { await app.syncAccounts() } } label: { Label("Sync Accounts", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .sheet(isPresented: $app.showComparison) {
            if let asset = app.selectedAsset {
                ComparisonView(asset: asset)
            }
        }
        .sheet(item: $app.postSheetVariation) { v in
            PostSheet(variation: v)
        }
        .sheet(isPresented: $app.showHelp) { HelpView() }
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
    }
}

struct EmptyEditorView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            if app.selectedAsset == nil {
                Text("Import a video, then select it to start making variations.")
            } else {
                Text("Select a variation, or create one.")
                Button("New Variation") { app.newVariation() }
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reel Manager").font(.title2.bold())
            Group {
                Text("1. Import videos with ⌘I or by dropping files onto the library.")
                Text("2. Select a video and create variations (⌘N). Edits save automatically; ⌘Z / ⇧⌘Z undo and redo.")
                Text("3. Use the crop tool in the preview to draw a frame. Add cuts at the playhead in the Timing section.")
                Text("4. Export the variation with a quality preset, then click Post to assign it to accounts.")
                Text("5. The tracker at the bottom shows every post. Failed posts stay there for retry, with a log of each attempt.")
                Text("Accounts connect through each platform's official sign-in. Add your developer app credentials in Settings first.")
                    .foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}
