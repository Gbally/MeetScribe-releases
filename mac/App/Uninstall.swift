// Removes MeetScribe from this Mac: the engine + models it downloaded (outside the app, several
// GB), its settings, the login item, and the app itself. Meeting notes are only removed when the
// user asks — and then go to the Trash, never deleted outright.

import AppKit
import ServiceManagement
import UserNotifications

enum Uninstaller {
    /// Hugging Face cache, where the AI models are downloaded (shared with other apps).
    static var hfCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let hub = env["HF_HUB_CACHE"], !hub.isEmpty { return URL(fileURLWithPath: hub) }
        if let home = env["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    /// Models downloaded through MeetScribe outside the catalog (custom Hugging Face links).
    static func rememberDownload(_ repo: String) {
        var repos = UserDefaults.standard.stringArray(forKey: "downloadedRepos") ?? []
        if !repos.contains(repo) { repos.append(repo) }
        UserDefaults.standard.set(repos, forKey: "downloadedRepos")
    }

    /// Only the models MeetScribe uses — never other repos someone has in their Hugging Face cache.
    @MainActor
    static func modelFolders(_ model: AppModel) -> [URL] {
        var repos = Set((model.catalog.notes + model.catalog.speech).map(\.repo))
        repos.formUnion([model.settings.llmModel, model.settings.whisperModel].compactMap { $0 })
        repos.formUnion(UserDefaults.standard.stringArray(forKey: "downloadedRepos") ?? [])
        return repos.map { hfCache.appendingPathComponent("models--" + $0.replacingOccurrences(of: "/", with: "--")) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func size(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { continue }
            for case let f as URL in e {
                if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                    total += Int64(v.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// Deletes everything, puts the app (and optionally the notes) in the Trash, then quits.
    @MainActor
    static func run(_ model: AppModel, removeNotes: Bool) {
        let fm = FileManager.default
        let models = modelFolders(model)
        let notes = model.settings.notesFolder
        Engine.log("uninstall (notes: \(removeNotes))")

        try? SMAppService.mainApp.unregister()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        for url in models { try? fm.removeItem(at: url) }
        // Recordings not processed yet live in the engine folder: keep them if the notes stay.
        if !removeNotes, let pending = try? fm.contentsOfDirectory(at: AppModel.workDir, includingPropertiesForKeys: nil),
           !pending.isEmpty {
            try? fm.createDirectory(at: notes, withIntermediateDirectories: true)
            for p in pending { try? fm.moveItem(at: p, to: notes.appendingPathComponent(p.lastPathComponent)) }
        }
        try? fm.removeItem(at: Engine.support)
        if removeNotes { try? fm.trashItem(at: notes, resultingItemURL: nil) }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)

        NSApp.terminate(nil)
    }
}
