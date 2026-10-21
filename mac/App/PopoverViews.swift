import AppKit
import AVFoundation
import SwiftUI

enum Route: Equatable {
    case home, todos, ask
    case meeting(Meeting.ID)
    case speakers(Meeting.ID)
    case brief(CalendarEvent)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var route: Route = .home

    var body: some View {
        Group {
            switch route {
            case .home: HomeView(route: $route)
            case .meeting(let id): MeetingView(id: id, route: $route)
            case .speakers(let id): SpeakersView(id: id, route: $route)
            case .todos: TodosView(route: $route)
            case .ask: AskView(route: $route)
            case .brief(let e): BriefView(event: e, route: $route)
            }
        }
        .frame(width: 380, height: 580)
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
    enum Tab { case today, meetings, todos }

    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = AppModelHolder.updater
    @Binding var route: Route
    @State private var confirmDiscard = false
    @State private var deleting: Meeting?
    @State private var template: String?
    @State private var search = ""
    @State private var tab: Tab = .today

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.phase {
                    case .needsSetup, .settingUp: SetupCard()
                    case .ready:
                        PermissionsCard()
                        hero
                    }
                    if let job = model.currentJob { jobCard(job) }
                    if model.phase == .ready || !model.meetings.isEmpty {
                        Divider()
                        if !search.isEmpty {
                            searchResults
                        } else {
                            switch tab {
                            case .today: todayTimeline
                            case .meetings: meetingList
                            case .todos: todoList
                            }
                        }
                    }
                }
                .padding(14)
            }
            footer
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date().formatted(.dateTime.weekday(.wide))).font(.headline)
                Text(Date().formatted(.dateTime.day().month(.wide))).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if updater.available != nil {
                Button { Windows.showSettings(model, tab: .about) } label: {
                    Text("Update").font(.caption.weight(.medium)).foregroundColor(.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("A new version of MeetScribe is available")
            }
            Button { Windows.showSettings(model) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
            Menu {
                Button("Transcribe an audio file…") { model.chooseAudioFile() }.disabled(model.phase != .ready)
                Button("Open notes folder") { NSWorkspace.shared.open(model.settings.notesFolder) }
                Divider()
                Button("Quit MeetScribe") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Hero (record / recording)

    @ViewBuilder var hero: some View {
        if model.isRecording {
            Card {
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
            }
        } else {
            let event = model.currentEvent
            let brief = event.map { model.brief(for: $0) }
            HStack(alignment: .center, spacing: 14) {
                Button {
                    model.startRecording(title: "", template: template)
                    template = nil
                } label: {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.14))
                        Circle().strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                        if model.isStarting { ProgressView().controlSize(.small) }
                        else { Circle().fill(Color.red).frame(width: 22, height: 22) }
                    }
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isStarting)
                .help("Start recording")
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.map { "Record \($0.title)" } ?? "Record").font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        if let e = event { Text("Now · \(e.start.formatted(date: .omitted, time: .shortened)) ·") }
                        Menu {
                            ForEach(meetingTemplates, id: \.id) { t in Button(t.name) { template = t.id } }
                        } label: {
                            Text(templateName(template ?? model.settings.defaultTemplate) + " ▾").font(.caption)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Meeting type: shapes the notes")
                        if let hk = model.settings.hotkey { Text("· \(hk.display)") }
                    }
                    .font(.caption).foregroundColor(.secondary)
                    if let e = event, let b = brief, !b.isEmpty {
                        Button { route = .brief(e) } label: {
                            Text(b.openTodos.isEmpty ? "Notes from last time ›"
                                 : "\(b.openTodos.count) open to-do\(b.openTodos.count == 1 ? "" : "s") from last time ›")
                                .font(.caption).foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    } else if model.settings.autoRecord {
                        Text("Records calls automatically").font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let err = model.startError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: Today

    @ViewBuilder var todayTimeline: some View {
        let items = model.today
        if items.isEmpty {
            if model.meetings.isEmpty {
                Text("Press record when your next meeting starts. Your notes and to-dos will show up here.")
                    .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(CalendarService.shared.eventsAllowed ? "No meetings today. Recent:" : "Recent")
                    .font(.caption).foregroundColor(.secondary)
                recentList
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in timelineRow(item, last: item.id == items.last?.id) }
            }
        }
    }

    func timelineRow(_ item: AppModel.TodayItem, last: Bool) -> some View {
        let phase = item.phase
        let color: Color = phase == .now ? .red : phase == .done ? .green : .secondary
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(color.opacity(phase == .later ? 0.4 : 1)).frame(width: 8, height: 8).padding(.top, 5)
                if !last { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            .frame(width: 10)
            Button {
                if let m = item.meeting { route = .meeting(m.id) }
                else if phase == .now { model.startRecording(title: item.title) }
                else if let e = item.event, !model.brief(for: e).isEmpty { route = .brief(e) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.time.formatted(date: .omitted, time: .shortened)
                         + (phase == .now ? " · now" : item.meeting == nil && phase == .done ? " · not recorded" : ""))
                        .font(.caption).foregroundColor(phase == .now ? .red : .secondary)
                    Text(item.title).font(.callout).lineLimit(1)
                        .foregroundColor(item.meeting == nil && phase == .done ? .secondary : .primary)
                    if let n = item.meeting?.notes, !n.actions.isEmpty {
                        let mine = n.actions.filter { model.isMine($0.owner) }.count
                        Text("\(n.actions.count) to-do\(n.actions.count == 1 ? "" : "s")" + (mine > 0 ? " · \(mine) yours" : ""))
                            .font(.caption).foregroundColor(.secondary)
                    } else if item.meeting.map({ model.isBusy($0.id) }) == true {
                        Text("Creating notes…").font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, last ? 0 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder var recentList: some View {
        let recent = Array(model.meetings.filter { $0.id != model.recordingID }.prefix(5))
        if recent.isEmpty {
            Text("Your meetings will appear here.").font(.callout).foregroundColor(.secondary)
        }
        VStack(spacing: 0) {
            ForEach(recent) { m in
                Button { route = .meeting(m.id) } label: { MeetingRow(meeting: m) }.buttonStyle(.plain)
                if m.id != recent.last?.id { Divider() }
            }
        }
    }

    // MARK: Search, tabs

    @ViewBuilder var searchResults: some View {
        if model.phase == .ready {
            Button { askAI() } label: {
                Label("Ask your meetings: “\(search)”", systemImage: "sparkles").font(.callout).lineLimit(1)
            }
            .buttonStyle(.borderless)
        }
        meetingList
    }

    var footer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search or ask", text: $search)
                    .textFieldStyle(.plain)
                    .onSubmit { askAI() }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider()
            HStack {
                tabButton(.today, icon: "calendar", label: "Today")
                tabButton(.meetings, icon: "list.bullet", label: "Meetings")
                tabButton(.todos, icon: "checklist", label: model.myOpenTodoCount > 0 ? "To-dos · \(model.myOpenTodoCount)" : "To-dos")
            }
            .padding(.vertical, 6)
        }
        .padding(.top, 8)
    }

    func tabButton(_ t: Tab, icon: String, label: String) -> some View {
        Button { tab = t; search = "" } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.caption2)
            }
            .foregroundColor(tab == t && search.isEmpty ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var meetingList: some View {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let past = model.meetings.filter { m in
            m.id != model.recordingID && words.allSatisfy { m.searchText.contains($0) }
        }
        if past.isEmpty {
            Text(search.isEmpty ? "Your meetings will appear here." : "No meeting mentions that. Press ↩ to ask.")
                .font(.callout).foregroundColor(.secondary)
        }
        VStack(spacing: 0) {
            ForEach(past) { m in
                Button { route = .meeting(m.id) } label: { MeetingRow(meeting: m) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { route = .meeting(m.id) }
                        Button("Open in a window") { Windows.showMeeting(m.id, model: model) }
                        Button("Email the notes…") { model.emailNotes(m.id) }.disabled(m.notes == nil)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = m }
                            .disabled(model.isBusy(m.id) || m.id == model.recordingID)
                    }
                if m.id != past.last?.id { Divider() }
            }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let d = deleting { model.delete(d.id) } }
        } message: {
            Text("The notes, transcript and audio go to the Trash.")
        }
    }

    @ViewBuilder var todoList: some View {
        let mine = model.todos(mineOnly: true).filter { !$0.done }.sorted {
            ($0.item.dueDay ?? .distantFuture, $1.meeting.date) < ($1.item.dueDay ?? .distantFuture, $0.meeting.date)
        }
        if mine.isEmpty {
            Text(model.settings.myName.isEmpty ? "Set your name in Settings to see your to-dos." : "Nothing open. Nice.")
                .font(.callout).foregroundColor(.secondary)
        }
        VStack(spacing: 0) {
            ForEach(mine.prefix(8)) { ref in
                Button { model.toggleDone(ref.meeting.id, ref.index) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle").foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ref.item.task).font(.callout).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                DueBadge(item: ref.item, done: false)
                                Text(ref.meeting.title).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Open the meeting") { route = .meeting(ref.meeting.id) } }
                if ref.id != mine.prefix(8).last?.id { Divider() }
            }
        }
        Button("See all to-dos") { route = .todos }.buttonStyle(.borderless).font(.caption)
    }

    func askAI() {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty, model.phase == .ready else { return }
        model.ask(search)
        route = .ask
    }

    func jobCard(_ job: Job) -> some View {
        Card {
            HStack {
                Text(jobTitle(job)).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if !model.queue.isEmpty { Text("+\(model.queue.count) waiting").font(.caption2).foregroundColor(.secondary) }
            }
            JobProgress()
        }
    }

    func jobTitle(_ job: Job) -> String {
        switch job {
        case .process(let id): return "Processing “\(model.meeting(id)?.title ?? "meeting")”"
        case .processFile(let url): return "Processing \(url.lastPathComponent)"
        case .rename(let id, _), .resummarize(let id): return "Updating “\(model.meeting(id)?.title ?? "meeting")”"
        case .ask(let q): return "Answering “\(q)”"
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
