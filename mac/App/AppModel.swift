import AppKit
import AVFoundation
import Foundation
import ServiceManagement
import UserNotifications

struct AppSettings: Codable, Equatable {
    var myName = NSFullUserName().components(separatedBy: " ").first ?? ""
    var language = ""            // "" = auto, "en", "fr", …
    var vocabulary = ""
    var teamsOnly = false        // false = all Mac audio
    var keepAudio = true
    var notesFolderPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetingNotes").path

    var notesFolder: URL { URL(fileURLWithPath: notesFolderPath, isDirectory: true) }
}

enum Job: Equatable {
    case process(Meeting.ID)
    case processFile(URL)
    case rename(Meeting.ID, [String: String])
    case resummarize(Meeting.ID)
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case needsSetup, settingUp, ready }

    @Published var phase: Phase = Engine.isInstalled ? .ready : .needsSetup
    @Published var settings: AppSettings { didSet { saveSettings() } }
    @Published var meetings: [Meeting] = []

    // Setup
    @Published var setupStatus = ""
    @Published var setupProgress: Double?
    @Published var setupError: String?

    // Recording
    @Published var recorder: MeetingRecorder?
    @Published var recordingID: Meeting.ID?
    @Published var elapsed: Double = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var notices: [String] = []
    @Published var startError: String?
    @Published var isStarting = false

    // Processing queue
    @Published var queue: [Job] = []
    @Published var currentJob: Job?
    @Published var jobStatus = ""

    // Permissions
    @Published var micPermission = MicCapture.permission
    @Published var screenPermission = SystemAudioCapture.hasPermission

    private var meterTimer: Timer?
    private var runner: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        try? FileManager.default.createDirectory(at: settings.notesFolder, withIntermediateDirectories: true)
        reload()
        if phase == .ready {
            // Finish meetings that were recorded but not processed (app quit / crashed meanwhile).
            for m in meetings where m.needsProcessing { enqueue(.process(m.id)) }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Make sure the recording files are finalized if the app is quit mid-meeting.
            let sem = DispatchSemaphore(value: 0)
            let rec = activeRecorder
            Task.detached { await rec?.stop(); sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
        try? FileManager.default.createDirectory(at: settings.notesFolder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        meetings = Meeting.loadAll(in: settings.notesFolder)
    }

    func meeting(_ id: Meeting.ID) -> Meeting? { meetings.first { $0.id == id } }

    func refreshPermissions() {
        micPermission = MicCapture.permission
        screenPermission = SystemAudioCapture.hasPermission
    }

    // MARK: - Setup

    func runSetup() {
        guard phase != .settingUp else { return }
        phase = .settingUp
        setupError = nil
        setupProgress = nil
        Task {
            setupStatus = "Installing the engine (Python + packages)…"
            let sync = await Engine.run(Engine.uv, ["sync", "--frozen", "--no-install-project", "--project", Engine.engineSource.path]) { _ in }
            guard sync.ok else { return failSetup("Couldn't install the engine.\n\(sync.errorTail)") }

            Engine.writeConfig(settings)
            let setup = await Engine.meetscribe(["setup"]) { [weak self] line in
                guard let self else { return }
                if line.hasPrefix("@@progress "), let v = Double(line.dropFirst(11)) {
                    self.setupProgress = v
                } else if line.hasPrefix("→ ") {
                    self.setupStatus = String(line.dropFirst(2))
                }
            }
            guard setup.ok else { return failSetup("Download failed.\n\(setup.errorTail)") }
            Engine.markInstalled()
            phase = .ready
            setupStatus = ""
            if micPermission == .notDetermined {
                _ = await MicCapture.requestPermission()
                refreshPermissions()
            }
        }
    }

    private func failSetup(_ message: String) {
        setupError = message
        phase = .needsSetup
    }

    // MARK: - Recording

    var isRecording: Bool { recorder != nil }

    func startRecording(title: String) {
        guard recorder == nil, !isStarting else { return }
        isStarting = true
        startError = nil
        notices = []
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let folder = settings.notesFolder.appendingPathComponent(stamp.string(from: Date()))
        let rec = MeetingRecorder(folder: folder)
        rec.onNotice = { [weak self] note in
            DispatchQueue.main.async { self?.notices.append(note) }
        }
        Task {
            do {
                try await rec.start(appName: settings.teamsOnly ? "Microsoft Teams" : nil)
                writeInfo(folder, MeetingInfo(title: title.trimmingCharacters(in: .whitespaces),
                                              started: ISO8601DateFormatter.local.string(from: Date()), duration: nil))
                recorder = rec
                activeRecorder = rec
                recordingID = folder.lastPathComponent
                startMeters()
                reload()
            } catch {
                startError = error.localizedDescription
                try? FileManager.default.removeItem(at: folder)
            }
            isStarting = false
            refreshPermissions()
        }
    }

    func stopRecording(discard: Bool = false) {
        guard let rec = recorder else { return }
        recorder = nil
        activeRecorder = nil
        meterTimer?.invalidate()
        let id = rec.folder.lastPathComponent
        let duration = rec.elapsed
        Task {
            await rec.stop()
            recordingID = nil
            if discard {
                try? FileManager.default.trashItem(at: rec.folder, resultingItemURL: nil)
            } else {
                if var info = readInfo(rec.folder) {
                    info.duration = duration
                    writeInfo(rec.folder, info)
                }
                enqueue(.process(id))
            }
            reload()
        }
    }

    private func startMeters() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.tickMeters() }
        }
    }

    private func tickMeters() {
        guard let rec = recorder else { return }
        elapsed = rec.elapsed
        // Smooth the meters so they don't flicker.
        micLevel = max(rec.mic?.writer.takePeak() ?? 0, micLevel * 0.6)
        systemLevel = max(rec.system?.writer.takePeak() ?? 0, systemLevel * 0.6)
    }

    private func readInfo(_ folder: URL) -> MeetingInfo? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
        return try? JSONDecoder().decode(MeetingInfo.self, from: data)
    }

    private func writeInfo(_ folder: URL, _ info: MeetingInfo) {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(info).write(to: folder.appendingPathComponent("meeting.json"))
    }

    // MARK: - Processing queue

    func enqueue(_ job: Job) {
        guard currentJob != job, !queue.contains(job) else { return }
        if case .process(let id) = job, let m = meeting(id) {
            try? FileManager.default.removeItem(at: m.url("error.txt"))
        }
        queue.append(job)
        runNext()
    }

    func isBusy(_ id: Meeting.ID) -> Bool {
        func matches(_ job: Job?) -> Bool {
            switch job {
            case .process(let j), .rename(let j, _), .resummarize(let j): return j == id
            default: return false
            }
        }
        return matches(currentJob) || queue.contains(where: matches)
    }

    private func runNext() {
        guard currentJob == nil, phase == .ready, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        currentJob = job
        jobStatus = "Starting…"
        Engine.writeConfig(settings)

        runner = Task {
            let (args, folder) = arguments(for: job)
            let result = await Engine.meetscribe(args) { [weak self] line in
                if line.hasPrefix("→ ") { self?.jobStatus = String(line.dropFirst(2)) }
            }
            if let folder {
                if result.ok {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("error.txt"))
                    if !settings.keepAudio, case .process = job {
                        for f in ["mic.caf", "system.caf"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
                    }
                } else if !Task.isCancelled {
                    let msg = result.errorTail.isEmpty ? "Processing failed." : result.errorTail
                    try? msg.write(to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
                }
            }
            reload()
            notify(job: job, ok: result.ok, folder: folder)
            currentJob = nil
            jobStatus = ""
            runNext()
        }
    }

    private func arguments(for job: Job) -> ([String], URL?) {
        let root = settings.notesFolder
        switch job {
        case .process(let id):
            let folder = root.appendingPathComponent(id)
            let title = readInfo(folder)?.title ?? ""
            return (["process", folder.path] + (title.isEmpty ? [] : ["--title", title]), folder)
        case .processFile(let url):
            return (["process", url.path], nil)
        case .rename(let id, let mapping):
            let folder = root.appendingPathComponent(id)
            return (["rename", folder.path] + mapping.map { "\($0.key)=\($0.value)" }, folder)
        case .resummarize(let id):
            let folder = root.appendingPathComponent(id)
            return (["summarize", folder.path], folder)
        }
    }

    private func notify(job: Job, ok: Bool, folder: URL?) {
        let content = UNMutableNotificationContent()
        let title = folder.flatMap { f in meetings.first { $0.folder == f }?.title } ?? "Meeting"
        if ok {
            content.title = "Notes ready"
            content.body = "\(title) — click the MeetScribe icon in the menu bar."
        } else {
            content.title = "Couldn't process the meeting"
            content.body = title
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Meeting actions

    func toggleDone(_ id: Meeting.ID, _ index: Int) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        if meetings[i].done.contains(index) { meetings[i].done.remove(index) } else { meetings[i].done.insert(index) }
        try? JSONEncoder().encode(Array(meetings[i].done).sorted()).write(to: meetings[i].url("todo.json"))
    }

    func delete(_ id: Meeting.ID) {
        guard let m = meeting(id) else { return }
        try? FileManager.default.trashItem(at: m.folder, resultingItemURL: nil)
        reload()
    }

    func copyNotes(_ id: Meeting.ID) {
        guard let m = meeting(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.shareText, forType: .string)
    }

    func chooseAudioFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Choose a meeting recording to transcribe"
        if panel.runModal() == .OK, let url = panel.url { enqueue(.processFile(url)) }
    }

    func chooseNotesFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.notesFolder
        if panel.runModal() == .OK, let url = panel.url { settings.notesFolderPath = url.path }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

/// The recording in progress, reachable from the quit handler (outside the main actor).
private var activeRecorder: MeetingRecorder?

extension ISO8601DateFormatter {
    /// Local time without zone, e.g. 2026-10-21T14:30:00 (what the engine expects).
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = .current
        return f
    }()
}
