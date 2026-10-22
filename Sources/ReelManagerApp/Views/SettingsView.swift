import SwiftUI
import ReelCore

/// Developer app credentials per platform. You register your own app with
/// each platform and paste its client ID / secret / redirect URI here.
struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView {
            PublishingSettings(background: app.background)
                .tabItem { Label("Publishing", systemImage: "paperplane") }
            ForEach(Platform.allCases) { p in
                PlatformConfigForm(platform: p)
                    .tabItem { Label(p.displayName, systemImage: p.symbolName) }
            }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 560, height: 520)
    }
}

struct PlatformConfigForm: View {
    @EnvironmentObject var app: AppState
    let platform: Platform
    @State private var config = PlatformAppConfig()
    @State private var saved = false

    var body: some View {
        Form {
            TextField(platform == .tiktok ? "Client key" : "Client ID", text: $config.clientID)
            SecureField("Client secret", text: $config.clientSecret)
            TextField("Redirect URI", text: $config.redirectURI)
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Setup Guide…") { app.wizardPlatform = platform }
                Spacer()
                if saved { Text("Saved").foregroundStyle(.secondary) }
                Button("Save") {
                    do { try app.configs.save(config, for: platform); saved = true } catch { app.report(error) }
                }
            }
        }
        .padding(20)
        .onAppear { config = app.configs.config(for: platform) }
        .onChange(of: config) { _ in saved = false }
    }

    private var hint: String {
        switch platform {
        case .facebook:
            return "Same Meta app as Instagram works. Use the App ID and App secret from App settings → Basic. Posts Reels to the Pages you manage."
        case .instagram:
            return "Meta app with Instagram Login. Instagram needs an https redirect URI that forwards to reelmanager://oauth (see README). Professional accounts only."
        case .tiktok:
            return "TikTok for Developers app with Login Kit (desktop) and Content Posting API (Direct Post). Example redirect: reelmanager://oauth/tiktok"
        case .youtube:
            return "Google Cloud OAuth client (iOS type works for a Mac app; secret can be empty). Redirect: com.googleusercontent.apps.<id>:/oauth2redirect"
        }
    }
}

struct StorageSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Form {
            LabeledContent("Library folder") { Text(app.store.root.path).textSelection(.enabled).lineLimit(2) }
            Text("Every save writes a version snapshot; a full database backup is made at launch. Both are kept for 30 days.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.store.root]) }
                Button("Back Up Now") {
                    do { _ = try app.store.backupDatabase() } catch { app.report(error) }
                }
            }
        }
        .padding(20)
    }
}
