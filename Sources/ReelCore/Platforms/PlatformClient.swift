import Foundation

public struct RemoteProfile: Sendable {
    public var remoteID: String
    public var username: String
}

public enum PostPrivacy: String, Codable, CaseIterable, Sendable {
    case publicAudience, followers, privateOnly

    public var label: String {
        switch self {
        case .publicAudience: return "Public"
        case .followers: return "Followers / unlisted"
        case .privateOnly: return "Only me"
        }
    }
}

public struct PublishRequest: Sendable {
    public var videoURL: URL
    public var caption: String
    /// Used as the YouTube title; other platforms ignore it.
    public var title: String
    public var privacy: PostPrivacy
    public var account: Account

    public init(videoURL: URL, caption: String, title: String, privacy: PostPrivacy, account: Account) {
        self.videoURL = videoURL; self.caption = caption; self.title = title
        self.privacy = privacy; self.account = account
    }
}

public struct PublishResult: Sendable {
    public var remotePostID: String
    public var url: String?
}

/// Engagement numbers as a platform reports them. Nil = not reported.
public struct PostMetrics: Sendable, Equatable {
    public var views: Int?
    public var likes: Int?
    public var comments: Int?
    public var shares: Int?
    public var reach: Int?
    public init(views: Int? = nil, likes: Int? = nil, comments: Int? = nil, shares: Int? = nil, reach: Int? = nil) {
        self.views = views; self.likes = likes; self.comments = comments; self.shares = shares; self.reach = reach
    }
}

/// One account a sign-in gives access to. Usually one; a Facebook login
/// can manage several Pages, each with its own token.
public struct ConnectableAccount: Sendable {
    public var profile: RemoteProfile
    public var tokens: OAuthTokens
}

public enum PublishStage: Sendable {
    /// Burning this account's on-screen text into its copy of the video.
    case rendering(Double)
    case uploading(Double)
    case processing
}

/// One implementation per platform. Each talks only to the platform's
/// official, documented API.
public protocol PlatformClient: Sendable {
    var platform: Platform { get }
    func authorizationURL(config: PlatformAppConfig, pkce: PKCE, state: String) -> URL
    func exchange(code: String, pkce: PKCE, config: PlatformAppConfig) async throws -> OAuthTokens
    func refresh(_ tokens: OAuthTokens, config: PlatformAppConfig) async throws -> OAuthTokens
    func fetchProfile(tokens: OAuthTokens) async throws -> RemoteProfile
    /// Accounts this sign-in can post to. Default: the signed-in profile.
    func connectableAccounts(tokens: OAuthTokens) async throws -> [ConnectableAccount]
    func publish(_ request: PublishRequest, tokens: OAuthTokens,
                 progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult
    /// Reads engagement for a post this app published.
    func fetchMetrics(remotePostID: String, account: Account, tokens: OAuthTokens) async throws -> PostMetrics
}

extension PlatformClient {
    public func connectableAccounts(tokens: OAuthTokens) async throws -> [ConnectableAccount] {
        [ConnectableAccount(profile: try await fetchProfile(tokens: tokens), tokens: tokens)]
    }
}

public enum PlatformClients {
    public static func client(for p: Platform, session: URLSession = .shared) -> PlatformClient {
        switch p {
        case .instagram: return InstagramClient(session: session)
        case .facebook: return FacebookClient(session: session)
        case .tiktok: return TikTokClient(session: session)
        case .youtube: return YouTubeClient(session: session)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
}

func tokens(fromJSON j: [String: Any], keepingRefresh old: String? = nil) -> OAuthTokens? {
    guard let access = j.string("access_token") else { return nil }
    return OAuthTokens(accessToken: access,
                       refreshToken: j.string("refresh_token") ?? old,
                       expiresAt: j.double("expires_in").map { Date().addingTimeInterval($0) },
                       scope: j.string("scope"))
}

func pollDelay(_ seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
