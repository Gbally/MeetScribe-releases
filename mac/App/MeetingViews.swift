import AppKit
import AVFoundation
import SwiftUI

// MARK: - Meeting detail

struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    var id: Meeting.ID
    @Binding var route: Route
    var inWindow = false
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var editing = false
    @State private var draftTitle = ""
    @State private var drafts: [AppModel.TodoDraft] = []

    var body: some View {
        VStack(spacing: 0) {
            if let m = model.meeting(id) {
                Header(title: editing ? tr("Edit") : m.title, back: inWindow ? nil : { editing = false; route = .home }) {
                    if !inWindow {
                        Button { Windows.showMeeting(id, model: model) } label: { Image(systemName: "macwindow") }
                            .buttonStyle(.borderless).help("Open in a window")
                    }
                    if m.notes != nil && !model.isBusy(id) {
                        Button(editing ? tr("Done") : tr("Edit")) { editing ? save() : startEditing(m) }
                            .controlSize(.small)
                            .keyboardShortcut(editing ? KeyboardShortcut.defaultAction : nil)
                    }
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
                            Menu("Regenerate as…") {
                                ForEach(meetingTemplates, id: \.id) { t in
                                    Button(tr(t.name) + (t.id == (m.notes?.template ?? "general") ? " ✓" : "")) {
                                        model.regenerate(id, template: t.id)
                                    }
                                }
                            }
                            .disabled(!m.hasTranscript)
                            Button("Transcribe again") { model.enqueue(.process(id)) }.disabled(!m.hasAudio)
                        }
                        Divider()
                        Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .confirmationDialog(tr("Move “%@” to the Trash?", m.title), isPresented: $confirmDelete) {
                    Button("Move to Trash", role: .destructive) { model.delete(id); route = .home }
                }
                Divider()
                ScrollView {
                    if editing { editor.padding(14) } else { content(m).padding(14) }
                }
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
                        } label: { Label(copied ? tr("Copied") : tr("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
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
                        Text(m.unnamedSpeakers.count == 1 ? tr("1 speaker without a name — name them")
                             : tr("%@ speakers without a name — name them", "\(m.unnamedSpeakers.count)"))
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
                                Button(m.done.contains(i) ? tr("Mark as not done") : tr("Mark as done")) { model.toggleDone(id, i) }
                                Button("Delete this to-do", role: .destructive) { model.deleteTodo(id, i) }
                            }
                    }
                }
                bullets("Summary", n.summary)
                ForEach(n.sections ?? [], id: \.self) { sec in bullets(sec.title, sec.items) }
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
                HStack(spacing: 6) {
                    if !a.owner.isEmpty { Text(a.owner).font(.caption).foregroundColor(.secondary) }
                    DueBadge(item: a, done: done)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    func startEditing(_ m: Meeting) {
        draftTitle = m.title
        drafts = (m.notes?.actions ?? []).enumerated().map { i, a in
            AppModel.TodoDraft(originalIndex: i, task: a.task, owner: a.owner, due: a.due, done: m.done.contains(i))
        }
        editing = true
    }

    func save() {
        model.saveEdits(id, title: draftTitle, todos: drafts)
        editing = false
    }

    @ViewBuilder var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Meeting name")
            TextField("Meeting name", text: $draftTitle).textFieldStyle(.roundedBorder)
            SectionTitle(text: "To-dos")
            ForEach($drafts) { $d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Task", text: $d.task).textFieldStyle(.roundedBorder)
                        Button { drafts.removeAll { $0.id == d.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete this to-do")
                    }
                    HStack {
                        TextField("Owner", text: $d.owner).textFieldStyle(.roundedBorder)
                        TextField("Due (e.g. Friday, 30 Oct)", text: $d.due).textFieldStyle(.roundedBorder)
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            Button {
                drafts.append(.init(originalIndex: nil, task: "", owner: model.settings.myName, due: "", done: false))
            } label: { Label("Add a to-do", systemImage: "plus.circle") }
            .buttonStyle(.borderless)
            Text("Due dates are understood in plain words (“Friday”, “next week”, “30 Oct”).")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button("Cancel") { editing = false }
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }
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
                                            Text(verbatim: "“\(clip.text)”").font(.caption).foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                ForEach(samples[s] ?? [], id: \.self) { line in
                                    Text(verbatim: "“\(line)”").font(.caption).foregroundColor(.secondary)
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

struct TodosView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @State private var mineOnly = true
    @State private var showDone = false

    var body: some View {
        // Open first, then by due date (no date last), then newest meeting first.
        let items = model.todos(mineOnly: mineOnly).filter { showDone || !$0.done }.sorted { a, b in
            if a.done != b.done { return !a.done }
            switch (a.item.dueDay, b.item.dueDay) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.meeting.date > b.meeting.date
            }
        }
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
                VStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        Text(mineOnly ? (showDone ? tr("Nothing assigned to you. 🎉") : tr("Nothing assigned to you is open. 🎉"))
                             : tr("No to-dos."))
                            .font(.callout).foregroundColor(.secondary).padding(.top, 20)
                        if mineOnly && model.settings.myName.isEmpty {
                            Text("Set your name in Settings so MeetScribe knows which to-dos are yours.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    ForEach(items) { ref in
                        let id = ref.meeting.id
                        Button { model.toggleDone(id, ref.index) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: ref.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(ref.done ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ref.item.task).font(.callout).strikethrough(ref.done)
                                        .foregroundColor(ref.done ? .secondary : .primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) {
                                        DueBadge(item: ref.item, done: ref.done)
                                        if !mineOnly && !ref.item.owner.isEmpty {
                                            Text(ref.item.owner).font(.caption).foregroundColor(.secondary)
                                        }
                                        Text(ref.meeting.title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(ref.done ? tr("Mark as not done") : tr("Mark as done")) { model.toggleDone(id, ref.index) }
                            Button("Open the meeting") { route = .meeting(id) }
                            Button("Delete this to-do", role: .destructive) { model.deleteTodo(id, ref.index) }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// "Overdue · 23 Oct", "Today", "Tomorrow", "Fri 30 Oct", or the due text when no date.

struct DueBadge: View {
    var item: ActionItem
    var done: Bool

    var body: some View {
        if let day = item.dueDay {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: day)).day ?? 0
            let (text, color): (String, Color) =
                days < 0 ? (tr("Overdue · %@", day.formatted(.dateTime.day().month(.abbreviated))), .red)
                : days == 0 ? (tr("Due today"), .orange)
                : days == 1 ? (tr("Due tomorrow"), .orange)
                : days < 7 ? (tr("Due %@", day.formatted(.dateTime.weekday(.wide))), .accentColor)
                : (tr("Due %@", day.formatted(.dateTime.day().month(.abbreviated))), .secondary)
            Text(text).font(.caption2.weight(.semibold))
                .foregroundColor(done ? .secondary : color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill((done ? Color.secondary : color).opacity(0.12)))
        } else if !item.due.isEmpty && item.due != "—" {
            Text(item.due).font(.caption).foregroundColor(.secondary)
        }
    }
}

/// Before a meeting: last time's notes and the to-dos still open from that series.

struct BriefView: View {
    @EnvironmentObject var model: AppModel
    var event: CalendarEvent
    @Binding var route: Route

    var body: some View {
        let b = model.brief(for: event)
        VStack(spacing: 0) {
            Header(title: event.title, back: { route = .home }) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
                         + (event.attendees.isEmpty ? "" : " · " + tr("%@ people", "\(event.attendees.count + 1)")))
                        .font(.caption).foregroundColor(.secondary)
                    if !model.isRecording {
                        Button {
                            model.startRecording(title: event.title)
                            route = .home
                        } label: {
                            Label("Start recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.red)
                    }
                    if !b.openTodos.isEmpty {
                        SectionTitle(text: "Still open")
                        ForEach(b.openTodos) { ref in
                            Button { model.toggleDone(ref.meeting.id, ref.index) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: ref.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(ref.done ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ref.item.task).font(.callout).fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 6) {
                                            if !ref.item.owner.isEmpty { Text(ref.item.owner).font(.caption).foregroundColor(.secondary) }
                                            DueBadge(item: ref.item, done: ref.done)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let last = b.last, let n = last.notes {
                        SectionTitle(text: tr("Last time · %@", last.date.formatted(date: .abbreviated, time: .omitted)))
                        ForEach((n.decisions.isEmpty ? n.summary : n.decisions).prefix(5), id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundColor(.secondary)
                                Text(item).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button("Open those notes") { route = .meeting(last.id) }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The answer to a question asked across all meetings, with its sources.

struct AskView: View {
    @EnvironmentObject var model: AppModel
    @Binding var route: Route
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            Header(title: "Ask your meetings", back: { route = .home }) { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Ask a question…", text: $question).textFieldStyle(.roundedBorder)
                            .onSubmit { model.ask(question) }
                        Button("Ask") { model.ask(question) }.disabled(model.isAsking)
                    }
                    if model.isAsking {
                        if case .ask = model.currentJob {
                            JobProgress()
                        } else {
                            HStack { ProgressView().controlSize(.small); Text("Waiting for the meeting being processed…").font(.caption) }
                        }
                    } else if let err = model.askError {
                        Text(err).font(.caption).foregroundColor(.red).textSelection(.enabled)
                    } else if let r = model.askResult {
                        Text(r.answer).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if !r.sources.isEmpty {
                            SectionTitle(text: "Sources")
                            ForEach(r.sources, id: \.self) { src in
                                let id = URL(fileURLWithPath: src.folder).lastPathComponent
                                Button { route = .meeting(id) } label: {
                                    HStack {
                                        Text(verbatim: "[\(src.n)]").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                        Text(src.title).font(.callout).lineLimit(1)
                                        Spacer()
                                        Text(src.date + (src.time.map { " · \(formatDuration($0))" } ?? ""))
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Text("Answers come from your notes and transcripts, by the AI on this Mac. Check the sources for anything important.")
                        .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            question = model.askQuestion
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
