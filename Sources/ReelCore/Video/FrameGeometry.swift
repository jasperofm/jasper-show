import Foundation
import CoreGraphics

/// Pure math that turns `EditSettings` framing values into concrete rectangles
/// and a transform. Kept free of Core Image so it can be unit tested.
///
/// Coordinate system: Core Image's (origin bottom-left, y up), in source pixels.
public struct FrameGeometry: Equatable {
    /// Region of the (rotated) source that becomes the output frame.
    public var window: CGRect
    /// Rotation in radians, counter-clockwise (CI convention).
    public var rotationRadians: Double
    /// Scale applied around the window center so rotation never exposes empty corners.
    public var coverScale: Double

    public init(sourceSize: CGSize, settings s: EditSettings) {
        let W = sourceSize.width, H = sourceSize.height

        // 1. Crop rect, converted from normalized top-left to CI bottom-left pixels.
        let c = s.crop
        var rect = CGRect(x: c.minX * W, y: (1 - c.maxY) * H, width: c.width * W, height: c.height * H)

        // 2. Force output aspect by taking the largest centered rect of that ratio.
        if let ratio = s.outputAspect.ratio {
            rect = Self.fit(aspect: ratio, in: rect)
        }

        // 3. Zoom shrinks the window around the crop center; pan slides it within the crop.
        let zoom = max(1, s.zoom)
        let winSize = CGSize(width: rect.width / zoom, height: rect.height / zoom)
        let slackX = (rect.width - winSize.width) / 2
        let slackY = (rect.height - winSize.height) / 2
        let center = CGPoint(x: rect.midX + s.pan.x * slackX,
                             y: rect.midY - s.pan.y * slackY) // pan.y > 0 means down on screen
        window = CGRect(x: center.x - winSize.width / 2, y: center.y - winSize.height / 2,
                        width: winSize.width, height: winSize.height)

        // 4. Rotation (settings are clockwise degrees; CI rotates counter-clockwise).
        rotationRadians = -s.rotation * .pi / 180
        coverScale = Self.coverScale(for: winSize, radians: rotationRadians)
    }

    /// Largest rect with `aspect` (w/h) centered inside `rect`.
    public static func fit(aspect: Double, in rect: CGRect) -> CGRect {
        var size = rect.size
        if size.width / size.height > aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Scale factor so a `size` rect, after the image under it is rotated by
    /// `radians`, is still fully covered by image content.
    public static func coverScale(for size: CGSize, radians: Double) -> Double {
        let cosA = abs(cos(radians)), sinA = abs(sin(radians))
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return 1 }
        let sx = (w * cosA + h * sinA) / w
        let sy = (w * sinA + h * cosA) / h
        return max(sx, sy)
    }

    /// Transform to apply to the source image: rotate + cover-scale around the
    /// window center, then move the window's origin to (0,0).
    public var imageTransform: CGAffineTransform {
        let cx = window.midX, cy = window.midY
        return CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(rotationAngle: rotationRadians))
            .concatenating(CGAffineTransform(scaleX: coverScale, y: coverScale))
            .concatenating(CGAffineTransform(translationX: window.width / 2, y: window.height / 2))
    }

    /// Render size for the window, capped to `maxLongEdge` and rounded to even
    /// dimensions (required by H.264/HEVC encoders).
    public func renderSize(maxLongEdge: Int) -> CGSize {
        let longEdge = max(window.width, window.height)
        let scale = longEdge > CGFloat(maxLongEdge) ? CGFloat(maxLongEdge) / longEdge : 1
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        return CGSize(width: even(window.width), height: even(window.height))
    }
}
