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
    let configs = PlatformConfigStore()

    @Published private(set) var assets: [SourceAsset] = []
    @Published private(set) var variations: [Variation] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var jobs: [PostJob] = []
    @Published var uploadProgress: [UUID: PublishStage] = [:]

    @Published var selectedAssetID: UUID? { didSet { if oldValue != selectedAssetID { selectedVariationID = nil } } }
    @Published var selectedVariationID: UUID? { didSet { if oldValue != selectedVariationID { openEditor() } } }
    @Published var selectedAccountFilter: UUID?
    @Published var librarySort: LibrarySort = .newest
    @Published private(set) var editor: EditorModel?

    @Published var isImporting = false
    @Published var showComparison = false
    @Published var showHelp = false
    @Published var postSheetVariation: Variation?
    @Published var alert: AppAlert?

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
        posting.onChange = { [weak self] in self?.reloadJobs(); self?.reloadAccounts() }
        posting.onProgress = { [weak self] id, stage in self?.uploadProgress[id] = stage }

        reloadAll()
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

    func connect(_ platform: Platform, reconnecting existing: Account? = nil) {
        Task {
            do {
                _ = try await accountService.connect(platform, existing: existing)
            } catch {
                report(error, title: "Couldn't connect \(platform.displayName)")
            }
            reloadAccounts()
        }
    }

    func disconnect(_ a: Account, remove: Bool) {
        do { try accountService.disconnect(a, remove: remove) } catch { report(error) }
        if remove && selectedAccountFilter == a.id { selectedAccountFilter = nil }
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

    /// Manual "Post now". Jobs run one after another so per-account rate
    /// limits and upload bandwidth aren't hammered.
    func post(_ jobs: [PostJob]) {
        Task {
            for j in jobs {
                let result = await posting.send(jobID: j.id)
                uploadProgress[j.id] = nil
                if let r = result, r.status == .failed {
                    let name = account(id: r.accountID)?.username ?? "account"
                    alert = AppAlert(title: "Post to \(name) failed",
                                     message: (r.lastError ?? "Unknown error") + "\n\nIt stays in the tracker so you can retry.")
                }
            }
        }
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
