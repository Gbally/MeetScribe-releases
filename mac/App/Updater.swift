// Self-update from the public releases repo: latest.json says which build is current; the app
// downloads the DMG, checks its SHA-256 and that it is signed with the same certificate as the
// running app, swaps itself and relaunches.

import AppKit
import CryptoKit
import Foundation
import Security
import UserNotifications

struct ReleaseInfo: Codable, Equatable {
    var version: String
    var build: Int
    var url: String
    var sha256: String
    var notes: String?
}

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, downloading, installing, failed(String) }

    @Published var available: ReleaseInfo?
    @Published var state: State = .idle
    @Published var lastChecked: Date?

    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }
    private var timer: Timer?

    func start() {
        Task { try? await Task.sleep(nanoseconds: 5_000_000_000); await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            guard let updater = self else { return }
            Task { @MainActor in await updater.check() }
        }
    }

    func check() async {
        guard let url = Releases.url("latest.json"), state != .downloading, state != .installing else { return }
        state = .checking
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        defer { if state == .checking { state = .idle } }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else { return }
        lastChecked = Date()
        available = info.build > Self.currentBuild ? info : nil
        announce()
    }

    /// One notification per new version (clicking it opens Settings → About).
    private func announce() {
        guard let info = available, UserDefaults.standard.integer(forKey: "announcedBuild") < info.build else { return }
        UserDefaults.standard.set(info.build, forKey: "announcedBuild")
        let content = UNMutableNotificationContent()
        content.title = tr("MeetScribe %@ is available", info.version)
        content.body = (info.notes.map { $0 + " " } ?? "") + tr("Click to install.")
        content.userInfo = ["action": "update"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(info.build)", content: content, trigger: nil))
    }

    /// Downloads, verifies and installs `available`, then relaunches. Call only when idle.
    func install() {
        guard let info = available, let url = URL(string: info.url) else { return }
        state = .downloading
        Task {
            do {
                let staged = try await Self.prepare(url: url, sha256: info.sha256)
                state = .installing
                try Self.swapAndRelaunch(with: staged)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private struct UpdateError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Download → checksum → mount → signature check → copy out. Returns the staged app.
    private static func prepare(url: URL, sha256: String) async throws -> URL {
        let (file, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw UpdateError(tr("The download is damaged (checksum mismatch).")) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MeetScribeUpdate-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try data.write(to: dmg)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let newApp = mount.appendingPathComponent("MeetScribe.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError(tr("The update doesn't contain MeetScribe.")) }
        try verifySameSigner(newApp)
        let staged = work.appendingPathComponent("MeetScribe.app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        return staged
    }

    /// The new app must satisfy the running app's designated requirement (same certificate) — or,
    /// when this build names the developer's Apple team (MSDeveloperTeam in Info.plist), be signed
    /// with that team's Developer ID: the one-time move from the local certificate to a notarized one.
    private static func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError(tr("Couldn't check the update's signature."))
        }
        var status = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        if status != errSecSuccess, let team = Bundle.main.object(forInfoDictionaryKey: "MSDeveloperTeam") as? String,
           team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil {
            var developerID: SecRequirement?
            let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
                + "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
            if SecRequirementCreateWithString(text as CFString, [], &developerID) == errSecSuccess, let developerID {
                status = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), developerID)
            }
        }
        guard status == errSecSuccess else {
            throw UpdateError(tr("The update isn't signed by the MeetScribe developer — not installed."))
        }
    }

    /// Replaces the running app once it has quit, then opens the new one.
    private static func swapAndRelaunch(with staged: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            // No permission to write /Applications (managed Mac): let the user drag it in.
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            throw UpdateError(tr("Drag the new MeetScribe from the Finder window into Applications (replace the old one)."))
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(current.path)" && /usr/bin/ditto "\(staged.path)" "\(current.path)" && /usr/bin/open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError(URL(fileURLWithPath: exe).lastPathComponent + " failed: " + text) }
        return text
    }
}
