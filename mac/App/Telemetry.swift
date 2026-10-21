// Anonymous usage pings to the owner's Zenhook workspace (https://zenhook.dev): a new install,
// each recording's length, updates, and processing failures. Never audio, text, titles or names.
// Can be turned off in Settings → Privacy and storage. Fire-and-forget: failures are ignored.

import Foundation

enum Telemetry {
    /// From Info.plist (filled at build time from the gitignored zenhook_token.txt).
    private static var token: String { Bundle.main.object(forInfoDictionaryKey: "MSZenhookToken") as? String ?? "" }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "telemetryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryEnabled") }
    }

    /// Random id per install (not tied to the person), to tell installs apart.
    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "installID") { return id }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        UserDefaults.standard.set(id, forKey: "installID")
        return id
    }

    static func send(title: String, level: String = "info", emoji: String, message: String? = nil,
                     fields: [String: String] = [:]) {
        guard enabled, !token.isEmpty, let url = URL(string: "https://zenhook.dev/api/webhook/\(token)") else { return }
        var all = fields
        all["Version"] = Engine.appVersion
        all["Mac"] = "\(Hardware.current.chip), \(Hardware.current.memoryGB) GB"
        all["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        var body: [String: Any] = [
            "title": String(title.prefix(200)), "level": level, "emoji": emoji, "actor": installID,
            "source": "MeetScribe",
            "fields": all.sorted { $0.key < $1.key }.map { ["label": $0.key, "value": $0.value] },
        ]
        if let message { body["message"] = String(message.prefix(1000)) }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: - Events

    static func installed(notesModel: String, speechModel: String) {
        send(title: "New install", level: "success", emoji: "👋",
             fields: ["Notes model": short(notesModel), "Speech model": short(speechModel)])
    }

    static func updated(from old: String) {
        send(title: "Updated to \(Engine.appVersion)", emoji: "⬆️", fields: ["From": old])
    }

    static func recording(duration: Double, processing: Double, template: String, meetingAudio: Bool,
                          speakers: Int, todos: Int, model: String) {
        send(title: "Meeting recorded · \(formatDuration(duration))", emoji: "🎙️", fields: [
            "Length": formatDuration(duration),
            "Processing": formatDuration(processing),
            "Type": templateName(template),
            "Meeting audio": meetingAudio ? "yes" : "no (mic only)",
            "Speakers": "\(speakers)",
            "To-dos": "\(todos)",
            "Notes model": short(model),
        ])
    }

    /// Only the kind of error — no paths or text from the meeting.
    static func failed(_ what: String, error: String) {
        let kind = error.split(separator: "\n").last.map { line -> String in
            let s = String(line)
            if let colon = s.firstIndex(of: ":") { return String(s[..<colon]) }
            return String(s.prefix(60))
        } ?? "unknown"
        send(title: "\(what) failed", level: "warning", emoji: "⚠️", fields: ["Error": kind])
    }

    private static func short(_ repo: String) -> String { repo.components(separatedBy: "/").last ?? repo }
}
