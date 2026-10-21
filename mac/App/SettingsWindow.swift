import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, notes, models, notifications, privacy, voices, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .recording: return "Recording"
        case .notes: return "Notes"
        case .models: return "AI models"
        case .notifications: return "Notifications"
        case .privacy: return "Privacy and storage"
        case .voices: return "Voices"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "person.crop.circle"
        case .recording: return "mic"
        case .notes: return "doc.text"
        case .models: return "cpu"
        case .notifications: return "bell"
        case .privacy: return "lock"
        case .voices: return "person.wave.2"
        case .about: return "info.circle"
        }
    }
}

/// Real windows (Settings, a meeting) for a menu bar app: plain NSWindows hosting SwiftUI, so
/// nothing opens by itself at launch and the model can open them (e.g. from a notification).
@MainActor
enum Windows {
    private static var settings: NSWindow?
    private static var meetings: [String: NSWindow] = [:]

    static func showSettings(_ model: AppModel, tab: SettingsTab? = nil) {
        if let tab { model.settingsTab = tab }
        if settings == nil {
            settings = make(title: "MeetScribe Settings", size: NSSize(width: 720, height: 520),
                            view: SettingsWindow().environmentObject(model), autosave: "Settings")
        }
        present(settings!)
    }

    static func showMeeting(_ id: Meeting.ID, model: AppModel) {
        if meetings[id] == nil {
            let title = model.meeting(id)?.title ?? "Meeting"
            meetings[id] = make(title: title, size: NSSize(width: 560, height: 680),
                                view: MeetingWindow(id: id).environmentObject(model), autosave: nil)
        }
        present(meetings[id]!)
    }

    private static var others: [String: NSWindow] = [:]

    /// Before a meeting: its brief in a small window (from the notification).
    static func showBrief(_ event: CalendarEvent, model: AppModel) {
        let key = "brief-\(event.id ?? event.title)"
        if others[key] == nil {
            others[key] = make(title: event.title, size: NSSize(width: 420, height: 520),
                               view: BriefWindow(event: event).environmentObject(model), autosave: nil)
        }
        present(others[key]!)
    }

    /// The menu bar content in a normal window (testing / screenshots: `--preview`).
    static func showPreview(_ model: AppModel) {
        if others["preview"] == nil {
            others["preview"] = make(title: "MeetScribe", size: NSSize(width: 380, height: 580),
                                     view: RootView().environmentObject(model), autosave: nil)
        }
        present(others["preview"]!)
    }

    private static func make<V: View>(title: String, size: NSSize, view: V, autosave: String?) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        if let autosave { w.setFrameAutosaveName(autosave) }
        return w
    }

    private static func present(_ w: NSWindow) {
        // Opened from the menu bar window? Close it, so it doesn't linger behind the new window.
        let managed = [settings].compactMap { $0 } + Array(meetings.values) + Array(others.values)
        if let key = NSApp.keyWindow, !managed.contains(where: { $0 === key }) { key.close() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// A meeting in its own resizable window (same content as the menu bar view).
struct MeetingWindow: View {
    var id: Meeting.ID
    @State private var route: Route = .home

    var body: some View {
        Group {
            switch route {
            case .speakers(let sid): SpeakersView(id: sid, route: $route)
            default: MeetingView(id: id, route: $route, inWindow: true)
            }
        }
        .frame(minWidth: 460, minHeight: 480)
    }
}

struct BriefWindow: View {
    var event: CalendarEvent
    @State private var route: Route = .home

    var body: some View {
        Group {
            switch route {
            case .meeting(let id): MeetingView(id: id, route: $route)
            default: BriefView(event: event, route: $route)
            }
        }
        .frame(minWidth: 380, minHeight: 440)
    }
}

struct SettingsWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding<SettingsTab?>(
                get: { model.settingsTab }, set: { if let t = $0 { model.settingsTab = t } })) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Form { pane }
                .formStyle(.grouped)
                .navigationTitle(model.settingsTab.title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder var pane: some View {
        switch model.settingsTab {
        case .general: GeneralPane()
        case .recording: RecordingPane()
        case .notes: NotesPane()
        case .models: ModelsPane()
        case .notifications: NotificationsSection()
        case .privacy:
            StorageSection()
            RetentionSection()
            EnginePane()
        case .voices: VoicesSection()
        case .about: AboutPane()
        }
    }
}

struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("You") {
            TextField("Your name", text: $model.settings.myName)
            Caption("Used for your voice in transcripts and to find the to-dos that are yours.")
        }
        Section("Shortcut and startup") {
            LabeledContent("Start / stop recording") { HotkeyField(hotkey: $model.settings.hotkey) }
            Toggle("Open MeetScribe at login", isOn: $model.launchAtLogin)
        }
        EmailSection()
    }
}

struct RecordingPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Audio") {
            Picker("Record", selection: $model.settings.teamsOnly) {
                Text("All Mac audio").tag(false)
                Text("Microsoft Teams only").tag(true)
            }
            Toggle("Record calls automatically", isOn: $model.settings.autoRecord)
            Caption("Starts when Teams, Zoom or a browser call uses the microphone, and stops when the call ends.")
        }
        Section("Calendar") { CalendarRow() }
        Section("Languages") {
            LanguagesSection()
            TextField("Names and jargon", text: $model.settings.vocabulary, prompt: Text("Acme, Kubernetes, Zora"))
            Caption("Comma-separated. Helps spell product names, acronyms and colleagues' names.")
        }
    }
}

struct NotesPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Notes") {
            Picker("Usual meeting type", selection: $model.settings.defaultTemplate) {
                ForEach(meetingTemplates, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Detail", selection: $model.settings.summaryStyle) {
                ForEach(SummaryStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Caption(model.settings.summaryStyle.help)
            Picker("Language", selection: $model.settings.notesLanguage) {
                Text("Same as the meeting").tag("auto")
                ForEach(meetingLanguages, id: \.code) { Text($0.name).tag($0.name) }
            }
            Caption("Applies to new meetings. To redo one: open it → ⋯ → Regenerate notes.")
        }
    }
}

struct ModelsPane: View {
    @EnvironmentObject var model: AppModel
    private let hw = Hardware.current

    var body: some View {
        Section {
            LabeledContent("This Mac", value: hw.summary)
        } footer: {
            Caption("Models run on this Mac only. Recommendations come from a list of models tested with MeetScribe (updated \(model.catalog.updated.isEmpty ? "—" : model.catalog.updated)).")
        }
        if let d = model.modelDownload {
            Section("Downloading") {
                if let p = d.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                Caption(d.status)
            }
        }
        Section("Notes model") {
            ForEach(model.catalog.notes) { m in modelRow(m, speech: false) }
        }
        Section("Speech model") {
            ForEach(model.catalog.speech) { m in modelRow(m, speech: true) }
        }
        let listed = Set((model.catalog.notes + model.catalog.speech).map(\.repo))
        let unused = model.installedModels.filter { repo, _ in
            repo != model.notesModel && repo != model.speechModel && repo.hasPrefix("mlx-community/") && !listed.contains(repo)
        }
        if !unused.isEmpty {
            Section("Downloaded, not in use") {
                ForEach(unused.sorted(by: { $0.key < $1.key }), id: \.key) { repo, gb in
                    LabeledContent(repo.components(separatedBy: "/").last ?? repo) {
                        Button("Delete (\(String(format: "%.1f", gb)) GB)") { model.deleteModel(repo) }
                    }
                }
            }
        }
    }

    func modelRow(_ m: CatalogModel, speech: Bool) -> some View {
        let inUse = (speech ? model.speechModel : model.notesModel) == m.repo
        let recommended = ModelCatalog.recommended(speech ? model.catalog.speech : model.catalog.notes, for: hw)?.repo == m.repo
        let fits = m.fits(hw)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.name)
                    if recommended { Tag(text: "Recommended", color: .accentColor) }
                    if inUse { Tag(text: "In use", color: .green) }
                }
                Caption("\(String(format: "%.1f", m.sizeGB)) GB · \(m.description)"
                        + (fits ? "" : " · needs \(m.minRamGB) GB memory"))
            }
            Spacer()
            if !inUse {
                let installed = model.installedModels[m.repo] != nil
                VStack(alignment: .trailing, spacing: 4) {
                    Button(installed ? "Use" : "Download and use") { model.useModel(m, speech: speech) }
                        .disabled(model.modelDownload != nil || !fits)
                    if installed {
                        Button("Delete") { model.deleteModel(m.repo) }
                            .buttonStyle(.borderless).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct Tag: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct EnginePane: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReinstall = false

    var body: some View {
        Section("Engine") {
            LabeledContent("Location") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Engine.support]) }
            }
            LabeledContent("Log") {
                Button("Open") { openFile(Engine.support.appendingPathComponent("engine.log")) }
            }
            LabeledContent("Reinstall") {
                Button("Reinstall engine…") { confirmReinstall = true }
                    .disabled(model.phase == .settingUp || model.currentJob != nil)
            }
            .confirmationDialog("Reinstall the engine? Downloaded models are kept.", isPresented: $confirmReinstall) {
                Button("Reinstall") { model.runSetup() }
            }
        }
    }
}

struct AboutPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater: Updater

    init() { _updater = ObservedObject(wrappedValue: AppModelHolder.updater) }

    var body: some View {
        Section {
            LabeledContent("Version", value: Engine.appVersion)
            if let info = updater.available {
                LabeledContent("Update available") {
                    Button("Install \(info.version) and restart") { updater.install() }
                        .disabled(model.isRecording || model.currentJob != nil || updater.state == .downloading)
                }
                if let notes = info.notes, !notes.isEmpty { Caption(notes) }
                if model.isRecording || model.currentJob != nil { Caption("Available once nothing is recording or processing.") }
            } else {
                LabeledContent("Updates") {
                    Button(updater.state == .checking ? "Checking…" : "Check now") { Task { await updater.check() } }
                }
                if let d = updater.lastChecked { Caption("Up to date · checked \(d.formatted(date: .omitted, time: .shortened))") }
            }
            switch updater.state {
            case .downloading: ProgressView("Downloading the update…").progressViewStyle(.linear)
            case .installing: Caption("Installing — MeetScribe will restart.")
            case .failed(let msg): Text(msg).font(.caption).foregroundColor(.red)
            default: EmptyView()
            }
            if let page = Releases.pageURL { Link("Release notes", destination: page) }
        }
        Section("Credits") {
            Caption("Speech: OpenAI Whisper (MIT), via MLX. Notes: Qwen (Apache 2.0), via MLX. Speaker separation: pyannote segmentation (MIT) and NVIDIA TitaNet (CC BY 4.0), via sherpa-onnx.")
        }
    }
}

/// Lets views reach the shared updater without threading it through every initializer.
@MainActor
enum AppModelHolder {
    static var updater = Updater()
}
