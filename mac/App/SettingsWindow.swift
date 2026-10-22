import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, notes, models, notifications, privacy, voices, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return i18n("General")
        case .recording: return i18n("Recording")
        case .notes: return i18n("Notes")
        case .models: return i18n("AI models")
        case .notifications: return i18n("Notifications")
        case .privacy: return i18n("Privacy and storage")
        case .voices: return i18n("Voices")
        case .about: return i18n("About")
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
            let w = make(title: tr("MeetScribe Settings"), size: NSSize(width: 780, height: 540),
                         view: SettingsWindow().environmentObject(model), autosave: "Settings")
            // Closing it forgets temporary state (e.g. a custom model check); reopening starts fresh.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in Windows.settings = nil }
            }
            settings = w
        }
        present(settings!)
    }

    static func showMeeting(_ id: Meeting.ID, model: AppModel) {
        if meetings[id] == nil {
            let title = model.meeting(id)?.title ?? tr("Meeting")
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

    /// First launch: the guided setup. Closing it (any way) counts as done.
    static func showWelcome(_ model: AppModel, step: Int = 0) {
        if others["welcome"] == nil {
            let close: () -> Void = { Windows.others["welcome"]?.close() }
            let w = make(title: tr("Welcome to MeetScribe"), size: NSSize(width: 540, height: 600),
                         view: WelcomeView(close: close, step: step).environmentObject(model), autosave: nil)
            w.styleMask.remove(.resizable)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: "welcomeDone")
                    Windows.others["welcome"] = nil
                }
            }
            others["welcome"] = w
        }
        present(others["welcome"]!)
    }

    /// The menu bar content in a normal window (testing / screenshots: `--preview`).
    static func showPreview(_ model: AppModel) {
        if others["preview"] == nil {
            others["preview"] = make(title: "MeetScribe", size: NSSize(width: 380, height: 580),
                                     view: RootView().environmentObject(model), autosave: nil)
        }
        present(others["preview"]!)
    }

    /// Re-titles open windows; their content redraws by itself (keyed by model.uiLanguage).
    static func languageChanged(_ model: AppModel) {
        settings?.title = tr("MeetScribe Settings")
        others["welcome"]?.title = tr("Welcome to MeetScribe")
        for (id, w) in meetings { w.title = model.meeting(id)?.title ?? tr("Meeting") }
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
    @EnvironmentObject var model: AppModel
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
        .environment(\.locale, AppLanguage.locale)
        .id(model.uiLanguage)
    }
}

struct BriefWindow: View {
    @EnvironmentObject var model: AppModel
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
        .environment(\.locale, AppLanguage.locale)
        .id(model.uiLanguage)
    }
}

struct SettingsWindow: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var draft = CustomModelDraft()

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding<SettingsTab?>(
                get: { model.settingsTab }, set: { if let t = $0 { model.settingsTab = t } })) { tab in
                Label(tr(tab.title), systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(230)
        } detail: {
            Form { pane }
                .formStyle(.grouped)
                .navigationTitle(tr(model.settingsTab.title))
        }
        .frame(minWidth: 680, minHeight: 460)
        .environmentObject(draft)
        .environment(\.locale, AppLanguage.locale)
        .id(model.uiLanguage)
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
            UsageStatsSection()
            EnginePane()
            RemoveSection()
        case .voices: VoicesSection()
        case .about: AboutPane()
        }
    }
}

struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(tr(text)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    @State private var language = AppLanguage.forced

    var body: some View {
        Section("Language") {
            Picker("App language", selection: Binding(get: { language }, set: { language = $0; model.setLanguage($0) })) {
                Text(tr("Same as the Mac") + " (" + languageName(Locale.preferredLanguages.first ?? "en") + ")").tag("")
                ForEach(AppLanguage.supported, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
            }
            Caption("Other languages show in English. Meeting notes follow the meeting's language (Settings → Notes).")
        }
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
                ForEach(meetingTemplates, id: \.id) { Text(tr($0.name)).tag($0.id) }
            }
            Picker("Detail", selection: $model.settings.summaryStyle) {
                ForEach(SummaryStyle.allCases, id: \.self) { Text(tr($0.label)).tag($0) }
            }
            .pickerStyle(.segmented)
            Caption(model.settings.summaryStyle.help)
            Picker("Language", selection: $model.settings.notesLanguage) {
                Text("Same as the meeting").tag("auto")
                ForEach(meetingLanguages, id: \.code) { Text(languageName($0.code)).tag($0.name) }
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
            LabeledContent("This Mac", value: hw.localizedSummary)
        } footer: {
            Caption(tr("Models run on this Mac only. Recommendations come from a list of models tested with MeetScribe (updated %@).",
                       model.catalog.updated.isEmpty ? "—" : model.catalog.updated))
        }
        if let d = model.modelDownload {
            Section("Downloading") {
                if let p = d.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                Caption(d.status)
            }
        }
        Section("Notes model") {
            ForEach(model.catalog.notes) { m in modelRow(m, speech: false) }
            customInUse(speech: false)
        }
        Section("Speech model") {
            ForEach(model.catalog.speech) { m in modelRow(m, speech: true) }
            customInUse(speech: true)
        }
        CustomModelSection()
        let listed = Set((model.catalog.notes + model.catalog.speech).map(\.repo))
        let unused = model.installedModels.filter { repo, _ in
            repo != model.notesModel && repo != model.speechModel && repo.hasPrefix("mlx-community/") && !listed.contains(repo)
        }
        if !unused.isEmpty {
            Section("Downloaded, not in use") {
                ForEach(unused.sorted(by: { $0.key < $1.key }), id: \.key) { repo, gb in
                    LabeledContent(repo.components(separatedBy: "/").last ?? repo) {
                        Button(tr("Delete (%@ GB)", String(format: "%.1f", gb))) { model.deleteModel(repo) }
                    }
                }
            }
        }
    }

    /// The model in use when it isn't one of the tested ones.
    @ViewBuilder func customInUse(speech: Bool) -> some View {
        let repo = speech ? model.speechModel : model.notesModel
        let list = speech ? model.catalog.speech : model.catalog.notes
        if !repo.isEmpty && !list.contains(where: { $0.repo == repo }) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(repo.components(separatedBy: "/").last ?? repo)
                        Tag(text: "Custom", color: .orange)
                        Tag(text: "In use", color: .green)
                    }
                    Caption(repo + " · " + tr("not tested with MeetScribe"))
                }
                Spacer()
                if let rec = ModelCatalog.recommended(list, for: hw) {
                    Button(tr("Back to %@", rec.name)) { model.useModel(rec, speech: speech) }
                        .disabled(model.modelDownload != nil)
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
                Caption(String(format: "%.1f GB", m.sizeGB) + " · " + m.localizedDescription
                        + (fits ? "" : " · " + tr("needs %@ GB memory", "\(m.minRamGB)")))
            }
            Spacer()
            if !inUse {
                let installed = model.installedModels[m.repo] != nil
                VStack(alignment: .trailing, spacing: 4) {
                    Button(installed ? tr("Use") : tr("Download and use")) { model.useModel(m, speech: speech) }
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
        Text(tr(text)).font(.caption2.weight(.medium)).foregroundColor(color)
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

    static let repo = URL(string: "https://github.com/Gbally/MeetScribe-releases")!

    var body: some View {
        Section {
            LabeledContent("Version", value: Engine.appVersion)
            if let info = updater.available {
                LabeledContent("Update available") {
                    Button(tr("Install %@ and restart", info.version)) { updater.install() }
                        .disabled(model.isRecording || model.currentJob != nil || updater.state == .downloading)
                }
                if let notes = info.notes, !notes.isEmpty { Caption(notes) }
                if model.isRecording || model.currentJob != nil { Caption("Available once nothing is recording or processing.") }
            } else {
                LabeledContent("Updates") {
                    Button(updater.state == .checking ? tr("Checking…") : tr("Check now")) { Task { await updater.check() } }
                }
                if let d = updater.lastChecked { Caption(tr("Up to date · checked %@", d.local(date: .omitted, time: .shortened))) }
            }
            switch updater.state {
            case .downloading: ProgressView("Downloading the update…").progressViewStyle(.linear)
            case .installing: Caption("Installing — MeetScribe will restart.")
            case .failed(let msg): Text(msg).font(.caption).foregroundColor(.red)
            default: EmptyView()
            }
            if let page = Releases.pageURL { Link("Release notes", destination: page) }
        }
        Section("Open source") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "star.fill").font(.title2).foregroundColor(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MeetScribe is free and open source").font(.callout.weight(.medium))
                    Caption("Like it? A star on GitHub helps other people find it.")
                }
                Spacer()
                Button("Star on GitHub") { NSWorkspace.shared.open(Self.repo) }.buttonStyle(.borderedProminent)
            }
            LabeledContent("Source code") { Link(destination: Self.repo) { Text(verbatim: "github.com/Gbally/MeetScribe-releases") } }
            LabeledContent("Bugs and ideas") { Link("Report a problem…", destination: Self.repo.appendingPathComponent("issues/new")) }
            LabeledContent("License") {
                HStack(spacing: 6) {
                    Link(destination: Self.repo.appendingPathComponent("blob/main/LICENSE")) { Text(verbatim: "MIT") }
                    Text(verbatim: "·").foregroundColor(.secondary)
                    Link("Privacy", destination: Self.repo.appendingPathComponent("blob/main/PRIVACY.md"))
                    Text(verbatim: "·").foregroundColor(.secondary)
                    Link("Third-party licenses", destination: Self.repo.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
                }
            }
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

/// Any model from Hugging Face, at the user's own risk.
/// What the user typed and checked in "Custom model" — kept while the Settings window is open.
final class CustomModelDraft: ObservableObject {
    @Published var speech = false
    @Published var links = [false: "", true: ""]   // one link per kind
    @Published var checks: [Bool: CustomModelCheck] = [:]
    @Published var checking = false
}

struct CustomModelSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var draft: CustomModelDraft
    @State private var confirm = false
    private let hw = Hardware.current

    private var speech: Bool { draft.speech }
    private var checks: [Bool: CustomModelCheck] { draft.checks }
    private var checking: Bool { draft.checking }

    private var link: Binding<String> {
        // Only a real edit clears the result (the field re-sends its text when redrawn).
        Binding(get: { draft.links[draft.speech] ?? "" },
                set: { if $0 != draft.links[draft.speech] { draft.links[draft.speech] = $0; draft.checks[draft.speech] = nil } })
    }

    var body: some View {
        let check = checks[speech]
        Section {
            Picker("Replace the", selection: $draft.speech) {
                Text("Notes model").tag(false)
                Text("Speech model").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("Hugging Face link", text: link,
                          prompt: Text(speech ? "huggingface.co/mlx-community/whisper-…" : "huggingface.co/mlx-community/…"))
                    .onSubmit { inspect() }
                Button(checking ? tr("Checking…") : tr("Check")) { inspect() }
                    .disabled(link.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
            if let c = check {
                if let err = c.error {
                    Text(err).font(.caption).foregroundColor(.red)
                } else {
                    LabeledContent(c.repo, value: String(format: "%.1f GB", c.sizeGB))
                    if c.compatible == false {
                        Label(tr("MeetScribe can't run it: %@", c.compatibilityReason), systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                    } else {
                        if c.compatible == true {
                            Label(tr("Compatible: %@", c.compatibilityReason), systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundColor(.green)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(c.warnings(speech: speech, hw: hw), id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Download and use anyway") { confirm = true }
                                .disabled(model.modelDownload != nil)
                        }
                    }
                }
            }
        } header: {
            Text("Custom model")
        } footer: {
            Caption("For experiments: any model from Hugging Face. MeetScribe checks it can run it; you can go back to the recommended model at any time.")
        }
        .confirmationDialog(tr("Use %@?", check?.repo ?? tr("this model")), isPresented: $confirm) {
            Button("Download and use") {
                if let c = checks[speech] { model.useModel(c.asCatalogModel(), speech: speech) }
            }
        } message: {
            Text("It isn't tested with MeetScribe. If results look wrong or processing fails, switch back to the recommended model here.")
        }
    }

    private func inspect() {
        draft.checking = true
        let input = draft.links[speech] ?? ""
        let kind = speech
        Task {
            var c = await CustomModelCheck.inspect(input)
            if c.error == nil && model.phase == .ready { await c.checkCompatibility(speech: kind) }
            draft.checks[kind] = c
            draft.checking = false
        }
    }
}

struct UsageStatsSection: View {
    @State private var on = Telemetry.enabled

    var body: some View {
        Section("Usage statistics") {
            Toggle("Send anonymous usage statistics", isOn: Binding(get: { on }, set: { on = $0; Telemetry.enabled = $0 }))
            Caption("Helps improve MeetScribe: a new install, each recording's length and type, model changes, updates, and errors — with your Mac model and the AI models used. Never audio, transcripts, notes, titles or names.")
        }
    }
}
