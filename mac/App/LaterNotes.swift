import AppKit
import CryptoKit
import Foundation
import IOKit.ps

/// When the notes are written. The transcript is always made right away (Whisper is light); the
/// notes model is what slows a busy Mac — so it can wait until the Mac is free, with a bigger model.
enum NotesTiming: String, Codable, CaseIterable {
    case now     // right after the meeting, with the usual model
    case later   // only when the Mac is free, with the "later" model
    case both    // quick notes now, better ones with the "later" model when the Mac is free

    var label: String {
        switch self {
        case .now: return tr("Right after the meeting")
        case .later: return tr("When I'm not using the Mac")
        case .both: return tr("Quick notes right away, better ones when I'm not using the Mac")
        }
    }
}

/// Hours of the day the Mac is usually free ("12:00–13:30"), in minutes from midnight.
struct TimeWindow: Codable, Hashable {
    var start: Int
    var end: Int

    func contains(_ minute: Int) -> Bool {
        start <= end ? (start..<end).contains(minute) : minute >= start || minute < end  // also "22:00–06:00"
    }
}

/// A meeting waiting for its notes (or its better notes): `notes_later.json` in its folder.
struct LaterNotes: Codable {
    var polish: Bool     // quick notes exist: replace them, unless they were edited since
    var notesHash: String?

    static let file = "notes_later.json"

    static func hash(_ folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("notes.json")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ folder: URL) -> LaterNotes? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(LaterNotes.self, from: data)
    }

    static func mark(_ folder: URL, polish: Bool) {
        let item = LaterNotes(polish: polish, notesHash: polish ? hash(folder) : nil)
        try? JSONEncoder().encode(item).write(to: folder.appendingPathComponent(file))
    }

    static func clear(_ folder: URL) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
}

/// Whether nobody is using the Mac right now, by the user's rules: set hours, no keyboard or mouse
/// for a while, or the screen locked — and always on power.
@MainActor
final class MacUse {
    static let shared = MacUse()
    private(set) var screenLocked = false

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in MacUse.shared.screenLocked = true }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in MacUse.shared.screenLocked = false }
        }
    }

    var onPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    /// Seconds since the last keyboard, mouse or trackpad event.
    var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func isFree(_ s: AppSettings, now: Date = Date()) -> Bool {
        guard onPower else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (s.laterInWindows && s.laterWindows.contains { $0.contains(minute) })
            || (s.laterWhenIdle && idleSeconds >= Double(s.laterIdleMinutes * 60))
            || (s.laterWhenLocked && screenLocked)
    }
}

extension AppModel {
    /// Meetings waiting for their notes (or better notes), oldest first.
    var waitingForNotes: [Meeting] {
        meetings.filter { $0.later != nil }.sorted { $0.date < $1.date }
    }

    /// The "later" notes model (or the usual one if none is chosen, or it was deleted).
    var laterNotesModel: String {
        guard let repo = settings.laterModel, installedModels.isEmpty || installedModels[repo] != nil else { return notesModel }
        return repo
    }

    /// After a recording or file became a meeting: what's still to write later.
    func markForLater(_ folder: URL?) {
        guard let folder, settings.notesTiming != .now else { return }
        LaterNotes.mark(folder, polish: settings.notesTiming == .both)
    }

    /// Every minute (and after each job): when the Mac is free, or `now`, writes the next waiting
    /// meeting's notes. One at a time: if someone comes back, the one being written is finished and
    /// the next ones wait.
    func writeLaterNotes(now force: Bool = false) {
        guard phase == .ready, currentJob == nil, queue.isEmpty, !isRecording else { return }
        guard force || MacUse.shared.isFree(settings) else { return }
        for m in waitingForNotes {
            guard let item = LaterNotes.read(m.folder) else { continue }
            if item.polish && item.notesHash != LaterNotes.hash(m.folder) {
                LaterNotes.clear(m.folder)  // the quick notes were edited: keep them as they are
                continue
            }
            notesModelFor[m.id] = laterNotesModel
            enqueue(.resummarize(m.id))
            if !force { return }
        }
    }
}
