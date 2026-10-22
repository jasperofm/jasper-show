import Foundation
import CoreGraphics

/// A half-open time range in seconds on the *source* timeline.
public struct TimeRange: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }
}

/// Every adjustment that defines a variation. Pure value type so it can be
/// diffed, stored as JSON in SQLite, and pushed onto the undo stack cheaply.
public struct EditSettings: Codable, Equatable, Sendable {
    // MARK: Framing
    /// Normalized crop rectangle (0...1 in both axes, origin top-left).
    public var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Pan offset applied after crop, normalized to the cropped frame (-1...1).
    public var pan: CGPoint = .zero
    /// 1.0 = no zoom. Clamped to 1...4.
    public var zoom: Double = 1.0
    /// Degrees, clockwise. Clamped to -180...180.
    public var rotation: Double = 0
    /// Output aspect ratio for the render (nil = keep the crop's aspect).
    public var outputAspect: OutputAspect = .source

    // MARK: Color
    /// -1...1, 0 = unchanged (CIColorControls inputBrightness).
    public var brightness: Double = 0
    /// 0.25...2, 1 = unchanged.
    public var contrast: Double = 1
    /// 0...2, 1 = unchanged.
    public var saturation: Double = 1
    /// Kelvin. 6500 = neutral.
    public var temperature: Double = 6500
    /// 0...1, darkens the corners.
    public var vignette: Double = 0
    /// 0...1.
    public var sharpness: Double = 0
    /// Imported .cube LUT (file name in the library's LUTs folder).
    public var lutID: String?
    /// 0...1, how strongly the LUT is applied.
    public var lutIntensity: Double = 1

    // MARK: Audio
    /// 0...2, 1 = unchanged, 0 = muted.
    public var volume: Double = 1
    /// Seconds of fade at the start and end of the output.
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0

    // MARK: Cover
    /// Frame used as the cover, in seconds on the output timeline. Nil = platform default.
    public var coverTime: Double?

    // MARK: Text
    /// Optional on-screen text burned into the video.
    public var overlay: TextOverlay?

    // MARK: Timing
    /// Sections of the source to remove.
    public var cuts: [TimeRange] = []
    /// Playback rate, 0.5...2.
    public var speed: Double = 1.0

    public init() {}

    /// Missing keys keep their defaults, so variations saved by older
    /// versions keep loading as new settings are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback }
        let d = EditSettings()
        crop = v(.crop, d.crop); pan = v(.pan, d.pan); zoom = v(.zoom, d.zoom); rotation = v(.rotation, d.rotation)
        outputAspect = v(.outputAspect, d.outputAspect)
        brightness = v(.brightness, d.brightness); contrast = v(.contrast, d.contrast)
        saturation = v(.saturation, d.saturation); temperature = v(.temperature, d.temperature)
        vignette = v(.vignette, d.vignette); sharpness = v(.sharpness, d.sharpness)
        lutID = v(.lutID, d.lutID); lutIntensity = v(.lutIntensity, d.lutIntensity)
        volume = v(.volume, d.volume); fadeIn = v(.fadeIn, d.fadeIn); fadeOut = v(.fadeOut, d.fadeOut)
        coverTime = v(.coverTime, d.coverTime)
        overlay = v(.overlay, d.overlay)
        cuts = v(.cuts, d.cuts); speed = v(.speed, d.speed)
    }

    public static let identity = EditSettings()
    public static let unitRange: ClosedRange<Double> = 0...1
    public static let volumeRange: ClosedRange<Double> = 0...2
    public static let fadeRange: ClosedRange<Double> = 0...5

    public static let zoomRange: ClosedRange<Double> = 1...4
    public static let rotationRange: ClosedRange<Double> = -180...180
    public static let brightnessRange: ClosedRange<Double> = -1...1
    public static let contrastRange: ClosedRange<Double> = 0.25...2
    public static let saturationRange: ClosedRange<Double> = 0...2
    public static let temperatureRange: ClosedRange<Double> = 2000...11000
    public static let speedRange: ClosedRange<Double> = 0.5...2

    /// Returns a copy with every value forced into its legal range and the cut
    /// list sorted, merged and clipped to the source duration.
    public func normalized(sourceDuration: Double) -> EditSettings {
        var s = self
        s.zoom = s.zoom.clamped(to: Self.zoomRange)
        s.rotation = s.rotation.clamped(to: Self.rotationRange)
        s.brightness = s.brightness.clamped(to: Self.brightnessRange)
        s.contrast = s.contrast.clamped(to: Self.contrastRange)
        s.saturation = s.saturation.clamped(to: Self.saturationRange)
        s.temperature = s.temperature.clamped(to: Self.temperatureRange)
        s.speed = s.speed.clamped(to: Self.speedRange)
        s.vignette = s.vignette.clamped(to: Self.unitRange)
        s.sharpness = s.sharpness.clamped(to: Self.unitRange)
        s.lutIntensity = s.lutIntensity.clamped(to: Self.unitRange)
        s.volume = s.volume.clamped(to: Self.volumeRange)
        s.fadeIn = s.fadeIn.clamped(to: Self.fadeRange)
        s.fadeOut = s.fadeOut.clamped(to: Self.fadeRange)
        s.pan = CGPoint(x: Double(s.pan.x).clamped(to: -1...1), y: Double(s.pan.y).clamped(to: -1...1))

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var c = s.crop.standardized.intersection(unit)
        if c.isNull || c.width < 0.05 || c.height < 0.05 { c = unit }
        s.crop = c

        s.cuts = Self.mergeCuts(s.cuts, duration: sourceDuration)
        return s
    }

    /// Sorted, non-overlapping cuts clipped to [0, duration]. Empty ranges dropped.
    public static func mergeCuts(_ cuts: [TimeRange], duration: Double) -> [TimeRange] {
        let clipped = cuts
            .map { TimeRange(id: $0.id, start: max(0, $0.start), end: min(duration, $0.end)) }
            .filter { $0.duration > 0.01 }
            .sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for cut in clipped {
            if var last = merged.last, cut.start <= last.end {
                last.end = max(last.end, cut.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(cut)
            }
        }
        return merged
    }

    /// Source ranges that survive the cuts, in order.
    public func keptRanges(sourceDuration: Double) -> [TimeRange] {
        var kept: [TimeRange] = []
        var cursor = 0.0
        for cut in Self.mergeCuts(cuts, duration: sourceDuration) {
            if cut.start > cursor { kept.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = cut.end
        }
        if cursor < sourceDuration { kept.append(TimeRange(start: cursor, end: sourceDuration)) }
        return kept
    }

    /// Duration of the rendered output after cuts and speed.
    public func outputDuration(sourceDuration: Double) -> Double {
        let kept = keptRanges(sourceDuration: sourceDuration).reduce(0) { $0 + $1.duration }
        return kept / speed.clamped(to: Self.speedRange)
    }

    /// Human-readable list of what differs from the untouched source. Used by
    /// the comparison view's hover tooltip.
    public var changeSummary: [String] {
        var out: [String] = []
        let d = EditSettings.identity
        if crop != d.crop { out.append(String(format: "Crop %.0f%%×%.0f%%", crop.width * 100, crop.height * 100)) }
        if pan != d.pan { out.append(String(format: "Pan (%.2f, %.2f)", pan.x, pan.y)) }
        if zoom != d.zoom { out.append(String(format: "Zoom %.2f×", zoom)) }
        if rotation != d.rotation { out.append(String(format: "Rotate %.0f°", rotation)) }
        if outputAspect != d.outputAspect { out.append("Aspect \(outputAspect.label)") }
        if brightness != d.brightness { out.append(String(format: "Brightness %+.2f", brightness)) }
        if contrast != d.contrast { out.append(String(format: "Contrast %.2f", contrast)) }
        if saturation != d.saturation { out.append(String(format: "Saturation %.2f", saturation)) }
        if temperature != d.temperature { out.append(String(format: "Temperature %.0fK", temperature)) }
        if !cuts.isEmpty {
            let total = cuts.reduce(0) { $0 + $1.duration }
            out.append(String(format: "%d cut(s), %.1fs removed", cuts.count, total))
        }
        if speed != d.speed { out.append(String(format: "Speed %.2f×", speed)) }
        if vignette != d.vignette { out.append(String(format: "Vignette %.2f", vignette)) }
        if sharpness != d.sharpness { out.append(String(format: "Sharpen %.2f", sharpness)) }
        if let l = lutID { out.append("LUT \((l as NSString).deletingPathExtension)") }
        if volume != d.volume { out.append(volume == 0 ? "Muted" : String(format: "Volume %.0f%%", volume * 100)) }
        if fadeIn > 0 || fadeOut > 0 { out.append(String(format: "Fade %.1fs / %.1fs", fadeIn, fadeOut)) }
        if let t = coverTime { out.append(String(format: "Cover at %.1fs", t)) }
        if let o = overlay, !o.isEmpty { out.append("Text \"\(o.text.prefix(24))\"") }
        return out.isEmpty ? ["No edits"] : out
    }
}

/// Text drawn on top of the video.
public struct TextOverlay: Codable, Equatable, Hashable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable {
        case top, center, bottom
        public var label: String { rawValue.capitalized }
    }
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// White text on a dark translucent box.
        case darkBox
        /// Black text on a white box.
        case lightBox
        /// White text, no box.
        case plain
        public var label: String {
            switch self {
            case .darkBox: return "White on dark"
            case .lightBox: return "Black on white"
            case .plain: return "White text"
            }
        }
    }

    public var text: String
    public var position: Position
    public var style: Style
    /// Text height as a fraction of the frame height.
    public var size: Double

    public init(text: String = "", position: Position = .top, style: Style = .darkBox, size: Double = 0.05) {
        self.text = text; self.position = position; self.style = style; self.size = size
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public static let sizeRange: ClosedRange<Double> = 0.025...0.12
}

public enum OutputAspect: String, Codable, CaseIterable, Sendable {
    case source, vertical9x16, square1x1, portrait4x5, landscape16x9

    public var label: String {
        switch self {
        case .source: return "Source"
        case .vertical9x16: return "9:16"
        case .square1x1: return "1:1"
        case .portrait4x5: return "4:5"
        case .landscape16x9: return "16:9"
        }
    }

    /// width / height, or nil to follow the crop.
    public var ratio: Double? {
        switch self {
        case .source: return nil
        case .vertical9x16: return 9.0 / 16.0
        case .square1x1: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .landscape16x9: return 16.0 / 9.0
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
