import AppKit
import AVFoundation
import SwiftUI

struct StorageSection: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: AppSettings?
    @State private var accounts = CloudFolders.oneDriveAccounts

    var body: some View {
        Section("Where notes are saved") {
            Picker("Storage", selection: Binding(get: { model.settings.storage }, set: choose)) {
                Text("This Mac only").tag(Storage.local)
                Text(accounts.isEmpty ? tr("OneDrive (not set up on this Mac)") : "OneDrive").tag(Storage.oneDrive)
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
            if model.settings.storage != .local && model.settings.audioRetentionDays != 0 {
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
            tr("Move your %@ existing meeting(s) to the new location?", "\(model.meetingsInNotesFolder)"),
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
            var s = tr("Stays on this Mac — never uploaded anywhere.")
            if !folder.path.contains("/Documents/") {
                s += " " + tr("(Your Documents folder is synced to the cloud, so notes go in your home folder instead.)")
            }
            return s
        case .oneDrive:
            let name = accounts.first { $0.url.path == model.settings.oneDrivePath }?.name ?? "OneDrive"
            return tr("Synced to %@: backed up, and available on your other devices and on the web. Your company's OneDrive rules apply.", name)
        case .custom:
            return CloudFolders.syncService(for: folder).map { tr("This folder is synced to %@.", $0) } ?? tr("This folder isn't synced to the cloud.")
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
                alert.messageText = tr("OneDrive isn't set up on this Mac")
                alert.informativeText = tr("Install the OneDrive app and sign in with your work account, then choose OneDrive again.")
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
                    Toggle(languageName(lang.code), isOn: Binding(
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
        }
    }

    var languagesHelp: String {
        switch model.settings.languages.count {
        case 0: return tr("None ticked: the language is detected automatically (one per meeting).")
        case 1: return tr("Everything is transcribed as %@.", languageName(model.settings.languages[0]))
        default: return tr("Meetings can switch between these languages — detected every few seconds.")
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
        Section("Known voices") {
            Text("Name the speakers of a meeting (⋯ → Name the speakers) and MeetScribe recognises them next time. Voiceprints stay on this Mac.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.voices.isEmpty {
                Text("No voices learned yet.").font(.caption).foregroundColor(.secondary)
            }
            ForEach(model.voices, id: \.name) { v in
                HStack {
                    Image(systemName: "person.wave.2").foregroundColor(.secondary)
                    Text(v.name).font(.callout)
                    Text(v.samples == 1 ? tr("1 sample") : tr("%@ samples", "\(v.samples)")).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("Forget") { forget = v.name }.controlSize(.small)
                }
            }
        }
        .onAppear { model.reloadVoices() }
        .confirmationDialog(tr("Forget %@'s voice?", forget ?? ""), isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } })) {
            Button("Forget", role: .destructive) { if let f = forget { model.forgetVoice(f) } }
        }
    }
}

struct NotificationsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Notify me") {
            Toggle("When notes are ready", isOn: $model.settings.notifyWhenReady)
            Toggle("When a call starts (“Record this call?”)", isOn: $model.settings.callReminders)
            Toggle("When the calendar meeting is over (“Stop recording?”)", isOn: $model.settings.endReminders)
            Toggle("5 min before a meeting: what's still open from last time", isOn: $model.settings.briefs)
            Toggle("The day before my to-dos are due", isOn: $model.settings.dueReminders)
            if let problem = model.notificationProblem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bell.slash.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button("Turn them on…") { model.openNotificationSettings() }.controlSize(.small)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }
        }
        .onAppear { model.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationStatus()
        }
    }
}

struct EmailSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Email") {
            Picker("Write emails with", selection: $model.settings.emailApp) {
                ForEach(EmailApp.allCases, id: \.self) { Text(tr($0.label)).tag($0) }
            }
            if model.settings.emailApp == .gmail {
                TextField("Gmail address (optional, if you use several)", text: $model.settings.gmailAccount)
                    .textFieldStyle(.roundedBorder)
            }
            if model.settings.emailApp.isWeb {
                Text("The draft opens in your browser, so the notes are sent to that website to create it.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RetentionSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Audio recordings") {
            Picker("Delete audio recordings", selection: $model.settings.audioRetentionDays) {
                ForEach(retentionChoices, id: \.days) { Text(tr($0.label)).tag($0.days) }
            }
            Text("Notes and transcripts are kept. The audio — including the short voice samples used to name speakers — is deleted.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
