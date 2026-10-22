import SwiftUI
import ReelCore

/// Shown on the dashboard when something is stopping posts from going out.
struct PublishingBanner: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let paused = app.accounts.filter(\.isPaused)
        let held = app.jobs.filter { $0.status == .held }
        let drafts = app.drafts
        if app.rules.killSwitch || !paused.isEmpty || !held.isEmpty || !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if app.rules.killSwitch {
                    row("pause.octagon.fill", .red, "All publishing is paused.", "Resume") { app.setKillSwitch(false) }
                }
                ForEach(paused) { a in
                    row("pause.circle.fill", .orange, "\(a.platform.displayName) \(a.handle) is paused. \(a.pauseReason ?? "")", "Resume") {
                        app.setPaused(a, false)
                    }
                }
                if !held.isEmpty {
                    row("hand.raised.fill", .yellow, "\(held.count) post\(held.count == 1 ? " is" : "s are") held by your rules: \(held.first?.holdReason ?? "")",
                        "See Schedule") { app.section = .schedule }
                }
                if !drafts.isEmpty {
                    row("doc.badge.clock", .purple, "\(drafts.count) draft\(drafts.count == 1 ? "" : "s") waiting for your approval.",
                        "Review") { app.section = .schedule }
                }
            }
            .card()
        }
    }

    private func row(_ icon: String, _ tint: Color, _ text: String, _ action: String, _ run: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).lineLimit(2)
            Spacer()
            Button(action, action: run).controlSize(.small)
        }
    }
}

/// The Mac may be asleep overnight, and the app never wakes it.
struct SleepWarning: View {
    var body: some View {
        Label("Some posts are between 1 and 6 am. If your Mac is asleep then, they go out when it wakes. Reel Manager never wakes your Mac.",
              systemImage: "moon.zzz")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Menu bar menu: kill switch and status at a glance.
struct PublisherMenu: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if app.rules.killSwitch {
            Text("Publishing is paused")
        } else if let next = app.nextScheduledRun {
            Text("Next post \(next.formatted(date: .omitted, time: .shortened))")
        } else {
            Text("Nothing scheduled")
        }
        let held = app.jobs.filter { $0.status == .held }.count
        let failed = app.jobs.filter { $0.status == .failed }.count
        if held > 0 { Text("\(held) held by rules") }
        if failed > 0 { Text("\(failed) failed") }
        Divider()
        Toggle("Pause All Publishing", isOn: Binding(get: { app.rules.killSwitch }, set: { app.setKillSwitch($0) }))
        Menu("Pause Platform") {
            ForEach(Platform.allCases) { p in
                Toggle(p.displayName, isOn: Binding(get: { app.rules.pausedPlatforms.contains(p) },
                                                    set: { app.setPlatformPaused(p, $0) }))
            }
        }
        Divider()
        Button("Open Reel Manager") { showMainWindow() }
        Button("Activity Log") {
            showMainWindow()
            app.showActivity = true
        }
        Divider()
        Button("Quit Reel Manager") { NSApplication.shared.terminate(nil) }
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let w = NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// Settings › Publishing: rules for unattended posting and the background publisher.
struct PublishingSettings: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var background: BackgroundPublisher

    var body: some View {
        Form {
            Section("Safety") {
                Toggle("Pause all publishing (kill switch)", isOn: rule(\.killSwitch))
                Stepper("Pause an account after \(app.rules.failureLimit) failures in a row",
                        value: rule(\.failureLimit), in: 1...10)
            }
            Section("Limits") {
                Stepper("Up to \(app.rules.perAccountDailyCap) posts per account per day", value: rule(\.perAccountDailyCap), in: 1...50)
                Stepper("Up to \(app.rules.globalDailyCap) posts in total per day", value: rule(\.globalDailyCap), in: 1...500)
                Stepper("At least \(app.rules.minGapMinutes) min between posts on one account",
                        value: rule(\.minGapMinutes), in: 0...1440, step: 15)
                ForEach(Platform.allCases) { p in
                    HStack {
                        Text(p.displayName)
                        Spacer()
                        Toggle("Paused", isOn: Binding(get: { app.rules.pausedPlatforms.contains(p) },
                                                       set: { app.setPlatformPaused(p, $0) }))
                    }
                }
            }
            Section("When to post") {
                windowToggle("Only post between", window: \.postingWindow, defaultWindow: DailyWindow(start: (8, 0), end: (22, 0)))
                quietHours
            }
            Section("Wait when") {
                Toggle("Battery is below \(app.rules.lowBatteryPercent)% and not charging", isOn: rule(\.pauseOnLowBattery))
                Toggle("The Mac is offline", isOn: rule(\.pauseWhenOffline))
                Stepper(String(format: "Free disk space is under %.0f GB", app.rules.minFreeDiskGB),
                        value: rule(\.minFreeDiskGB), in: 1...50)
            }
            Section("Background publisher") {
                Toggle("Keep publishing when Reel Manager is closed", isOn: Binding(
                    get: { background.status == .on || background.status == .needsApproval },
                    set: { background.setEnabled($0) }))
                    .disabled(background.status == .unavailable)
                Text("Status: \(background.status.label)").font(.caption).foregroundStyle(.secondary)
                if background.status == .needsApproval {
                    Button("Open Login Items…") { background.openLoginItems() }
                }
                if let e = background.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                Text("Starts at login, restarts if it crashes, and publishes only approved posts whose time has come. It never wakes a sleeping Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { background.refresh() }
    }

    private func rule<T>(_ key: WritableKeyPath<PublishRules, T>) -> Binding<T> {
        Binding(get: { app.rules[keyPath: key] }, set: { v in app.updateRules { $0[keyPath: key] = v } })
    }

    @ViewBuilder
    private func windowToggle(_ title: String, window key: WritableKeyPath<PublishRules, DailyWindow?>,
                              defaultWindow: DailyWindow) -> some View {
        let w = app.rules[keyPath: key]
        Toggle(title + (w.map { " \($0.label)" } ?? ""), isOn: Binding(
            get: { w != nil }, set: { on in app.updateRules { $0[keyPath: key] = on ? defaultWindow : nil } }))
        if let w {
            HStack {
                hourPicker("From", minute: w.startMinute) { m in app.updateRules { $0[keyPath: key]?.startMinute = m } }
                hourPicker("To", minute: w.endMinute) { m in app.updateRules { $0[keyPath: key]?.endMinute = m } }
            }
        }
    }

    private var quietHours: some View {
        let q = app.rules.blackoutWindows.first
        return Group {
            Toggle("Quiet hours" + (q.map { " \($0.label)" } ?? ""), isOn: Binding(
                get: { q != nil },
                set: { on in app.updateRules { $0.blackoutWindows = on ? [DailyWindow(start: (23, 0), end: (7, 0))] : [] } }))
            if let q {
                HStack {
                    hourPicker("From", minute: q.startMinute) { m in app.updateRules { $0.blackoutWindows[0].startMinute = m } }
                    hourPicker("To", minute: q.endMinute) { m in app.updateRules { $0.blackoutWindows[0].endMinute = m } }
                }
            }
        }
    }

    private func hourPicker(_ title: String, minute: Int, set: @escaping (Int) -> Void) -> some View {
        Picker(title, selection: Binding(get: { (minute / 60) % 24 }, set: { set($0 * 60) })) {
            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
        }
        .fixedSize()
    }
}

/// Every publish, failure, pause, hold and approval, newest first.
struct ActivityLogSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var events: [AppEvent] = []
    @State private var kind: AppEvent.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity").font(.title2.weight(.bold))
                Spacer()
                Picker("Show", selection: $kind) {
                    Text("Everything").tag(AppEvent.Kind?.none)
                    ForEach([AppEvent.Kind.publish, .failure, .pause, .resume, .hold, .approval, .schedule, .auth, .system], id: \.self) {
                        Text($0.rawValue.capitalized).tag(AppEvent.Kind?.some($0))
                    }
                }
                .fixedSize()
            }
            Text("Kept for 90 days. Tokens and secrets are removed before anything is logged.")
                .font(.caption).foregroundStyle(.secondary)
            List(events.filter { kind == nil || $0.kind == kind }) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(e.kind)).foregroundStyle(tint(e.kind)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.message).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(e.at.formatted(date: .abbreviated, time: .standard))
                            if let a = e.accountID.flatMap({ app.account(id: $0) }) {
                                Text("· \(a.platform.displayName) \(a.handle)")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
            HStack {
                Button("Refresh") { load() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear(perform: load)
    }

    private func load() { events = (try? app.store.events(limit: 1000)) ?? [] }

    private func icon(_ k: AppEvent.Kind) -> String {
        switch k {
        case .publish: return "checkmark.seal.fill"
        case .failure: return "xmark.octagon.fill"
        case .pause: return "pause.circle.fill"
        case .resume: return "play.circle.fill"
        case .hold: return "hand.raised.fill"
        case .approval: return "checkmark.circle"
        case .schedule: return "calendar"
        case .auth: return "person.badge.key"
        case .system: return "gearshape"
        }
    }

    private func tint(_ k: AppEvent.Kind) -> Color {
        switch k {
        case .publish, .resume: return .green
        case .failure: return .red
        case .pause, .hold: return .orange
        default: return .secondary
        }
    }
}
