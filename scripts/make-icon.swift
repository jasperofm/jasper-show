// Renders the 1024×1024 app icon PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centered in 1024.
let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1),
                    NSColor(red: 0.90, green: 0.25, blue: 0.55, alpha: 1),
                    NSColor(red: 0.55, green: 0.30, blue: 0.96, alpha: 1)])!
    .draw(in: shape, angle: -55)

// Three stacked "reels" cards.
func card(_ r: NSRect, alpha: CGFloat) {
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: r, xRadius: 56, yRadius: 56).fill()
}
card(NSRect(x: 300, y: 250, width: 300, height: 520).offsetBy(dx: 120, dy: 20), alpha: 0.28)
card(NSRect(x: 300, y: 250, width: 300, height: 520).offsetBy(dx: 60, dy: 10), alpha: 0.5)
card(NSRect(x: 300, y: 250, width: 300, height: 520), alpha: 1)

// Play triangle.
let play = NSBezierPath()
play.move(to: NSPoint(x: 405, y: 400))
play.line(to: NSPoint(x: 405, y: 620))
play.line(to: NSPoint(x: 545, y: 510))
play.close()
NSColor(red: 0.85, green: 0.27, blue: 0.62, alpha: 1).setFill()
play.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
