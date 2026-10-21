import AppKit
import Foundation

enum Storage: String, Codable, CaseIterable {
    case local      // this Mac only, never synced
    case oneDrive   // <OneDrive>/MeetingNotes
    case custom     // a folder the user picked
}

enum SummaryStyle: String, Codable, CaseIterable {
    case detailed, standard, brief

    var label: String {
        switch self {
        case .detailed: return "Detailed"
        case .standard: return "Standard"
        case .brief: return "Brief"
        }
    }

    var help: String {
        switch self {
        case .detailed: return "Long notes with context, who said what, numbers — for people who missed the meeting."
        case .standard: return "The main topics and outcomes, one line each."
        case .brief: return "As short as possible — a few bullet points to skim in 15 seconds."
        }
    }
}

struct AppSettings: Codable, Equatable {
    var myName = NSFullUserName().components(separatedBy: " ").first ?? ""
    var languages: [String] = [] // spoken in meetings: [] = detect automatically, ["en","fr"] = may switch
    var notesLanguage = "auto"   // "auto" = the meeting's main language, else e.g. "English"
    var vocabulary = ""
    var summaryStyle = SummaryStyle.standard
    var teamsOnly = false        // false = all Mac audio
    var keepAudio = true
    var storage = Storage.local
    var oneDrivePath = ""        // root of the chosen OneDrive account
    var customFolderPath = ""
    var useCalendar = true       // meeting title + attendees from the calendar
    var callReminders = true     // "Record this meeting?" when a call starts

    var notesFolder: URL {
        switch storage {
        case .local:
            return CloudFolders.localNotesFolder
        case .oneDrive:
            guard !oneDrivePath.isEmpty else { return CloudFolders.localNotesFolder }
            return URL(fileURLWithPath: oneDrivePath, isDirectory: true).appendingPathComponent("MeetingNotes", isDirectory: true)
        case .custom:
            guard !customFolderPath.isEmpty else { return CloudFolders.localNotesFolder }
            return URL(fileURLWithPath: customFolderPath, isDirectory: true)
        }
    }

    init() {}

    // Tolerant decoding: settings saved by older versions keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? d.myName
        if let l = try c.decodeIfPresent([String].self, forKey: .languages) {
            languages = l
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .language), !legacy.isEmpty {
            languages = [legacy]
        }
        notesLanguage = try c.decodeIfPresent(String.self, forKey: .notesLanguage) ?? d.notesLanguage
        useCalendar = try c.decodeIfPresent(Bool.self, forKey: .useCalendar) ?? d.useCalendar
        callReminders = try c.decodeIfPresent(Bool.self, forKey: .callReminders) ?? d.callReminders
        vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? d.vocabulary
        summaryStyle = (try? c.decodeIfPresent(SummaryStyle.self, forKey: .summaryStyle)) ?? d.summaryStyle
        teamsOnly = try c.decodeIfPresent(Bool.self, forKey: .teamsOnly) ?? d.teamsOnly
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? d.keepAudio
        oneDrivePath = try c.decodeIfPresent(String.self, forKey: .oneDrivePath) ?? ""
        customFolderPath = try c.decodeIfPresent(String.self, forKey: .customFolderPath) ?? ""
        if let s = try? c.decodeIfPresent(Storage.self, forKey: .storage) {
            storage = s
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .notesFolderPath),
                  URL(fileURLWithPath: legacy).standardizedFileURL != CloudFolders.localNotesFolder.standardizedFileURL {
            storage = .custom // v0.1 stored a plain folder path
            customFolderPath = legacy
        }
    }

    private enum CodingKeys: String, CodingKey {
        case myName, language, languages, notesLanguage, useCalendar, callReminders, vocabulary, summaryStyle, teamsOnly, keepAudio, storage, oneDrivePath,
             customFolderPath, notesFolderPath
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(myName, forKey: .myName)
        try c.encode(languages, forKey: .languages)
        try c.encode(notesLanguage, forKey: .notesLanguage)
        try c.encode(useCalendar, forKey: .useCalendar)
        try c.encode(callReminders, forKey: .callReminders)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(summaryStyle, forKey: .summaryStyle)
        try c.encode(teamsOnly, forKey: .teamsOnly)
        try c.encode(keepAudio, forKey: .keepAudio)
        try c.encode(storage, forKey: .storage)
        try c.encode(oneDrivePath, forKey: .oneDrivePath)
        try c.encode(customFolderPath, forKey: .customFolderPath)
    }
}

/// Finds OneDrive and tells whether a folder is synced to a cloud service.
enum CloudFolders {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    struct Account: Hashable {
        let url: URL
        var name: String {
            // "OneDrive-Contoso" → "OneDrive – Contoso", "OneDrive - Personal" → "OneDrive – Personal"
            let raw = url.lastPathComponent
            let rest = raw.dropFirst("OneDrive".count).trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
            return rest.isEmpty ? "OneDrive" : "OneDrive – \(rest)"
        }
    }

    /// OneDrive folders on this Mac: ~/Library/CloudStorage/OneDrive-* (current app) and the
    /// older ~/OneDrive* location.
    static var oneDriveAccounts: [Account] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in [home.appendingPathComponent("Library/CloudStorage"), home] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            found += items.filter {
                $0.lastPathComponent.hasPrefix("OneDrive")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }.map(Account.init)
    }

    /// "OneDrive", "iCloud", "Google Drive"… if the folder (or a parent) is synced, else nil.
    static func syncService(for url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/Library/Mobile Documents/") { return "iCloud" }
        if let r = path.range(of: "/Library/CloudStorage/") {
            let provider = path[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            if provider.hasPrefix("OneDrive") { return "OneDrive" }
            if provider.hasPrefix("GoogleDrive") { return "Google Drive" }
            return provider.split(separator: "-").first.map(String.init) ?? "the cloud"
        }
        if path.hasPrefix(home.appendingPathComponent("OneDrive").path) { return "OneDrive" }
        // iCloud "Desktop & Documents": ~/Documents keeps its path but is synced.
        var probe = url
        while probe.path.count > home.path.count {
            if FileManager.default.fileExists(atPath: probe.path) {
                if (try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return "iCloud" }
            }
            probe.deleteLastPathComponent()
        }
        return nil
    }

    /// "This Mac only": ~/Documents/MeetingNotes, or ~/MeetingNotes when Documents is synced.
    static var localNotesFolder: URL {
        let docs = home.appendingPathComponent("Documents", isDirectory: true)
        let base = syncService(for: docs) == nil ? docs : home
        return base.appendingPathComponent("MeetingNotes", isDirectory: true)
    }
}

/// Languages offered in Settings (Whisper codes → names).
let meetingLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("fr", "French"), ("de", "German"), ("es", "Spanish"), ("it", "Italian"),
    ("pt", "Portuguese"), ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"),
]
