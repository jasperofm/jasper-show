import Foundation

/// Connects, refreshes and disconnects accounts. Owns the only path that
/// reads tokens out of the Keychain.
@MainActor
public final class AccountService {
    private let store: LibraryStore
    private let keychain: KeychainStore
    private let configs: PlatformConfigStore
    private let clients: (Platform) -> PlatformClient

    public init(store: LibraryStore, keychain: KeychainStore = KeychainStore(),
                configs: PlatformConfigStore = PlatformConfigStore(),
                clients: @escaping (Platform) -> PlatformClient = { PlatformClients.client(for: $0) }) {
        self.store = store; self.keychain = keychain; self.configs = configs; self.clients = clients
    }

    /// Full OAuth2 flow: browser sign-in → code exchange → profile → Keychain + DB.
    /// Pass `existing` to reconnect an account that is in the error state.
    public func connect(_ platform: Platform, existing: Account? = nil) async throws -> Account {
        let config = configs.config(for: platform)
        guard config.isComplete else { throw OAuthError.notConfigured(platform) }
        let client = clients(platform)
        let pkce = PKCE()
        let state = UUID().uuidString

        let code = try await OAuthBrowserFlow().authorize(
            url: client.authorizationURL(config: config, pkce: pkce, state: state),
            callbackScheme: config.callbackScheme, expectedState: state)
        let tokens = try await client.exchange(code: code, pkce: pkce, config: config)
        let profile = try await client.fetchProfile(tokens: tokens)

        // Same remote account connected twice → update the existing row.
        let match = try store.accounts().first { $0.platform == platform && $0.remoteID == profile.remoteID }
        var account = existing ?? match ?? Account(platform: platform, username: profile.username)
        account.username = profile.username
        account.remoteID = profile.remoteID
        account.status = .connected
        account.statusMessage = nil
        account.lastSyncAt = Date()
        try keychain.save(tokens, for: account.keychainKey)
        try store.upsert(account)
        return account
    }

    public func disconnect(_ account: Account, remove: Bool) throws {
        try keychain.delete(for: account.keychainKey)
        if remove {
            try store.deleteAccount(account)
        } else {
            var a = account
            a.status = .disconnected
            a.statusMessage = nil
            try store.upsert(a)
        }
    }

    /// Returns a usable access token, refreshing first if it is about to expire.
    /// Marks the account as errored if the token can't be recovered.
    public func validTokens(for account: Account) async throws -> OAuthTokens {
        guard let tokens = try keychain.load(OAuthTokens.self, for: account.keychainKey) else {
            try mark(account, .error, "Not signed in. Reconnect this account.")
            throw PlatformError(platform: account.platform, message: "Not signed in", requiresReauth: true)
        }
        guard tokens.isExpired() else { return tokens }
        do {
            let fresh = try await clients(account.platform).refresh(tokens, config: configs.config(for: account.platform))
            try keychain.save(fresh, for: account.keychainKey)
            return fresh
        } catch let e as PlatformError where e.requiresReauth || e.httpStatus == 400 || e.httpStatus == 401 {
            try mark(account, .error, "Sign-in expired. Reconnect this account.")
            throw PlatformError(platform: account.platform, httpStatus: e.httpStatus, message: e.message, requiresReauth: true)
        }
    }

    /// "Sync accounts": re-reads each profile to confirm the token still works.
    public func sync(_ account: Account) async {
        do {
            let t = try await validTokens(for: account)
            let p = try await clients(account.platform).fetchProfile(tokens: t)
            var a = account
            a.username = p.username
            a.status = .connected
            a.statusMessage = nil
            a.lastSyncAt = Date()
            try store.upsert(a)
        } catch {
            try? mark(account, .error, error.localizedDescription)
        }
    }

    public func mark(_ account: Account, _ status: AccountStatus, _ message: String?) throws {
        var a = account
        a.status = status
        a.statusMessage = message
        try store.upsert(a)
    }

    public func client(for p: Platform) -> PlatformClient { clients(p) }
}
