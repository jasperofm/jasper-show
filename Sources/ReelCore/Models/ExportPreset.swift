import Foundation
import AVFoundation

/// Quality presets. All presets render H.264/HEVC through AVAssetWriter-backed
/// export sessions; "Maximum" keeps the source resolution with a very high bitrate.
public enum ExportPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximum, high, balanced
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maximum: return "Maximum"
        case .high: return "High"
        case .balanced: return "Balanced"
        }
    }

    public var detail: String {
        switch self {
        case .maximum: return "Source resolution up to 4K, HEVC, highest bitrate"
        case .high: return "Up to 1080p, H.264, minimal loss"
        case .balanced: return "Up to 720p, H.264, smaller files"
        }
    }

    /// AVAssetExportSession preset name.
    public var avPresetName: String {
        switch self {
        case .maximum: return AVAssetExportPresetHEVCHighestQuality
        case .high: return AVAssetExportPreset1920x1080
        case .balanced: return AVAssetExportPreset1280x720
        }
    }

    /// Longest edge, in pixels, the render is allowed to reach.
    public var maxLongEdge: Int {
        switch self {
        case .maximum: return 3840
        case .high: return 1920
        case .balanced: return 1280
        }
    }
}
