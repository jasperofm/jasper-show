import Foundation
import AuthenticationServices
import CryptoKit
import Security
import AppKit

/// Developer app credentials for one platform. Client IDs and redirect URIs are
/// stored in UserDefaults; client secrets live in the Keychain.
public struct PlatformAppConfig: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    /// Must match exactly what is registered in the platform's developer console.
    public var redirectURI: String

    public init(clientID: String = "", clientSecret: String = "", redirectURI: String = "") {
        self.clientID = clientID; self.clientSecret = clientSecret; self.redirectURI = redirectURI
    }

    public var isComplete: Bool { !clientID.isEmpty && !redirectURI.isEmpty }

    /// Scheme ASWebAuthenticationSession listens for. For https redirects
    /// (Instagram requires one) the registered page must forward to the app's
    /// custom scheme; see README.
    public var callbackScheme: String {
        let scheme = URL(string: redirectURI)?.scheme ?? "reelmanager"
        return scheme == "https" ? "reelmanager" : scheme
    }
}

/// Redirect URIs the setup wizard fills in for you.
public enum OAuthRedirects {
    /// GitHub Pages site hosting the small "back to the app" pages in /docs/oauth.
    /// Meta and TikTok only accept https redirects; those pages forward to reelmanager://.
    public static var pagesBase = "https://jasperofm.github.io/jasper-show"

    public static func suggested(for p: Platform, clientID: String) -> String {
        switch p {
        case .instagram, .facebook, .tiktok:
            return "\(pagesBase)/oauth/\(p.rawValue)/"
        case .youtube:
            // Google iOS-type clients use the reversed client ID as a custom scheme.
            let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return prefix.isEmpty ? "" : "com.googleusercontent.apps.\(prefix):/oauth2redirect"
        }
    }
}

public final class PlatformConfigStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychain: KeychainStore

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(service: "com.reelmanager.appconfig")) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func config(for p: Platform) -> PlatformAppConfig {
        var c = PlatformAppConfig(clientID: defaults.string(forKey: "config.\(p.rawValue).clientID") ?? "",
                                  redirectURI: defaults.string(forKey: "config.\(p.rawValue).redirectURI") ?? "")
        c.clientSecret = (try? keychain.load(String.self, for: "secret.\(p.rawValue)")) ?? ""
        return c
    }

    public func save(_ c: PlatformAppConfig, for p: Platform) throws {
        defaults.set(c.clientID, forKey: "config.\(p.rawValue).clientID")
        defaults.set(c.redirectURI, forKey: "config.\(p.rawValue).redirectURI")
        if c.clientSecret.isEmpty {
            try keychain.delete(for: "secret.\(p.rawValue)")
        } else {
            try keychain.save(c.clientSecret, for: "secret.\(p.rawValue)")
        }
    }
}

/// RFC 7636 PKCE pair.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URLEncoded
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    /// TikTok's desktop flow wants the challenge as hex SHA-256 instead of base64url.
    public var hexChallenge: String {
        SHA256.hash(data: Data(verifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthError: Error, LocalizedError {
    case notConfigured(Platform)
    case cancelled
    case stateMismatch
    case missingCode(String?)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let p): return "Add your \(p.displayName) app's client ID and redirect URI in Settings first."
        case .cancelled: return "Sign-in was cancelled."
        case .stateMismatch: return "Sign-in response didn't match the request. Please try again."
        case .missingCode(let e): return "Sign-in failed: \(e ?? "no authorization code returned")."
        }
    }
}

/// Runs the browser part of an authorization-code flow and returns the code.
public final class OAuthBrowserFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let anchor: ASPresentationAnchor

    @MainActor
    public override init() {
        anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        super.init()
    }

    @MainActor
    public func authorize(url: URL, callbackScheme: String, expectedState: String) async throws -> String {
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: OAuthError.cancelled) }
                else { cont.resume(throwing: error ?? OAuthError.missingCode(nil)) }
            }
            s.presentationContextProvider = self
            // Separate cookie jar so each connect can sign into a different account.
            s.prefersEphemeralWebBrowserSession = true
            session = s
            s.start()
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard item("state") == expectedState else { throw OAuthError.stateMismatch }
        guard let code = item("code") else { throw OAuthError.missingCode(item("error_description") ?? item("error")) }
        return code
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
