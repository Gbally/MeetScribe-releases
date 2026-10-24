import AppKit
import Foundation

/// Sending a meeting's notes and to-dos to other apps: a Markdown folder (Obsidian, Logseq,
/// iA Writer…), Apple Notes and Things. Everything stays on this Mac — no account, no server.
@MainActor
enum Export {
    /// The notes as a Markdown file for a notes app's folder: front matter (date, people, tags)
    /// that Obsidian and the like understand, then the same notes as notes.md.
    static func markdown(_ m: Meeting) -> String? {
        guard let body = try? String(contentsOf: m.url("notes.md"), encoding: .utf8) else { return nil }
        let day = m.date.formatted(.iso8601.year().month().day())
        let people = (m.notes?.participants ?? []).map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }
        let front = ["---", "date: \(day)", "participants: [\(people.joined(separator: ", "))]",
                     "tags: [meeting]", "source: MeetScribe", "---", ""]
        // The link to the transcript only works inside the meeting folder.
        let lines = body.components(separatedBy: "\n").filter { !$0.contains("(transcript.md)") }
        return (front + lines).joined(separator: "\n")
    }

    /// "2026-10-23 Weekly sync.md" in `folder`; an earlier export of the same meeting is replaced.
    @discardableResult
    static func saveToFolder(_ m: Meeting, folder: URL) throws -> URL {
        guard let text = markdown(m) else { throw CocoaError(.fileReadNoSuchFile) }
        let day = m.date.formatted(.iso8601.year().month().day())
        let safe = m.title.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let file = folder.appendingPathComponent("\(day) \(safe.isEmpty ? tr("Meeting") : String(safe.prefix(80))).md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A new note in Apple Notes (macOS asks once to allow MeetScribe to control Notes).
    static func appleNotes(_ m: Meeting) -> Bool {
        let html = "<h1>\(escape(m.title))</h1>" + m.shareText.components(separatedBy: "\n").dropFirst()
            .map { $0.isEmpty ? "<br>" : "<div>\(escape($0))</div>" }.joined()
        let script = """
        set noteTitle to "\(quoted(m.title))"
        set noteText to "\(quoted(html))"
        tell application "Notes"
            make new note at folder 1 of default account with properties {name:noteTitle, body:noteText}
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }

    static var hasThings: Bool { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "things:///show")!) != nil }

    /// The to-dos into Things' inbox (its URL scheme: no account or key needed), each with the
    /// meeting and owner in its notes and the deadline if one was said.
    static func things(_ items: [ActionItem], meetingTitle: String) -> Bool {
        let todos: [[String: Any]] = items.map { a in
            var attributes: [String: Any] = ["title": a.task,
                                             "notes": [meetingTitle, a.owner].filter { !$0.isEmpty }.joined(separator: " — ")]
            if let d = a.dueDate { attributes["deadline"] = d }
            return ["type": "to-do", "attributes": attributes]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: todos), let json = String(data: data, encoding: .utf8)
        else { return false }
        var c = URLComponents(string: "things:///add-json")!
        c.queryItems = [URLQueryItem(name: "data", value: json), URLQueryItem(name: "reveal", value: "true")]
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Inside an AppleScript string literal.
    private static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
