import SwiftUI
import AppKit
import ReelCore

/// App-wide state. Views read published arrays; all mutations go through here
/// (or the editor model) so the database and UI stay in step.
@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore
    let importer: MediaImporter
    let accountService: AccountService
    let posting: PostingService
    let scheduler: PostScheduler
    let analytics: AnalyticsService
    let notifier = Notifier()
    let configs = PlatformConfigStore()

    @Published private(set) var assets: [SourceAsset] = []
    @Published private(set) var variations: [Variation] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var jobs: [PostJob] = []
    @Published var uploadProgress: [UUID: PublishStage] = [:]
    @Published private(set) var stats: [UUID: PostStats] = [:]
    @Published private(set) var nextScheduledRun: Date?
    @Published private(set) var isSyncingStats = false
    @Published private(set) var rules = PublishRules()
    @Published private(set) var isPublisher = false
    @Published var showActivity = false
    @Published private(set) var slotSchedule = SlotSchedule()
    @Published var showSlots = false
    /// Posts to place with "Fill Slots"; nil = sheet closed.
    @Published var fillSlotsJobs: [UUID]?
    let background = BackgroundPublisher()

    @Published var selectedAssetID: UUID? { didSet { if oldValue != selectedAssetID { selectedVariationID = nil } } }
    @Published var selectedVariationID: UUID? { didSet { if oldValue != selectedVariationID { openEditor() } } }
    @Published var selectedAccountFilter: UUID?
    @Published var librarySort: LibrarySort = .newest
    @Published private(set) var editor: EditorModel?

    @Published var isImporting = false
    @Published var showComparison = false
    @Published var showHelp = false
    @Published var section: SidebarSection = .dashboard
    @Published var compose: ComposeRequest?
    @Published var wizardPlatform: Platform?
    @Published var showAddAccount = false
    @Published var showScheduleAll = false
    @Published var connecting: Platform?
    @Published var alert: AppAlert?

    enum SidebarSection: Hashable {
        case dashboard, library, calendar, schedule, analytics
        case account(UUID)
    }

    /// Opens the Compose window, optionally with a video and accounts chosen.
    struct ComposeRequest: Identifiable {
        let id = UUID()
        var variationID: UUID?
        var accountIDs: Set<UUID> = []
    }

    enum LibrarySort: String, CaseIterable, Identifiable {
        case newest = "Newest", oldest = "Oldest", title = "Title", assigned = "Most assigned"
        var id: String { rawValue }
    }

    struct AppAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        do {
            store = try LibraryStore()
        } catch {
            fatalError("Could not open the library: \(error.localizedDescription)")
        }
        importer = MediaImporter(store: store)
        accountService = AccountService(store: store)
        posting = PostingService(store: store, accounts: accountService)
        scheduler = PostScheduler(store: store, posting: posting, conditions: SystemConditions(diskURL: store.root))
        analytics = AnalyticsService(store: store, accounts: accountService)
        posting.onChange = { [weak self] in self?.reloadJobs(); self?.reloadAccounts() }
        posting.onProgress = { [weak self] id, stage in self?.uploadProgress[id] = stage }
        posting.onFinished = { [weak self] job in self?.postFinished(job) }
        posting.onAccountPaused = { [weak self] a in self?.accountPaused(a) }
        accountService.onPaused = { [weak self] a in self?.accountPaused(a) }
        scheduler.onStateChange = { [weak self] in self?.schedulerTicked() }
        scheduler.onAlert = { [weak self] alert in self?.notify(alert) }

        // Interrupted uploads are reset by the scheduler once it holds the
        // publisher lock, so a running background publisher isn't disturbed.
        rules = PublishRules.load(from: store)
        slotSchedule = SlotSchedule.load(from: store)
        reloadAll()
        stats = (try? store.stats()) ?? [:]
        notifier.requestPermission()
        scheduler.start()
        // Auto-backup on launch, then trim history to 30 days.
        Task.detached(priority: .background) { [store] in
            _ = try? store.backupDatabase()
            try? store.pruneHistory()
        }
    }

    // MARK: Loading

    func reloadAll() {
        assets = (try? store.assets()) ?? []
        variations = (try? store.allVariations()) ?? []
        reloadAccounts()
        reloadJobs()
    }

    func reloadAccounts() { accounts = (try? store.accounts()) ?? [] }

    /// The background publisher may have changed things; refresh what's shown.
    private func schedulerTicked() {
        nextScheduledRun = scheduler.nextWake
        isPublisher = scheduler.isPublisher
        let fresh = PublishRules.load(from: store)
        if fresh != rules { rules = fresh }
        let newJobs = (try? store.jobs()) ?? []
        if newJobs != jobs { jobs = newJobs }
        let newAccounts = (try? store.accounts()) ?? []
        if newAccounts != accounts { accounts = newAccounts }
    }

    // MARK: Publishing rules and pauses

    func updateRules(_ change: (inout PublishRules) -> Void) {
        var r = rules
        change(&r)
        do {
            try r.save(to: store)
            rules = r
        } catch { report(error) }
        Task { await scheduler.tick(now: Date()) }
    }

    /// The global kill switch.
    func setKillSwitch(_ on: Bool) {
        updateRules { $0.killSwitch = on }
        store.log(on ? .pause : .resume, on ? "Kill switch on: all publishing paused." : "Kill switch off: publishing resumed.")
    }

    func setPaused(_ account: Account, _ paused: Bool) {
        do { try accountService.setPaused(account, paused) } catch { report(error) }
        reloadAccounts()
        if !paused { Task { await scheduler.tick(now: Date()) } }
    }

    func setPlatformPaused(_ platform: Platform, _ paused: Bool) {
        updateRules { r in
            if paused { r.pausedPlatforms.insert(platform) } else { r.pausedPlatforms.remove(platform) }
        }
        store.log(paused ? .pause : .resume, "\(platform.displayName) \(paused ? "paused" : "resumed").")
    }

    private func accountPaused(_ a: Account) {
        reloadAccounts()
        notifier.send(title: "Paused \(a.platform.displayName) \(a.handle)", body: a.pauseReason ?? "Publishing to this account is paused.")
    }

    private func notify(_ alert: PublisherAlert) {
        switch alert {
        case .morningDigest(let text): notifier.send(title: "Today in Reel Manager", body: text)
        case .queueRunningLow(let text): notifier.send(title: "Queue running low", body: text)
        case .signInExpiring(let text): notifier.send(title: "Sign-in expiring", body: text)
        }
    }

    func approve(_ jobs: [PostJob]) {
        do { try posting.approve(jobs) } catch { report(error) }
    }

    func unapprove(_ job: PostJob) {
        do { try posting.unapprove(job) } catch { report(error) }
    }

    func startOver(_ job: PostJob) {
        do { try posting.startOver(job) } catch { report(error) }
    }

    // MARK: Calendar and slots

    func saveSlots(_ s: SlotSchedule) {
        do {
            try s.save(to: store)
            slotSchedule = s
        } catch { report(error) }
    }

    /// Moves a post to a new time. Only approved posts can be on the calendar.
    func reschedule(_ job: PostJob, to date: Date) {
        guard job.isApproved, !job.status.isTerminal, !job.status.isActive else { return }
        guard date > Date() else {
            alert = AppAlert(title: "That time has passed", message: "Pick a time in the future.")
            return
        }
        do { try posting.schedule([job], at: [date]) } catch { report(error) }
        nextScheduledRun = try? store.nextWakeDate()
    }

    /// Preview for "Fill Slots": where each post would go.
    func planSlots(for jobIDs: [UUID], from: Date = Date()) -> [SlotPlanner.Planned] {
        let list = jobIDs.compactMap { id in jobs.first { $0.id == id } }
        return SlotPlanner.plan(list, existing: jobs, accounts: accounts, schedule: slotSchedule, rules: rules, from: from)
    }

    /// Schedules the planned posts exactly as previewed.
    func apply(_ plan: [SlotPlanner.Planned]) {
        let placed = plan.compactMap { p in p.date.flatMap { d in jobs.first { $0.id == p.jobID }.map { ($0, d) } } }
        guard !placed.isEmpty else { return }
        do { try posting.schedule(placed.map(\.0), at: placed.map(\.1)) } catch { report(error) }
        nextScheduledRun = try? store.nextWakeDate()
        Task { await scheduler.tick(now: Date()) }
    }

    /// Approved posts that aren't on the calendar yet.
    var unscheduledApproved: [PostJob] {
        jobs.filter { $0.status == .pending && $0.isApproved }.sorted { $0.createdAt < $1.createdAt }
    }

    func exportSchedule(asICS: Bool) {
        let rows = jobs.filter { $0.calendarDate != nil }.map { j in
            ScheduleExport.Row(job: j, accountName: account(id: j.accountID)?.handle ?? "",
                               platform: account(id: j.accountID)?.platform.displayName ?? "",
                               videoName: variation(id: j.variationID)?.name ?? "")
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asICS ? "Reel Manager schedule.ics" : "Reel Manager schedule.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = asICS ? ScheduleExport.ics(rows) : ScheduleExport.csv(rows)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { report(error) }
    }

    /// Drafts waiting for approval.
    var drafts: [PostJob] { jobs.filter { $0.status == .pending && !$0.isApproved } }
    func reloadJobs() { jobs = (try? store.jobs()) ?? [] }

    func report(_ error: Error, title: String = "Something went wrong") {
        if error is CancellationError { return }
        if case OAuthError.cancelled? = error as? OAuthError { return }
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    // MARK: Derived

    var selectedAsset: SourceAsset? { assets.first { $0.id == selectedAssetID } }

    func variations(of assetID: UUID) -> [Variation] { variations.filter { $0.assetID == assetID } }
    func asset(id: UUID) -> SourceAsset? { assets.first { $0.id == id } }
    func account(id: UUID) -> Account? { accounts.first { $0.id == id } }
    func variation(id: UUID) -> Variation? { variations.first { $0.id == id } }
    func jobs(for variationID: UUID) -> [PostJob] { jobs.filter { $0.variationID == variationID } }

    /// Library contents after sort and the sidebar's account filter.
    var sortedAssets: [SourceAsset] {
        var list = assets
        if let acc = selectedAccountFilter {
            let varIDs = Set(jobs.filter { $0.accountID == acc && $0.status != .cancelled }.map(\.variationID))
            let assetIDs = Set(variations.filter { varIDs.contains($0.id) }.map(\.assetID))
            list = list.filter { assetIDs.contains($0.id) }
        }
        switch librarySort {
        case .newest: list.sort { $0.importedAt > $1.importedAt }
        case .oldest: list.sort { $0.importedAt < $1.importedAt }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .assigned:
            func count(_ a: SourceAsset) -> Int {
                let ids = Set(variations(of: a.id).map(\.id))
                return jobs.filter { ids.contains($0.variationID) && $0.status != .cancelled }.count
            }
            list.sort { count($0) > count($1) }
        }
        return list
    }

    func thumbnail(_ relative: String?) -> NSImage? {
        guard let relative else { return nil }
        return NSImage(contentsOf: store.url(forRelative: relative))
    }

    // MARK: Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        Task {
            var last: SourceAsset?
            for url in urls {
                do { last = try await importer.importVideo(at: url) }
                catch { report(error, title: "Couldn't import \(url.lastPathComponent)") }
            }
            isImporting = false
            reloadAll()
            if let last { selectedAssetID = last.id }
        }
    }

    func deleteAsset(_ a: SourceAsset) {
        if editor?.asset.id == a.id { editor = nil }
        do { try store.deleteAsset(a) } catch { report(error) }
        if selectedAssetID == a.id { selectedAssetID = nil }
        reloadAll()
    }

    func rename(_ a: SourceAsset, to title: String) {
        var copy = a
        copy.title = title
        try? store.update(copy)
        reloadAll()
    }

    // MARK: Variations

    func newVariation(from base: Variation? = nil) {
        guard let asset = selectedAsset else { return }
        let n = variations(of: asset.id).count + 1
        let v = Variation(assetID: asset.id, name: base.map { "\($0.name) copy" } ?? "Variation \(n)",
                          settings: base?.settings ?? .identity)
        do {
            try store.insert(v)
            reloadAll()
            selectedVariationID = v.id
        } catch { report(error) }
    }

    func deleteVariation(_ v: Variation) {
        if editor?.variation.id == v.id { editor = nil }
        do { try store.deleteVariation(v) } catch { report(error) }
        if selectedVariationID == v.id { selectedVariationID = nil }
        reloadAll()
    }

    /// Called by the editor after saves and exports.
    func variationDidChange(_ v: Variation) {
        if let i = variations.firstIndex(where: { $0.id == v.id }) { variations[i] = v }
    }

    private func openEditor() {
        editor?.save()
        guard let id = selectedVariationID, let v = variation(id: id), let a = asset(id: v.assetID) else {
            editor = nil
            return
        }
        editor = EditorModel(app: self, asset: a, variation: v)
    }

    // MARK: Accounts

    /// Opens the sign-in window, or the setup wizard if this platform's
    /// developer app isn't set up yet.
    func connect(_ platform: Platform, reconnecting existing: Account? = nil) {
        guard accountService.isConfigured(platform) else {
            wizardPlatform = platform
            return
        }
        connecting = platform
        Task {
            do {
                let added = try await accountService.connect(platform, existing: existing)
                reloadAccounts()
                if let first = added.first { section = .account(first.id) }
            } catch {
                report(error, title: "Couldn't connect \(platform.displayName)")
            }
            connecting = nil
            reloadAccounts()
        }
    }

    func disconnect(_ a: Account, remove: Bool) {
        do { try accountService.disconnect(a, remove: remove) } catch { report(error) }
        if remove && selectedAccountFilter == a.id { selectedAccountFilter = nil }
        if remove && section == .account(a.id) { section = .dashboard }
        reloadAll()
    }

    func syncAccounts() async {
        for a in accounts where a.status != .disconnected { await accountService.sync(a) }
        reloadAccounts()
    }

    // MARK: Posting

    func assign(_ v: Variation, to accountIDs: [UUID], caption: String, title: String, privacy: PostPrivacy) -> [PostJob] {
        let targets = accounts.filter { accountIDs.contains($0.id) }
        do {
            return try posting.assign(variation: v, to: targets, caption: caption, title: title, privacy: privacy)
        } catch {
            report(error)
            return []
        }
    }

    /// One entry per account from the Compose box.
    struct ComposeEntry {
        let account: Account
        let caption: String
        let overlay: TextOverlay?
    }

    /// Creates (or updates) one job per account, each with its own caption and text.
    func composeJobs(_ v: Variation, entries: [ComposeEntry], title: String, privacy: PostPrivacy) -> [PostJob] {
        var out: [PostJob] = []
        do {
            for e in entries {
                out += try posting.assign(variation: v, to: [e.account], caption: e.caption, title: title,
                                          privacy: privacy, overlay: e.overlay)
            }
        } catch {
            report(error)
        }
        return out
    }

    /// Manual "Post now". Clicking it is the approval. Jobs run one after
    /// another so per-account rate limits and upload bandwidth aren't hammered.
    func post(_ jobs: [PostJob]) {
        approve(jobs)
        Task {
            for j in jobs { await posting.send(jobID: j.id) }
        }
    }

    /// Runs after every attempt (manual, scheduled or retry): clears the
    /// progress bar and tells the user how it went.
    private func postFinished(_ job: PostJob) {
        uploadProgress[job.id] = nil
        let name = account(id: job.accountID).map { "\($0.platform.displayName) @\($0.username)" } ?? "account"
        let video = variation(id: job.variationID)?.name ?? "Video"
        switch job.status {
        case .posted:
            notifier.send(title: "Posted to \(name)", body: "\(video) is live.")
        case .failed:
            let reason = job.lastError ?? "Unknown error"
            if let next = job.nextAttemptAt {
                notifier.send(title: "Post to \(name) failed",
                              body: "\(reason)\nRetrying at \(next.formatted(date: .omitted, time: .shortened)).")
            } else {
                notifier.send(title: "Post to \(name) failed", body: "\(reason)\nIt's waiting in the tracker for you to retry.")
                alert = AppAlert(title: "Post to \(name) failed",
                                 message: reason + "\n\nAutomatic retries are used up. It stays in the tracker so you can retry.")
            }
        default:
            break
        }
        nextScheduledRun = try? store.nextWakeDate()
    }

    /// Approves and schedules jobs one after another: the first at `start`,
    /// then every `interval` seconds.
    func schedule(_ jobs: [PostJob], start: Date, interval: TimeInterval) {
        approve(jobs)
        let dates = StaggerPlanner.dates(count: jobs.count, start: start, interval: interval)
        do { try posting.schedule(jobs, at: dates) } catch { report(error) }
        nextScheduledRun = try? store.nextWakeDate()
        Task { await scheduler.tick(now: Date()) }
    }

    func unschedule(_ job: PostJob) {
        do { try posting.unschedule(job) } catch { report(error) }
        nextScheduledRun = try? store.nextWakeDate()
    }

    /// Approved, unscheduled jobs whose variation is exported, oldest first:
    /// the queue for "Schedule All". Drafts must be approved first.
    var schedulableJobs: [PostJob] {
        jobs.filter { j in
            j.status == .pending && j.isApproved && !(variation(id: j.variationID)?.needsExport ?? true)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func openCompose(_ v: Variation? = nil, accounts preselected: Set<UUID> = []) {
        compose = ComposeRequest(variationID: v?.id, accountIDs: preselected)
    }

    /// Variations that are exported and ready to post, newest first.
    var postableVariations: [Variation] {
        variations.filter { !$0.needsExport }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func jobs(for account: Account) -> [PostJob] {
        jobs.filter { $0.accountID == account.id && $0.status != .cancelled }
    }

    // MARK: Analytics

    func syncStats() async {
        isSyncingStats = true
        await analytics.syncAll()
        stats = (try? store.stats()) ?? [:]
        isSyncingStats = false
    }

    func cancel(_ job: PostJob) {
        do { try posting.cancel(job) } catch { report(error) }
    }

    func removeJob(_ job: PostJob) {
        guard !posting.isRunning(job.id) else { return }
        try? store.deleteJob(job)
        reloadJobs()
    }
}
