import Foundation

/// Facebook Pages via the Graph API: Facebook Login, then Reels publishing
/// to each Page the user manages.
/// Docs: https://developers.facebook.com/docs/video-api/guides/reels-publishing
///
/// One Facebook login can manage several Pages; each Page becomes its own
/// account with its own (non-expiring) Page token.
public struct FacebookClient: PlatformClient {
    public let platform = Platform.facebook
    private let http: HTTP
    static let graphVersion = "v21.0"
    private var graph: URL { URL(string: "https://graph.facebook.com/\(Self.graphVersion)/")! }

    public init(session: URLSession = .shared) { http = HTTP(platform: .facebook, session: session) }

    public func authorizationURL(config: PlatformAppConfig, pkce: PKCE, state: String) -> URL {
        URL(string: "https://www.facebook.com/\(Self.graphVersion)/dialog/oauth")!.with(query: [
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "response_type": "code",
            "state": state,
            "scope": "pages_show_list,pages_manage_posts,pages_read_engagement",
        ])
    }

    public func exchange(code: String, pkce: PKCE, config: PlatformAppConfig) async throws -> OAuthTokens {
        let shortURL = graph.appendingPathComponent("oauth/access_token").with(query: [
            "client_id": config.clientID, "client_secret": config.clientSecret,
            "redirect_uri": config.redirectURI, "code": code,
        ])
        guard let short = try await http.json(.make(shortURL)).string("access_token") else {
            throw PlatformError(platform: platform, message: "No access token returned")
        }
        // Long-lived user token; Page tokens fetched with it don't expire.
        let longURL = graph.appendingPathComponent("oauth/access_token").with(query: [
            "grant_type": "fb_exchange_token", "client_id": config.clientID,
            "client_secret": config.clientSecret, "fb_exchange_token": short,
        ])
        guard let t = tokens(fromJSON: try await http.json(.make(longURL))) else {
            throw PlatformError(platform: platform, message: "Token exchange failed")
        }
        return t
    }

    /// Page tokens don't expire; if one stops working the user reconnects.
    public func refresh(_ old: OAuthTokens, config: PlatformAppConfig) async throws -> OAuthTokens {
        if let exp = old.expiresAt, exp < Date() {
            throw PlatformError(platform: platform, message: "Session expired", requiresReauth: true)
        }
        return old
    }

    public func fetchProfile(tokens: OAuthTokens) async throws -> RemoteProfile {
        let url = graph.appendingPathComponent("me").with(query: ["fields": "id,name", "access_token": tokens.accessToken])
        let j = try await http.json(.make(url))
        guard let id = j.string("id") else { throw PlatformError(platform: platform, message: "Could not read the profile") }
        return RemoteProfile(remoteID: id, username: j.string("name") ?? id)
    }

    public func connectableAccounts(tokens: OAuthTokens) async throws -> [ConnectableAccount] {
        let url = graph.appendingPathComponent("me/accounts")
            .with(query: ["fields": "id,name,access_token", "limit": "100", "access_token": tokens.accessToken])
        let j = try await http.json(.make(url))
        let pages = (j["data"] as? [[String: Any]]) ?? []
        let out = pages.compactMap { p -> ConnectableAccount? in
            guard let id = p.string("id"), let token = p.string("access_token") else { return nil }
            return ConnectableAccount(profile: RemoteProfile(remoteID: id, username: p.string("name") ?? id),
                                      tokens: OAuthTokens(accessToken: token))
        }
        guard !out.isEmpty else {
            throw PlatformError(platform: platform, message: "This Facebook account doesn't manage any Pages. Create a Page first, or tick it when Facebook asks which Pages to share.")
        }
        return out
    }

    public func publish(_ req: PublishRequest, tokens: OAuthTokens,
                        progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult {
        guard let pageID = req.account.remoteID else { throw PlatformError(platform: platform, message: "Account has no Page id") }
        let token = tokens.accessToken
        let statusURL: (String) -> URL = { id in
            graph.appendingPathComponent(id).with(query: ["fields": "status", "access_token": token])
        }

        // Resuming: a Reel is only published by the "finish" call. An upload
        // that never reached it is abandoned; one that did is checked, never re-sent.
        var videoID: String?
        var needsFinish = true
        if let cp = req.resume {
            switch cp.step {
            case .created:
                break
            case .uploaded:
                videoID = cp.remoteID
            case .publishRequested:
                let s: [String: Any]
                do {
                    s = try await http.json(.make(statusURL(cp.remoteID))).dict("status") ?? [:]
                } catch let e as PlatformError where e.isRetryable {
                    throw e
                } catch {
                    throw PlatformError.unconfirmed(platform, "the video can't be read")
                }
                if s.string("video_status") != "error" {
                    videoID = cp.remoteID
                    needsFinish = false
                }
            }
        }

        if videoID == nil {
            // 1. Start an upload session.
            let startURL = graph.appendingPathComponent("\(pageID)/video_reels")
                .with(query: ["upload_phase": "start", "access_token": token])
            let start = try await http.json(.make(startURL, method: "POST"))
            guard let id = start.string("video_id") else {
                throw PlatformError(platform: platform, message: "Could not start the upload")
            }
            await req.checkpoint(.created, id)
            let fallback = "https://rupload.facebook.com/video-upload/\(Self.graphVersion)/\(id)"
            guard let uploadURL = URL(string: start.string("upload_url") ?? fallback) else {
                throw PlatformError(platform: platform, message: "Invalid upload address")
            }

            // 2. Upload the file.
            let size = try FileManager.default.attributesOfItem(atPath: req.videoURL.path)[.size] as? Int ?? 0
            var up = URLRequest(url: uploadURL)
            up.httpMethod = "POST"
            up.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            up.setValue("0", forHTTPHeaderField: "offset")
            up.setValue(String(size), forHTTPHeaderField: "file_size")
            progress(.uploading(0))
            _ = try await http.upload(up, fromFile: req.videoURL)
            progress(.uploading(1))
            await req.checkpoint(.uploaded, id)
            videoID = id
        }
        guard let reelID = videoID else { throw PlatformError(platform: platform, message: "No upload session") }

        // 3. Publish. Saved first, so a crash here is checked on the next try.
        if needsFinish {
            await req.checkpoint(.publishRequested, reelID)
            let finishURL = graph.appendingPathComponent("\(pageID)/video_reels").with(query: [
                "upload_phase": "finish", "video_id": reelID, "video_state": "PUBLISHED",
                "description": req.caption, "access_token": token,
            ])
            _ = try await http.json(.make(finishURL, method: "POST"))
        }

        // 4. Wait for processing.
        progress(.processing)
        for _ in 0..<60 {
            try await pollDelay(5)
            let s = try await http.json(.make(statusURL(reelID))).dict("status") ?? [:]
            if s.string("video_status") == "error" {
                let msg = s.dict("processing_phase")?.dict("error")?.string("message") ?? "Processing failed"
                throw PlatformError(platform: platform, httpStatus: 400, message: msg)
            }
            if s.string("video_status") == "ready" || s.dict("publishing_phase")?.string("status") == "complete" {
                return PublishResult(remotePostID: reelID, url: "https://www.facebook.com/reel/\(reelID)")
            }
        }
        throw PlatformError(platform: platform, message: "Still processing after 5 minutes; check the Page.")
    }

    public func fetchMetrics(remotePostID: String, account: Account, tokens: OAuthTokens) async throws -> PostMetrics {
        let token = tokens.accessToken
        let url = graph.appendingPathComponent(remotePostID).with(query: [
            "fields": "likes.summary(true).limit(0),comments.summary(true).limit(0)", "access_token": token,
        ])
        let j = try await http.json(.make(url))
        var m = PostMetrics(likes: j.dict("likes")?.dict("summary")?.int("total_count"),
                            comments: j.dict("comments")?.dict("summary")?.int("total_count"))
        let insURL = graph.appendingPathComponent("\(remotePostID)/video_insights")
            .with(query: ["metric": "total_video_views", "access_token": token])
        if let ins = try? await http.json(.make(insURL)),
           let first = (ins["data"] as? [[String: Any]])?.first {
            m.views = (first["values"] as? [[String: Any]])?.first?.int("value")
        }
        return m
    }
}
