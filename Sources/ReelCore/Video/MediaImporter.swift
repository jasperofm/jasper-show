import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Copies a video into the library, reads its metadata and makes a thumbnail.
public final class MediaImporter {
    private let store: LibraryStore
    public static let supportedTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    public init(store: LibraryStore) { self.store = store }

    public func importVideo(at url: URL) async throws -> SourceAsset {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let relative = "Sources/\(id.uuidString).\(ext)"
        let dest = store.url(forRelative: relative)
        try FileManager.default.copyItem(at: url, to: dest)

        let asset = AVURLAsset(url: dest)
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
            let fps = try await track.load(.nominalFrameRate)
            let size = try await VariationRenderer.orientedSize(of: asset)

            let thumbRel = "Thumbnails/\(id.uuidString).jpg"
            try await Thumbnailer.writeThumbnail(for: asset, at: min(1, duration / 2), to: store.url(forRelative: thumbRel))

            let a = SourceAsset(id: id, title: url.deletingPathExtension().lastPathComponent, relativePath: relative,
                                originalFilename: url.lastPathComponent, duration: duration,
                                pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                frameRate: Double(fps), thumbnailPath: thumbRel)
            try store.insert(a)
            return a
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }
}

public enum Thumbnailer {
    /// Writes a JPEG of `asset` (or of a variation's composition when a video
    /// composition is passed) at `seconds`.
    public static func writeThumbnail(for asset: AVAsset, videoComposition: AVVideoComposition? = nil,
                                      at seconds: Double, to url: URL, maxSize: CGSize = CGSize(width: 640, height: 640)) async throws {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        gen.videoComposition = videoComposition
        let (cg, _) = try await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try data.write(to: url, options: .atomic)
    }
}
