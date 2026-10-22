import Foundation

/// Instagram API with Instagram Login (professional accounts only), Reels via
/// resumable upload so no public video URL is needed.
/// Docs: https://developers.facebook.com/docs/instagram-platform/content-publishing
///
/// Instagram requires an https redirect URI and does not support PKCE; the
/// PKCE argument is ignored. Publishing is capped per account per 24h; we
/// read `content_publishing_limit` before each post instead of guessing.
public struct InstagramClient: PlatformClient {
    public let platform = Platform.instagram
    private let http: HTTP
    static let graphVersion = "v21.0"
    private var graph: URL { URL(string: "https://graph.instagram.com/\(Self.graphVersion)/")! }

    public init(session: URLSession = .shared) { http = HTTP(platform: .instagram, session: session) }

    public func authorizationURL(config: PlatformAppConfig, pkce: PKCE, state: String) -> URL {
        URL(string: "https://www.instagram.com/oauth/authorize")!.with(query: [
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "response_type": "code",
            "scope": "instagram_business_basic,instagram_business_content_publish",
            "state": state,
        ])
    }

    public func exchange(code: String, pkce: PKCE, config: PlatformAppConfig) async throws -> OAuthTokens {
        // 1. Short-lived token.
        let short = try await http.json(.make(URL(string: "https://api.instagram.com/oauth/access_token")!, method: "POST", form: [
            "client_id": config.clientID, "client_secret": config.clientSecret, "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI, "code": code,
        ]))
        let shortBody = (short["data"] as? [[String: Any]])?.first ?? short
        guard let shortToken = shortBody.string("access_token") else {
            throw PlatformError(platform: platform, message: "No access token returned")
        }
        // 2. Long-lived (60 day) token.
        let url = URL(string: "https://graph.instagram.com/access_token")!.with(query: [
            "grant_type": "ig_exchange_token", "client_secret": config.clientSecret, "access_token": shortToken,
        ])
        let long = try await http.json(.make(url))
        guard let t = tokens(fromJSON: long) else { throw PlatformError(platform: platform, message: "Token exchange failed") }
        return t
    }

    /// Long-lived tokens are refreshed with themselves (must be ≥24h old and unexpired).
    public func refresh(_ old: OAuthTokens, config: PlatformAppConfig) async throws -> OAuthTokens {
        if let exp = old.expiresAt, exp < Date() {
            throw PlatformError(platform: platform, message: "Session expired", requiresReauth: true)
        }
        let url = URL(string: "https://graph.instagram.com/refresh_access_token")!.with(query: [
            "grant_type": "ig_refresh_token", "access_token": old.accessToken,
        ])
        let j = try await http.json(.make(url))
        guard let t = tokens(fromJSON: j) else { throw PlatformError(platform: platform, message: "Refresh failed", requiresReauth: true) }
        return t
    }

    public func fetchProfile(tokens: OAuthTokens) async throws -> RemoteProfile {
        let url = graph.appendingPathComponent("me").with(query: ["fields": "user_id,username", "access_token": tokens.accessToken])
        let j = try await http.json(.make(url))
        guard let id = j.string("user_id") ?? j.string("id") else {
            throw PlatformError(platform: platform, message: "Could not read the Instagram profile")
        }
        return RemoteProfile(remoteID: id, username: j.string("username") ?? id)
    }

    public func fetchMetrics(remotePostID: String, account: Account, tokens: OAuthTokens) async throws -> PostMetrics {
        let token = tokens.accessToken
        let basicURL = graph.appendingPathComponent(remotePostID)
            .with(query: ["fields": "like_count,comments_count", "access_token": token])
        let basic = try await http.json(.make(basicURL))
        var m = PostMetrics(likes: basic.int("like_count"), comments: basic.int("comments_count"))

        // Insights are best-effort: metric names change between Graph versions.
        let insightsURL = graph.appendingPathComponent("\(remotePostID)/insights")
            .with(query: ["metric": "reach,views,shares", "access_token": token])
        if let ins = try? await http.json(.make(insightsURL)), let data = ins["data"] as? [[String: Any]] {
            for metric in data {
                let value = (metric["values"] as? [[String: Any]])?.first?.int("value")
                switch metric.string("name") {
                case "reach": m.reach = value
                case "views": m.views = value
                case "shares": m.shares = value
                default: break
                }
            }
        }
        return m
    }

    public func publish(_ req: PublishRequest, tokens: OAuthTokens,
                        progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult {
        guard let igID = req.account.remoteID else { throw PlatformError(platform: platform, message: "Account has no Instagram user id") }
        let token = tokens.accessToken

        // Resuming: ask Instagram what happened to the earlier container first.
        // A container is only ever published by an explicit media_publish call,
        // so one that was never uploaded can simply be abandoned.
        var resumed: String?
        if let cp = req.resume, cp.step != .created {
            let status = try? await http.json(.make(statusURL(cp.remoteID, token)))
            switch status?.string("status_code") {
            case "PUBLISHED":
                return try await findPublished(igID: igID, caption: req.caption, since: cp.savedAt, token: token)
                    ?? PublishResult(remotePostID: cp.remoteID, url: nil)
            case "FINISHED", "IN_PROGRESS":
                resumed = cp.remoteID
            default:
                // Expired or errored. If publish was already requested, look for the post before starting over.
                if cp.step == .publishRequested {
                    if let found = try await findPublished(igID: igID, caption: req.caption, since: cp.savedAt, token: token) {
                        return found
                    }
                    if status == nil { throw PlatformError.unconfirmed(platform, "container status unavailable") }
                }
            }
        }

        if resumed == nil {
            // Respect the daily publishing cap.
            let limitURL = graph.appendingPathComponent("\(igID)/content_publishing_limit")
                .with(query: ["fields": "quota_usage,config", "access_token": token])
            if let limit = (try await http.json(.make(limitURL))["data"] as? [[String: Any]])?.first,
               let used = limit.double("quota_usage"), let total = limit.dict("config")?.double("quota_total"), used >= total {
                throw PlatformError(platform: platform, httpStatus: 429,
                                    message: "Daily publishing limit reached (\(Int(used))/\(Int(total))).", retryAfter: 3600)
            }

            // 1. Create a resumable Reels container.
            let createURL = graph.appendingPathComponent("\(igID)/media").with(query: [
                "media_type": "REELS", "upload_type": "resumable", "caption": req.caption,
                // Instagram has no per-post privacy; visibility follows the account's setting.
                "share_to_feed": "true", "access_token": token,
            ])
            let created = try await http.json(.make(createURL, method: "POST"))
            guard let id = created.string("id"), let uploadURI = created.string("uri").flatMap(URL.init(string:)) else {
                throw PlatformError(platform: platform, message: "Could not create a media container")
            }
            await req.checkpoint(.created, id)

            // 2. Upload the file.
            let size = try FileManager.default.attributesOfItem(atPath: req.videoURL.path)[.size] as? Int ?? 0
            var up = URLRequest(url: uploadURI)
            up.httpMethod = "POST"
            up.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            up.setValue("0", forHTTPHeaderField: "offset")
            up.setValue(String(size), forHTTPHeaderField: "file_size")
            progress(.uploading(0))
            _ = try await http.upload(up, fromFile: req.videoURL)
            progress(.uploading(1))
            await req.checkpoint(.uploaded, id)
            resumed = id
        }
        guard let containerID = resumed else { throw PlatformError(platform: platform, message: "No media container") }

        // 3. Wait for processing.
        progress(.processing)
        var finished = false
        for i in 0..<60 {
            if i > 0 || req.resume == nil { try await pollDelay(5) }
            let s = try await http.json(.make(statusURL(containerID, token)))
            switch s.string("status_code") {
            case "FINISHED": finished = true
            case "PUBLISHED":
                return try await findPublished(igID: igID, caption: req.caption, since: Date().addingTimeInterval(-86400), token: token)
                    ?? PublishResult(remotePostID: containerID, url: nil)
            case "ERROR", "EXPIRED":
                throw PlatformError(platform: platform, httpStatus: 400, message: s.string("status") ?? "Processing failed")
            default: break
            }
            if finished { break }
        }
        guard finished else { throw PlatformError(platform: platform, message: "Still processing after 5 minutes") }

        // 4. Publish. Saved first, so a crash here is checked on the next try.
        await req.checkpoint(.publishRequested, containerID)
        let pubURL = graph.appendingPathComponent("\(igID)/media_publish").with(query: ["creation_id": containerID, "access_token": token])
        let pub = try await http.json(.make(pubURL, method: "POST"))
        guard let mediaID = pub.string("id") else { throw PlatformError(platform: platform, message: "Publish returned no media id") }

        let linkURL = graph.appendingPathComponent(mediaID).with(query: ["fields": "permalink", "access_token": token])
        let permalink = try? await http.json(.make(linkURL)).string("permalink")
        return PublishResult(remotePostID: mediaID, url: permalink)
    }

    private func statusURL(_ containerID: String, _ token: String) -> URL {
        graph.appendingPathComponent(containerID).with(query: ["fields": "status_code,status", "access_token": token])
    }

    /// The account's own recent post with this caption, made after `since`.
    /// Used when resuming, to recognise a post that already went out.
    private func findPublished(igID: String, caption: String, since: Date, token: String) async throws -> PublishResult? {
        let url = graph.appendingPathComponent("\(igID)/media")
            .with(query: ["fields": "id,caption,permalink,timestamp", "limit": "10", "access_token": token])
        let items = try await http.json(.make(url))["data"] as? [[String: Any]] ?? []
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        for m in items {
            guard let id = m.string("id"), (m.string("caption") ?? "") == caption else { continue }
            if let t = m.string("timestamp").flatMap(f.date(from:)), t < since.addingTimeInterval(-300) { continue }
            return PublishResult(remotePostID: id, url: m.string("permalink"))
        }
        return nil
    }
}
