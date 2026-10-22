import SwiftUI
import ReelCore

/// Step-by-step setup of a platform's developer app, ending in a normal
/// "Log in with …" window. Done once per platform; after that every
/// account on that platform logs in with one click.
struct SetupWizard: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let platform: Platform

    @State private var step = 0
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var redirect = ""
    /// Steps the user has ticked as done. Next stays off until the current one is.
    @State private var done: Set<Int> = []

    private var guide: SetupGuide { SetupGuide.for(platform) }
    private var isLast: Bool { step == guide.steps.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PlatformBadge(platform: platform, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up \(platform.displayName)").font(.title2.weight(.bold))
                    Text("One time only. About \(guide.minutes) minutes.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(isLast ? "Last step" : "Step \(step + 1) of \(guide.steps.count + 1)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(20)

            ProgressView(value: Double(step), total: Double(guide.steps.count))
                .tint(platform.color)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLast { credentialsStep } else { stepView(guide.steps[step]) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if isLast {
                    Button("Save and Log In") { saveAndLogin() }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(idProblem != nil || (guide.needsSecret && clientSecret.isEmpty) || redirect.isEmpty)
                } else {
                    Button("Next") { step += 1 }
                        .buttonStyle(BrandButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!done.contains(step))
                        .help(done.contains(step) ? "" : "Tick \"I've done this step\" first")
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            let c = app.configs.config(for: platform)
            clientID = c.clientID
            clientSecret = c.clientSecret
            redirect = c.redirectURI.isEmpty ? OAuthRedirects.suggested(for: platform, clientID: c.clientID) : c.redirectURI
        }
        .onChange(of: clientID) { id in
            if platform == .youtube {
                redirect = OAuthRedirects.suggested(for: .youtube, clientID: id.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func stepView(_ s: SetupGuide.Step) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(s.title).font(.title3.weight(.semibold))
            ForEach(Array(s.lines.enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(platform.color))
                    Text(.init(line)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let link = s.link, let url = URL(string: link.url) {
                Link(destination: url) {
                    Label(link.title, systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(platform.color)
            }
            ForEach(s.copies, id: \.label) { c in
                CopyField(label: c.label, value: c.value == "{redirect}" ? redirect : c.value)
            }
            if let note = s.note {
                Label { Text(.init(note)) } icon: { Image(systemName: "info.circle") }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 4)
            Toggle(isOn: Binding(get: { done.contains(step) },
                                 set: { if $0 { done.insert(step) } else { done.remove(step) } })) {
                Text("I've done this step").font(.callout.weight(.semibold))
            }
            .toggleStyle(.checkbox)
        }
    }

    /// Why the pasted ID can't be right yet, if it can't.
    private var idProblem: String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "Paste the \(guide.idLabel.components(separatedBy: " (").first ?? "ID") first." }
        if platform == .youtube && !id.hasSuffix(".apps.googleusercontent.com") {
            return "That doesn't look like a Google Client ID. It ends in .apps.googleusercontent.com. Go back a step if you haven't created the client yet."
        }
        if id.contains(" ") { return "The ID shouldn't contain spaces." }
        return nil
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste your app's details").font(.title3.weight(.semibold))
            Text(.init(guide.credentialsHint)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(guide.idLabel).font(.caption).foregroundStyle(.secondary)
                TextField(guide.idLabel, text: $clientID).textFieldStyle(.roundedBorder)
                if let p = idProblem, !clientID.isEmpty {
                    Text(p).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            if guide.needsSecret || platform == .youtube {
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.secretLabel).font(.caption).foregroundStyle(.secondary)
                    SecureField(guide.secretLabel, text: $clientSecret).textFieldStyle(.roundedBorder)
                }
            }
            CopyField(label: platform == .youtube ? "Redirect URI (made from your Client ID)"
                                                  : "Redirect URI (already filled in; it must match what you entered on the website)",
                      value: redirect,
                      placeholder: "Fills in by itself once you paste the Client ID above.")
            Label("Your secret is stored in your Mac's Keychain, never in a file.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            Label { Text(.init(guide.limits)) } icon: { Image(systemName: "exclamationmark.bubble") }
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveAndLogin() {
        let config = PlatformAppConfig(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                       clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                                       redirectURI: redirect)
        do {
            try app.configs.save(config, for: platform)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.connect(platform) }
        } catch {
            app.report(error, title: "Couldn't save")
        }
    }
}

/// The written instructions for each platform's developer console.
struct SetupGuide {
    struct Link { let title: String; let url: String }
    struct Copy { let label: String; let value: String }
    struct Step {
        let title: String
        let lines: [String]
        var link: Link?
        var copies: [Copy] = []
        var note: String?
    }

    let minutes: Int
    let steps: [Step]
    let idLabel: String
    let secretLabel: String
    let needsSecret: Bool
    let credentialsHint: String
    let limits: String

    static let pagesStep = Step(
        title: "Turn on the sign-in page (one time, shared by all platforms)",
        lines: [
            "Open your repository's **Pages** settings with the button below.",
            "Under **Build and deployment**, set Source to **Deploy from a branch**.",
            "Choose branch **main** and folder **/docs**, then click **Save**.",
            "Wait about a minute. That's it. Skip this step if you've done it before.",
        ],
        link: Link(title: "Open GitHub Pages settings", url: "https://github.com/jasperofm/jasper-show/settings/pages"),
        note: "Meta and TikTok only send you back to an https web address. This tiny page passes the login back to the app.")

    static func `for`(_ p: Platform) -> SetupGuide {
        switch p {
        case .instagram:
            return SetupGuide(
                minutes: 10,
                steps: [
                    Step(title: "Use a Professional Instagram account",
                         lines: ["In the Instagram app: **Profile → ☰ → Account type and tools → Switch to professional account**.",
                                 "Pick **Creator** or **Business**. Your posts and followers stay the same.",
                                 "Do this for every Instagram account you want to post to."]),
                    pagesStep,
                    Step(title: "Create a Meta developer app",
                         lines: ["Open Meta for Developers and log in with Facebook.",
                                 "Click **Create app**. Name it (for example \"Reel Manager\").",
                                 "Use case: choose **Manage messaging & content on Instagram**. Finish creating the app.",
                                 "You can reuse this same app for Facebook Pages later."],
                         link: Link(title: "Open Meta for Developers", url: "https://developers.facebook.com/apps/")),
                    Step(title: "Add the redirect address",
                         lines: ["In your app, open **Instagram → API setup with Instagram login**.",
                                 "Find **Set up Instagram business login → Business login settings**.",
                                 "Paste the address below into **OAuth redirect URIs** and click **Save**."],
                         copies: [Copy(label: "Redirect URI", value: "{redirect}")]),
                    Step(title: "Add your accounts as testers",
                         lines: ["Go to **App roles → Roles → Add people → Instagram Tester** and type each Instagram username.",
                                 "On each Instagram account, accept the invite: on the web go to **instagram.com → Settings → Apps and websites → Tester invites**.",
                                 "Until Meta reviews your app, only tester accounts can log in."],
                         link: Link(title: "Open Instagram tester invites", url: "https://www.instagram.com/accounts/manage_access/")),
                ],
                idLabel: "Instagram app ID", secretLabel: "Instagram app secret", needsSecret: true,
                credentialsHint: "In **Instagram → API setup with Instagram login**, copy the **Instagram app ID** and **Instagram app secret** (click Show).",
                limits: "Until Meta approves your app (App Review), only accounts added as testers can be used. Posting works for them right away.")

        case .facebook:
            return SetupGuide(
                minutes: 8,
                steps: [
                    Step(title: "You need a Facebook Page",
                         lines: ["Reel Manager posts Reels to **Facebook Pages** (Facebook doesn't allow apps to post to personal profiles).",
                                 "If you don't have a Page yet, create one with the button below."],
                         link: Link(title: "Create a Facebook Page", url: "https://www.facebook.com/pages/create")),
                    pagesStep,
                    Step(title: "Use your Meta developer app",
                         lines: ["Open Meta for Developers. Use the app you made for Instagram, or click **Create app**.",
                                 "Add the use case **Manage everything on your Page** (in **Use cases → Add use cases**).",
                                 "Add the product **Facebook Login for Business**."],
                         link: Link(title: "Open Meta for Developers", url: "https://developers.facebook.com/apps/")),
                    Step(title: "Add the redirect address",
                         lines: ["Open **Facebook Login for Business → Settings**.",
                                 "Paste the address below into **Valid OAuth Redirect URIs** and click **Save changes**."],
                         copies: [Copy(label: "Redirect URI", value: "{redirect}")]),
                ],
                idLabel: "App ID", secretLabel: "App secret", needsSecret: true,
                credentialsHint: "Go to **App settings → Basic** and copy the **App ID** and **App secret** (click Show). These are different from the Instagram app ID.",
                limits: "While your Meta app is in development mode, only people with a role on the app (you) can log in. That's enough to post to your own Pages.")

        case .tiktok:
            return SetupGuide(
                minutes: 10,
                steps: [
                    pagesStep,
                    Step(title: "Create a TikTok developer app",
                         lines: ["Open TikTok for Developers and log in.",
                                 "Go to **Manage apps → Connect an app** and create it.",
                                 "Add the products **Login Kit** and **Content Posting API**. In Content Posting API, turn on **Direct Post**.",
                                 "Under scopes, make sure **user.info.basic**, **video.publish** and **video.list** are added."],
                         link: Link(title: "Open TikTok for Developers", url: "https://developers.tiktok.com/apps/")),
                    Step(title: "Add the redirect address",
                         lines: ["In **Login Kit**, add the address below as a **Redirect URI** (Web).",
                                 "Save your changes."],
                         copies: [Copy(label: "Redirect URI", value: "{redirect}")]),
                    Step(title: "Add your accounts to the sandbox",
                         lines: ["Switch the app to **Sandbox**, then open **Sandbox settings → Target users**.",
                                 "Add each TikTok account you want to post to.",
                                 "To post publicly, submit the app for review from the app page when you're ready."]),
                ],
                idLabel: "Client key", secretLabel: "Client secret", needsSecret: true,
                credentialsHint: "On your app's page, copy the **Client key** and **Client secret**.",
                limits: "Until TikTok reviews your app, posts can only be private (\"Only me\"). You can change them to public in the TikTok app.")

        case .youtube:
            return SetupGuide(
                minutes: 10,
                steps: [
                    Step(title: "Create a Google Cloud project",
                         lines: ["Open Google Cloud Console and sign in.",
                                 "Click the project picker at the top, then **New project**. Name it and create it."],
                         link: Link(title: "Open Google Cloud Console", url: "https://console.cloud.google.com/projectcreate")),
                    Step(title: "Turn on the YouTube API",
                         lines: ["Open the YouTube Data API v3 page with the button below (make sure your new project is selected).",
                                 "Click **Enable**."],
                         link: Link(title: "Open YouTube Data API v3", url: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")),
                    Step(title: "Set up the sign-in screen",
                         lines: ["Open **Google Auth Platform → Branding** (or OAuth consent screen) and fill in the app name and your email.",
                                 "Audience: choose **External**.",
                                 "Under **Test users**, add every Google account whose channel you want to post to."],
                         link: Link(title: "Open OAuth consent screen", url: "https://console.cloud.google.com/auth/overview")),
                    Step(title: "Create the login key",
                         lines: ["Open **Clients → Create client**.",
                                 "Application type: **iOS** (this works for Mac apps).",
                                 "Bundle ID: paste the value below, then click **Create**."],
                         link: Link(title: "Open Clients", url: "https://console.cloud.google.com/auth/clients"),
                         copies: [Copy(label: "Bundle ID", value: "com.reelmanager.app")]),
                ],
                idLabel: "Client ID (ends in .apps.googleusercontent.com)", secretLabel: "Client secret (leave empty for iOS clients)",
                needsSecret: false,
                credentialsHint: "Copy the **Client ID** of the client you just made. The redirect is filled in for you from it.",
                limits: "Until Google verifies your app, only the test users you added can log in, and uploads are private. You can make them public in YouTube Studio.")
        }
    }
}
