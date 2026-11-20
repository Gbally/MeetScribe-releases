// Draws Hesper's app icon (direction A: the evening star rising over a planet's lit edge) → the
// AppIcon.iconset PNGs. The 16 and 32 px slots use the simplified star + horizon bar: the planet's
// edge is lost at that size. Vectors from the brand SVGs (100-unit box, y down).
// Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let duskInk = color(0x1B1F2E), horizon = color(0x2E3550), star = color(0xF2B544)

/// The four-point star with curved sides: quarter curves through its centre (SVG quadratics → cubics).
func starPath(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat, x: CGFloat, y: CGFloat, map: (NSPoint) -> NSPoint) -> NSBezierPath {
    let c = NSPoint(x: x, y: y)
    let pts = [NSPoint(x: x, y: top), NSPoint(x: right, y: y), NSPoint(x: x, y: bottom), NSPoint(x: left, y: y)]
    let path = NSBezierPath()
    path.move(to: map(pts[0]))
    for i in 0..<4 {
        let p0 = pts[i], p = pts[(i + 1) % 4]
        let c1 = NSPoint(x: p0.x + 2 / 3 * (c.x - p0.x), y: p0.y + 2 / 3 * (c.y - p0.y))
        let c2 = NSPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
        path.curve(to: map(p), controlPoint1: map(c1), controlPoint2: map(c2))
    }
    path.close()
    return path
}

func render(_ px: Int, small: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let s = CGFloat(px)
    // macOS icon grid: the rounded square sits inside a ~10 % margin (less at the smallest sizes).
    let inset = s * (small ? 0.06 : 0.1)
    let side = s - 2 * inset
    let u = side / 100
    func map(_ p: NSPoint) -> NSPoint { NSPoint(x: inset + p.x * u, y: s - inset - p.y * u) }  // y down → AppKit's y up

    let square = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: 22 * u, yRadius: 22 * u)
    duskInk.setFill()
    square.fill()
    if small {
        star.setFill()
        starPath(top: 14, bottom: 66, left: 26, right: 74, x: 50, y: 40, map: map).fill()
        let o = map(NSPoint(x: 14, y: 83))
        NSBezierPath(roundedRect: NSRect(x: o.x, y: o.y, width: 72 * u, height: 7 * u), xRadius: 3.5 * u, yRadius: 3.5 * u).fill()
    } else {
        NSGraphicsContext.saveGraphicsState()
        square.addClip()
        let c = map(NSPoint(x: 50, y: 132))
        let planet = NSBezierPath(ovalIn: NSRect(x: c.x - 64 * u, y: c.y - 64 * u, width: 128 * u, height: 128 * u))
        horizon.setFill()
        planet.fill()
        star.withAlphaComponent(0.9).setStroke()
        planet.lineWidth = 2.2 * u
        planet.stroke()
        NSGraphicsContext.restoreGraphicsState()
        star.setFill()
        starPath(top: 22, bottom: 54, left: 36, right: 64, x: 50, y: 38, map: map).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base, small: base <= 32).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2, small: base <= 16).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
