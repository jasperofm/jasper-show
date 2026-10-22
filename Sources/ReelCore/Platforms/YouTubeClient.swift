import Foundation

/// YouTube Data API v3. Uploads with the resumable protocol.
/// Docs: https://developers.google.com/youtube/v3/guides/using_resumable_upload_protocol
///
/// Note: videos uploaded by API projects that haven't passed Google's audit
/// are locked to private. Each upload costs ~1,600 of the default 10,000
/// daily quota units.
public struct YouTubeClient: PlatformClient {
    public let platform = Platform.youtube
    private let http: HTTP
    static let scopes = "https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly"

    public init(session: URLSession = .shared) { http = HTTP(platform: .youtube, session: session) }

    public func authorizationURL(config: PlatformAppConfig, pkce: PKCE, state: String) -> URL {
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!.with(query: [
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "response_type": "code",
            "scope": Self.scopes,
            "state": state,
            "code_challenge": pkce.challenge,
            "code_challenge_method": "S256",
            "access_type": "offline",
            "prompt": "consent select_account",
        ])
    }

    public func exchange(code: String, pkce: PKCE, config: PlatformAppConfig) async throws -> OAuthTokens {
        var form = ["code": code, "client_id": config.clientID, "redirect_uri": config.redirectURI,
                    "grant_type": "authorization_code", "code_verifier": pkce.verifier]
        if !config.clientSecret.isEmpty { form["client_secret"] = config.clientSecret }
        let j = try await http.json(.make(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: form))
        guard let t = tokens(fromJSON: j) else { throw PlatformError(platform: platform, message: "No access token returned") }
        return t
    }

    public func refresh(_ old: OAuthTokens, config: PlatformAppConfig) async throws -> OAuthTokens {
        guard let refresh = old.refreshToken else {
            throw PlatformError(platform: platform, message: "Session expired", requiresReauth: true)
        }
        var form = ["refresh_token": refresh, "client_id": config.clientID, "grant_type": "refresh_token"]
        if !config.clientSecret.isEmpty { form["client_secret"] = config.clientSecret }
        let j = try await http.json(.make(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST", form: form))
        guard let t = tokens(fromJSON: j, keepingRefresh: refresh) else {
            throw PlatformError(platform: platform, message: "Refresh failed", requiresReauth: true)
        }
        return t
    }

    public func fetchProfile(tokens: OAuthTokens) async throws -> RemoteProfile {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/channels")!.with(query: ["part": "snippet", "mine": "true"])
        let j = try await http.json(.make(url, bearer: tokens.accessToken))
        guard let item = (j["items"] as? [[String: Any]])?.first, let id = item.string("id") else {
            throw PlatformError(platform: platform, message: "This Google account has no YouTube channel.")
        }
        let snippet = item.dict("snippet")
        let name = snippet?.string("customUrl") ?? snippet?.string("title") ?? id
        return RemoteProfile(remoteID: id, username: name)
    }

    public func fetchMetrics(remotePostID: String, account: Account, tokens: OAuthTokens) async throws -> PostMetrics {
        let url = URL(string: "https://www.googleapis.com/youtube/v3/videos")!
            .with(query: ["part": "statistics", "id": remotePostID])
        let j = try await http.json(.make(url, bearer: tokens.accessToken))
        guard let stats = (j["items"] as? [[String: Any]])?.first?.dict("statistics") else {
            throw PlatformError(platform: platform, message: "Video not found (it may have been deleted)")
        }
        return PostMetrics(views: stats.int("viewCount"), likes: stats.int("likeCount"), comments: stats.int("commentCount"))
    }

    public func publish(_ req: PublishRequest, tokens: OAuthTokens,
                        progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult {
        let size = try FileManager.default.attributesOfItem(atPath: req.videoURL.path)[.size] as? Int ?? 0

        // Resuming: ask the upload session how far it got. A finished
        // session means the video already exists; never start a second one.
        if let cp = req.resume, let session = URL(string: cp.remoteID) {
            var probe = URLRequest(url: session)
            probe.httpMethod = "PUT"
            probe.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            probe.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
            do {
                let (data, resp) = try await http.upload(probe, data: Data())
                if resp.statusCode == 308 {
                    let received = resp.value(forHTTPHeaderField: "Range")
                        .flatMap { $0.split(separator: "-").last }.flatMap { Int($0) }.map { $0 + 1 } ?? 0
                    return try await upload(req, to: session, from: received, size: size, tokens: tokens, progress: progress)
                }
                return try video(from: data)
            } catch let e as PlatformError where e.httpStatus == 404 || e.httpStatus == 410 {
                // Session expired before the upload finished: nothing was published.
            }
        }

        let privacy: String
        switch req.privacy {
        case .publicAudience: privacy = "public"
        case .followers: privacy = "unlisted"
        case .privateOnly: privacy = "private"
        }
        let metadata: [String: Any] = [
            "snippet": ["title": String(req.title.prefix(100)), "description": req.caption, "categoryId": "22"],
            "status": ["privacyStatus": privacy, "selfDeclaredMadeForKids": false],
        ]
        let initURL = URL(string: "https://www.googleapis.com/upload/youtube/v3/videos")!
            .with(query: ["uploadType": "resumable", "part": "snippet,status"])
        var initReq = URLRequest.make(initURL, method: "POST", bearer: tokens.accessToken, json: metadata)
        initReq.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        initReq.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        let (_, initResp) = try await http.send(initReq)
        guard let loc = initResp.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: loc) else {
            throw PlatformError(platform: platform, message: "Upload session was not created")
        }
        await req.checkpoint(.created, uploadURL.absoluteString)
        return try await upload(req, to: uploadURL, from: 0, size: size, tokens: tokens, progress: progress)
    }

    private func upload(_ req: PublishRequest, to session: URL, from offset: Int, size: Int, tokens: OAuthTokens,
                        progress: @escaping @Sendable (PublishStage) -> Void) async throws -> PublishResult {
        progress(.uploading(size > 0 ? Double(offset) / Double(size) : 0))
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        put.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let data: Data
        if offset == 0 {
            (data, _) = try await http.upload(put, fromFile: req.videoURL)
        } else {
            let handle = try FileHandle(forReadingFrom: req.videoURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let rest = handle.readDataToEndOfFile()
            put.setValue("bytes \(offset)-\(size - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            (data, _) = try await http.upload(put, data: rest)
        }
        progress(.uploading(1))
        return try video(from: data)
    }

    private func video(from data: Data) throws -> PublishResult {
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let id = j.string("id") else { throw PlatformError(platform: platform, message: "Upload finished without a video id") }
        return PublishResult(remotePostID: id, url: "https://www.youtube.com/shorts/\(id)")
    }
}
