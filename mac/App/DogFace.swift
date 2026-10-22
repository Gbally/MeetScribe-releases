// MeetNouse's shiba face (a nod to Minousse): pointed ears, fluffy cheeks, a pale muzzle and the
// shiba's little eyebrow dots. Drawn from paths so it is crisp at menu bar size, and shared with
// the app icon (build_app.sh runs scripts/make_icon.swift together with this file).

import AppKit

enum DogFace {
    // MARK: Shapes, on an 18×18 grid (y up)

    private static func mirror(_ x: CGFloat) -> CGFloat { 18 - x }

    /// Head with cheek fluff and both ears.
    static func head() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 9, y: 1.6))                                             // chin
        p.curve(to: NSPoint(x: 2.0, y: 6.0), controlPoint1: NSPoint(x: 5.6, y: 1.7), controlPoint2: NSPoint(x: 3.2, y: 3.6))
        p.line(to: NSPoint(x: 1.2, y: 6.4))                                           // cheek tuft
        p.curve(to: NSPoint(x: 2.8, y: 10.6), controlPoint1: NSPoint(x: 1.6, y: 8.2), controlPoint2: NSPoint(x: 2.0, y: 9.6))
        p.curve(to: NSPoint(x: 3.5, y: 15.6), controlPoint1: NSPoint(x: 2.5, y: 12.4), controlPoint2: NSPoint(x: 2.7, y: 14.6)) // ear
        p.curve(to: NSPoint(x: 7.4, y: 12.9), controlPoint1: NSPoint(x: 4.9, y: 15.5), controlPoint2: NSPoint(x: 6.4, y: 14.0))
        p.curve(to: NSPoint(x: mirror(7.4), y: 12.9), controlPoint1: NSPoint(x: 8.4, y: 13.3), controlPoint2: NSPoint(x: 9.6, y: 13.3))
        p.curve(to: NSPoint(x: mirror(3.5), y: 15.6), controlPoint1: NSPoint(x: mirror(6.4), y: 14.0), controlPoint2: NSPoint(x: mirror(4.9), y: 15.5))
        p.curve(to: NSPoint(x: mirror(2.8), y: 10.6), controlPoint1: NSPoint(x: mirror(2.7), y: 14.6), controlPoint2: NSPoint(x: mirror(2.5), y: 12.4))
        p.curve(to: NSPoint(x: mirror(1.2), y: 6.4), controlPoint1: NSPoint(x: mirror(2.0), y: 9.6), controlPoint2: NSPoint(x: mirror(1.6), y: 8.2))
        p.line(to: NSPoint(x: mirror(2.0), y: 6.0))
        p.curve(to: NSPoint(x: 9, y: 1.6), controlPoint1: NSPoint(x: mirror(3.2), y: 3.6), controlPoint2: NSPoint(x: mirror(5.6), y: 1.7))
        p.close()
        return p
    }

    static func innerEar(left: Bool) -> NSBezierPath {
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: left ? x : mirror(x), y: y) }
        let p = NSBezierPath()
        p.move(to: pt(3.9, 11.3))
        p.curve(to: pt(4.0, 14.3), controlPoint1: pt(3.7, 12.4), controlPoint2: pt(3.8, 13.4))
        p.curve(to: pt(6.4, 12.5), controlPoint1: pt(4.9, 14.0), controlPoint2: pt(5.8, 13.2))
        p.curve(to: pt(3.9, 11.3), controlPoint1: pt(5.4, 11.9), controlPoint2: pt(4.6, 11.5))
        p.close()
        return p
    }

    /// The pale muzzle and cheeks (urajiro).
    static func muzzle() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 9, y: 1.6))
        p.curve(to: NSPoint(x: 3.0, y: 5.6), controlPoint1: NSPoint(x: 5.8, y: 1.7), controlPoint2: NSPoint(x: 3.8, y: 3.4))
        p.curve(to: NSPoint(x: 9, y: 7.6), controlPoint1: NSPoint(x: 4.6, y: 7.0), controlPoint2: NSPoint(x: 7.0, y: 7.7))
        p.curve(to: NSPoint(x: mirror(3.0), y: 5.6), controlPoint1: NSPoint(x: 11.0, y: 7.7), controlPoint2: NSPoint(x: mirror(4.6), y: 7.0))
        p.curve(to: NSPoint(x: 9, y: 1.6), controlPoint1: NSPoint(x: mirror(3.8), y: 3.4), controlPoint2: NSPoint(x: mirror(5.8), y: 1.7))
        p.close()
        return p
    }

    /// The muzzle, kept inside the outline (one-colour icon: cut out, the nose sits inside).
    static func muzzleInset() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 9, y: 2.6))
        p.curve(to: NSPoint(x: 4.0, y: 5.5), controlPoint1: NSPoint(x: 6.4, y: 2.6), controlPoint2: NSPoint(x: 4.6, y: 3.8))
        p.curve(to: NSPoint(x: 9, y: 7.3), controlPoint1: NSPoint(x: 5.2, y: 6.8), controlPoint2: NSPoint(x: 7.2, y: 7.3))
        p.curve(to: NSPoint(x: mirror(4.0), y: 5.5), controlPoint1: NSPoint(x: 10.8, y: 7.3), controlPoint2: NSPoint(x: mirror(5.2), y: 6.8))
        p.curve(to: NSPoint(x: 9, y: 2.6), controlPoint1: NSPoint(x: mirror(4.6), y: 3.8), controlPoint2: NSPoint(x: mirror(6.4), y: 2.6))
        p.close()
        return p
    }

    static func eyes() -> [NSBezierPath] {
        [NSBezierPath(ovalIn: NSRect(x: 5.6, y: 7.9, width: 1.5, height: 1.6)),
         NSBezierPath(ovalIn: NSRect(x: 10.9, y: 7.9, width: 1.5, height: 1.6))]
    }

    static func brows() -> [NSBezierPath] {
        [NSBezierPath(ovalIn: NSRect(x: 5.7, y: 10.2, width: 1.3, height: 0.8)),
         NSBezierPath(ovalIn: NSRect(x: 11.0, y: 10.2, width: 1.3, height: 0.8))]
    }

    static func nose() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 7.7, y: 5.6))
        p.curve(to: NSPoint(x: 10.3, y: 5.6), controlPoint1: NSPoint(x: 8.2, y: 6.3), controlPoint2: NSPoint(x: 9.8, y: 6.3))
        p.curve(to: NSPoint(x: 7.7, y: 5.6), controlPoint1: NSPoint(x: 10.1, y: 4.4), controlPoint2: NSPoint(x: 7.9, y: 4.4))
        p.close()
        return p
    }

    static func mouth() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 7.5, y: 4.0))
        p.curve(to: NSPoint(x: 9, y: 3.9), controlPoint1: NSPoint(x: 7.9, y: 3.1), controlPoint2: NSPoint(x: 8.8, y: 3.2))
        p.curve(to: NSPoint(x: 10.5, y: 4.0), controlPoint1: NSPoint(x: 9.2, y: 3.2), controlPoint2: NSPoint(x: 10.1, y: 3.1))
        p.lineWidth = 0.6
        p.lineCapStyle = .round
        return p
    }

    // MARK: Drawing

    private static func onGrid(_ rect: NSRect, _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 18, y: rect.height / 18)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// One colour, with the details cut out (transparent): the menu bar icon.
    static func draw(in rect: NSRect, color: NSColor) {
        onGrid(rect) {
            color.setFill()
            color.setStroke()
            head().fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            innerEar(left: true).fill()
            innerEar(left: false).fill()
            eyes().forEach { $0.fill() }
            muzzleInset().fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            nose().fill()
            mouth().stroke()
        }
    }

    /// In shiba colours: the app icon.
    static func drawColored(in rect: NSRect) {
        let fur = NSColor(calibratedRed: 0.91, green: 0.56, blue: 0.24, alpha: 1)
        let cream = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.89, alpha: 1)
        let ink = NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.10, alpha: 1)
        onGrid(rect) {
            fur.setFill(); head().fill()
            cream.setFill()
            innerEar(left: true).fill(); innerEar(left: false).fill()
            muzzle().fill()
            brows().forEach { $0.fill() }
            ink.setFill(); ink.setStroke()
            eyes().forEach { $0.fill() }
            nose().fill()
            mouth().stroke()
        }
    }

    /// The menu bar icon: a template image, so macOS tints it for light and dark menu bars.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            draw(in: r, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MeetNouse"
        return image
    }()
}
