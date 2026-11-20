// Hesper's identity: palette, the star-over-horizon glyph, the app icon and the wordmark.
// "Dusk, not midnight": native macOS materials and SF Symbols, with an evening-star accent
// in place of system blue. The vectors are the brand SVGs' (100- or 18-unit boxes, y down).

import AppKit
import SwiftUI

enum Brand {
    static let duskInk = Color(hex: 0x1B1F2E)       // icon background, text on amber
    static let horizon = Color(hex: 0x2E3550)       // the planet, secondary surfaces
    static let eveningStar = Color(hex: 0xF2B544)   // the accent: fills (buttons, toggles, selected tab)
    static let recording = Color(hex: 0xD93A3A)     // only while the mic is live

    /// Accent for text and small glyphs: amber on dark backgrounds, a darker amber on light ones
    /// (#F2B544 on white is 1.9:1; this is 4.9:1).
    static let accent = Color(nsColor: dynamic(light: 0x9A6510, dark: 0xF2B544))
    /// Links: starLight on dark, ember on light (4.5:1 or better on both).
    static let link = Color(nsColor: dynamic(light: 0x8A5A0F, dark: 0xF4C978))
    /// The to-do count badge.
    static let badgeBg = Color(nsColor: dynamic(light: 0xF7E7C2, dark: 0x4A3B1C))
    static let badgeText = Color(nsColor: dynamic(light: 0x5E3D08, dark: 0xF7D58F))

    static let tagline = "Private meeting notes, fully offline"
    static let publisher = "by Gbally"

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - The glyph: a four-point star over a horizon line (18-unit box)

/// The star with curved sides, as the SVGs draw it: from the top point, a quarter curve to each side.
struct BrandStar: Shape {
    var top = CGPoint(x: 9, y: 2), bottom = CGPoint(x: 9, y: 12), left = CGPoint(x: 4, y: 7), right = CGPoint(x: 14, y: 7)
    var box: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / box
        let o = CGPoint(x: rect.midX - box * s / 2, y: rect.midY - box * s / 2)
        func p(_ q: CGPoint) -> CGPoint { CGPoint(x: o.x + q.x * s, y: o.y + q.y * s) }
        let centre = CGPoint(x: top.x, y: left.y)
        var path = Path()
        path.move(to: p(top))
        path.addQuadCurve(to: p(right), control: p(centre))
        path.addQuadCurve(to: p(bottom), control: p(centre))
        path.addQuadCurve(to: p(left), control: p(centre))
        path.addQuadCurve(to: p(top), control: p(centre))
        path.closeSubpath()
        return path
    }
}

/// The star over its horizon line; `progress` (0…1) fills the line, the rest at 35 % (processing).
struct BrandGlyph: View {
    var color: Color = Brand.accent
    var outlined = false
    var progress: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 18
            ZStack(alignment: .topLeading) {
                if outlined {
                    BrandStar().stroke(color, lineWidth: 1.1 * s)
                } else {
                    BrandStar().fill(color)
                }
                Capsule().fill(color.opacity(progress == nil ? 1 : 0.35))
                    .frame(width: 14 * s, height: 1.6 * s).offset(x: 2 * s, y: 14.2 * s)
                if let progress {
                    Capsule().fill(color)
                        .frame(width: max(1.6, 14 * min(max(progress, 0), 1)) * s, height: 1.6 * s).offset(x: 2 * s, y: 14.2 * s)
                }
            }
            .frame(width: 18 * s, height: 18 * s)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - The app icon (direction A: the evening star rising over a planet's lit edge)

struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 100
            let square = Path(roundedRect: CGRect(x: 0, y: 0, width: sz.width, height: sz.height), cornerRadius: 22 * s,
                              style: .continuous)
            ctx.fill(square, with: .color(Brand.duskInk))
            if size < 24 {  // the planet's edge is lost at this size: star + horizon bar
                ctx.fill(BrandStar(top: CGPoint(x: 50, y: 14), bottom: CGPoint(x: 50, y: 66), left: CGPoint(x: 26, y: 40),
                                   right: CGPoint(x: 74, y: 40), box: 100).path(in: CGRect(origin: .zero, size: sz)),
                         with: .color(Brand.eveningStar))
                ctx.fill(Path(roundedRect: CGRect(x: 14 * s, y: 76 * s, width: 72 * s, height: 7 * s), cornerRadius: 3.5 * s),
                         with: .color(Brand.eveningStar))
                return
            }
            ctx.clip(to: square)
            let planet = Path(ellipseIn: CGRect(x: (50 - 64) * s, y: (132 - 64) * s, width: 128 * s, height: 128 * s))
            ctx.fill(planet, with: .color(Brand.horizon))
            ctx.stroke(planet, with: .color(Brand.eveningStar.opacity(0.9)), lineWidth: 2.2 * s)
            ctx.fill(BrandStar(top: CGPoint(x: 50, y: 22), bottom: CGPoint(x: 50, y: 54), left: CGPoint(x: 36, y: 38),
                               right: CGPoint(x: 64, y: 38), box: 100).path(in: CGRect(origin: .zero, size: sz)),
                     with: .color(Brand.eveningStar))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Hesper")
    }
}

// MARK: - The wordmark: lowercase "hesper", Manrope ExtraBold, tracking −0.02 em

struct Wordmark: View {
    var size: CGFloat = 28

    var body: some View {
        Text(verbatim: "Hesper")
            .font(Self.font(size))
            .tracking(-0.02 * size)
            .accessibilityLabel("Hesper")
    }

    /// Manrope (OFL) when it's bundled in Resources/Fonts, else the system's heaviest rounded face.
    static func font(_ size: CGFloat) -> Font {
        registerFonts
        if NSFont(name: "Manrope-ExtraBold", size: size) != nil { return .custom("Manrope-ExtraBold", size: size) }
        return .system(size: size, weight: .heavy, design: .rounded)
    }

    private static let registerFonts: Void = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }()
}

// MARK: - Menu-bar images

enum MenuBarIcon {
    /// Idle: the glyph as a template (macOS tints it for light and dark menu bars).
    static let idle: NSImage = glyph(outlined: false, progress: nil, dot: false)

    /// Processing: the outlined star; the horizon line fills with the job's progress.
    static func processing(_ progress: Double?) -> NSImage {
        glyph(outlined: true, progress: progress.map { (($0 * 20).rounded() / 20) } ?? 0.5, dot: false)
    }

    /// Recording: not a template, so the dot stays red; the glyph is drawn in the menu bar's text colour.
    static let recording: NSImage = glyph(outlined: false, progress: nil, dot: true)

    private static func glyph(outlined: Bool, progress: Double?, dot: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ink: NSColor = dot ? .labelColor : .black
            let star = NSBezierPath()
            let c = NSPoint(x: 9, y: 7)
            func quad(to p: NSPoint, from p0: NSPoint) {
                star.curve(to: p, controlPoint1: NSPoint(x: p0.x + 2 / 3 * (c.x - p0.x), y: p0.y + 2 / 3 * (c.y - p0.y)),
                           controlPoint2: NSPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y)))
            }
            let top = NSPoint(x: 9, y: 2), right = NSPoint(x: 14, y: 7), bottom = NSPoint(x: 9, y: 12), left = NSPoint(x: 4, y: 7)
            star.move(to: top)
            quad(to: right, from: top); quad(to: bottom, from: right); quad(to: left, from: bottom); quad(to: top, from: left)
            star.close()
            ink.set()
            if outlined { star.lineWidth = 1.1; star.stroke() } else { star.fill() }
            let bar = NSRect(x: 2, y: 14.2, width: 14, height: 1.6)
            if let progress {
                ink.withAlphaComponent(0.35).set()
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
                ink.set()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 14.2, width: max(1.6, 14 * min(max(progress, 0), 1)), height: 1.6),
                             xRadius: 0.8, yRadius: 0.8).fill()
            } else {
                NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
            }
            if dot {
                NSColor(hex: 0xD93A3A).set()
                NSBezierPath(ovalIn: NSRect(x: 15 - 2.6, y: 3.5 - 2.6, width: 5.2, height: 5.2)).fill()
            }
            return true
        }
        image.isTemplate = !dot
        image.accessibilityDescription = "Hesper"
        return image
    }
}
