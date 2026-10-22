import SwiftUI
import ReelCore

/// One box for posting to every platform: pick a video and accounts, write
/// captions and on-screen text (shared or per account), then post now,
/// schedule, or spread the posts out.
struct ComposeView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let request: AppState.ComposeRequest

    @State private var variationID: UUID?
    @State private var selected: Set<UUID> = []
    @State private var caption = ""
    @State private var overlay = TextOverlay()
    @State private var customCaption: [UUID: String] = [:]
    @State private var customOverlay: [UUID: TextOverlay] = [:]
    @State private var customized: Set<UUID> = []
    @State private var title = ""
    @State private var privacy: PostPrivacy?
    @State private var timing: Timing = .now
    @State private var startDate = Date().addingTimeInterval(3600)
    @State private var intervalMinutes = 240.0

    enum Timing: String, CaseIterable, Identifiable {
        case now = "Post now", once = "Schedule", stagger = "Spread out"
        var id: String { rawValue }
    }

    private var variation: Variation? { variationID.flatMap(app.variation(id:)) }
    private var connected: [Account] { app.accounts.filter { $0.status == .connected } }
    private var targets: [Account] { connected.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compose").font(.title2.weight(.bold))
                Spacer()
                if !targets.isEmpty {
                    Text("\(targets.count) account\(targets.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Divider()

            HSplitView {
                ScrollView { left.padding(20) }
                    .frame(minWidth: 320, idealWidth: 360)
                ScrollView { right.padding(20) }
                    .frame(minWidth: 420)
            }

            Divider()
            footer.padding(16)
        }
        .frame(width: 960, height: 700)
        .onAppear {
            variationID = request.variationID ?? app.postableVariations.first?.id
            selected = request.accountIDs.isEmpty ? [] : request.accountIDs
        }
    }

    // MARK: Left: video + accounts

    private var left: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Video").font(.headline)
            if app.postableVariations.isEmpty {
                Text("Export a variation in the Library first (Export button in the editor).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(app.postableVariations) { v in
                    VStack(spacing: 3) {
                        Thumb(image: app.thumbnail(v.thumbnailPath))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .stroke(variationID == v.id ? Theme.accent : .clear, lineWidth: 3))
                        Text(v.name).font(.caption2).lineLimit(1)
                    }
                    .onTapGesture { variationID = v.id }
                    .help(v.settings.changeSummary.joined(separator: "\n"))
                }
            }

            Text("Accounts").font(.headline)
            if connected.isEmpty {
                Button("Add an Account") { dismiss(); app.showAddAccount = true }
            }
            ForEach(Platform.allCases) { p in
                let list = connected.filter { $0.platform == p }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            PlatformBadge(platform: p, size: 18)
                            Text(p.displayName).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(list.allSatisfy { selected.contains($0.id) } ? "None" : "All") {
                                if list.allSatisfy({ selected.contains($0.id) }) { list.forEach { selected.remove($0.id) } }
                                else { list.forEach { selected.insert($0.id) } }
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                        ForEach(list) { a in
                            Toggle(isOn: Binding(get: { selected.contains(a.id) },
                                                 set: { if $0 { selected.insert(a.id) } else { selected.remove(a.id) } })) {
                                HStack {
                                    Text(a.handle)
                                    if alreadyPosted(a) {
                                        Text("already posted").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(alreadyPosted(a))
                        }
                    }
                    .card(padding: 10)
                }
            }
        }
    }

    private func alreadyPosted(_ a: Account) -> Bool {
        guard let v = variationID else { return false }
        return app.jobs.contains { $0.variationID == v && $0.accountID == a.id && $0.status == .posted }
    }

    // MARK: Right: text, timing

    private var right: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Caption").font(.headline)
                TextEditor(text: $caption)
                    .font(.body).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                Text("Used for every account unless you customize one below.").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("On-screen text").font(.headline)
                OverlayEditor(overlay: $overlay, placeholder: "Optional, e.g. \"Wait for it…\"")
            }

            if targets.contains(where: { $0.platform == .youtube }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YouTube title").font(.headline)
                    TextField("Defaults to the variation name", text: $title).textFieldStyle(.roundedBorder)
                }
            }

            if !targets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Per account").font(.headline)
                    ForEach(targets) { a in perAccount(a) }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Who can see it").font(.headline)
                // TikTok's rules: the user picks privacy every time, no default.
                Picker("Who can see it", selection: $privacy) {
                    Text("Choose…").tag(PostPrivacy?.none)
                    ForEach(PostPrivacy.allCases, id: \.self) { Text($0.label).tag(PostPrivacy?.some($0)) }
                }
                .labelsHidden().fixedSize()
                Text("Instagram and Facebook follow the account's own visibility.").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("When").font(.headline)
                Picker("When", selection: $timing) {
                    ForEach(Timing.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch timing {
                case .now:
                    Text("Posts go out one after another, right away.").font(.caption).foregroundStyle(.secondary)
                case .once:
                    DatePicker("Post at", selection: $startDate, in: Date()...)
                    Text("Every selected account posts at this time.").font(.caption).foregroundStyle(.secondary)
                case .stagger:
                    DatePicker("First post", selection: $startDate, in: Date()...)
                    HStack {
                        Text("Then one every")
                        TextField("", value: $intervalMinutes, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("minutes")
                    }
                    if targets.count > 1 {
                        Text("Last post: \(lastStaggerDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(app.background.status == .on
                     ? "The background publisher sends scheduled posts even when Reel Manager is closed."
                     : "Keep Reel Manager open (or in the menu bar) for scheduled posts, or turn on the background publisher in Settings › Publishing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if timing != .now && scheduleDates.contains(where: { PublishGate.isInLikelySleepWindow($0) }) {
                    SleepWarning()
                }
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                .card(padding: 10)
            }
        }
    }

    @ViewBuilder
    private func perAccount(_ a: Account) -> some View {
        let isCustom = customized.contains(a.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PlatformBadge(platform: a.platform, size: 20)
                Text(a.handle).font(.callout.weight(.semibold))
                Spacer()
                Toggle("Customize", isOn: Binding(get: { isCustom }, set: { on in
                    if on {
                        customized.insert(a.id)
                        customCaption[a.id] = customCaption[a.id] ?? caption
                        customOverlay[a.id] = customOverlay[a.id] ?? overlay
                    } else {
                        customized.remove(a.id)
                    }
                }))
                .toggleStyle(.switch).controlSize(.mini)
            }
            if isCustom {
                TextEditor(text: Binding(get: { customCaption[a.id] ?? "" }, set: { customCaption[a.id] = $0 }))
                    .frame(height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                OverlayEditor(overlay: Binding(get: { customOverlay[a.id] ?? TextOverlay() }, set: { customOverlay[a.id] = $0 }),
                              placeholder: "On-screen text for this account")
            } else {
                Text(caption.isEmpty ? "Shared caption (empty)" : caption)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .card(padding: 10)
    }

    private var scheduleDates: [Date] {
        StaggerPlanner.dates(count: max(1, targets.count), start: startDate,
                             interval: timing == .stagger ? intervalMinutes * 60 : 0)
    }

    private var lastStaggerDate: Date {
        startDate.addingTimeInterval(Double(max(0, targets.count - 1)) * intervalMinutes * 60)
    }

    private var warnings: [String] {
        guard let v = variation, let asset = app.asset(id: v.assetID) else { return [] }
        let duration = v.settings.outputDuration(sourceDuration: asset.duration)
        let geo = FrameGeometry(sourceSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight), settings: v.settings)
        let aspect = geo.window.width / max(geo.window.height, 1)
        var out: [String] = []
        for p in Set(targets.map(\.platform)).sorted(by: { $0.rawValue < $1.rawValue }) {
            out += PlatformSpec.spec(for: p).issues(duration: duration, aspect: aspect, fileBytes: nil)
        }
        return out
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if privacy == nil && !targets.isEmpty {
                Text("Choose who can see it").font(.caption).foregroundStyle(.secondary)
            }
            Button("Save as Draft") { submit(queueOnly: true) }
                .disabled(!canSubmit)
                .help("Saves the posts as drafts. Approve and schedule them later from the Schedule page.")
            Button(actionTitle) { submit(queueOnly: false) }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool { variation != nil && !targets.isEmpty && privacy != nil }

    private var actionTitle: String {
        let n = targets.count
        switch timing {
        case .now: return "Approve & Post to \(n) account\(n == 1 ? "" : "s")"
        case .once, .stagger: return "Approve & Schedule \(n) post\(n == 1 ? "" : "s")"
        }
    }

    private func submit(queueOnly: Bool) {
        guard let v = variation, let privacy else { return }
        let entries = targets.map { a -> AppState.ComposeEntry in
            let custom = customized.contains(a.id)
            let text = custom ? (customOverlay[a.id] ?? overlay) : overlay
            return AppState.ComposeEntry(account: a,
                                         caption: custom ? (customCaption[a.id] ?? caption) : caption,
                                         overlay: text.isEmpty ? nil : text)
        }
        let jobs = app.composeJobs(v, entries: entries, title: title, privacy: privacy).filter { $0.status != .posted }
        if !queueOnly {
            switch timing {
            case .now: app.post(jobs)
            case .once: app.schedule(jobs, start: startDate, interval: 0)
            case .stagger: app.schedule(jobs, start: startDate, interval: max(1, intervalMinutes) * 60)
            }
        }
        dismiss()
    }
}

/// Text field + position/style/size controls for on-screen text.
struct OverlayEditor: View {
    @Binding var overlay: TextOverlay
    var placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $overlay.text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            if !overlay.isEmpty {
                HStack {
                    Picker("Position", selection: $overlay.position) {
                        ForEach(TextOverlay.Position.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Picker("Style", selection: $overlay.style) {
                        ForEach(TextOverlay.Style.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                HStack {
                    Text("Size").font(.caption)
                    Slider(value: $overlay.size, in: TextOverlay.sizeRange)
                }
                .controlSize(.small)
            }
        }
    }
}
