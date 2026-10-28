// Draws MacAgent's app icon: a macOS-style rounded square in a Finder-like blue gradient with a
// white stencil security shield (checkmark cut out, stencil bridges top and bottom).
//
//   swift packaging/make-icon.swift packaging/AppIcon.icns
//
// Drawn in code (no Xcode, no Apple artwork or SF Symbols, which can't be used in app icons).
import AppKit

let out = CommandLine.arguments.last.map { $0.hasSuffix(".icns") ? $0 : "AppIcon.icns" } ?? "AppIcon.icns"

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Big Sur icon grid: the tile is ~80% of the canvas, corner radius ~22.5% of the tile.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    // Soft drop shadow, then the gradient tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let top = NSColor(srgbRed: 0.42, green: 0.79, blue: 1.0, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.08, green: 0.45, blue: 0.93, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // Shield, centred on the tile.
    let w = tile.width * 0.52, h = tile.width * 0.62
    let cx = tile.midX, top0 = tile.midY + h * 0.5
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: cx, y: top0))
    shield.addCurve(to: CGPoint(x: cx + w / 2, y: top0 - h * 0.12),
                    control1: CGPoint(x: cx + w * 0.18, y: top0 - h * 0.06), control2: CGPoint(x: cx + w * 0.36, y: top0 - h * 0.1))
    shield.addLine(to: CGPoint(x: cx + w / 2, y: top0 - h * 0.45))
    shield.addCurve(to: CGPoint(x: cx, y: top0 - h),
                    control1: CGPoint(x: cx + w / 2, y: top0 - h * 0.72), control2: CGPoint(x: cx + w * 0.22, y: top0 - h * 0.9))
    shield.addCurve(to: CGPoint(x: cx - w / 2, y: top0 - h * 0.45),
                    control1: CGPoint(x: cx - w * 0.22, y: top0 - h * 0.9), control2: CGPoint(x: cx - w / 2, y: top0 - h * 0.72))
    shield.addLine(to: CGPoint(x: cx - w / 2, y: top0 - h * 0.12))
    shield.addCurve(to: CGPoint(x: cx, y: top0),
                    control1: CGPoint(x: cx - w * 0.36, y: top0 - h * 0.1), control2: CGPoint(x: cx - w * 0.18, y: top0 - h * 0.06))
    shield.closeSubpath()

    // White shield with a subtle shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(shield)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Stencil cut-outs: a checkmark, plus bridges (thin gaps) at the top and bottom, punched through
    // to the blue so it reads as a stencil.
    ctx.saveGState()
    ctx.addPath(shield)
    ctx.clip()
    ctx.setBlendMode(.copy)
    ctx.setFillColor(NSColor.clear.cgColor)
    ctx.setStrokeColor(NSColor(srgbRed: 0.16, green: 0.56, blue: 0.97, alpha: 1).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(w * 0.13)
    let check = CGMutablePath()
    check.move(to: CGPoint(x: cx - w * 0.22, y: top0 - h * 0.5))
    check.addLine(to: CGPoint(x: cx - w * 0.04, y: top0 - h * 0.66))
    check.addLine(to: CGPoint(x: cx + w * 0.25, y: top0 - h * 0.3))
    ctx.addPath(check)
    ctx.strokePath()
    // Bridges: short vertical gaps where a stencil's ties would be.
    ctx.setLineCap(.butt)
    ctx.setLineWidth(w * 0.035)
    for (y0, y1) in [(top0 + s * 0.01, top0 - h * 0.16), (top0 - h * 0.82, top0 - h - s * 0.01)] {
        ctx.move(to: CGPoint(x: cx, y: y0))
        ctx.addLine(to: CGPoint(x: cx, y: y1))
    }
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacAgent-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
