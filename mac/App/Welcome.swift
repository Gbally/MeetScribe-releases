// First launch: a short guided setup in its own window. The models start downloading on the first
// page, so the person fills in their name, languages and permissions while it runs.

import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var close: () -> Void
    @State var step = 0
    @State private var language = AppLanguage.forced
    @State private var screenAsked = false
    @State private var notifications = UNAuthorizationStatus.notDetermined
    @State private var tick = 0 // redraws permission states that aren't published (calendar)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.primary.opacity(0.12)).frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case 0: intro
                    case 1: about
                    case 2: permissions
                    default: ready
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if step > 0 { download.padding(.horizontal, 28).padding(.bottom, 10) }
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 0 {
                    Button("Get started") {
                        if model.phase == .needsSetup { model.runSetup() }
                        step = 1
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else if step < steps - 1 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 540, height: 600)
        .environment(\.locale, AppLanguage.locale)
        .id(model.uiLanguage)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    // MARK: Pages

    @ViewBuilder var intro: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
        Text("Welcome to MeetNouce").font(.largeTitle.weight(.semibold))
        Text("Meeting notes that never leave your Mac.").font(.title3).foregroundColor(.secondary)
        VStack(alignment: .leading, spacing: 12) {
            point("Records Teams, Zoom and Meet calls — your voice and the other participants'.", icon: "waveform")
            point("Writes a transcript with who said what, then a summary, decisions and to-dos.", icon: "person.2")
            point("Everything runs on this Mac: no account, no cloud, no subscription.", icon: "lock")
        }
        .padding(.vertical, 6)
        Picker("App language", selection: Binding(get: { language }, set: { language = $0; model.setLanguage($0) })) {
            Text(tr("Same as the Mac") + " (" + languageName(Locale.preferredLanguages.first ?? "en") + ")").tag("")
            ForEach(AppLanguage.supported, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
        }
        .frame(maxWidth: 360)
        Text(tr("Next, MeetNouce downloads its AI models, picked for this Mac (%@): %@. It takes 10–20 minutes — you can finish the setup meanwhile.",
                Hardware.current.chip + ", \(Hardware.current.memoryGB) GB", modelSummary))
            .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var about: some View {
        title("About you", subtitle: "So MeetNouce knows which voice is yours and which to-dos are for you.")
        TextField("Your name", text: $model.settings.myName).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
        Caption("As colleagues say it in meetings — usually your first name.")
        Divider()
        LanguagesSection()
        Divider()
        Picker("Write the notes in", selection: $model.settings.notesLanguage) {
            Text("Same as the meeting").tag("auto")
            ForEach(meetingLanguages, id: \.code) { Text(languageName($0.code)).tag($0.name) }
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder var permissions: some View {
        title("Permissions", subtitle: "macOS asks you once for each. MeetNouce only listens while you record.")
        permission("Microphone", detail: "To record your voice.", icon: "mic.fill",
                   state: model.micPermission == .authorized ? .allowed : model.micPermission == .notDetermined ? .ask : .denied) {
            Task {
                if model.micPermission == .notDetermined { _ = await MicCapture.requestPermission() }
                else { openPrivacy("Privacy_Microphone") }
                model.refreshPermissions()
            }
        }
        permission("Screen & System Audio Recording", detail: "To hear the other participants. MeetNouce records sound only, never the screen.", icon: "speaker.wave.2.fill",
                   state: model.screenPermission ? .allowed : screenAsked ? .denied : .ask) {
            screenAsked = true
            if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
        }
        if screenAsked && !model.screenPermission {
            Caption("Turned it on in System Settings? macOS applies it after MeetNouce restarts — a button appears in the menu bar window once the download is done.")
        }
        permission("Calendar (optional)", detail: "Names meetings and their attendees, and reminds you of open to-dos before the next one.", icon: "calendar",
                   state: CalendarService.shared.eventsAllowed ? .allowed : CalendarService.shared.eventsUndecided ? .ask : .denied) {
            model.settings.useCalendar = true
            model.allowCalendar()
        }
        permission("Notifications (optional)", detail: "Tells you when notes are ready, and offers to record when a call starts.", icon: "bell.fill",
                   state: [.authorized, .provisional].contains(notifications) ? .allowed : notifications == .notDetermined ? .ask : .denied) {
            if notifications == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    DispatchQueue.main.async { refresh() }
                }
            } else {
                model.openNotificationSettings()
            }
        }
        let _ = tick
    }

    @ViewBuilder var ready: some View {
        title("You're all set", subtitle: "MeetNouce lives in the menu bar, at the top right of the screen.")
        HStack(spacing: 10) {
            Image(nsImage: DogFace.menuBarImage).frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            Text("Click this icon in the menu bar, then the red button when a meeting starts. Your notes appear there when it ends.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        Form {
            LabeledContent("Start / stop recording") { HotkeyField(hotkey: $model.settings.hotkey) }
            Toggle("Record calls automatically", isOn: $model.settings.autoRecord)
            Toggle("Open MeetNouce at login", isOn: $model.launchAtLogin)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 170)
        Caption("Everything else — where notes are saved, meeting types, AI models — is in Settings (gear icon).")
    }

    // MARK: Download status

    @ViewBuilder var download: some View {
        switch model.phase {
        case .settingUp:
            VStack(alignment: .leading, spacing: 4) {
                if let p = model.setupProgress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                HStack {
                    Text(model.setupStatus).lineLimit(1)
                    Spacer()
                    if let p = model.setupProgress { Text(verbatim: "\(Int(p * 100)) %").monospacedDigit() }
                }
                .font(.caption).foregroundColor(.secondary)
            }
        case .needsSetup:
            HStack {
                Label(model.setupError == nil ? tr("The AI models aren't downloaded yet.") : tr("The download failed."),
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                Spacer()
                Button(model.setupError == nil ? tr("Download") : tr("Try again")) { model.runSetup() }.controlSize(.small)
            }
        case .ready:
            Label("AI models ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bits

    enum PermissionState { case allowed, ask, denied }

    func permission(_ name: String, detail: String, icon: String, state: PermissionState,
                    action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(.accentColor).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(name)).font(.callout.weight(.medium))
                Text(tr(detail)).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .allowed: Label("Allowed", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
            case .ask: Button("Allow…", action: action).controlSize(.small)
            case .denied: Button("Open Settings…", action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    func point(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(.accentColor)
            Text(tr(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder func title(_ text: String, subtitle: String) -> some View {
        Text(tr(text)).font(.title.weight(.semibold))
        Text(tr(subtitle)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var modelSummary: String {
        let all = model.catalog.notes + model.catalog.speech
        let picked = [model.notesModel, model.speechModel].compactMap { repo in all.first { $0.repo == repo } }
        let gb = picked.map(\.sizeGB).reduce(0, +)
        let names = picked.map(\.name).joined(separator: " + ")
        return gb > 0 ? "\(names) (\(String(format: "%.1f", gb)) GB)" : names
    }

    func refresh() {
        model.refreshPermissions()
        tick += 1
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { notifications = s.authorizationStatus }
        }
    }

    func openPrivacy(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
