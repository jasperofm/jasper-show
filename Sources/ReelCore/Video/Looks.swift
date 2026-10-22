import Foundation
import CoreImage

/// One-click color looks. Each just sets the ordinary color sliders, so the
/// result stays fully editable afterwards.
public enum LookPreset: String, CaseIterable, Identifiable, Sendable {
    case natural, warm, cool, punchy, faded, mono, cinematic

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public func apply(to s: inout EditSettings) {
        let d = EditSettings.identity
        s.brightness = d.brightness; s.contrast = d.contrast; s.saturation = d.saturation
        s.temperature = d.temperature; s.vignette = 0; s.sharpness = 0
        switch self {
        case .natural: break
        case .warm: s.temperature = 5200; s.saturation = 1.1
        case .cool: s.temperature = 8000; s.contrast = 1.05
        case .punchy: s.contrast = 1.2; s.saturation = 1.3; s.sharpness = 0.3
        case .faded: s.contrast = 0.8; s.saturation = 0.75; s.brightness = 0.05
        case .mono: s.saturation = 0; s.contrast = 1.15
        case .cinematic: s.contrast = 1.15; s.saturation = 0.85; s.temperature = 6000; s.vignette = 0.5
        }
    }
}

public enum LUTError: Error, LocalizedError {
    case unreadable, noSize, wrongCount(Int, Int), unsupportedSize(Int)
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be read as a .cube LUT."
        case .noSize: return "The LUT has no LUT_3D_SIZE line. Only 3D .cube LUTs are supported."
        case .wrongCount(let want, let got): return "The LUT should have \(want) color rows but has \(got)."
        case .unsupportedSize(let n): return "LUT size \(n) isn't supported (2 to 64)."
        }
    }
}

/// A parsed 3D LUT, ready for CIColorCubeWithColorSpace.
public struct CubeLUT: Sendable {
    public let size: Int
    /// RGBA floats, red changing fastest (the order Core Image expects).
    public let data: Data

    public static func parse(_ text: String) throws -> CubeLUT {
        var size: Int?
        var minV: [Float] = [0, 0, 0], maxV: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts.first?.uppercased() {
            case "LUT_3D_SIZE": size = parts.count > 1 ? Int(parts[1]) : nil
            case "DOMAIN_MIN": minV = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX": maxV = parts.dropFirst().compactMap { Float($0) }
            case "TITLE", "LUT_1D_SIZE", "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE": continue
            default:
                let nums = parts.compactMap { Float($0) }
                if nums.count == 3 {
                    for i in 0..<3 {
                        let lo = minV.count == 3 ? minV[i] : 0, hi = maxV.count == 3 ? maxV[i] : 1
                        values.append(hi > lo ? (nums[i] - lo) / (hi - lo) : nums[i])
                    }
                    values.append(1)
                }
            }
        }
        guard let n = size else { throw LUTError.noSize }
        guard (2...64).contains(n) else { throw LUTError.unsupportedSize(n) }
        guard values.count == n * n * n * 4 else { throw LUTError.wrongCount(n * n * n, values.count / 4) }
        return CubeLUT(size: n, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}

/// Imported LUT files, kept in the library's LUTs folder, parsed once and cached.
public final class LUTLibrary: @unchecked Sendable {
    public static let shared = LUTLibrary()
    public var directory: URL
    private var cache: [String: CubeLUT] = [:]
    private let lock = NSLock()

    public init(directory: URL = LibraryStore.defaultRoot.appendingPathComponent("LUTs")) {
        self.directory = directory
    }

    /// Copies a .cube file into the library (after checking it parses) and returns its id.
    public func importCube(from url: URL) throws -> String {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            throw LUTError.unreadable
        }
        let lut = try CubeLUT.parse(text)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = url.lastPathComponent
        let dest = directory.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dest)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        lock.lock(); cache[id] = lut; lock.unlock()
        return id
    }

    public func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".cube") }.sorted()
    }

    public func lut(_ id: String) -> CubeLUT? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[id] { return c }
        guard let text = try? String(contentsOf: directory.appendingPathComponent(id), encoding: .utf8),
              let lut = try? CubeLUT.parse(text) else { return nil }
        cache[id] = lut
        return lut
    }

    /// Applies the LUT at `intensity` (0...1). Missing LUTs leave the image unchanged.
    public func apply(_ id: String, intensity: Double, to image: CIImage) -> CIImage {
        guard let lut = lut(id), intensity > 0 else { return image }
        let graded = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.size,
            "inputCubeData": lut.data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
        ])
        guard intensity < 1 else { return graded }
        return graded.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - intensity,
        ])
    }
}

/// Where each platform's buttons, captions and profile info usually cover a
/// 9:16 video. Approximate guides for keeping text readable, measured from
/// typical app layouts; not official numbers.
public struct SafeZone: Sendable, Equatable {
    /// Fractions of the frame covered at each edge.
    public var top: Double, bottom: Double, left: Double, right: Double

    public static func `for`(_ p: Platform) -> SafeZone {
        switch p {
        case .instagram: return SafeZone(top: 0.14, bottom: 0.35, left: 0.06, right: 0.15)
        case .facebook: return SafeZone(top: 0.14, bottom: 0.35, left: 0.06, right: 0.15)
        case .tiktok: return SafeZone(top: 0.10, bottom: 0.26, left: 0.06, right: 0.16)
        case .youtube: return SafeZone(top: 0.12, bottom: 0.30, left: 0.06, right: 0.15)
        }
    }

    /// The area safe for text, normalized (origin top-left).
    public var safeRect: CGRect { CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom) }
}
