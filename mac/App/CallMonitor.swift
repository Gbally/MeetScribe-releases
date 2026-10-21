// Notices when a call starts and ends: another app (Teams, Zoom, a browser…) opens or releases
// the microphone. Uses CoreAudio's per-process audio objects (macOS 14+), which say which
// process is using an input — so MeetScribe's own recording doesn't count. Needs no permission
// and never touches the audio. On older macOS, falls back to "some app is using a mic".

import AppKit
import CoreAudio
import Foundation

final class CallMonitor {
    /// Bundle-ID prefixes of apps whose microphone use means "a call" (helpers included).
    static let meetingApps = [
        "com.microsoft.teams", "us.zoom", "com.cisco.webex", "com.webex", "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime", "com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari",
        "com.apple.WebKit", "org.mozilla.firefox", "company.thebrowser",
    ]

    var onCallStarted: ((_ appName: String) -> Void)?
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private var busySince: Date?
    private var idleSince: Date?
    private var inCall = false

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let users = Self.otherMicUsers()
        let callApp = users?.first { id in Self.meetingApps.contains { id.hasPrefix($0) } }
        let busy = users == nil ? Self.micInUse() && Self.meetingAppRunning() != nil : callApp != nil

        if busy {
            idleSince = nil
            if busySince == nil { busySince = Date() }
            if !inCall, let since = busySince, Date().timeIntervalSince(since) >= 4 {
                inCall = true
                onCallStarted?(callApp.flatMap(Self.appName) ?? Self.meetingAppRunning() ?? "A meeting app")
            }
        } else {
            busySince = nil
            guard inCall else { return }
            if idleSince == nil { idleSince = Date() }
            // Only per-process detection can tell that the call ended while we record.
            if users != nil, let since = idleSince, Date().timeIntervalSince(since) >= 45 {
                inCall = false
                onCallEnded?()
            } else if users == nil {
                inCall = false
            }
        }
    }

    // MARK: - CoreAudio

    private static func fourcc(_ s: String) -> AudioObjectPropertySelector {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Bundle IDs of other processes currently recording from an input; nil if this macOS
    /// can't tell (before 14.0).
    static func otherMicUsers() -> [String]? {
        var addr = address(fourcc("prs#")) // kAudioHardwarePropertyProcessObjectList
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        var users: [String] = []
        for id in ids {
            var running: UInt32 = 0, pid: Int32 = 0
            var s4 = UInt32(MemoryLayout<UInt32>.size), sp = UInt32(MemoryLayout<Int32>.size)
            var a1 = address(fourcc("piri")), a2 = address(fourcc("ppid")) // IsRunningInput, PID
            guard AudioObjectGetPropertyData(id, &a1, 0, nil, &s4, &running) == noErr, running != 0,
                  AudioObjectGetPropertyData(id, &a2, 0, nil, &sp, &pid) == noErr, pid != me else { continue }
            var bundle: Unmanaged<CFString>?
            var sb = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var a3 = address(fourcc("pbid")) // BundleID
            let fromAudio = AudioObjectGetPropertyData(id, &a3, 0, nil, &sb, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            users.append(fromAudio ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid:\(pid)")
        }
        return users
    }

    private static func appName(_ bundleID: String) -> String? {
        let main = meetingApps.first { bundleID.hasPrefix($0) } ?? bundleID
        return NSWorkspace.shared.runningApplications.first { ($0.bundleIdentifier ?? "").hasPrefix(main) }?.localizedName
    }

    private static func meetingAppRunning() -> String? {
        NSWorkspace.shared.runningApplications.first { app in
            meetingApps.contains { (app.bundleIdentifier ?? "").hasPrefix($0) }
        }?.localizedName
    }

    /// Fallback: any input device is in use by some process.
    static func micInUse() -> Bool {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return false }
        for device in devices {
            var saddr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            var ssize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &saddr, 0, nil, &ssize) == noErr, ssize > 0 else { continue }
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectGetPropertyData(device, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}
