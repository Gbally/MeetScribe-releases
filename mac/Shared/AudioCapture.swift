// Audio capture shared by the menu bar app and the `meeting-recorder` CLI.
//
// Records the microphone and the Mac's system audio (Teams, browser, …) into two separate
// 16 kHz mono files on a shared timeline (t = 0 at start). Gaps — nothing playing, a
// device switch, a capture restart — are filled with silence so the tracks stay aligned.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

/// Writes audio of any format to a 16 kHz mono 16-bit CAF file, padding gaps with silence.
final class TrackWriter {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    let url: URL
    let startSeconds: Double
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0
    private let lock = NSLock()

    init(url: URL, startSeconds: Double) {
        self.url = url
        self.startSeconds = startSeconds
    }

    func write(_ buffer: AVAudioPCMBuffer, atSeconds t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard buffer.frameLength > 0, let pcm = convert(buffer) else { return }
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let file else { return }
            let expected = AVAudioFramePosition(max(0, t - startSeconds) * 16_000)
            var gap = expected - framesWritten
            if gap > 800 { // > 50 ms: pad with silence to keep the timeline aligned
                while gap > 0 {
                    let n = AVAudioFrameCount(min(gap, 160_000))
                    let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: n)!
                    silence.frameLength = n
                    silence.floatChannelData![0].update(repeating: 0, count: Int(n))
                    try file.write(from: silence)
                    framesWritten += AVAudioFramePosition(n)
                    gap -= AVAudioFramePosition(n)
                }
            }
            try file.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
            let ch = pcm.floatChannelData![0]
            for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(ch[i])) }
        } catch {
            NSLog("MeetNouce: write error (\(url.lastPathComponent)): \(error.localizedDescription)")
        }
    }

    /// Converts any input format (48 kHz stereo, AirPods' 24 kHz, …) to 16 kHz mono.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == Self.format { return buffer }
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    /// Loudest sample since the last call (0…1), for level meters.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peak; peak = 0; return p
    }

    var seconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(framesWritten) / 16_000
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        file = nil // AVAudioFile finalizes the file when released
    }
}

enum CaptureError: LocalizedError {
    case permission(String)
    case other(String)
    var errorDescription: String? {
        switch self { case .permission(let s), .other(let s): return s }
    }
}

/// System audio via ScreenCaptureKit. Restarts itself if the stream dies (display change, sleep…).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: TrackWriter
    /// Called (on any thread) with a user-facing note, e.g. "Teams isn't running — recording all Mac audio".
    var onNotice: ((String) -> Void)?
    private var stream: SCStream?
    private var appName: String?
    private var stopped = false
    private var restarts = 0
    private let queue = DispatchQueue(label: "meetscribe.system-audio")

    init(writer: TrackWriter) { self.writer = writer }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start(appName: String?) async throws {
        self.appName = appName?.isEmpty == true ? nil : appName
        try await startStream()
    }

    private func startStream() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permission(tr("Mac audio isn't allowed yet (Screen & System Audio Recording permission)."))
        }
        guard let display = content.displays.first else { throw CaptureError.other(tr("No display found.")) }

        var filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        if let appName {
            let apps = content.applications.filter { $0.applicationName.localizedCaseInsensitiveContains(appName) }
            if apps.isEmpty {
                onNotice?(tr("%@ isn't running — recording all Mac audio instead.", appName))
            } else {
                filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            }
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Only audio is needed; keep the mandatory video stream tiny and slow.
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
        stopped = true
        try? await stream?.stopCapture()
        stream = nil
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
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { return }
        writer.write(pcm, atSeconds: sb.presentationTimeStamp.seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        NSLog("MeetNouce: system audio stopped: \(error.localizedDescription)")
        guard restarts < 20 else {
            onNotice?(tr("Mac audio capture stopped: %@", error.localizedDescription))
            return
        }
        restarts += 1
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !self.stopped else { return }
            do { try await self.startStream() } catch {
                self.onNotice?(tr("Mac audio capture stopped: %@", error.localizedDescription))
            }
        }
    }
}

/// Microphone via AVAudioEngine. Follows device changes (AirPods connecting, USB headset…).
final class MicCapture {
    let writer: TrackWriter
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(writer: TrackWriter) { self.writer = writer }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        try startEngine()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.stopped else { return }
            NSLog("MeetNouce: audio device changed — restarting microphone")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.engine = AVAudioEngine()
            try? self.startEngine()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.other(tr("No microphone available."))
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [writer] buffer, time in
            let t = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : hostSeconds()
            writer.write(buffer, atSeconds: t)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
    }
}

/// One recording: mic + system audio into `folder`. Starts whatever it can; reports the rest.
final class MeetingRecorder {
    let folder: URL
    let startSeconds = hostSeconds()
    private(set) var mic: MicCapture?
    private(set) var system: SystemAudioCapture?
    /// User-facing problems (missing permission, app not running…).
    private(set) var notices: [String] = []
    var onNotice: ((String) -> Void)?

    init(folder: URL) { self.folder = folder }

    /// Throws only if nothing at all could be recorded.
    func start(appName: String?, captureMic: Bool = true, captureSystem: Bool = true) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if captureSystem {
            let cap = SystemAudioCapture(writer: TrackWriter(url: folder.appendingPathComponent("system.caf"), startSeconds: startSeconds))
            cap.onNotice = { [weak self] in self?.notice($0) }
            do {
                try await cap.start(appName: appName)
                system = cap
            } catch {
                notice(error.localizedDescription + " " + tr("Only your microphone is recorded."))
            }
        }
        if captureMic {
            if MicCapture.permission == .notDetermined { _ = await MicCapture.requestPermission() }
            if MicCapture.permission == .authorized {
                let cap = MicCapture(writer: TrackWriter(url: folder.appendingPathComponent("mic.caf"), startSeconds: startSeconds))
                do {
                    try cap.start()
                    mic = cap
                } catch {
                    notice(tr("Microphone: %@", error.localizedDescription))
                }
            } else {
                notice(tr("Microphone access isn't allowed — your voice won't be recorded."))
            }
        }
        if mic == nil && system == nil {
            throw CaptureError.other(notices.joined(separator: "\n"))
        }
    }

    private func notice(_ s: String) {
        notices.append(s)
        onNotice?(s)
    }

    func stop() async {
        mic?.stop()
        await system?.stop()
    }

    var elapsed: Double { hostSeconds() - startSeconds }
}
