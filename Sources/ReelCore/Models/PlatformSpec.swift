import Foundation

/// What each platform accepts through its publishing API, used to warn
/// before posting and to suggest export settings.
public struct PlatformSpec: Sendable {
    public var platform: Platform
    public var minDuration: Double
    public var maxDuration: Double
    public var recommendedAspect: OutputAspect
    public var recommendedPreset: ExportPreset
    public var maxFileBytes: Int
    public var note: String

    public static func spec(for p: Platform) -> PlatformSpec {
        switch p {
        case .instagram:
            return PlatformSpec(platform: p, minDuration: 3, maxDuration: 15 * 60, recommendedAspect: .vertical9x16,
                                recommendedPreset: .high, maxFileBytes: 1_000_000_000,
                                note: "Reels: 9:16, 3 s to 15 min, up to 1 GB.")
        case .facebook:
            return PlatformSpec(platform: p, minDuration: 3, maxDuration: 90, recommendedAspect: .vertical9x16,
                                recommendedPreset: .high, maxFileBytes: 1_000_000_000,
                                note: "Page Reels: 9:16, 3 to 90 s.")
        case .tiktok:
            return PlatformSpec(platform: p, minDuration: 3, maxDuration: 10 * 60, recommendedAspect: .vertical9x16,
                                recommendedPreset: .high, maxFileBytes: 4_000_000_000,
                                note: "9:16, 3 s to 10 min (your account's limit may be lower).")
        case .youtube:
            return PlatformSpec(platform: p, minDuration: 1, maxDuration: 12 * 3600, recommendedAspect: .vertical9x16,
                                recommendedPreset: .maximum, maxFileBytes: 256_000_000_000,
                                note: "Vertical videos up to 3 min are treated as Shorts.")
        }
    }

    /// Problems that would make the upload fail or look wrong, in plain words.
    public func issues(duration: Double, aspect: Double, fileBytes: Int?) -> [String] {
        var out: [String] = []
        if duration < minDuration { out.append("\(platform.displayName) needs at least \(Int(minDuration)) s.") }
        if duration > maxDuration { out.append("\(platform.displayName) allows up to \(Self.format(maxDuration)) through its API.") }
        if let b = fileBytes, b > maxFileBytes { out.append("File is too large for \(platform.displayName).") }
        if platform == .youtube, aspect < 1, duration > 180 {
            out.append("Over 3 min, so YouTube will post it as a regular video, not a Short.")
        }
        if let ratio = recommendedAspect.ratio, abs(aspect - ratio) > 0.02 {
            out.append("Not \(recommendedAspect.label); \(platform.displayName) will add bars or crop it.")
        }
        return out
    }

    static func format(_ s: Double) -> String {
        s >= 3600 ? "\(Int(s / 3600)) h" : s >= 60 ? "\(Int(s / 60)) min" : "\(Int(s)) s"
    }
}
