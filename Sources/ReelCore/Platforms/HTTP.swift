import Foundation

/// Error from a platform API, carrying what the posting service needs to
/// decide between "retry later" and "needs the user".
public struct PlatformError: Error, LocalizedError, Sendable {
    public var platform: Platform
    public var httpStatus: Int?
    public var message: String
    /// Server-provided Retry-After, if any.
    public var retryAfter: TimeInterval?
    /// Token invalid or revoked: the account must be reconnected.
    public var requiresReauth: Bool

    public init(platform: Platform, httpStatus: Int? = nil, message: String,
                retryAfter: TimeInterval? = nil, requiresReauth: Bool = false) {
        self.platform = platform; self.httpStatus = httpStatus; self.message = message
        self.retryAfter = retryAfter; self.requiresReauth = requiresReauth
    }

    /// Network errors, 429 and 5xx are worth retrying; 4xx usually are not.
    public var isRetryable: Bool {
        if requiresReauth { return false }
        guard let s = httpStatus else { return true }
        return s == 408 || s == 429 || (500...599).contains(s)
    }

    public var errorDescription: String? {
        let code = httpStatus.map { " (HTTP \($0))" } ?? ""
        return "\(platform.displayName): \(message)\(code)"
    }
}

/// Small async HTTP helper shared by the platform clients.
public struct HTTP: Sendable {
    public let platform: Platform
    public let session: URLSession

    public init(platform: Platform, session: URLSession = .shared) {
        self.platform = platform
        self.session = session
    }

    public func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw PlatformError(platform: platform, message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw PlatformError(platform: platform, message: "Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw error(from: data, response: http)
        }
        return (data, http)
    }

    public func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await send(req)
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlatformError(platform: platform, message: "Unexpected response body")
        }
        return obj
    }

    public func upload(_ req: URLRequest, fromFile url: URL) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.upload(for: req, fromFile: url)
        } catch {
            throw PlatformError(platform: platform, message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw PlatformError(platform: platform, message: "Invalid response") }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 308 else { throw error(from: data, response: http) }
        return (data, http)
    }

    public func upload(_ req: URLRequest, data body: Data) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.upload(for: req, from: body)
        } catch {
            throw PlatformError(platform: platform, message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw PlatformError(platform: platform, message: "Invalid response") }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 308 else { throw error(from: data, response: http) }
        return (data, http)
    }

    /// Pulls a readable message out of the three platforms' error shapes.
    func error(from data: Data, response: HTTPURLResponse) -> PlatformError {
        var message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any] {
                // Graph API: {error:{message}}, Google: {error:{message}}, TikTok: {error:{code,message}}
                message = (err["message"] as? String) ?? (err["code"] as? String) ?? message
            } else if let desc = obj["error_description"] as? String {
                message = desc
            } else if let err = obj["error"] as? String {
                message = err
            }
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return PlatformError(platform: platform, httpStatus: response.statusCode, message: message,
                             retryAfter: retryAfter, requiresReauth: response.statusCode == 401)
    }
}

extension URLRequest {
    static func make(_ url: URL, method: String = "GET", bearer: String? = nil,
                     json: [String: Any]? = nil, form: [String: String]? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        } else if let form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = form.formEncoded.data(using: .utf8)
        }
        return r
    }
}

extension Dictionary where Key == String, Value == String {
    var formEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }
        .sorted()
        .joined(separator: "&")
    }
}

extension URL {
    func with(query: [String: String]) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}
