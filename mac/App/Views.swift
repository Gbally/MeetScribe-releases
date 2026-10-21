import AppKit
import AVFoundation
import SwiftUI

enum Route: Equatable {
    case home, settings, todos
    case meeting(Meeting.ID)
    case speakers(Meeting.ID)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var route: Route = .home

    var body: some View {
        Group {
            switch route {
            case .home: HomeView(route: $route)
            case .settings: SettingsView(route: $route)
            case .meeting(let id): MeetingView(id: id, route: $route)
            case .speakers(let id): SpeakersView(id: id, route: $route)
            case .todos: TodosView(route: $route)
            }
        }
        .frame(width: 400, height: 580)
        .onAppear {
            model.reload()
            model.refreshPermissions()
            model.refreshCalendar()
            takePendingRoute()
        }
        .onChange(of: model.pendingRoute) { _ in takePendingRoute() }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast).font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial)).shadow(radius: 3).padding(.bottom, 50)
            }
        }
    }
}

extension RootView {
    func takePendingRoute() {
        if let r = model.pendingRoute {
            route = r
            model.pendingRoute = nil
        }
    }
}

/// Progress bar + percentage + time left for the running job.
struct JobProgress: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let p = model.jobProgress {
                ProgressView(value: p)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(model.jobStatus).lineLimit(1)
                Spacer()
                if let p = model.jobProgress {
                    Text("\(Int(p * 100)) %" + (model.jobETA.map { " · \($0)" } ?? "")).monospacedDigit()
                }
            }
            .font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Shared bits

struct Header<Trailing: View>: View {
    var title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.top, 6)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct LevelMeter: View {
    var label: String
    var icon: String
    var level: Float
    var active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundColor(.secondary)
            Text(label).font(.caption).frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(active ? Color.green : Color.gray)
                        .frame(width: active ? max(3, geo.size.width * CGFloat(min(1, sqrt(level) * 1.4))) : 0)
                }
            }
            .frame(height: 6)
            if !active { Text("off").font(.caption2).foregroundColor(.secondary) }
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @State private var title = ""
    @State private var confirmDiscard = false
    @State private var deleting: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "MeetScribe") {
                Menu {
                    Button("Transcribe an audio file…") { model.chooseAudioFile() }
                        .disabled(model.phase != .ready)
                    Button("Open notes folder") { NSWorkspace.shared.open(model.settings.notesFolder) }
                    Divider()
                    Button("Settings…") { route = .settings }
                    Divider()
                    Button("Quit MeetScribe") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.phase {
                    case .needsSetup, .settingUp: SetupCard()
                    case .ready:
                        recordCard
                        PermissionsCard()
                        todosButton
                    }
                    if let job = model.currentJob { jobCard(job) }
                    history
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder var recordCard: some View {
        Card {
            if model.isRecording {
                HStack {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Recording").font(.headline)
                    Spacer()
                    Text(formatDuration(model.elapsed)).font(.system(.title2, design: .monospaced))
                }
                if let e = model.recordingEvent {
                    Label("\(e.title) · until \(e.end.formatted(date: .omitted, time: .shortened))", systemImage: "calendar")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                LevelMeter(label: "Your mic", icon: "mic.fill", level: model.micLevel, active: model.recorder?.mic != nil)
                LevelMeter(label: "Meeting", icon: "speaker.wave.2.fill", level: model.systemLevel, active: model.recorder?.system != nil)
                ForEach(model.notices, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange) }
                Button {
                    model.stopRecording()
                } label: {
                    Label("Stop & create notes", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button("Discard this recording", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
                        Button("Discard", role: .destructive) { model.stopRecording(discard: true) }
                    }
            } else {
                if let e = model.currentEvent {
                    Label {
                        Text("\(e.title) · \(e.timeRange)" + (e.attendees.isEmpty ? "" : " · \(e.attendees.count + 1) people"))
                            .lineLimit(1)
                    } icon: { Image(systemName: "calendar") }
                    .font(.caption).foregroundColor(.secondary)
                }
                TextField(model.currentEvent.map { "Meeting name (default: \($0.title))" } ?? "Meeting name (optional — AI names it otherwise)",
                          text: $title)
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.startRecording(title: title)
                    title = ""
                } label: {
                    Label(model.isStarting ? "Starting…" : "Start recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isStarting)
                if let err = model.startError {
                    Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.red)
                }
                Text(model.settings.teamsOnly ? "Records your microphone + Microsoft Teams." : "Records your microphone + all Mac audio (Teams, browser…).")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder var todosButton: some View {
        let open = model.myOpenTodoCount
        if open > 0 || !model.todos(mineOnly: false).isEmpty {
            Button { route = .todos } label: {
                HStack {
                    Image(systemName: "checklist").foregroundColor(.accentColor)
                    Text("My to-dos").font(.callout.weight(.medium))
                    Spacer()
                    Text(open == 0 ? "all done" : "\(open) open").font(.caption).foregroundColor(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
    }

    func jobCard(_ job: Job) -> some View {
        Card {
            HStack {
                Text(jobTitle(job)).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if !model.queue.isEmpty { Text("+\(model.queue.count) waiting").font(.caption2).foregroundColor(.secondary) }
            }
            JobProgress()
            Text("You can close this window — a notification tells you when the notes are ready.")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func jobTitle(_ job: Job) -> String {
        switch job {
        case .process(let id): return "Processing “\(model.meeting(id)?.title ?? "meeting")”"
        case .processFile(let url): return "Processing \(url.lastPathComponent)"
        case .rename(let id, _), .resummarize(let id): return "Updating “\(model.meeting(id)?.title ?? "meeting")”"
        }
    }

    @ViewBuilder var history: some View {
        let past = model.meetings.filter { $0.id != model.recordingID }
        SectionTitle(text: "Meetings")
        if past.isEmpty {
            Text("Your meetings will appear here.").font(.callout).foregroundColor(.secondary)
        }
        ForEach(past) { m in
            Button { route = .meeting(m.id) } label: { MeetingRow(meeting: m) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open") { route = .meeting(m.id) }
                    Button("Email the notes…") { model.emailNotes(m.id) }.disabled(m.notes == nil)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = m }
                        .disabled(model.isBusy(m.id) || m.id == model.recordingID)
                }
        }
        if !past.isEmpty {
            Text("Right-click a meeting to delete it.").font(.caption2).foregroundColor(.secondary)
        }
        Color.clear.frame(height: 0)
            .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Move to Trash", role: .destructive) { if let d = deleting { model.delete(d.id) } }
            } message: {
                Text("The notes, transcript and audio go to the Trash (you can still restore them from there).")
            }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var model: AppModel
    var meeting: Meeting

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let n = meeting.notes, !n.actions.isEmpty {
                let open = n.actions.indices.filter { !meeting.done.contains($0) }.count
                if open > 0 {
                    Text("\(open) to-do").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    var subtitle: String {
        var parts = [meeting.date.formatted(date: .abbreviated, time: .shortened)]
        if let d = meeting.duration { parts.append(formatDuration(d)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var statusIcon: some View {
        if model.isBusy(meeting.id) {
            ProgressView().controlSize(.small)
        } else if meeting.error != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        } else if meeting.notes != nil {
            Image(systemName: "doc.text.fill").foregroundColor(.accentColor)
        } else {
            Image(systemName: "waveform").foregroundColor(.secondary)
        }
    }
}

// MARK: - Setup & permissions

struct SetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            Label("One-time setup", systemImage: "arrow.down.circle").font(.headline)
            Text("MeetScribe runs its AI entirely on this Mac — nothing is sent to the cloud. It first needs to download its engine and models (about 6 GB, 10–20 minutes).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if model.phase == .settingUp {
                if let p = model.setupProgress {
                    ProgressView(value: p) { Text(model.setupStatus).font(.caption) } currentValueLabel: {
                        Text("\(Int(p * 100)) %").font(.caption2)
                    }
                } else {
                    ProgressView { Text(model.setupStatus).font(.caption) }.progressViewStyle(.linear)
                }
            } else {
                if let err = model.setupError {
                    Text(err).font(.caption).foregroundColor(.red).textSelection(.enabled)
                }
                Button {
                    model.runSetup()
                } label: {
                    Text(model.setupError == nil ? "Download & set up" : "Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

struct PermissionsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.micPermission != .authorized || !model.screenPermission {
            Card {
                Label("Permissions needed", systemImage: "lock.shield").font(.headline)
                if model.micPermission != .authorized {
                    permissionRow("Microphone — to record your voice", pane: "Privacy_Microphone") {
                        Task {
                            if model.micPermission == .notDetermined { _ = await MicCapture.requestPermission() }
                            else { openPane("Privacy_Microphone") }
                            model.refreshPermissions()
                        }
                    }
                }
                if !model.screenPermission {
                    permissionRow("Screen & System Audio Recording — to hear the other participants", pane: "Privacy_ScreenCapture") {
                        if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
                        model.refreshPermissions()
                    }
                }
                HStack {
                    Text("Already allowed? macOS applies it after a restart.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Restart MeetScribe") { model.restartApp() }.controlSize(.small)
                }
            }
        }
    }

    func permissionRow(_ text: String, pane: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Allow…", action: action).controlSize(.small)
        }
    }

    func openPane(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: - Meeting detail

struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    var id: Meeting.ID
    @Binding var route: Route
    @State private var confirmDelete = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if let m = model.meeting(id) {
                Header(title: m.title, back: { route = .home }) {
                    Menu {
                        Group {
                            Button("Open notes") { openFile(m.url("notes.md")) }.disabled(m.notes == nil)
                            Button("Open transcript") { openFile(m.url("transcript.md")) }.disabled(!m.hasTranscript)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                        }
                        Divider()
                        Group {
                            Button("Name the speakers…") { route = .speakers(id) }.disabled(m.notes == nil)
                            Button("Email the notes…") { model.emailNotes(id) }.disabled(m.notes == nil)
                            Button("Add my to-dos to Reminders") { model.addToReminders(id, mineOnly: true) }.disabled(m.notes == nil)
                            Button("Add all to-dos to Reminders") { model.addToReminders(id, mineOnly: false) }.disabled(m.notes == nil)
                        }
                        Divider()
                        Group {
                            Button("Regenerate notes") { model.enqueue(.resummarize(id)) }.disabled(!m.hasTranscript)
                            Button("Transcribe again") { model.enqueue(.process(id)) }.disabled(!m.hasAudio)
                        }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .confirmationDialog("Move “\(m.title)” to the Trash?", isPresented: $confirmDelete) {
                    Button("Move to Trash", role: .destructive) { model.delete(id); route = .home }
                }
                Divider()
                ScrollView { content(m).padding(14) }
                if m.notes != nil {
                    Divider()
                    HStack {
                        Button { openFile(m.url("transcript.md")) } label: { Label("Transcript", systemImage: "text.alignleft") }
                        Button { openFile(m.url("notes.md")) } label: { Label("Notes", systemImage: "doc.text") }
                        Spacer()
                        Button { model.emailNotes(id) } label: { Label("Email", systemImage: "envelope") }
                        Button {
                            model.copyNotes(id)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    }
                    .controlSize(.small)
                    .padding(10)
                }
            } else {
                Header(title: "Meeting", back: { route = .home }) { EmptyView() }
                Spacer()
            }
        }
    }

    @ViewBuilder func content(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meta(m)).font(.caption).foregroundColor(.secondary)

            if model.isBusy(id) {
                Card {
                    if model.currentJob.map(\.meetingID) == id {
                        JobProgress()
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Waiting for the meeting before it…").font(.callout) }
                    }
                }
            } else if let err = m.error {
                Card {
                    Label("Processing failed", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(err).font(.caption).textSelection(.enabled)
                    if m.hasAudio { Button("Try again") { model.enqueue(.process(id)) } }
                }
            } else if m.notes == nil && m.hasAudio && !m.hasTranscript {
                Card {
                    Text("This recording hasn't been processed yet.").font(.callout)
                    Button("Create notes now") { model.enqueue(.process(id)) }
                }
            }

            if let n = m.notes, n.missingMeetingAudio {
                Card {
                    Label("The meeting audio wasn't recorded", systemImage: "speaker.slash").font(.callout.weight(.medium))
                        .foregroundColor(.orange)
                    Text("Only your microphone was captured, so other people's voices were picked up through your speakers — speaker names may be less reliable. Check Screen & System Audio Recording for MeetScribe in System Settings.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !m.unnamedSpeakers.isEmpty && !model.isBusy(id) && m.notes != nil {
                Button { route = .speakers(id) } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.questionmark").foregroundColor(.accentColor)
                        Text("\(m.unnamedSpeakers.count) speaker\(m.unnamedSpeakers.count == 1 ? "" : "s") without a name — name them")
                            .font(.callout)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            if let n = m.notes {
                if !n.actions.isEmpty {
                    SectionTitle(text: "To-do")
                    ForEach(Array(n.actions.enumerated()), id: \.offset) { i, a in
                        Button { model.toggleDone(id, i) } label: { todoRow(a, done: m.done.contains(i)) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(m.done.contains(i) ? "Mark as not done" : "Mark as done") { model.toggleDone(id, i) }
                                Button("Delete this to-do", role: .destructive) { model.deleteTodo(id, i) }
                            }
                    }
                }
                bullets("Summary", n.summary)
                bullets("Decisions", n.decisions)
                bullets("Open questions", n.questions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func meta(_ m: Meeting) -> String {
        var parts = [m.date.formatted(date: .long, time: .shortened)]
        if let d = m.duration { parts.append(formatDuration(d)) }
        if let p = m.notes?.participants, !p.isEmpty { parts.append(p.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    func todoRow(_ a: ActionItem, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.task).font(.callout).strikethrough(done).foregroundColor(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                let extra = [a.owner, a.due].filter { !$0.isEmpty }
                if !extra.isEmpty { Text(extra.joined(separator: " · ")).font(.caption).foregroundColor(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            SectionTitle(text: title)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundColor(.secondary)
                    Text(item).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Name speakers

struct SpeakersView: View {
    @EnvironmentObject var model: AppModel
    var id: Meeting.ID
    @Binding var route: Route
    @State private var names: [String: String] = [:]
    @State private var samples: [String: [String]] = [:]
    @State private var clips: [String: [Meeting.Clip]] = [:]
    @State private var preparingClips = false
    @StateObject private var player = ClipPlayer()

    var speakers: [String] { model.meeting(id)?.notes?.participants ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Name the speakers", back: { player.stop(); route = .meeting(id) }) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Listen to each speaker (▶︎), then type their name. MeetScribe remembers their voice for next time, and the notes are rewritten with the names. Same person split in two? Give both the same name.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    if preparingClips {
                        HStack { ProgressView().controlSize(.small); Text("Preparing voice samples…").font(.caption) }
                    }
                    ForEach(speakers, id: \.self) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(s).font(.callout.weight(.semibold)).frame(width: 100, alignment: .leading)
                                TextField("Name", text: Binding(get: { names[s] ?? "" }, set: { names[s] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                if !model.settings.myName.isEmpty && s != model.settings.myName {
                                    Button("Me") { names[s] = model.settings.myName }.controlSize(.small)
                                        .help("This speaker is you")
                                }
                            }
                            if let list = clips[s], !list.isEmpty, let m = model.meeting(id) {
                                ForEach(list, id: \.self) { clip in
                                    let url = m.url(clip.file)
                                    Button { player.toggle(url) } label: {
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: player.playing == url ? "stop.circle.fill" : "play.circle.fill")
                                                .font(.title3).foregroundColor(.accentColor)
                                            Text("“\(clip.text)”").font(.caption).foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                ForEach(samples[s] ?? [], id: \.self) { line in
                                    Text("“\(line)”").font(.caption).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if (samples[s] ?? []).isEmpty {
                                    Text("Only said a few words.").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                    Button("Open the full transcript") { model.meeting(id).map { openFile($0.url("transcript.md")) } }
                        .controlSize(.small)
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Save & regenerate notes") {
                    player.stop()
                    let mapping = names.mapValues { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.value.isEmpty && $0.key != $0.value }
                    if !mapping.isEmpty { model.enqueue(.rename(id, mapping)) }
                    route = .meeting(id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            load()
        }
        .onDisappear { player.stop() }
    }

    private func load() {
        guard let m = model.meeting(id) else { return }
        samples = m.samples()
        if let c = m.clips {
            clips = c
        } else if m.hasAudio && m.hasTranscript && model.phase == .ready {
            // Meetings processed before voice samples existed: make them now (a few seconds).
            preparingClips = true
            Engine.writeConfig(model.settings)
            Task {
                _ = await Engine.meetscribe(["clips", m.folder.path]) { _ in }
                clips = model.meeting(id)?.clips ?? [:]
                preparingClips = false
            }
        }
    }
}

/// Plays one voice sample at a time.
final class ClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing: URL?
    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = url
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playing = nil }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @State private var confirmReinstall = false

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Settings", back: { route = .home }) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        SectionTitle(text: "You")
                        TextField("Your name (used for your voice in transcripts)", text: $model.settings.myName)
                            .textFieldStyle(.roundedBorder)

                    }
                    SummarySection()
                    Group {
                        SectionTitle(text: "Transcription")
                        LanguagesSection()
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Names & jargon, comma-separated", text: $model.settings.vocabulary)
                                .textFieldStyle(.roundedBorder)
                            Text("Helps spell product names, acronyms and colleagues' names correctly.")
                                .font(.caption).foregroundColor(.secondary)
                        }

                    }
                    Group {
                        SectionTitle(text: "Recording")
                        Picker("Record", selection: $model.settings.teamsOnly) {
                            Text("All Mac audio (recommended)").tag(false)
                            Text("Microsoft Teams only").tag(true)
                        }
                        Toggle("Keep audio files after creating notes", isOn: $model.settings.keepAudio)
                        Toggle("Open MeetScribe at login", isOn: $model.launchAtLogin)
                        Toggle("Remind me to record when a call starts", isOn: $model.settings.callReminders)
                        CalendarRow()

                    }
                    StorageSection()
                    VoicesSection()
                    Group {
                        SectionTitle(text: "Engine")
                        Text("AI models run locally. Stored in ~/Library/Application Support/MeetScribe and ~/.cache/huggingface.")
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Reinstall engine…") { confirmReinstall = true }
                            .controlSize(.small)
                            .disabled(model.phase == .settingUp || model.currentJob != nil)
                            .confirmationDialog("Reinstall the engine? Downloaded models are kept.", isPresented: $confirmReinstall) {
                                Button("Reinstall") { route = .home; model.runSetup() }
                            }
                        Text("MeetScribe \(Engine.appVersion)").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct SummarySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Notes")
            Picker("Detail", selection: $model.settings.summaryStyle) {
                ForEach(SummaryStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.settings.summaryStyle.help).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Applies to new meetings. To redo an older one: open it → ⋯ → Regenerate notes.")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StorageSection: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: AppSettings?
    @State private var accounts = CloudFolders.oneDriveAccounts

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Where notes are saved")
            Picker("Storage", selection: Binding(get: { model.settings.storage }, set: choose)) {
                Text("This Mac only").tag(Storage.local)
                Text(accounts.isEmpty ? "OneDrive (not set up on this Mac)" : "OneDrive").tag(Storage.oneDrive)
                Text("Another folder…").tag(Storage.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!model.canChangeStorage)

            if model.settings.storage == .oneDrive && accounts.count > 1 {
                Picker("Account", selection: Binding(get: { model.settings.oneDrivePath }, set: { path in
                    var n = model.settings
                    n.oneDrivePath = path
                    request(n)
                })) {
                    ForEach(accounts, id: \.self) { Text($0.name).tag($0.url.path) }
                }
                .disabled(!model.canChangeStorage)
            }

            Text(description).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.settings.storage != .local && model.settings.keepAudio {
                Label("Audio files (~230 MB per hour) are synced too — turn off “Keep audio files” to sync only the notes.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(model.settings.notesFolder.path).font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(model.settings.notesFolder) }
                if model.settings.storage == .custom {
                    Button("Change…") { choose(.custom) }.disabled(!model.canChangeStorage)
                }
            }
            .controlSize(.small)
            if let status = model.movingStatus {
                Label(status, systemImage: "arrow.right.doc.on.clipboard").font(.caption)
            } else if !model.canChangeStorage {
                Text("Can be changed when nothing is recording or processing.").font(.caption2).foregroundColor(.secondary)
            }
        }
        .onAppear { accounts = CloudFolders.oneDriveAccounts }
        .confirmationDialog(
            "Move your \(model.meetingsInNotesFolder) existing meeting(s) to the new location?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("Move them") { if let p = pending { model.changeStorage(to: p, moveExisting: true) } }
            Button("Leave them where they are") { if let p = pending { model.changeStorage(to: p, moveExisting: false) } }
        } message: {
            Text("Meetings left behind won't show in the history, but stay in their folder.")
        }
    }

    var description: String {
        let folder = model.settings.notesFolder
        switch model.settings.storage {
        case .local:
            var s = "Stays on this Mac — never uploaded anywhere."
            if !folder.path.contains("/Documents/") {
                s += " (Your Documents folder is synced to the cloud, so notes go in your home folder instead.)"
            }
            return s
        case .oneDrive:
            let name = accounts.first { $0.url.path == model.settings.oneDrivePath }?.name ?? "OneDrive"
            return "Synced to \(name): backed up, and available on your other devices and on the web. Your company's OneDrive rules apply."
        case .custom:
            return CloudFolders.syncService(for: folder).map { "This folder is synced to \($0)." } ?? "This folder isn't synced to the cloud."
        }
    }

    func choose(_ storage: Storage) {
        var n = model.settings
        n.storage = storage
        switch storage {
        case .local:
            break
        case .oneDrive:
            accounts = CloudFolders.oneDriveAccounts
            guard let first = accounts.first else {
                model.movingStatus = nil
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "OneDrive isn't set up on this Mac"
                alert.informativeText = "Install the OneDrive app and sign in with your work account, then choose OneDrive again."
                alert.runModal()
                return
            }
            if !accounts.contains(where: { $0.url.path == n.oneDrivePath }) { n.oneDrivePath = first.url.path }
        case .custom:
            guard let url = model.pickFolder() else { return }
            n.customFolderPath = url.path
        }
        request(n)
    }

    func request(_ n: AppSettings) {
        if n.notesFolder.standardizedFileURL == model.settings.notesFolder.standardizedFileURL || model.meetingsInNotesFolder == 0 {
            model.changeStorage(to: n, moveExisting: false)
        } else {
            pending = n
        }
    }
}

struct LanguagesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Languages spoken in your meetings").font(.callout)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(meetingLanguages, id: \.code) { lang in
                    Toggle(lang.name, isOn: Binding(
                        get: { model.settings.languages.contains(lang.code) },
                        set: { on in
                            var l = model.settings.languages.filter { $0 != lang.code }
                            if on { l.append(lang.code) }
                            model.settings.languages = meetingLanguages.map(\.code).filter(l.contains)
                        }))
                    .toggleStyle(.checkbox)
                }
            }
            Text(languagesHelp).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Notes language", selection: $model.settings.notesLanguage) {
                Text("Same as the meeting").tag("auto")
                ForEach(meetingLanguages, id: \.code) { Text($0.name).tag($0.name) }
            }
        }
    }

    var languagesHelp: String {
        switch model.settings.languages.count {
        case 0: return "None ticked: the language is detected automatically (one per meeting)."
        case 1: return "Everything is transcribed as \(meetingLanguages.first { $0.code == model.settings.languages[0] }?.name ?? "that language")."
        default: return "Meetings can switch between these languages — detected every few seconds."
        }
    }
}

struct CalendarRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use my calendar for meeting names & attendees", isOn: Binding(
                get: { model.settings.useCalendar },
                set: { on in
                    model.settings.useCalendar = on
                    if on && !CalendarService.shared.eventsAllowed { model.allowCalendar() }
                    model.refreshCalendar()
                }))
            if model.settings.useCalendar && !CalendarService.shared.eventsAllowed {
                HStack {
                    Text("Calendar access isn't allowed yet.").font(.caption).foregroundColor(.orange)
                    Button("Allow…") { model.allowCalendar() }.controlSize(.small)
                }
            }
            Text("Outlook meetings appear once your work account is added to the Calendar app (System Settings → Internet Accounts).")
                .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VoicesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var forget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Known voices")
            Text("Name the speakers of a meeting (⋯ → Name the speakers) and MeetScribe recognises them next time. Voiceprints stay on this Mac.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.voices.isEmpty {
                Text("No voices learned yet.").font(.caption).foregroundColor(.secondary)
            }
            ForEach(model.voices, id: \.name) { v in
                HStack {
                    Image(systemName: "person.wave.2").foregroundColor(.secondary)
                    Text(v.name).font(.callout)
                    Text("\(v.samples) sample\(v.samples == 1 ? "" : "s")").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Forget") { forget = v.name }.controlSize(.small)
                }
            }
        }
        .onAppear { model.reloadVoices() }
        .confirmationDialog("Forget \(forget ?? "")'s voice?", isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } })) {
            Button("Forget", role: .destructive) { if let f = forget { model.forgetVoice(f) } }
        }
    }
}

struct TodosView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @State private var mineOnly = true
    @State private var showDone = false

    var body: some View {
        let items = model.todos(mineOnly: mineOnly).filter { showDone || !$0.done }
        let grouped = Dictionary(grouping: items, by: \.meeting.id)
        let order = model.meetings.map(\.id).filter { grouped[$0] != nil }
        VStack(spacing: 0) {
            Header(title: "To-dos", back: { route = .home }) {
                Toggle("Done", isOn: $showDone).toggleStyle(.checkbox).font(.caption)
            }
            Picker("", selection: $mineOnly) {
                Text("Mine").tag(true)
                Text("Everyone's").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text(mineOnly ? "Nothing assigned to you\(showDone ? "" : " is open"). 🎉" : "No to-dos.")
                            .font(.callout).foregroundColor(.secondary).padding(.top, 20)
                        if mineOnly && model.settings.myName.isEmpty {
                            Text("Set your name in Settings so MeetScribe knows which to-dos are yours.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    ForEach(order, id: \.self) { id in
                        if let refs = grouped[id], let m = refs.first?.meeting {
                            Button { route = .meeting(id) } label: {
                                HStack {
                                    Text(m.title).font(.caption.weight(.semibold)).lineLimit(1)
                                    Text("· \(m.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                            ForEach(refs) { ref in
                                Button { model.toggleDone(id, ref.index) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: ref.done ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(ref.done ? .green : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ref.item.task).font(.callout).strikethrough(ref.done)
                                                .foregroundColor(ref.done ? .secondary : .primary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            let extra = [mineOnly ? "" : ref.item.owner, ref.item.due].filter { !$0.isEmpty }
                                            if !extra.isEmpty {
                                                Text(extra.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(ref.done ? "Mark as not done" : "Mark as done") { model.toggleDone(id, ref.index) }
                                    Button("Open the meeting") { route = .meeting(id) }
                                    Button("Delete this to-do", role: .destructive) { model.deleteTodo(id, ref.index) }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
