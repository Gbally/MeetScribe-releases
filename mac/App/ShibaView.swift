// The animated shiba on the record button: waiting (blinks, ear twitches, a slow head tilt), then
// putting on a headset with a mic when the recording starts, and listening (nods, REC light,
// sound waves). Drawn from paths on a 24×24 grid (y up); the face is DogFace's.

import AppKit
import SwiftUI

enum ShibaMode: Equatable {
    case waiting
    case listening(since: Date)
}

struct ShibaView: View {
    var mode: ShibaMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { gc, size in
                let now = timeline.date
                gc.withCGContext { cg in
                    ShibaDrawing.draw(cg, size: size, time: reduceMotion ? 0 : now.timeIntervalSinceReferenceDate,
                                      listening: listeningTime(now))
                }
            }
        }
        .accessibilityLabel(Text(listeningTime(Date()) == nil ? "Start recording" : "Recording now"))
    }

    /// Seconds since the headset went on (nil while waiting).
    private func listeningTime(_ now: Date) -> Double? {
        guard case .listening(let since) = mode else { return nil }
        return reduceMotion ? 10 : max(0, now.timeIntervalSince(since))
    }
}

enum ShibaDrawing {
    /// The headset in the app's purple, so it shows on the black fur.
    static let gear = NSColor(calibratedRed: 0.42, green: 0.34, blue: 1.0, alpha: 1)
    static let cushion = NSColor(calibratedRed: 0.26, green: 0.20, blue: 0.62, alpha: 1)
    static let rec = NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)

    /// Draws one frame. `time` drives the idle motion; `listening` is the time since the headset
    /// went on (nil = waiting). `cg` is a y-down context (SwiftUI Canvas); it is flipped here.
    static func draw(_ cg: CGContext, size: CGSize, time t: Double, listening: Double?) {
        let ns = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        cg.saveGState()
        let side = min(size.width, size.height)
        cg.translateBy(x: (size.width - side) / 2, y: (size.height + side) / 2)
        cg.scaleBy(x: side / 24, y: -side / 24)
        cg.translateBy(x: 3, y: 2.6) // the 18×18 face sits in the middle of the 24×24 grid

        let p = listening ?? 0
        let on = listening != nil
        // Whole head: slow tilt and breathing while waiting; a nod while listening.
        let tilt = on ? 2.0 * sin(2 * .pi * p / 1.8) : 3.5 * sin(2 * .pi * t / 4.2)
        let bob = on ? 0.22 * max(0, sin(2 * .pi * p / 0.9)) : 0.12 * sin(2 * .pi * t / 2.6)
        let breathe = 1 + 0.012 * sin(2 * .pi * t / 2.6)
        cg.translateBy(x: 9, y: 2 + bob)
        cg.rotate(by: tilt * .pi / 180)
        cg.scaleBy(x: breathe, y: breathe)
        cg.translateBy(x: -9, y: -2)

        // Ears: an occasional twitch while waiting, perked up while listening. Eyes: a blink.
        let twitchPhase = t.truncatingRemainder(dividingBy: 5.3)
        let twitch = !on && twitchPhase < 0.3 ? 14 * sin(.pi * twitchPhase / 0.3) : 0
        let perk = on ? -4.0 : 0
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.7)
        let blink = blinkPhase < 0.14 ? max(0.08, abs(blinkPhase - 0.07) / 0.07) : 1
        DogFace.drawColored(in: NSRect(x: 0, y: 0, width: 18, height: 18),
                            earAngles: (CGFloat(twitch + perk), CGFloat(perk)), blink: CGFloat(blink))

        if on { headset(cg, p) }

        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Parts

    /// The headset: drops onto the head with a small bounce, then the mic swings in front of the
    /// mouth; afterwards a blinking REC light and sound waves.
    private static func headset(_ cg: CGContext, _ p: Double) {
        // Roomier than the head: scaled up around the middle of the face.
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: 9, y: 7.6)
        cg.scaleBy(x: 1.16, y: 1.13)
        cg.translateBy(x: -9, y: -7.6)

        let drop = 0.55
        let k = min(1, p / drop)
        let y = 7 * (1 - easeOutBack(k))
        cg.saveGState()
        cg.setAlpha(CGFloat(min(1, p / 0.18)))
        cg.translateBy(x: 0, y: y)

        // Band over the head, between the ears.
        let band = NSBezierPath()
        band.move(to: NSPoint(x: 1.5, y: 8.4))
        band.curve(to: NSPoint(x: 16.5, y: 8.4), controlPoint1: NSPoint(x: 1.0, y: 17.4), controlPoint2: NSPoint(x: 17.0, y: 17.4))
        band.lineWidth = 1.15
        band.lineCapStyle = .round
        gear.setStroke(); band.stroke()

        // Mic boom from the left cup to the mouth, swinging in after the drop.
        let swing = min(1, max(0, (p - 0.3) / 0.4))
        cg.saveGState()
        cg.translateBy(x: 1.6, y: 6.6)
        cg.rotate(by: CGFloat((1 - easeOutBack(swing)) * 70 * .pi / 180))
        cg.translateBy(x: -1.6, y: -6.6)
        let boom = NSBezierPath()
        boom.move(to: NSPoint(x: 1.8, y: 6.0))
        boom.curve(to: NSPoint(x: 6.4, y: 3.6), controlPoint1: NSPoint(x: 2.0, y: 3.6), controlPoint2: NSPoint(x: 4.4, y: 3.2))
        boom.lineWidth = 0.55
        boom.lineCapStyle = .round
        gear.setStroke(); boom.stroke()
        gear.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6.0, y: 3.05, width: 1.6, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()
        cg.restoreGState()

        // Ear cups.
        for cx in [CGFloat(1.4), 16.6] {
            gear.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - 1.35, y: 5.6, width: 2.7, height: 4.0), xRadius: 1.2, yRadius: 1.2).fill()
            cushion.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx - 0.8, y: 6.2, width: 1.6, height: 2.8), xRadius: 0.75, yRadius: 0.75).fill()
        }
        cg.restoreGState()

        guard p > 0.7 else { return }
        let q = p - 0.7
        // REC light on the right cup.
        if q.truncatingRemainder(dividingBy: 1.1) < 0.7 {
            rec.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16.6 - 0.5, y: 7.1, width: 1.0, height: 1.0)).fill()
        }
        // Sound waves coming in on both sides.
        for i in 0..<2 {
            let phase = (q / 1.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let r = 2.0 + 1.3 * phase
            let alpha = CGFloat(0.55 * (1 - phase))
            for (cx, start) in [(CGFloat(1.4), CGFloat(140)), (CGFloat(16.6), CGFloat(-40))] {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: cx, y: 7.6), radius: CGFloat(r), startAngle: start, endAngle: start + 80)
                arc.lineWidth = 0.45
                arc.lineCapStyle = .round
                NSColor.systemGray.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
        }
    }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
