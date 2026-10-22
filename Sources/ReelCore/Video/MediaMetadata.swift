import Foundation
import AVFoundation

/// Reads identifying metadata in the user's own file (where it was filmed,
/// on which device) so they can see it before it's removed on export.
public enum MediaMetadata {
    public struct Item: Hashable, Sendable {
        public var label: String
        public var value: String
    }

    public static func privateInfo(of url: URL) async -> [Item] {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return [] }
        var out: [Item] = []
        for item in items {
            guard let label = label(for: item) else { continue }
            let value = (try? await item.load(.stringValue)) ?? nil
            if let value, !value.isEmpty, !out.contains(where: { $0.label == label }) {
                out.append(Item(label: label, value: value))
            }
        }
        return out.sorted { $0.label < $1.label }
    }

    static func label(for item: AVMetadataItem) -> String? {
        if item.commonKey == .commonKeyLocation || item.identifier == .quickTimeMetadataLocationISO6709 { return "Location" }
        if item.commonKey == .commonKeyMake || item.identifier == .quickTimeMetadataMake { return "Device maker" }
        if item.commonKey == .commonKeyModel || item.identifier == .quickTimeMetadataModel { return "Device model" }
        if item.commonKey == .commonKeySoftware || item.identifier == .quickTimeMetadataSoftware { return "Software" }
        if item.commonKey == .commonKeyCreationDate || item.identifier == .quickTimeMetadataCreationDate { return "Recorded on" }
        return nil
    }
}
