// Draws MacLean's app icon (serif "m." on a warm squircle) at every size an
// .icns needs. Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.13, green: 0.11, blue: 0.10, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()

    // Background: deep ink with a terracotta glow from the lower right.
    shape.addClip()
    NSGradient(colors: [NSColor(red: 0.16, green: 0.13, blue: 0.12, alpha: 1),
                        NSColor(red: 0.09, green: 0.08, blue: 0.08, alpha: 1)])!.draw(in: body, angle: -90)
    let glow = NSGradient(colors: [NSColor(red: 0.85, green: 0.42, blue: 0.27, alpha: 0.55), .clear])!
    glow.draw(fromCenter: NSPoint(x: body.maxX - body.width * 0.15, y: body.minY + body.height * 0.1), radius: 0,
              toCenter: NSPoint(x: body.maxX - body.width * 0.15, y: body.minY + body.height * 0.1), radius: body.width * 0.9,
              options: [])

    // Disk-usage ring behind the letter: a quiet nod to what the app does.
    let ringRect = body.insetBy(dx: body.width * 0.16, dy: body.width * 0.16)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2, startAngle: 90, endAngle: 90 - 290, clockwise: true)
    ring.lineWidth = body.width * 0.035
    ring.lineCapStyle = .round
    NSColor(red: 0.85, green: 0.45, blue: 0.30, alpha: 0.9).setStroke()
    ring.stroke()
    let track = NSBezierPath()
    track.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2, startAngle: 90 - 290 - 14, endAngle: 90 - 360 + 14, clockwise: true)
    track.lineWidth = body.width * 0.035
    track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()

    // The mark: serif "m" in cream, terracotta dot.
    let font = NSFont(name: "Georgia-Bold", size: body.width * 0.40) ?? .boldSystemFont(ofSize: body.width * 0.40)
    let m = NSAttributedString(string: "m", attributes: [.font: font, .foregroundColor: NSColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1)])
    let size = m.size()
    let dot = body.width * 0.065
    let total = size.width + dot * 1.2
    let origin = NSPoint(x: body.midX - total / 2, y: body.midY - size.height / 2 + body.width * 0.01)
    m.draw(at: origin)
    NSColor(red: 0.90, green: 0.47, blue: 0.31, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: origin.x + size.width + dot * 0.2, y: origin.y + size.height * 0.2, width: dot, height: dot)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
