import Foundation
import CoreImage
import AppKit

/// Draws a `TextOverlay` into a transparent CIImage the size of the frame.
/// The result only depends on the overlay and frame size, so it is cached
/// and reused for every frame.
final class OverlayRenderer: @unchecked Sendable {
    static let shared = OverlayRenderer()
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]

    func image(for o: TextOverlay, renderSize: CGSize) -> CIImage {
        let key = "\(o.hashValue)-\(Int(renderSize.width))x\(Int(renderSize.height))"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let img = draw(o, size: renderSize)
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = img
        lock.unlock()
        return img
    }

    private func draw(_ o: TextOverlay, size: CGSize) -> CIImage {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }

        let maxWidth = size.width * 0.86
        var fontSize = max(10, size.height * o.size)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        func attributed(_ fs: CGFloat) -> NSAttributedString {
            NSAttributedString(string: o.text, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: .heavy),
                .foregroundColor: o.style == .lightBox ? NSColor.black : NSColor.white,
                .paragraphStyle: para,
            ])
        }
        // Shrink until it fits in at most 4 lines.
        var text = attributed(fontSize)
        var bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        while bounds.height > fontSize * 1.25 * 4, fontSize > 10 {
            fontSize *= 0.9
            text = attributed(fontSize)
            bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        let pad = fontSize * 0.45
        let boxSize = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2)
        let margin = size.height * 0.08
        let y: CGFloat
        switch o.position {
        case .top: y = size.height - margin - boxSize.height
        case .center: y = (size.height - boxSize.height) / 2
        case .bottom: y = margin
        }
        let box = CGRect(x: (size.width - boxSize.width) / 2, y: y, width: boxSize.width, height: boxSize.height)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        switch o.style {
        case .darkBox:
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: pad, yRadius: pad).fill()
        case .lightBox:
            NSColor.white.setFill()
            NSBezierPath(roundedRect: box, xRadius: pad, yRadius: pad).fill()
        case .plain:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = fontSize * 0.15
            shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.05)
            shadow.set()
        }
        text.draw(with: CGRect(x: box.minX + pad, y: box.minY + pad, width: ceil(bounds.width) + 1, height: ceil(bounds.height)),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }
}
