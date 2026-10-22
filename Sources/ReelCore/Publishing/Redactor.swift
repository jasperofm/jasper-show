import Foundation

/// Strips secrets from text before it is logged or shown: access tokens in
/// query strings and JSON, Bearer/OAuth headers, client secrets and codes.
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        // key=value in URLs and form bodies
        #"(?i)((?:access_token|refresh_token|client_secret|code|code_verifier|id_token|fb_exchange_token)=)[^&\s"']+"#,
        // "key": "value" in JSON
        #"(?i)("(?:access_token|refresh_token|client_secret|id_token)"\s*:\s*")[^"]+"#,
        // Authorization headers
        #"(?i)((?:Bearer|OAuth)\s+)[A-Za-z0-9\-._~+/=]{8,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var s = text
        for re in patterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1[redacted]")
        }
        return s
    }
}
