// MeetNouce's black-and-tan shiba (a nod to Minousse): pointed ears with pink insides, tan
// eyebrow dots and mask, big shiny eyes, a cream muzzle. Drawn from paths so it is crisp at any
// size; shared by the menu bar icon, the animated record button (ShibaView) and the app icon
// (build_app.sh runs scripts/make_icon.swift together with this file).
//
// Designed on a 100×100 grid with y pointing DOWN (like the reference drawing).

import AppKit

enum DogFace {
    // MARK: Colours

    static let fur = NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.10, alpha: 1)
    static let tan = NSColor(calibratedRed: 0.81, green: 0.52, blue: 0.27, alpha: 1)
    static let cream = NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.87, alpha: 1)
    static let beige = NSColor(calibratedRed: 0.89, green: 0.80, blue: 0.71, alpha: 1)
    static let pink = NSColor(calibratedRed: 0.94, green: 0.70, blue: 0.64, alpha: 1)
    static let deepPink = NSColor(calibratedRed: 0.87, green: 0.52, blue: 0.49, alpha: 1)
    static let lid = NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.16, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.06, alpha: 1)
    /// A soft rim so the black head stays visible on dark backgrounds.
    static let rim = NSColor(white: 0.55, alpha: 0.55)

    // MARK: Shapes (100×100, y down)

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    private static func m(_ x: CGFloat) -> CGFloat { 100 - x }

    /// The head without the ears.
    static func face() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(6.5, 40))
        p.curve(to: pt(50, 14), controlPoint1: pt(14, 24), controlPoint2: pt(31, 14))
        p.curve(to: pt(m(6.5), 40), controlPoint1: pt(69, 14), controlPoint2: pt(m(14), 24))
        p.curve(to: pt(100, 63), controlPoint1: pt(97, 47), controlPoint2: pt(100, 54))
        p.curve(to: pt(50, 100), controlPoint1: pt(100, 86), controlPoint2: pt(76, 100))
        p.curve(to: pt(0, 63), controlPoint1: pt(24, 100), controlPoint2: pt(0, 86))
        p.curve(to: pt(6.5, 40), controlPoint1: pt(0, 54), controlPoint2: pt(3, 47))
        p.close()
        return p
    }

    /// One ear (black outside).
    static func ear(left: Bool) -> NSBezierPath {
        func q(_ x: CGFloat, _ y: CGFloat) -> NSPoint { pt(left ? x : m(x), y) }
        let p = NSBezierPath()
        p.move(to: q(6.5, 42))
        p.curve(to: q(12.5, 1.5), controlPoint1: q(4.6, 26), controlPoint2: q(7.6, 3.5))
        p.curve(to: q(34, 17.5), controlPoint1: q(17.5, -0.5), controlPoint2: q(27, 9))
        p.line(to: q(26, 30))
        p.close()
        return p
    }

    /// Where an ear turns when it twitches.
    static func earPivot(left: Bool) -> NSPoint { pt(left ? 20 : m(20), 27) }

    /// Inside of an ear: a tan edge, light pink, then deeper pink.
    static func innerEar(left: Bool) -> [(NSBezierPath, NSColor)] {
        func q(_ x: CGFloat, _ y: CGFloat) -> NSPoint { pt(left ? x : m(x), y) }
        func tri(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: a)
            p.curve(to: b, controlPoint1: NSPoint(x: a.x + (b.x - a.x) * 0.3 - (left ? 1.2 : -1.2), y: a.y + (b.y - a.y) * 0.3),
                    controlPoint2: NSPoint(x: a.x + (b.x - a.x) * 0.8 - (left ? 0.5 : -0.5), y: a.y + (b.y - a.y) * 0.8))
            p.line(to: c)
            p.close()
            return p
        }
        return [
            (tri(q(11.0, 34), q(14.2, 6.0), q(29.5, 20.5)), tan),
            (tri(q(11.2, 33), q(14.4, 7.5), q(25.5, 22.5)), pink),
            (tri(q(13.0, 30), q(15.6, 12.5), q(22.5, 24.5)), deepPink),
        ]
    }

    /// The tan mask: cheeks and the bridge rising between the eyes.
    static func mask() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(3, 58))
        p.curve(to: pt(17, 55), controlPoint1: pt(7, 55), controlPoint2: pt(13, 54))
        p.curve(to: pt(31, 64), controlPoint1: pt(20, 63), controlPoint2: pt(26, 66))
        p.curve(to: pt(50, 50.5), controlPoint1: pt(38, 61), controlPoint2: pt(42, 50.5))
        p.curve(to: pt(m(31), 64), controlPoint1: pt(58, 50.5), controlPoint2: pt(62, 61))
        p.curve(to: pt(m(17), 55), controlPoint1: pt(m(26), 66), controlPoint2: pt(m(20), 63))
        p.curve(to: pt(m(3), 58), controlPoint1: pt(m(13), 54), controlPoint2: pt(m(7), 55))
        p.line(to: pt(100, 100))
        p.line(to: pt(0, 100))
        p.close()
        return p
    }

    /// The cream muzzle and chin, with two little tan notches either side of the nose.
    static func muzzle() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(6, 76))
        p.curve(to: pt(21, 67.5), controlPoint1: pt(10, 70), controlPoint2: pt(15, 67.5))
        p.curve(to: pt(33.5, 76), controlPoint1: pt(28, 67.5), controlPoint2: pt(32, 70))
        p.curve(to: pt(50, 68.5), controlPoint1: pt(37, 71), controlPoint2: pt(43, 68.5))
        p.curve(to: pt(m(33.5), 76), controlPoint1: pt(57, 68.5), controlPoint2: pt(m(37), 71))
        p.curve(to: pt(m(21), 67.5), controlPoint1: pt(m(32), 70), controlPoint2: pt(m(28), 67.5))
        p.curve(to: pt(m(6), 76), controlPoint1: pt(m(15), 67.5), controlPoint2: pt(m(10), 70))
        p.line(to: pt(100, 100))
        p.line(to: pt(0, 100))
        p.close()
        return p
    }

    static func brows() -> [NSBezierPath] {
        [true, false].map { left in
            let p = NSBezierPath(ovalIn: NSRect(x: -5.6, y: -4.0, width: 11.2, height: 8.0))
            var t = AffineTransform(translationByX: left ? 36 : m(36), byY: 40.5)
            t.rotate(byDegrees: left ? 22 : -22)
            p.transform(using: t)
            return p
        }
    }

    static let eyeCenters = [NSPoint(x: 30, y: 52.5), NSPoint(x: 70, y: 52.5)]
    static let eyeRadius: CGFloat = 6.8

    static func nose() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(42.5, 66))
        p.curve(to: pt(57.5, 66), controlPoint1: pt(45, 62.8), controlPoint2: pt(55, 62.8))
        p.curve(to: pt(50, 76.5), controlPoint1: pt(60.5, 70), controlPoint2: pt(54.5, 76.5))
        p.curve(to: pt(42.5, 66), controlPoint1: pt(45.5, 76.5), controlPoint2: pt(39.5, 70))
        p.close()
        return p
    }

    static func mouth() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pt(50, 76))
        p.line(to: pt(50, 80.5))
        p.move(to: pt(38.5, 81.5))
        p.curve(to: pt(50, 80.5), controlPoint1: pt(42, 84.5), controlPoint2: pt(47, 84))
        p.curve(to: pt(61.5, 81.5), controlPoint1: pt(53, 84), controlPoint2: pt(58, 84.5))
        p.lineWidth = 1.9
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    // MARK: Drawing

    /// Runs `body` with the 100×100 y-down grid mapped onto `rect` (y-up), in a transparency layer.
    static func onGrid(_ rect: NSRect, _ body: (CGContext) -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 100, y: -rect.height / 100)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body(ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func rotated(_ ctx: CGContext, around c: NSPoint, degrees: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -c.x, y: -c.y)
        body()
        ctx.restoreGState()
    }

    /// In colour. `earAngles` (degrees, + = outwards) and `blink` (1 open … 0 shut) animate it.
    static func drawColored(in rect: NSRect, earAngles: (CGFloat, CGFloat) = (0, 0), blink: CGFloat = 1) {
        onGrid(rect) { ctx in
            let ears = [(true, earAngles.0), (false, earAngles.1)]
            // Soft rim (only its outer half shows once the fur is drawn on top).
            rim.setStroke()
            for (left, angle) in ears {
                rotated(ctx, around: earPivot(left: left), degrees: left ? -angle : angle) {
                    let e = ear(left: left); e.lineWidth = 3; e.stroke()
                }
            }
            let outline = face(); outline.lineWidth = 3; outline.stroke()

            for (left, angle) in ears {
                rotated(ctx, around: earPivot(left: left), degrees: left ? -angle : angle) {
                    fur.setFill(); ear(left: left).fill()
                    for (shape, colour) in innerEar(left: left) { colour.setFill(); shape.fill() }
                }
            }
            fur.setFill(); face().fill()

            // Markings stay within the head.
            ctx.saveGState()
            face().addClip()
            tan.setFill(); mask().fill()
            brows().forEach { $0.fill() }
            muzzle().addClip()
            beige.setFill(); NSRect(x: 0, y: 60, width: 100, height: 40).fill()
            cream.setFill(); NSBezierPath(ovalIn: NSRect(x: 4, y: 58, width: 92, height: 37)).fill()
            ctx.restoreGState()

            for c in eyeCenters { eye(ctx, at: c, blink: blink) }
            ink.setFill(); nose().fill()
            NSColor(white: 0.36, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 46, y: 64.6, width: 8, height: 2.6)).fill()
            ink.setStroke(); mouth().stroke()
            beige.setFill()
            let chin = NSBezierPath()
            chin.move(to: pt(45, 86.5))
            chin.curve(to: pt(55, 86.5), controlPoint1: pt(47, 89), controlPoint2: pt(53, 89))
            chin.curve(to: pt(45, 86.5), controlPoint1: pt(52, 87.6), controlPoint2: pt(48, 87.6))
            chin.fill()
        }
    }

    private static func eye(_ ctx: CGContext, at c: NSPoint, blink: CGFloat) {
        let r = eyeRadius
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: max(0.08, blink))
        ctx.translateBy(x: -c.x, y: -c.y)
        cream.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r - 0.8, y: c.y - r + 0.2, width: 2 * r + 1.6, height: 2 * r + 1.4)).fill()
        lid.setFill()
        let lidArc = NSBezierPath()
        lidArc.appendArc(withCenter: c, radius: r + 1.1, startAngle: 190, endAngle: 350)
        lidArc.appendArc(withCenter: NSPoint(x: c.x, y: c.y + 0.6), radius: r - 0.2, startAngle: 350, endAngle: 190, clockwise: true)
        lidArc.close()
        lidArc.fill()
        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
        if blink > 0.5 {
            NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 3.7, y: c.y - 3.8, width: 3.4, height: 3.4)).fill()
            NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.36, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x + 1.6, y: c.y + 1.4, width: 1.6, height: 1.6)).fill()
        }
        ctx.restoreGState()
    }

    /// One colour with the face cut out: the menu bar icon.
    static func draw(in rect: NSRect, color: NSColor) {
        onGrid(rect) { ctx in
            color.setFill()
            ear(left: true).fill(); ear(left: false).fill(); face().fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for left in [true, false] { innerEar(left: left)[1].0.fill() }
            ctx.saveGState()
            face().addClip()
            muzzle().fill()
            ctx.restoreGState()
            brows().forEach { $0.fill() }
            for c in eyeCenters { NSBezierPath(ovalIn: NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)).fill() }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            nose().fill()
            let mouth = mouth(); mouth.lineWidth = 4; color.setStroke(); mouth.stroke()
        }
    }

    /// The menu bar icon: a template image, so macOS tints it for light and dark menu bars.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            draw(in: r, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MeetNouce"
        return image
    }()
}
