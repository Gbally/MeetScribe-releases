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
    case ask(String)

    var meetingID: Meeting.ID? {
        switch self {
        case .process(let id), .rename(let id, _), .resummarize(let id): return id
        case .processFile, .ask: return nil
        }
    }
}

struct AskResult: Decodable, Equatable {
    struct Source: Decodable, Equatable, Hashable {
        var n: Int
        var folder: String
        var title: String
        var date: String
        var time: Double?
    }
    var answer: String
    var sources: [Source]
}

/// What to remember before a calendar meeting: last time's notes and still-open to-dos.
struct Brief {
    var event: CalendarEvent
    var last: Meeting?
    var openTodos: [AppModel.TodoRef]
    var isEmpty: Bool { last == nil && openTodos.isEmpty }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case needsSetup, settingUp, ready }

    @Published var phase: Phase = Engine.isInstalled ? .ready : .needsSetup
    @Published var settings: AppSettings {
        didSet {
            saveSettings()
            if settings.hotkey != oldValue.hotkey { HotkeyCenter.shared.register(settings.hotkey) }
        }
    }
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
    @Published var jobProgress: Double?
    @Published var notificationProblem: String?
    @Published var jobStarted = Date()
    /// Set by a notification click: the window opens on this meeting.
    @Published var pendingRoute: Route?
    @Published var movingStatus: String?

    // Calendar, voices, messages
    @Published var currentEvent: CalendarEvent?
    @Published var recordingEvent: CalendarEvent?
    @Published var voices: [(name: String, samples: Int)] = []
    @Published var toast: String?
    @Published var nextEvent: CalendarEvent?     // happening now or within 30 min (for the brief card)
    @Published var todayEvents: [CalendarEvent] = []
    @Published var catalog = ModelCatalog.load()
    @Published var installedModels: [String: Double] = [:]   // repo → GB on disk
    @Published var modelDownload: (repo: String, progress: Double?, status: String)?
    @Published var settingsTab: SettingsTab = .general
    let updater = AppModelHolder.updater
    @Published var askQuestion = ""
    @Published var askResult: AskResult?
    @Published var askError: String?
    private var endReminderSent = false
    private var autoStarted = false
    private var briefed = Set<String>()
    private var briefTimer: Timer?
    private var lastCleanup = Date.distantPast
    private var reminderSignature = ""
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
        // Installs from before the catalog used Qwen3 8B + Whisper turbo: keep them (the catalog
        // may recommend something else, but never switches models by itself).
        if settings.llmModel == nil && FileManager.default.fileExists(atPath: Engine.python.path) {
            settings.llmModel = "mlx-community/Qwen3-8B-4bit"
            settings.whisperModel = settings.whisperModel ?? "mlx-community/whisper-large-v3-turbo"
        }
        reload()
        if phase == .needsSetup && FileManager.default.fileExists(atPath: Engine.python.path) {
            runSetup() // app was updated: refresh the engine quietly (models are already downloaded)
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "AUTO", actions: [
                UNNotificationAction(identifier: "STOP", title: "Stop & create notes", options: []),
                UNNotificationAction(identifier: "DISCARD", title: "Discard", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "CALL", actions: [
                UNNotificationAction(identifier: "RECORD", title: "Record", options: []),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ENDED", actions: [
                UNNotificationAction(identifier: "STOP", title: "Stop & create notes", options: []),
            ], intentIdentifiers: []),
        ])
        callMonitor.onCallStarted = { [weak self] app in
            Task { @MainActor in self?.callStarted(app: app) }
        }
        callMonitor.onCallEnded = { [weak self] in
            Task { @MainActor in self?.callEnded() }
        }
        callMonitor.start()
        HotkeyCenter.shared.action = { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        HotkeyCenter.shared.register(settings.hotkey)
        briefTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in
                model.refreshCalendar()
                model.checkBriefs()
                model.cleanUpOldAudio()
                await model.refreshCatalogDaily()
            }
        }
        refreshCalendar()
        if phase == .ready { askForScreenAudioIfNeeded() }
        updater.start()
        Task {
            if let c = await ModelCatalog.refresh() { catalog = c }
            loadInstalledModels()
        }
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
        upgradeOldNotes()
        scheduleDueReminders()
        cleanUpOldAudio()
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

            // Pick the models that fit this Mac, and keep them (a later catalog only recommends).
            if settings.llmModel == nil { settings.llmModel = ModelCatalog.recommended(catalog.notes, for: .current)?.repo }
            if settings.whisperModel == nil { settings.whisperModel = ModelCatalog.recommended(catalog.speech, for: .current)?.repo }
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

    func toggleRecording() {
        guard phase == .ready else { return }
        if isRecording { stopRecording() } else { startRecording(title: "") }
    }

    func startRecording(title: String, template: String? = nil, auto: Bool = false) {
        guard recorder == nil, !isStarting else { return }
        autoStarted = auto
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
                                              duration: nil, calendar: event, template: template ?? settings.defaultTemplate))
                if auto {
                    notify(title: "Recording “\(name.isEmpty ? "this call" : name)”",
                           body: "Started automatically — it stops by itself when the call ends.", category: "AUTO")
                }
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
                if auto { notify(title: "Couldn't start recording", body: error.localizedDescription) }
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
        autoStarted = false
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
        if settings.endReminders, let end = recordingEvent?.end, !endReminderSent, Date() > end.addingTimeInterval(300) {
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
        jobProgress = nil
        jobStarted = Date()
        Engine.writeConfig(settings)

        runner = Task {
            let (args, folder) = arguments(for: job)
            if case .ask = job { askResult = nil; askError = nil }
            let result = await Engine.meetscribe(args) { [weak self] line in
                if line.hasPrefix("@@result "), let data = line.dropFirst(9).data(using: .utf8) {
                    self?.askResult = try? JSONDecoder().decode(AskResult.self, from: data)
                } else if line.hasPrefix("→ ") {
                    self?.jobStatus = String(line.dropFirst(2))
                } else if line.hasPrefix("@@progress "), let v = Double(line.dropFirst(11)) {
                    self?.jobProgress = max(self?.jobProgress ?? 0, v)
                }
            }
            var finalFolder = folder
            if let folder {
                if result.ok {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("error.txt"))
                    if case .process = job {
                        if settings.audioRetentionDays == 0 { Self.deleteAudio(in: folder) }
                        finalFolder = await moveToNotesFolder(folder)
                    }
                } else if !Task.isCancelled {
                    let msg = result.errorTail.isEmpty ? "Processing failed." : result.errorTail
                    try? msg.write(to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
                }
            }
            reload()
            if case .ask = job {
                if !result.ok { askError = result.errorTail.isEmpty ? "Something went wrong." : result.errorTail }
            } else {
                notify(job: job, ok: result.ok, folder: finalFolder)
            }
            currentJob = nil
            jobStatus = ""
            jobProgress = nil
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
        case .ask(let question):
            return (["ask", "--json", question], nil)
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
        guard settings.notifyWhenReady else { return }
        let content = UNMutableNotificationContent()
        let title = folder.flatMap { Meeting.load($0)?.title } ?? "Meeting"
        content.sound = .default
        if let folder { content.userInfo = ["meeting": folder.lastPathComponent] }
        if ok {
            content.title = "Notes ready"
            content.body = "\(title) — click to see the summary and to-dos."
        } else {
            content.title = "Couldn't process the meeting"
            content.body = title
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Calendar, notifications

    func refreshCalendar() {
        currentEvent = settings.useCalendar ? CalendarService.shared.currentMeeting() : nil
        nextEvent = settings.useCalendar
            ? (currentEvent ?? CalendarService.shared.upcomingMeetings(within: 30).first) : nil
        todayEvents = settings.useCalendar ? CalendarService.shared.todayMeetings() : []
    }

    // MARK: - Today

    /// One line of the Today timeline: a calendar meeting and/or a recording.
    struct TodayItem: Identifiable {
        var id: String
        var time: Date
        var end: Date?
        var title: String
        var event: CalendarEvent?
        var meeting: Meeting?

        enum Phase { case done, now, later }
        var phase: Phase {
            if meeting != nil { return .done }
            let now = Date()
            if let end, time <= now.addingTimeInterval(300), end > now { return .now }
            return time > now ? .later : .done
        }
    }

    /// Today's calendar meetings, matched with what was recorded, plus unplanned recordings.
    var today: [TodayItem] {
        let cal = Calendar.current
        let recorded = meetings.filter { cal.isDateInToday($0.date) && $0.id != recordingID }
        var used = Set<String>()
        var items: [TodayItem] = todayEvents.map { e in
            let match = recorded.first { m in
                guard !used.contains(m.id), let c = m.info?.calendar else { return false }
                return (c.id != nil && c.id == e.id) || c.title == e.title
            }
            if let match { used.insert(match.id) }
            return TodayItem(id: e.id ?? "\(e.title)\(e.start)", time: e.start, end: e.end,
                             title: match?.title ?? e.title, event: e, meeting: match)
        }
        items += recorded.filter { !used.contains($0.id) }.map {
            TodayItem(id: $0.id, time: $0.date, end: nil, title: $0.title, event: nil, meeting: $0)
        }
        return items.sorted { $0.time < $1.time }
    }

    // MARK: - Briefs

    private var briefEvents: [String: CalendarEvent] = [:]

    /// Earlier meetings that were the same meeting: same recurring series, same title, or
    /// mostly the same people.
    func previousMeetings(for event: CalendarEvent) -> [Meeting] {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let emails = Set(event.attendees.map { $0.email.lowercased() }.filter { !$0.isEmpty })
        let generic: Set<String> = ["meeting", "call", "sync", "teams meeting", "réunion"]
        return meetings.filter { m in
            guard m.notes != nil, m.date < event.start.addingTimeInterval(-600) else { return false }
            guard let cal = m.info?.calendar else { return false }
            if let a = cal.seriesKey, let b = event.seriesKey, a == b { return true }
            if norm(cal.title) == norm(event.title), !generic.contains(norm(event.title)), event.title.count > 3 { return true }
            let theirs = Set(cal.attendees.map { $0.email.lowercased() }.filter { !$0.isEmpty })
            let shared = emails.intersection(theirs).count
            return shared >= 2 && Double(shared) >= 0.5 * Double(min(emails.count, theirs.count))
        }
    }

    func brief(for event: CalendarEvent) -> Brief {
        let previous = previousMeetings(for: event)
        let ids = Set(previous.map(\.id))
        let open = todos(mineOnly: false).filter { ids.contains($0.meeting.id) && !$0.done }
        return Brief(event: event, last: previous.first, openTodos: open)
    }

    /// ~5 minutes before a meeting that happened before: a notification with what's still open.
    private func checkBriefs() {
        guard settings.briefs, settings.useCalendar, phase == .ready else { return }
        for event in CalendarService.shared.upcomingMeetings(within: 6) {
            let key = event.id ?? "\(event.title)\(event.start)"
            guard !briefed.contains(key) else { continue }
            briefed.insert(key)
            let b = brief(for: event)
            guard !b.isEmpty else { continue }
            briefEvents[key] = event
            let minutes = max(1, Int(event.start.timeIntervalSinceNow / 60))
            var body = b.openTodos.isEmpty ? "No open to-dos from last time"
                : "\(b.openTodos.count) open to-do\(b.openTodos.count == 1 ? "" : "s") from last time"
            if let last = b.last { body += " (\(last.date.formatted(date: .abbreviated, time: .omitted)))" }
            let content = UNMutableNotificationContent()
            content.title = "In \(minutes) min: \(event.title)"
            content.body = body + ". Click to review."
            content.sound = .default
            content.userInfo = ["meeting": "brief:\(key)"]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brief-\(key)", content: content, trigger: nil))
        }
    }

    private var upgrading = false

    /// Notes made before due dates existed get them once (quick: no AI involved).
    private func upgradeOldNotes() {
        guard phase == .ready, !upgrading else { return }
        let old = meetings.filter { $0.notes != nil && ($0.notes?.version ?? 0) < 2 && !isBusy($0.id) }.map(\.folder)
        guard !old.isEmpty else { return }
        upgrading = true
        Task {
            for f in old { _ = await Engine.meetscribe(["render", f.path]) { _ in } }
            upgrading = false
            reload()
        }
    }

    // MARK: - Due-date reminders

    /// One notification per open to-do of mine: 9:00 the day before it's due (or 9:00 on the day).
    private func scheduleDueReminders() {
        let mine = settings.dueReminders ? todos(mineOnly: true).filter { !$0.done && $0.item.dueDay != nil } : []
        let cal = Calendar.current
        var planned: [(id: String, date: Date, title: String, body: String, meeting: String)] = []
        for ref in mine {
            guard let due = ref.item.dueDay else { continue }
            let dayBefore = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: due)!)!
            let onTheDay = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due)!
            let (when, label) = dayBefore > Date() ? (dayBefore, "Due tomorrow") : (onTheDay, "Due today")
            guard when > Date() else { continue }
            planned.append(("due-\(ref.id)", when, label, "\(ref.item.task) — from “\(ref.meeting.title)”", ref.meeting.id))
        }
        planned = Array(planned.sorted { $0.date < $1.date }.prefix(40))
        let signature = planned.map { "\($0.id)\($0.date)\($0.body)" }.joined()
        guard signature != reminderSignature else { return }
        reminderSignature = signature
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("due-") })
            for p in planned {
                let content = UNMutableNotificationContent()
                content.title = p.title
                content.body = p.body
                content.sound = .default
                content.userInfo = ["meeting": p.meeting]
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: p.date)
                center.add(UNNotificationRequest(identifier: p.id, content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
    }

    // MARK: - Audio retention

    nonisolated static func deleteAudio(in folder: URL) {
        let fm = FileManager.default
        for f in ["mic.caf", "system.caf", "clips", "clips.json"] { try? fm.removeItem(at: folder.appendingPathComponent(f)) }
    }

    /// Deletes recordings (and voice samples) of processed meetings older than the retention.
    private func cleanUpOldAudio() {
        let days = settings.audioRetentionDays
        guard days > 0, Date().timeIntervalSince(lastCleanup) > 3600 else { return }
        lastCleanup = Date()
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        let old = meetings.filter { $0.notes != nil && $0.date < limit && !isBusy($0.id) }.map(\.folder)
        Task.detached(priority: .background) {
            let fm = FileManager.default
            var cleaned = 0
            for f in old where ["mic.caf", "system.caf", "clips"].contains(where: { fm.fileExists(atPath: f.appendingPathComponent($0).path) }) {
                AppModel.deleteAudio(in: f)
                cleaned += 1
            }
            if cleaned > 0 { Engine.log("retention: deleted audio of \(cleaned) meeting(s) older than \(days) days") }
        }
    }

    // MARK: - AI models

    private var lastCatalogRefresh = Date()

    func refreshCatalogDaily() async {
        guard Date().timeIntervalSince(lastCatalogRefresh) > 24 * 3600 else { return }
        lastCatalogRefresh = Date()
        if let c = await ModelCatalog.refresh() { catalog = c }
    }

    var notesModel: String { settings.llmModel ?? ModelCatalog.recommended(catalog.notes, for: .current)?.repo ?? "" }
    var speechModel: String { settings.whisperModel ?? ModelCatalog.recommended(catalog.speech, for: .current)?.repo ?? "" }

    /// A better notes model than the one in use fits this Mac.
    var betterNotesModel: CatalogModel? {
        guard let best = ModelCatalog.recommended(catalog.notes, for: .current), best.repo != notesModel else { return nil }
        let current = catalog.notes.first { $0.repo == notesModel }
        return (current == nil || best.quality > current!.quality) ? best : nil
    }

    func loadInstalledModels() {
        guard phase == .ready else { return }
        Task {
            var found: [String: Double] = [:]
            _ = await Engine.meetscribe(["models", "list"]) { line in
                if line.hasPrefix("@@result "), let data = line.dropFirst(9).data(using: .utf8),
                   let dict = try? JSONDecoder().decode([String: Double].self, from: data) { found = dict }
            }
            installedModels = found
        }
    }

    /// Switch to a model, downloading it first if needed.
    func useModel(_ model: CatalogModel, speech: Bool) {
        let apply = { [weak self] in
            guard let self else { return }
            if speech { self.settings.whisperModel = model.repo } else { self.settings.llmModel = model.repo }
            Engine.writeConfig(self.settings)
        }
        if installedModels[model.repo] != nil { apply(); return }
        guard modelDownload == nil else { return }
        modelDownload = (model.repo, nil, "Starting download…")
        Task {
            let result = await Engine.meetscribe(["models", "download", model.repo]) { [weak self] line in
                guard let self, var d = self.modelDownload else { return }
                if line.hasPrefix("@@progress "), let v = Double(line.dropFirst(11)) { d.progress = v }
                else if line.hasPrefix("→ ") { d.status = String(line.dropFirst(2)) }
                self.modelDownload = d
            }
            modelDownload = nil
            if result.ok { apply() } else { show("Download failed: \(result.errorTail)") }
            loadInstalledModels()
        }
    }

    func deleteModel(_ repo: String) {
        guard repo != notesModel, repo != speechModel else { return }
        Task {
            _ = await Engine.meetscribe(["models", "delete", repo]) { _ in }
            loadInstalledModels()
        }
    }

    // MARK: - Ask

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, phase == .ready else { return }
        askQuestion = q
        askResult = nil
        askError = nil
        enqueue(.ask(q))
    }

    var isAsking: Bool {
        if case .ask = currentJob { return true }
        return queue.contains { if case .ask = $0 { return true } else { return false } }
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

    private func callStarted(app: String) {
        guard phase == .ready, recorder == nil else { return }
        if settings.autoRecord {
            startRecording(title: "", auto: true)
        } else {
            offerToRecord(app: app)
        }
    }

    /// The call app released the microphone for 45 s: an automatic recording stops by itself.
    private func callEnded() {
        guard isRecording, autoStarted else { return }
        stopRecording()
    }

    private func offerToRecord(app: String) {
        guard settings.callReminders else { return }
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

    /// Buttons on our notifications (and clicks on "Notes ready").
    func handleNotificationAction(_ id: String, meeting: String? = nil) {
        switch id {
        case "RECORD": startRecording(title: "")
        case "STOP": stopRecording()
        case "DISCARD": stopRecording(discard: true)
        default:
            if let meeting, meeting.hasPrefix("brief:") {
                if let e = briefEvents[String(meeting.dropFirst(6))] { Windows.showBrief(e, model: self) }
            } else if let meeting {
                Windows.showMeeting(meeting, model: self)
            }
        }
    }

    /// Why our notifications might not be seen (nil = they show normally), for Settings.
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            var problem: String?
            switch s.authorizationStatus {
            case .denied:
                problem = "Notifications are turned off for MeetScribe in macOS, so you won't see these."
            case .notDetermined:
                problem = "macOS hasn't asked for permission yet."
            default:
                if s.alertStyle == .none {
                    problem = "macOS only lists MeetScribe's notifications in Notification Center — no pop-up."
                }
            }
            DispatchQueue.main.async { self.notificationProblem = problem }
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    /// "About 3 min left", from the progress so far.
    var jobETA: String? {
        guard let p = jobProgress, p > 0.05, p < 0.999 else { return nil }
        let elapsed = Date().timeIntervalSince(jobStarted)
        let left = elapsed * (1 - p) / p
        if left < 50 { return "less than a minute left" }
        return "about \(Int((left / 60).rounded(.up))) min left"
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

    /// Opens an email draft to the calendar attendees with the notes, in the chosen app.
    func emailNotes(_ id: Meeting.ID) {
        guard let m = meeting(id) else { return }
        let to = (m.info?.calendar?.attendees ?? []).map(\.email).filter { !$0.isEmpty }.joined(separator: ",")
        let subject = "Notes: \(m.title)"
        let body = m.shareText
        let app = settings.emailApp

        func open(_ url: URL?, withApp bundleID: String? = nil) {
            // URLComponents leaves "+" as is, which web apps read as a space.
            guard var c = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return }
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = c.url else { return }
            if let bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        switch app {
        case .gmail:
            var c = URLComponents(string: "https://mail.google.com/mail/")!
            c.queryItems = [URLQueryItem(name: "view", value: "cm"), URLQueryItem(name: "fs", value: "1"),
                            URLQueryItem(name: "to", value: to), URLQueryItem(name: "su", value: subject),
                            URLQueryItem(name: "body", value: body)]
            let account = settings.gmailAccount.trimmingCharacters(in: .whitespaces)
            if !account.isEmpty { c.queryItems?.insert(URLQueryItem(name: "authuser", value: account), at: 0) }
            open(c.url, withApp: "com.google.Chrome") // falls back to the default browser
        case .outlookWeb:
            var c = URLComponents(string: "https://outlook.office.com/mail/deeplink/compose")!
            c.queryItems = [URLQueryItem(name: "to", value: to), URLQueryItem(name: "subject", value: subject),
                            URLQueryItem(name: "body", value: body)]
            open(c.url)
        case .systemDefault, .outlook, .appleMail:
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = to
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            let bundle = app == .outlook ? "com.microsoft.Outlook" : app == .appleMail ? "com.apple.mail" : nil
            if let bundle, NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil {
                show("\(app.label) isn't installed — using your default mail app.")
            }
            open(c.url, withApp: bundle)
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
        guard let m = meeting(id) else { return }
        editNotes(id) { json in
            guard var actions = json["actions"] as? [Any], index < actions.count else { return }
            actions.remove(at: index)
            json["actions"] = actions
        }
        // Done flags after the removed item shift down by one.
        let done = Set(m.done.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
        try? JSONEncoder().encode(Array(done).sorted()).write(to: m.url("todo.json"))
    }

    // MARK: - Editing notes

    /// Changes notes.json, then lets the engine rebuild notes.md and the due dates.
    func editNotes(_ id: Meeting.ID, _ change: (inout [String: Any]) -> Void) {
        guard let m = meeting(id), let data = try? Data(contentsOf: m.url("notes.json")),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        change(&json)
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? out.write(to: m.url("notes.json"), options: .atomic)
        let folder = m.folder
        reload()
        Task {
            _ = await Engine.meetscribe(["render", folder.path]) { _ in }
            reload()
        }
    }

    func updateTodo(_ id: Meeting.ID, _ index: Int, task: String, owner: String, due: String) {
        editNotes(id) { json in
            guard var actions = json["actions"] as? [[String: Any]], index < actions.count else { return }
            actions[index]["task"] = task
            actions[index]["owner"] = owner
            actions[index]["due"] = due
            json["actions"] = actions
        }
    }

    func addTodo(_ id: Meeting.ID, task: String, owner: String, due: String) {
        editNotes(id) { json in
            var actions = json["actions"] as? [[String: Any]] ?? []
            actions.append(["task": task, "owner": owner, "due": due])
            json["actions"] = actions
        }
    }

    func renameMeeting(_ id: Meeting.ID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let m = meeting(id) else { return }
        // Also in meeting.json, so regenerating the notes keeps the name.
        var info = readInfo(m.folder) ?? MeetingInfo(title: t, started: m.notes?.date ?? ISO8601DateFormatter.local.string(from: m.date))
        info.title = t
        writeInfo(m.folder, info)
        editNotes(id) { $0["title"] = t }
    }

    struct TodoDraft: Identifiable, Equatable {
        let id = UUID()
        var originalIndex: Int?   // nil = added by hand
        var task: String
        var owner: String
        var due: String
        var done: Bool
    }

    /// Saves the edit mode of a meeting at once: title + the whole to-do list.
    func saveEdits(_ id: Meeting.ID, title: String, todos: [TodoDraft]) {
        guard let m = meeting(id) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != m.title {
            var info = readInfo(m.folder) ?? MeetingInfo(title: t, started: m.notes?.date ?? ISO8601DateFormatter.local.string(from: m.date))
            info.title = t
            writeInfo(m.folder, info)
        }
        let kept = todos.filter { !$0.task.trimmingCharacters(in: .whitespaces).isEmpty }
        editNotes(id) { json in
            if !t.isEmpty { json["title"] = t }
            json["actions"] = kept.map { ["task": $0.task.trimmingCharacters(in: .whitespaces),
                                          "owner": $0.owner.trimmingCharacters(in: .whitespaces),
                                          "due": $0.due.trimmingCharacters(in: .whitespaces)] }
        }
        let done = kept.enumerated().filter { $0.element.done }.map(\.offset)
        try? JSONEncoder().encode(done).write(to: m.url("todo.json"))
    }

    /// Rewrite the notes as another meeting type (1:1, stand-up…).
    func regenerate(_ id: Meeting.ID, template: String) {
        guard let m = meeting(id) else { return }
        var info = readInfo(m.folder) ?? MeetingInfo(title: "", started: m.notes?.date ?? ISO8601DateFormatter.local.string(from: m.date))
        info.template = template
        writeInfo(m.folder, info)
        enqueue(.resummarize(id))
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
