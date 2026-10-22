import Foundation
import AVFoundation
import CoreImage
import AppKit

public enum RenderError: Error, LocalizedError {
    case noVideoTrack
    case nothingLeft
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .nothingLeft: return "The cuts remove the whole video."
        case .exportFailed(let m): return "Export failed: \(m)"
        }
    }
}

/// Everything AVFoundation needs to play or export a variation.
public struct RenderPlan {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    /// Volume and fades; nil when the audio is untouched.
    public let audioMix: AVAudioMix?
    public let renderSize: CGSize
}

/// Holds the settings read by the Core Image handler. The live preview swaps
/// settings in here, so color and framing changes appear without rebuilding
/// the player item.
public final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: EditSettings
    public init(_ v: EditSettings) { _value = v }
    public var value: EditSettings {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Builds compositions for a source asset and a set of edits.
public enum VariationRenderer {

    /// Timeline part: drops cut ranges and applies the speed change.
    /// Changing cuts or speed requires a new composition.
    public static func makeComposition(source: AVAsset, settings: EditSettings) async throws -> AVMutableComposition {
        let duration = try await source.load(.duration).seconds
        guard let srcVideo = try await source.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let srcAudio = try await source.loadTracks(withMediaType: .audio).first
        let transform = try await srcVideo.load(.preferredTransform)

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.noVideoTrack
        }
        vTrack.preferredTransform = transform
        let aTrack = srcAudio == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let kept = settings.keptRanges(sourceDuration: duration)
        guard !kept.isEmpty else { throw RenderError.nothingLeft }

        var cursor = CMTime.zero
        let timescale: CMTimeScale = 600
        for range in kept {
            let tr = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: timescale),
                                 end: CMTime(seconds: range.end, preferredTimescale: timescale))
            try vTrack.insertTimeRange(tr, of: srcVideo, at: cursor)
            if let srcAudio, let aTrack { try aTrack.insertTimeRange(tr, of: srcAudio, at: cursor) }
            cursor = cursor + tr.duration
        }

        let speed = settings.speed
        if abs(speed - 1) > 0.0001 {
            let whole = CMTimeRange(start: .zero, duration: cursor)
            let scaled = CMTimeMultiplyByFloat64(cursor, multiplier: 1 / speed)
            comp.scaleTimeRange(whole, toDuration: scaled)
        }
        return comp
    }

    /// Visual part: framing + color via a Core Image handler that reads `box`.
    public static func makeVideoComposition(for composition: AVAsset, sourceSize: CGSize,
                                            box: SettingsBox, maxLongEdge: Int) -> AVMutableVideoComposition {
        let initial = FrameGeometry(sourceSize: sourceSize, settings: box.value)
        let vc = AVMutableVideoComposition(asset: composition) { request in
            let s = box.value
            let output = apply(s, to: request.sourceImage, sourceSize: request.sourceImage.extent.size,
                               renderSize: request.renderSize)
            request.finish(with: output, context: nil)
        }
        vc.renderSize = initial.renderSize(maxLongEdge: maxLongEdge)
        return vc
    }

    /// Applies every visual edit to one frame and scales it to `renderSize`.
    public static func apply(_ s: EditSettings, to image: CIImage, sourceSize: CGSize, renderSize: CGSize) -> CIImage {
        let origin = image.extent.origin
        let base = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let geo = FrameGeometry(sourceSize: sourceSize, settings: s)

        var img = base.clampedToExtent().transformed(by: geo.imageTransform)
            .cropped(to: CGRect(origin: .zero, size: geo.window.size))

        // Fit window to the render size (window aspect can drift from renderSize
        // when only the color changed but renderSize was computed for the old crop).
        let sx = renderSize.width / geo.window.width
        let sy = renderSize.height / geo.window.height
        img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // Color.
        let d = EditSettings.identity
        if s.brightness != d.brightness || s.contrast != d.contrast || s.saturation != d.saturation {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: s.brightness,
                kCIInputContrastKey: s.contrast,
                kCIInputSaturationKey: s.saturation,
            ])
        }
        if s.temperature != d.temperature {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: s.temperature, y: 0),
            ])
        }
        if let lut = s.lutID {
            img = LUTLibrary.shared.apply(lut, intensity: s.lutIntensity, to: img)
        }
        if s.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: s.sharpness * 1.5])
        }
        if s.vignette > 0 {
            let r = Double(max(renderSize.width, renderSize.height))
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: renderSize.width / 2, y: renderSize.height / 2),
                kCIInputRadiusKey: r * 0.75, kCIInputIntensityKey: s.vignette, "inputFalloff": 0.6,
            ])
        }
        if let overlay = s.overlay, !overlay.isEmpty {
            img = OverlayRenderer.shared.image(for: overlay, renderSize: renderSize).composited(over: img)
        }
        return img.cropped(to: CGRect(origin: .zero, size: renderSize))
    }

    /// Volume and fade ramps for the composition's audio. Nil when unchanged.
    public static func makeAudioMix(for comp: AVComposition, settings s: EditSettings) -> AVAudioMix? {
        let tracks = comp.tracks(withMediaType: .audio)
        guard !tracks.isEmpty, s.volume != 1 || s.fadeIn > 0 || s.fadeOut > 0 else { return nil }
        let total = comp.duration
        let ts: CMTimeScale = 600
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let p = AVMutableAudioMixInputParameters(track: track)
            let v = Float(s.volume)
            p.setVolume(v, at: .zero)
            let fadeIn = min(s.fadeIn, total.seconds / 2)
            let fadeOut = min(s.fadeOut, total.seconds / 2)
            if fadeIn > 0 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: v,
                                timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fadeIn, preferredTimescale: ts)))
            }
            if fadeOut > 0 {
                let d = CMTime(seconds: fadeOut, preferredTimescale: ts)
                p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: total - d, duration: d))
            }
            return p
        }
        return mix
    }

    /// Display size of the source's video track after its preferred transform.
    public static func orientedSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let (natural, t) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Full plan for playback or export.
    public static func plan(source: AVAsset, settings: EditSettings, box: SettingsBox? = nil,
                            maxLongEdge: Int) async throws -> RenderPlan {
        let size = try await orientedSize(of: source)
        let comp = try await makeComposition(source: source, settings: settings)
        let vc = makeVideoComposition(for: comp, sourceSize: size, box: box ?? SettingsBox(settings), maxLongEdge: maxLongEdge)
        return RenderPlan(composition: comp, videoComposition: vc, audioMix: makeAudioMix(for: comp, settings: settings),
                          renderSize: vc.renderSize)
    }
}
