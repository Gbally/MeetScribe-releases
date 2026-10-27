// Meeting folders on disk → history entries.
//
// Each meeting is a folder in the notes folder:
//   meeting.json      written by the app (title typed by the user, start time, duration)
//   mic.caf / system.caf   the recording
//   transcript.md/.json, notes.md, notes.json   written by the engine
//   todo.json         which action items were ticked off in the app
//   error.txt         why processing failed

import AppKit
import Foundation

struct ActionItem: Codable, Hashable {
    var owner: String
    var task: String
    var due: String
    var dueDate: String?  // yyyy-MM-dd, worked out by the engine from `due`

    enum CodingKeys: String, CodingKey { case owner, task, due, dueDate = "due_date" }

    var dueDay: Date? {
        guard let dueDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: dueDate)
    }
}

struct NoteSection: Codable, Hashable {
    var title: String
    var items: [String]
}

struct MeetingNotes: Codable {
    var title: String
    var date: String
    var duration: Double
    var participants: [String]
    var summary: [String]
    var decisions: [String]
    var actions: [ActionItem]
    var questions: [String]
    var tracks: [String]?
    var template: String?
    var sections: [NoteSection]?
    var version: Int?
    var guessedNames: [String]?   // speaker names taken from the calendar invitations, not yet confirmed

    enum CodingKeys: String, CodingKey {
        case title, date, duration, participants, summary, decisions, actions, questions, tracks, template,
             sections, version, guessedNames = "guessed_names"
    }

    /// Recorded by the app, but only the microphone had sound: the other participants were
    /// only captured through the speakers (usually: Screen & System Audio permission missing).
    var missingMeetingAudio: Bool { tracks?.contains("room") == true }
}

struct MeetingInfo: Codable {
    var title: String
    var started: String
    var duration: Double?
    var calendar: CalendarEvent?
    var template: String?
    var label: String?  // a copy's name ("Qwen3.5 9B"), added to its title
}

extension JSONDecoder {
    static let meetscribe: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let meetscribe: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

struct Meeting: Identifiable, Equatable {
    let folder: URL
    var id: String { folder.lastPathComponent }
    var info: MeetingInfo?
    var notes: MeetingNotes?
    var error: String?
    var hasAudio: Bool
    var hasTranscript: Bool
    var done: Set<Int>
    /// Lowercased title + notes + transcript, for the search box.
    var searchText = ""
    /// Waiting for its notes, or for better ones (Settings → Notes → when to write them).
    var later: LaterNotes?

    static func == (a: Meeting, b: Meeting) -> Bool {
        a.id == b.id && a.notes?.title == b.notes?.title && a.error == b.error && (a.later == nil) == (b.later == nil)
            && a.hasTranscript == b.hasTranscript && a.done == b.done && a.hasAudio == b.hasAudio
    }

    /// Speaker labels nobody has named yet ("Speaker 2"…).
    var unnamedSpeakers: [String] {
        (notes?.participants ?? []).filter { $0.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil }
    }

    struct Clip: Codable, Hashable {
        var file: String
        var start: Double
        var text: String
    }

    /// Short voice samples per speaker (clips.json, made by the engine).
    var clips: [String: [Clip]]? {
        guard let data = try? Data(contentsOf: url("clips.json")) else { return nil }
        return try? JSONDecoder().decode([String: [Clip]].self, from: data)
    }

    /// The first things each speaker said, to help tell who is who.
    func samples(perSpeaker n: Int = 3) -> [String: [String]] {
        guard let data = try? Data(contentsOf: url("transcript.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let utts = json["utterances"] as? [[String: Any]] else { return [:] }
        var out: [String: [String]] = [:]
        for u in utts {
            guard let spk = u["speaker"] as? String, let text = u["text"] as? String,
                  text.split(separator: " ").count >= 4, (out[spk]?.count ?? 0) < n else { continue }
            out[spk, default: []].append(text.count > 140 ? String(text.prefix(140)) + "…" : text)
        }
        return out
    }

    var title: String {
        if let t = notes?.title, !t.isEmpty { return t }
        if let t = info?.title, !t.isEmpty { return t }
        return tr("Meeting")
    }

    var date: Date {
        for s in [info?.started, notes?.date].compactMap({ $0 }) {
            if let d = ISO8601DateFormatter.local.date(from: String(s.prefix(19))) { return d }
        }
        return (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    var duration: Double? { notes?.duration ?? info?.duration }

    /// Recorded but never transcribed (e.g. the app quit while processing).
    var needsProcessing: Bool { hasAudio && !hasTranscript && error == nil }

    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    static func load(_ folder: URL) -> Meeting? {
        let fm = FileManager.default
        let dec = JSONDecoder.meetscribe
        func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? dec.decode(type, from: data)
        }
        let info = read("meeting.json", MeetingInfo.self)
        let notes = read("notes.json", MeetingNotes.self)
        let hasAudio = ["mic.caf", "system.caf"].contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let hasTranscript = fm.fileExists(atPath: folder.appendingPathComponent("transcript.json").path)
        guard info != nil || notes != nil || hasAudio || hasTranscript else { return nil }
        let error = try? String(contentsOf: folder.appendingPathComponent("error.txt"))
        let done = Set(read("todo.json", [Int].self) ?? [])
        var m = Meeting(folder: folder, info: info, notes: notes, error: error, hasAudio: hasAudio,
                        hasTranscript: hasTranscript, done: done)
        var text = [m.title] + (notes?.participants ?? []) + (notes?.summary ?? []) + (notes?.decisions ?? [])
        text += (notes?.actions ?? []).map { "\($0.owner) \($0.task)" } + (notes?.questions ?? [])
        text += (notes?.sections ?? []).flatMap(\.items)
        if let t = try? String(contentsOf: folder.appendingPathComponent("transcript.md")) { text.append(t) }
        m.searchText = text.joined(separator: "\n").lowercased()
        m.later = LaterNotes.read(folder)
        return m
    }

    static func loadAll(in root: URL) -> [Meeting] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(load)
            .sorted { $0.date > $1.date }
    }

    /// Plain-text notes for pasting into an email / Teams chat.
    var shareText: String {
        guard let n = notes else { return title }
        var out = ["\(title) — \(date.local(date: .abbreviated, time: .shortened))", ""]
        if !n.summary.isEmpty { out += [tr("Summary")] + n.summary.map { "• \($0)" } + [""] }
        if !n.decisions.isEmpty { out += [tr("Decisions")] + n.decisions.map { "• \($0)" } + [""] }
        if !n.actions.isEmpty {
            out += [tr("Action items")] + n.actions.map { a in
                var s = "☐ \(a.task)"
                let extra = [a.owner, a.due].filter { !$0.isEmpty }
                if !extra.isEmpty { s += " (\(extra.joined(separator: ", ")))" }
                return s
            } + [""]
        }
        if !n.questions.isEmpty { out += [tr("Open questions")] + n.questions.map { "• \($0)" } }
        return out.joined(separator: "\n")
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Opens a file in its default app, or TextEdit for Markdown when nothing claims .md.
func openFile(_ url: URL) {
    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
        NSWorkspace.shared.open(url)
    } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}
