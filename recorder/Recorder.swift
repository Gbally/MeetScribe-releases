// meeting-recorder — records the microphone and the Mac's system audio (e.g. Teams)
// into two separate files, time-aligned, until Ctrl+C.
//
//   meeting-recorder <output-dir> [--app "Microsoft Teams"] [--no-mic] [--no-system]
//
// Writes <output-dir>/mic.caf and <output-dir>/system.caf. Gaps (e.g. no audio playing)
// are filled with silence so both tracks share the same timeline (t = 0 at start).
// System audio uses ScreenCaptureKit: the terminal app needs the "Screen & System Audio
// Recording" permission; the microphone needs the "Microphone" permission.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// Writes PCM buffers to a file, padding with silence when the timestamps jump forward.
final class TrackWriter {
    let url: URL
    let startSeconds: Double
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private let lock = NSLock()
    private(set) var peak: Float = 0

    init(url: URL, startSeconds: Double) {
        self.url = url
        self.startSeconds = startSeconds
    }

    func write(_ buffer: AVAudioPCMBuffer, atSeconds t: Double) {
        lock.lock(); defer { lock.unlock() }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
            }
            guard let file else { return }
            let sr = buffer.format.sampleRate
            sampleRate = sr
            let expected = AVAudioFramePosition(max(0, t - startSeconds) * sr)
            let gap = expected - framesWritten
            // Pad gaps larger than 50 ms with silence to keep the timeline aligned.
            if gap > AVAudioFramePosition(sr * 0.05),
               let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(gap)) {
                silence.frameLength = AVAudioFrameCount(gap)
                for i in 0..<Int(silence.format.channelCount) {
                    if let ch = silence.floatChannelData?[i] { ch.update(repeating: 0, count: Int(gap)) }
                }
                try file.write(from: silence)
                framesWritten += gap
            }
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            }
        } catch {
            log("Write error (\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak; peak = 0; return p
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil  // AVAudioFile finalizes on deinit
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: TrackWriter
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "system-audio")

    init(writer: TrackWriter) { self.writer = writer }

    func start(appName: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }

        let filter: SCContentFilter
        if let appName {
            let apps = content.applications.filter { $0.applicationName.localizedCaseInsensitiveContains(appName) }
            if apps.isEmpty {
                let running = Set(content.applications.map(\.applicationName)).filter { !$0.isEmpty }.sorted().joined(separator: ", ")
                throw NSError(domain: "rec", code: 2, userInfo: [NSLocalizedDescriptionKey: "No running app matches \"\(appName)\" — start it first (Teams in a browser? use the browser's name, e.g. --app \"Google Chrome\").\n   Running: \(running)"])
            }
            log("Capturing audio from: \(apps.map(\.applicationName).joined(separator: ", "))")
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want audio; keep the (mandatory) video stream as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        writer.close()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let fd = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        writer.write(pcm, atSeconds: sb.presentationTimeStamp.seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("System audio capture stopped: \(error.localizedDescription)")
    }
}

final class MicCapture {
    let writer: TrackWriter
    private let engine = AVAudioEngine()

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "rec", code: 3, userInfo: [NSLocalizedDescriptionKey: "No microphone available"]) }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [writer] buffer, time in
            let t = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CMClockGetTime(CMClockGetHostTimeClock()).seconds
            writer.write(buffer, atSeconds: t)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
    }
}

@main
struct Recorder {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func flag(_ name: String) -> Bool {
            if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
            return false
        }
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
        }
        let appName = option("--app")
        let noMic = flag("--no-mic")
        let noSystem = flag("--no-system")
        guard let outDir = args.first else {
            log("usage: meeting-recorder <output-dir> [--app NAME] [--no-mic] [--no-system]")
            exit(2)
        }
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let t0 = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        var mic: MicCapture?
        var system: SystemAudioCapture?

        if !noSystem {
            let cap = SystemAudioCapture(writer: TrackWriter(url: dir.appendingPathComponent("system.caf"), startSeconds: t0))
            do {
                try await cap.start(appName: appName)
                system = cap
            } catch {
                log("❌ System audio capture failed: \(error.localizedDescription)")
                if (error as NSError).domain != "rec" {
                    log("   Allow your terminal in System Settings → Privacy & Security → Screen & System Audio Recording, then restart it.")
                }
                exit(1)
            }
        }
        if !noMic {
            let cap = MicCapture(writer: TrackWriter(url: dir.appendingPathComponent("mic.caf"), startSeconds: t0))
            do {
                try cap.start()
                mic = cap
            } catch {
                log("❌ Microphone capture failed: \(error.localizedDescription)")
                log("   Allow your terminal in System Settings → Privacy & Security → Microphone.")
                await system?.stop()
                exit(1)
            }
        }

        log("🔴 Recording… press Ctrl+C to stop.")

        // Status line every 5 s: elapsed time + whether each track is hearing anything.
        let status = DispatchSource.makeTimerSource(queue: .global())
        status.schedule(deadline: .now() + 5, repeating: 5)
        status.setEventHandler {
            let elapsed = Int(CMClockGetTime(CMClockGetHostTimeClock()).seconds - t0)
            func meter(_ p: Float?) -> String {
                guard let p else { return "off" }
                return p < 0.001 ? "silent" : String(repeating: "▮", count: max(1, min(10, Int(p * 10) + 1)))
            }
            log(String(format: "  %02d:%02d  mic %@  system %@", elapsed / 60, elapsed % 60,
                       meter(mic?.writer.takePeak()), meter(system?.writer.takePeak())))
        }
        status.resume()

        // Wait for Ctrl+C (SIGINT) or SIGTERM.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var fired = false
            let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
                let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                s.setEventHandler {
                    if !fired { fired = true; cont.resume() }
                }
                s.resume()
                return s
            }
            signalSources = sources
        }

        status.cancel()
        mic?.stop()
        await system?.stop()
        log(String(format: "⏹  Stopped. mic %.0fs, system %.0fs → %@", mic?.writer.seconds ?? 0, system?.writer.seconds ?? 0, dir.path))
    }
}

/// Keeps the signal sources alive for the process lifetime.
var signalSources: [DispatchSourceSignal] = []
