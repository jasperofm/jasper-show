import Foundation

/// Pulls engagement numbers for posted jobs from each platform's API and
/// stores the latest snapshot per post.
@MainActor
public final class AnalyticsService {
    private let store: LibraryStore
    private let accounts: AccountService

    public init(store: LibraryStore, accounts: AccountService) {
        self.store = store
        self.accounts = accounts
    }

    /// Refreshes every posted job. Errors are stored per post, not thrown.
    /// Returns how many posts were updated successfully.
    @discardableResult
    public func syncAll() async -> Int {
        let posted = ((try? store.jobs()) ?? []).filter { $0.status == .posted && $0.remotePostID != nil }
        let accountList = (try? store.accounts()) ?? []
        var ok = 0
        for job in posted {
            guard let account = accountList.first(where: { $0.id == job.accountID }),
                  account.status == .connected, let remoteID = job.remotePostID else { continue }
            do {
                let tokens = try await accounts.validTokens(for: account)
                let m = try await accounts.client(for: account.platform)
                    .fetchMetrics(remotePostID: remoteID, account: account, tokens: tokens)
                try store.upsert(PostStats(jobID: job.id, views: m.views, likes: m.likes, comments: m.comments,
                                           shares: m.shares, reach: m.reach))
                ok += 1
            } catch {
                var s = ((try? store.stats()) ?? [:])[job.id] ?? PostStats(jobID: job.id)
                s.error = error.localizedDescription
                s.fetchedAt = Date()
                try? store.upsert(s)
            }
        }
        return ok
    }
}
