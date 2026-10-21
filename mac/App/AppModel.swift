import AppKit
import AVFoundation
import Foundation
import ServiceManagement
import UserNotifications

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
    @Published var movingStatus: String?

    // Calendar, voices, messages
    @Published var currentEvent: CalendarEvent?
    @Published var recordingEvent: CalendarEvent?
    @Published var voices: [(name: String, samples: Int)] = []
    @Published var toast: String?
    private var endReminderSent = false
    let callMonitor = CallMonitor()

    // Permissions
    @Published var micPermission = MicCapture.permission
    @Published var screenPermission = SystemAudioCapture.hasPermission

    /// Recordings live here until processed, then move to the notes folder — so a synced
    /// folder (OneDrive…) only ever receives finished meetings, never half-written audio.
    static let workDir: URL = {
        let url = Engine.support.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var meterTimer: Timer?
    private var runner: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        reload()
        if phase == .needsSetup && FileManager.default.fileExists(atPath: Engine.python.path) {
            runSetup() // app was updated: refresh the engine quietly (models are already downloaded)
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "CALL", actions: [
                UNNotificationAction(identifier: "RECORD", title: "Record", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ENDED", actions: [
                UNNotificationAction(identifier: "STOP", title: "Stop & create notes", options: []),
            ], intentIdentifiers: []),
        ])
        callMonitor.isPaused = { activeRecorder != nil }
        callMonitor.onCallStarted = { [weak self] app in
            Task { @MainActor in self?.offerToRecord(app: app) }
        }
        callMonitor.start()
        refreshCalendar()
        if phase == .ready { askForScreenAudioIfNeeded() }
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
        reload()
    }

    private var reloadGeneration = 0
    private var resumedUnprocessed = false

    /// Rescans the meeting folders in the background. (Reading ~/Documents can make macOS ask
    /// for permission, which blocks the caller until answered — never do that on the main thread.)
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let roots = [Self.workDir, settings.notesFolder]
        Task.detached(priority: .userInitiated) { [weak self] in
            try? FileManager.default.createDirectory(at: roots[1], withIntermediateDirectories: true)
            let all = roots.flatMap { Meeting.loadAll(in: $0) }.sorted { $0.date > $1.date }
            await self?.applyReload(all, generation)
        }
    }

    private func applyReload(_ all: [Meeting], _ generation: Int) {
        guard generation == reloadGeneration else { return }
        meetings = all
        resumeUnprocessed()
    }

    /// Finish meetings that were recorded but never processed (app quit or crashed meanwhile).
    private func resumeUnprocessed() {
        guard phase == .ready, !resumedUnprocessed else { return }
        resumedUnprocessed = true
        for m in meetings where m.needsProcessing && m.id != recordingID { enqueue(.process(m.id)) }
    }

    func meeting(_ id: Meeting.ID) -> Meeting? { meetings.first { $0.id == id } }

    /// Shows macOS's "record screen & system audio" request (and adds MeetScribe to the list in
    /// System Settings) without waiting for the first recording to fail.
    private func askForScreenAudioIfNeeded() {
        guard !SystemAudioCapture.hasPermission else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = CGRequestScreenCaptureAccess() }
    }

    /// macOS applies a new Screen & System Audio permission only to a fresh launch.
    func restartApp() {
        let url = Bundle.main.bundleURL
        let rec = recorder
        Task {
            await rec?.stop()
            // Relaunch shortly after we quit (the new instance would otherwise see us running).
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    func refreshPermissions() {
        micPermission = MicCapture.permission
        screenPermission = SystemAudioCapture.hasPermission
    }

    // MARK: - Setup

    func runSetup() {
        guard phase != .settingUp else { return }
        Engine.log("setup \(Engine.appVersion) (installed: \(Engine.isInstalled))")
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
            resumedUnprocessed = false
            resumeUnprocessed()
            askForScreenAudioIfNeeded()
            if micPermission == .notDetermined {
                _ = await MicCapture.requestPermission()
                refreshPermissions()
            }
            if settings.useCalendar && CalendarService.shared.eventsUndecided {
                _ = await CalendarService.shared.requestEvents()
                refreshCalendar()
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
        let folder = Self.workDir.appendingPathComponent(stamp.string(from: Date()))
        let rec = MeetingRecorder(folder: folder)
        rec.onNotice = { [weak self] note in
            DispatchQueue.main.async { self?.notices.append(note) }
        }
        let event = settings.useCalendar ? CalendarService.shared.currentMeeting() : nil
        var name = title.trimmingCharacters(in: .whitespaces)
        if name.isEmpty, let event { name = event.title }
        Task {
            do {
                try await rec.start(appName: settings.teamsOnly ? "Microsoft Teams" : nil)
                writeInfo(folder, MeetingInfo(title: name, started: ISO8601DateFormatter.local.string(from: Date()),
                                              duration: nil, calendar: event))
                recordingEvent = event
                endReminderSent = false
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
            recordingEvent = nil
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
        // The calendar says the meeting ended 5 minutes ago: offer to stop.
        if let end = recordingEvent?.end, !endReminderSent, Date() > end.addingTimeInterval(300) {
            endReminderSent = true
            notify(title: "Is “\(recordingEvent?.title ?? "the meeting")” over?",
                   body: "MeetScribe is still recording.", category: "ENDED")
        }
        // Smooth the meters so they don't flicker.
        micLevel = max(rec.mic?.writer.takePeak() ?? 0, micLevel * 0.6)
        systemLevel = max(rec.system?.writer.takePeak() ?? 0, systemLevel * 0.6)
    }

    private func readInfo(_ folder: URL) -> MeetingInfo? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
        return try? JSONDecoder.meetscribe.decode(MeetingInfo.self, from: data)
    }

    private func writeInfo(_ folder: URL, _ info: MeetingInfo) {
        try? JSONEncoder.meetscribe.encode(info).write(to: folder.appendingPathComponent("meeting.json"))
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
            var finalFolder = folder
            if let folder {
                if result.ok {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("error.txt"))
                    if case .process = job {
                        if !settings.keepAudio {
                            for f in ["mic.caf", "system.caf"] { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
                        }
                        finalFolder = await moveToNotesFolder(folder)
                    }
                } else if !Task.isCancelled {
                    let msg = result.errorTail.isEmpty ? "Processing failed." : result.errorTail
                    try? msg.write(to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
                }
            }
            reload()
            notify(job: job, ok: result.ok, folder: finalFolder)
            currentJob = nil
            jobStatus = ""
            runNext()
        }
    }

    private func arguments(for job: Job) -> ([String], URL?) {
        func folder(_ id: Meeting.ID) -> URL {
            if let m = meeting(id) { return m.folder }
            let work = Self.workDir.appendingPathComponent(id)
            return FileManager.default.fileExists(atPath: work.path) ? work : settings.notesFolder.appendingPathComponent(id)
        }
        switch job {
        case .process(let id):
            let f = folder(id)
            let title = readInfo(f)?.title ?? ""
            return (["process", f.path] + (title.isEmpty ? [] : ["--title", title]), f)
        case .processFile(let url):
            return (["process", url.path], nil)
        case .rename(let id, let mapping):
            return (["rename", folder(id).path] + mapping.map { "\($0.key)=\($0.value)" }, folder(id))
        case .resummarize(let id):
            return (["summarize", folder(id).path], folder(id))
        }
    }

    /// A processed recording leaves the working folder for the (possibly synced) notes folder.
    /// Returns where the meeting ended up.
    private func moveToNotesFolder(_ folder: URL) async -> URL {
        guard folder.deletingLastPathComponent().standardizedFileURL == Self.workDir.standardizedFileURL else { return folder }
        let dest = settings.notesFolder.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        return await Task.detached { () -> URL in
            let fm = FileManager.default
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path), (try? fm.moveItem(at: folder, to: dest)) != nil { return dest }
            return folder
        }.value
    }

    // MARK: - Storage

    var canChangeStorage: Bool { recorder == nil && currentJob == nil && queue.isEmpty && movingStatus == nil }

    /// Number of finished meetings in the current notes folder.
    var meetingsInNotesFolder: Int { Meeting.loadAll(in: settings.notesFolder).count }

    /// Switches where notes are kept, optionally moving the existing meetings there.
    func changeStorage(to new: AppSettings, moveExisting: Bool) {
        let from = settings.notesFolder
        let to = new.notesFolder
        guard from.standardizedFileURL != to.standardizedFileURL else { settings = new; return }
        guard moveExisting else { settings = new; return }
        let folders = Meeting.loadAll(in: from).map(\.folder)
        movingStatus = "Moving \(folders.count) meeting(s)…"
        Task {
            let failed = await Task.detached { () -> Int in
                let fm = FileManager.default
                try? fm.createDirectory(at: to, withIntermediateDirectories: true)
                var failed = 0
                for f in folders {
                    let dest = to.appendingPathComponent(f.lastPathComponent)
                    if fm.fileExists(atPath: dest.path) { failed += 1; continue }
                    do { try fm.moveItem(at: f, to: dest) } catch { failed += 1 }
                }
                // Remove the old folder if nothing else is left in it.
                if let rest = try? fm.contentsOfDirectory(atPath: from.path), rest.allSatisfy({ $0.hasPrefix(".") }) {
                    try? fm.removeItem(at: from)
                }
                return failed
            }.value
            settings = new
            movingStatus = failed > 0 ? "\(failed) meeting(s) couldn't be moved — they're still in \(from.path)." : nil
        }
    }

    private func notify(job: Job, ok: Bool, folder: URL?) {
        let content = UNMutableNotificationContent()
        let title = folder.flatMap { Meeting.load($0)?.title } ?? "Meeting"
        if ok {
            content.title = "Notes ready"
            content.body = "\(title) — click the MeetScribe icon in the menu bar."
        } else {
            content.title = "Couldn't process the meeting"
            content.body = title
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Calendar, notifications

    func refreshCalendar() {
        currentEvent = settings.useCalendar ? CalendarService.shared.currentMeeting() : nil
    }

    func allowCalendar() {
        Task {
            if CalendarService.shared.eventsUndecided {
                _ = await CalendarService.shared.requestEvents()
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
            refreshCalendar()
            objectWillChange.send()
        }
    }

    private func offerToRecord(app: String) {
        guard settings.callReminders, phase == .ready, recorder == nil else { return }
        let event = settings.useCalendar ? CalendarService.shared.currentMeeting() : nil
        notify(title: event.map { "Record “\($0.title)”?" } ?? "Record this call?",
               body: "\(app) is using the microphone. Click Record to take notes with MeetScribe.", category: "CALL")
    }

    func notify(title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Buttons on our notifications.
    func handleNotificationAction(_ id: String) {
        switch id {
        case "RECORD": startRecording(title: "")
        case "STOP": stopRecording()
        default: break
        }
    }

    // MARK: - To-dos

    struct TodoRef: Identifiable {
        var meeting: Meeting
        var index: Int
        var item: ActionItem
        var id: String { "\(meeting.id)#\(index)" }
        var done: Bool { meeting.done.contains(index) }
    }

    func isMine(_ owner: String) -> Bool {
        let o = owner.lowercased().trimmingCharacters(in: .whitespaces)
        let me = settings.myName.lowercased().trimmingCharacters(in: .whitespaces)
        if o == "me" || o == "moi" { return true }
        guard !me.isEmpty, !o.isEmpty else { return false }
        let first = me.components(separatedBy: " ").first ?? me
        return o == me || o.contains(me) || o.components(separatedBy: CharacterSet(charactersIn: " ,&/")).contains(first)
    }

    func todos(mineOnly: Bool) -> [TodoRef] {
        meetings.flatMap { m in
            (m.notes?.actions ?? []).enumerated().compactMap { i, a in
                mineOnly && !isMine(a.owner) ? nil : TodoRef(meeting: m, index: i, item: a)
            }
        }
    }

    var myOpenTodoCount: Int { todos(mineOnly: true).filter { !$0.done }.count }

    // MARK: - Sharing

    /// Opens an email draft (Outlook if installed) to the calendar attendees with the notes.
    func emailNotes(_ id: Meeting.ID) {
        guard let m = meeting(id) else { return }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = (m.info?.calendar?.attendees ?? []).map(\.email).filter { !$0.isEmpty }.joined(separator: ",")
        c.queryItems = [URLQueryItem(name: "subject", value: "Notes: \(m.title)"),
                        URLQueryItem(name: "body", value: m.shareText)]
        guard let url = c.url else { return }
        if let outlook = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") {
            NSWorkspace.shared.open([url], withApplicationAt: outlook, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func addToReminders(_ id: Meeting.ID, mineOnly: Bool) {
        guard let m = meeting(id), let actions = m.notes?.actions else { return }
        let items = actions.enumerated().filter { !m.done.contains($0.offset) && (!mineOnly || isMine($0.element.owner)) }.map(\.element)
        guard !items.isEmpty else { show(mineOnly ? "No open to-dos for you in this meeting." : "No open to-dos."); return }
        Task {
            if let n = await CalendarService.shared.addReminders(items, meetingTitle: m.title) {
                show("Added \(n) to-do\(n == 1 ? "" : "s") to Reminders.")
            } else {
                show("Reminders access is off — allow it in System Settings → Privacy & Security → Reminders.")
            }
        }
    }

    func show(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: - Voice library

    private var voicesFile: URL { Engine.support.appendingPathComponent("voices.json") }

    func reloadVoices() {
        guard let data = try? Data(contentsOf: voicesFile),
              let lib = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]] else { voices = []; return }
        voices = lib.map { ($0.key, $0.value.count) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func forgetVoice(_ name: String) {
        guard let data = try? Data(contentsOf: voicesFile),
              var lib = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lib.removeValue(forKey: name)
        if let out = try? JSONSerialization.data(withJSONObject: lib) { try? out.write(to: voicesFile, options: .atomic) }
        reloadVoices()
    }

    // MARK: - Meeting actions

    func toggleDone(_ id: Meeting.ID, _ index: Int) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        if meetings[i].done.contains(index) { meetings[i].done.remove(index) } else { meetings[i].done.insert(index) }
        try? JSONEncoder().encode(Array(meetings[i].done).sorted()).write(to: meetings[i].url("todo.json"))
    }

    /// Removes one action item (e.g. a wrong one) from a meeting's to-do list.
    func deleteTodo(_ id: Meeting.ID, _ index: Int) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        let m = meetings[i]
        guard let data = try? Data(contentsOf: m.url("notes.json")),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var actions = json["actions"] as? [Any], index < actions.count else { return }
        actions.remove(at: index)
        json["actions"] = actions
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? out.write(to: m.url("notes.json"), options: .atomic)
        // Done flags after the removed item shift down by one.
        let done = Set(m.done.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        try? JSONEncoder().encode(Array(done).sorted()).write(to: m.url("todo.json"))
        if var notes = m.notes { notes.actions.remove(at: index); meetings[i].notes = notes }
        meetings[i].done = done
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

    func pickFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.directoryURL = settings.notesFolder
        return panel.runModal() == .OK ? panel.url : nil
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
