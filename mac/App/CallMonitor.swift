// Notices when a call starts — a meeting app is running and some app opened a microphone —
// so MeetScribe can offer to record. Uses CoreAudio's "device is running somewhere" flag,
// which needs no permission and never touches the audio itself.

import AppKit
import CoreAudio
import Foundation

final class CallMonitor {
    /// Teams (new + classic), Zoom, Webex, Slack, FaceTime, and browsers (Teams/Meet on the web).
    static let meetingApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.tinyspeck.slackmacgap", "com.apple.FaceTime",
        "com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox",
        "company.thebrowser.Browser",
    ]
    static let callApps: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos",
                                        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"]

    /// Called on the main thread when a call seems to have started (mic busy for a few seconds).
    var onCallStarted: ((_ appName: String) -> Void)?
    var isPaused: () -> Bool = { false }

    private var timer: Timer?
    private var busySince: Date?
    private var notifiedThisCall = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // While we record, our own capture keeps the mic busy — nothing to detect.
        if isPaused() { busySince = nil; notifiedThisCall = true; return }
        let busy = Self.micInUse()
        if !busy {
            busySince = nil
            notifiedThisCall = false
            return
        }
        if busySince == nil { busySince = Date() }
        guard !notifiedThisCall, let since = busySince, Date().timeIntervalSince(since) >= 4 else { return }
        let running = NSWorkspace.shared.runningApplications
        // Prefer naming a dedicated call app; fall back to a browser.
        let app = running.first { Self.callApps.contains($0.bundleIdentifier ?? "") }
            ?? running.first { Self.meetingApps.contains($0.bundleIdentifier ?? "") }
        guard let app else { return }
        notifiedThisCall = true
        onCallStarted?(app.localizedName ?? "A meeting app")
    }

    /// True if any input device (mic) is currently being used by some process.
    static func micInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return false }

        for device in devices where hasInput(device) {
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(device, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }
}
