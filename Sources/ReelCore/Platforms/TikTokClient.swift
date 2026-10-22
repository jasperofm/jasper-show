import Foundation

/// TikTok Content Posting API, Direct Post with FILE_UPLOAD.
/// Docs: https://developers.tiktok.com/doc/content-posting-api-reference-direct-post
///
/// Unaudited client apps can only post with SELF_ONLY privacy. TikTok's
/// Direct Post UX guidelines also require showing the creator's nickname and
/// letting the user pick a privacy level each time; the post sheet does this.
public struct TikTokClient: PlatformClient {
    public let platform = Platform.tiktok
    private let http: HTTP
    private let base = URL(string: "https://open.tiktokapis.com/v2/")!

    public init(session: URLSession = .shared) { http = HTTP(platform: .tiktok, session: session) }

    public func authorizationURL(config: PlatformAppConfig, pkce: PKCE, state: String) -> URL {
        URL(string: "https://www.tiktok.com/v2/auth/authorize/")!.with(query: [
            "client_key": config.clientID,
            "redirect_uri": config.redirectURI,
            "response_type": "code",
            "scope": "user.info.basic,video.publish,video.list",
            "state": state,
            "code_challenge": pkce.hexChallenge,
            "code_challenge_method": "S256",
        ])
    }

    public func exchange(code: String, pkce: PKCE, config: PlatformAppConfig) async throws -> OAuthTokens {
        let j = try await http.json(.make(base.appendingPathComponent("oauth/token/"), method: "POST", form: [
            "client_key": config.clientID, "client_secret": config.clientSecret, "code": code,
            "grant_type": "authorization_code", "redirect_uri": config.redirectURI, "code_verifier": pkce.verifier,
        ]))
        guard let t = tokens(fromJSON: j) else {
            throw PlatformError(platform: platform, message: j.string("error_description") ?? "No access token returned")
        }
        return t
    }

    public func refresh(_ old: OAuthTokens, config: PlatformAppConfig) async throws -> OAuthTokens {
        guard let refresh = old.refreshToken else {
            throw PlatformError(platform: platform, message: "Session expired", requiresReauth: true)
        }
        let j = try await http.json(.make(base.appendingPathComponent("oauth/token/"), method: "POST", form: [
            "client_key": config.clientID, "client_secret": config.clientSecret,
            "grant_type": "refresh_token", "refresh_token": refresh,
        ]))
        guard let t = tokens(fromJSON: j, keepingRefresh: refresh) else {
            throw PlatformError(platform: platform, message: "Refresh failed", requiresReauth: true)
        }
        return t
    }

    public func fetchProfile(tokens: OAuthTokens) async throws -> RemoteProfile {
        let url = base.appendingPathComponent("user/info/").with(query: ["fields": "open_id,display_name"])
        let j = try await http.json(.make(url, bearer: tokens.accessToken))
        guard let user = j.dict("data")?.dict("user"), let id = user.string("open_id") else {
            throw PlatformError(platform: platform, message: "Could not read the TikTok profile")
        }
        return RemoteProfile(remoteID: id, username: user.string("display_name") ?? id)
    }

    /// Needs the `video.list` scope. Only works once TikTok has assigned a
    /// public post id (not for private SELF_ONLY posts).
    public func fetchMetrics(remotePostID: String, account: Account, tokens: OAuthTokens) async throws -> PostMetrics {
        let url = base.appendingPathComponent("video/query/")
            .with(query: ["fields": "id,view_count,like_count,comment_count,share_count"])
        let j = try await http.json(.make(url, method: "POST", bearer: tokens.accessToken,
                                          json: ["filters": ["video_ids": [remotePostID]]]))
        guard let v = (j.dict("data")?["videos"] as? [[String: Any]])?.first else {
            throw PlatformError(platform: platform, message: "TikTok doesn't report stats for this post yet")
        }
        return PostMetrics(views: v.int("view_count"), likes: v.int("like_count"),
                           comments: v.int("comment_count"), shares: v.int("share_count"))
    }

    /// Privacy levels this creator may use right now (required before each post).
    public func privacyOptions(tokens: OAuthTokens) async throws -> [String] {
        let j = try await http.json(.make(base.appendingPathComponent("post/publish/creator_info/query/"),
                                          method: "POST", bearer: tokens.accessToken, json: [:]))
        return j.dict("data")?["privacy_level_options"] as? [String] ?? []
    }

    public func publish(_ req: PublishRequest, tokens: OAuthTokens,
                        progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult {
        // Resuming: with FILE_UPLOAD, TikTok posts once the upload completes.
        // Check the earlier publish id; start over only if it failed or its
        // upload never finished.
        if let cp = req.resume {
            let d: [String: Any]
            do {
                d = try await publishStatus(cp.remoteID, tokens: tokens)
            } catch let e as PlatformError where e.isRetryable {
                throw e
            } catch {
                throw PlatformError.unconfirmed(platform, "TikTok didn't return the earlier post's status")
            }
            switch d.string("status") {
            case "PUBLISH_COMPLETE":
                return result(d, publishID: cp.remoteID)
            case "FAILED":
                break
            case "PROCESSING_UPLOAD" where cp.step == .created:
                break
            default:
                progress(.processing)
                return try await waitForPublish(cp.remoteID, tokens: tokens)
            }
        }

        let options = try await privacyOptions(tokens: tokens)
        let wanted: String
        switch req.privacy {
        case .publicAudience: wanted = "PUBLIC_TO_EVERYONE"
        case .followers: wanted = "FOLLOWER_OF_CREATOR"
        case .privateOnly: wanted = "SELF_ONLY"
        }
        guard options.contains(wanted) else {
            throw PlatformError(platform: platform, httpStatus: 400,
                                message: "This account can't post as \"\(req.privacy.label)\". Allowed: \(options.joined(separator: ", "))")
        }

        let size = try FileManager.default.attributesOfItem(atPath: req.videoURL.path)[.size] as? Int ?? 0
        let plan = Self.chunkPlan(fileSize: size)
        var postInfo: [String: Any] = ["title": String(req.caption.prefix(2200)), "privacy_level": wanted]
        if let ms = req.coverTimeMs { postInfo["video_cover_timestamp_ms"] = ms }
        let initBody: [String: Any] = [
            "post_info": postInfo,
            "source_info": ["source": "FILE_UPLOAD", "video_size": size,
                            "chunk_size": plan.chunkSize, "total_chunk_count": plan.count],
        ]
        let initJ = try await http.json(.make(base.appendingPathComponent("post/publish/video/init/"),
                                              method: "POST", bearer: tokens.accessToken, json: initBody))
        guard let data = initJ.dict("data"), let publishID = data.string("publish_id"),
              let uploadURL = data.string("upload_url").flatMap(URL.init(string:)) else {
            throw PlatformError(platform: platform, message: "TikTok did not return an upload URL")
        }
        await req.checkpoint(.created, publishID)

        let handle = try FileHandle(forReadingFrom: req.videoURL)
        defer { try? handle.close() }
        for i in 0..<plan.count {
            let start = i * plan.chunkSize
            let end = i == plan.count - 1 ? size : start + plan.chunkSize
            try handle.seek(toOffset: UInt64(start))
            let chunk = handle.readData(ofLength: end - start)
            var put = URLRequest(url: uploadURL)
            put.httpMethod = "PUT"
            put.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            put.setValue("bytes \(start)-\(end - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            _ = try await http.upload(put, data: chunk)
            progress(.uploading(Double(i + 1) / Double(plan.count)))
        }
        await req.checkpoint(.uploaded, publishID)

        progress(.processing)
        return try await waitForPublish(publishID, tokens: tokens)
    }

    private func publishStatus(_ publishID: String, tokens: OAuthTokens) async throws -> [String: Any] {
        let s = try await http.json(.make(base.appendingPathComponent("post/publish/status/fetch/"),
                                          method: "POST", bearer: tokens.accessToken, json: ["publish_id": publishID]))
        return s.dict("data") ?? [:]
    }

    private func result(_ d: [String: Any], publishID: String) -> PublishResult {
        let postID = (d["publicaly_available_post_id"] as? [Any])?.first.map { "\($0)" }
        return PublishResult(remotePostID: postID ?? publishID, url: nil)
    }

    private func waitForPublish(_ publishID: String, tokens: OAuthTokens) async throws -> PublishResult {
        for _ in 0..<60 {
            try await pollDelay(5)
            let d = try await publishStatus(publishID, tokens: tokens)
            switch d.string("status") {
            case "PUBLISH_COMPLETE":
                return result(d, publishID: publishID)
            case "FAILED":
                throw PlatformError(platform: platform, httpStatus: 400, message: d.string("fail_reason") ?? "Processing failed")
            default:
                continue
            }
        }
        throw PlatformError(platform: platform, message: "Still processing after 5 minutes; check the TikTok app.")
    }

    /// TikTok: chunks 5–64 MB, last chunk may absorb the remainder (≤128 MB).
    /// Files ≤64 MB go up in one piece.
    static func chunkPlan(fileSize: Int) -> (chunkSize: Int, count: Int) {
        let mb = 1024 * 1024
        if fileSize <= 64 * mb { return (fileSize, 1) }
        let chunk = 10 * mb
        return (chunk, fileSize / chunk)
    }
}
