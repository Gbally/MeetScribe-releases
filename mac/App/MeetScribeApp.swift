import SwiftUI
import UserNotifications

@main
struct MeetScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(delegate.model)
        } label: {
            MenuBarLabel().environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// `open -a MeetScribe --args --settings models` opens Settings on that tab (for testing).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--settings") {
            let tab = i + 1 < args.count ? SettingsTab(rawValue: args[i + 1]) : nil
            Windows.showSettings(model, tab: tab)
        }
        if args.contains("--preview") { Windows.showPreview(model) }
    }

    // Show our banners even while the app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // "Record" / "Stop & create notes" buttons.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let meeting = response.notification.request.content.userInfo["meeting"] as? String
        let isUpdate = response.notification.request.content.userInfo["action"] as? String == "update"
        Task { @MainActor in
            if isUpdate { Windows.showSettings(self.model, tab: .about) }
            else { self.model.handleNotificationAction(action, meeting: meeting) }
            completionHandler()
        }
    }
}

/// The menu bar icon: waveform when idle, ● + timer while recording, hourglass while processing.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Text("\(Image(systemName: "record.circle.fill")) \(formatDuration(model.elapsed))")
                .monospacedDigit()
        } else if model.currentJob != nil {
            if let p = model.jobProgress {
                Text("\(Image(systemName: "hourglass")) \(Int(p * 100))%").monospacedDigit()
            } else {
                Image(systemName: "hourglass")
            }
        } else if model.phase == .settingUp {
            Image(systemName: "hourglass")
        } else {
            Image(systemName: "waveform")
        }
    }
}
