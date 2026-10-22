import Foundation
import AVFoundation

/// Renders a variation to an .mp4 file.
public final class VideoExporter {
    public init() {}

    /// - Parameter progress: called on an arbitrary queue with 0...1.
    public func export(sourceURL: URL, settings: EditSettings, preset: ExportPreset, to output: URL,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let source = AVURLAsset(url: sourceURL)
        let plan = try await VariationRenderer.plan(source: source, settings: settings, maxLongEdge: preset.maxLongEdge)

        guard let session = AVAssetExportSession(asset: plan.composition, presetName: preset.avPresetName) else {
            throw RenderError.exportFailed("Preset \(preset.displayName) is not available for this video.")
        }
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = plan.videoComposition
        session.audioTimePitchAlgorithm = .spectral // keep pitch natural at non-1× speed
        session.shouldOptimizeForNetworkUse = true

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler { progress(Double(session.progress)) }
        timer.resume()
        defer { timer.cancel() }

        await session.export()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default: throw RenderError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        }
    }
}
