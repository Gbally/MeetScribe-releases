import SwiftUI
import UserNotifications

@main
struct HesperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(delegate.model).tint(Brand.accent)
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

    /// `open -a Hesper --args --settings models` opens Settings on that tab (for testing).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }  // screenshots
        if let i = args.firstIndex(of: "--settings") {
            let tab = i + 1 < args.count ? SettingsTab(rawValue: args[i + 1]) : nil
            Windows.showSettings(model, tab: tab)
        }
        if args.contains("--preview") { Windows.showPreview(model) }
        // Testing: --welcome [page]
        if let i = args.firstIndex(of: "--welcome") {
            Windows.showWelcome(model, step: i + 1 < args.count ? Int(args[i + 1]) ?? 0 : 0)
        } else if model.shouldWelcome {
            Windows.showWelcome(model)
        }
        // Testing: switch language while running, e.g. --switch-language fr
        if let i = args.firstIndex(of: "--switch-language"), i + 1 < args.count {
            let code = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.model.setLanguage(code) }
        }
        if let i = args.firstIndex(of: "--meeting"), i + 1 < args.count {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Windows.showMeeting(id, model: self.model) }
        }
        // Testing: --snapshot DIR saves each open window as a PNG (the app draws its own views: no
        // screen-recording permission), plus the menu-bar icons, then quits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                func save(_ rep: NSBitmapImageRep?, _ name: String) {
                    if let data = rep?.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent(name)) }
                }
                for (n, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    save(rep, "window-\(n)-\(w.title.replacingOccurrences(of: "/", with: "-")).png")
                }
                for (name, img) in [("idle", MenuBarIcon.idle), ("processing", MenuBarIcon.processing(0.4)), ("recording", MenuBarIcon.recording)] {
                    let big = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { r in img.draw(in: r); return true }
                    save(big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), "menubar-\(name).png")
                }
                NSApp.terminate(nil)
            }
        }
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
            // Not a template image: the red dot means the mic is on, it must stay red.
            Text("\(Image(nsImage: MenuBarIcon.recording)) \(formatDuration(model.elapsed))")
                .monospacedDigit()
        } else if model.currentJob != nil {
            if let p = model.jobProgress {
                Text("\(Image(nsImage: MenuBarIcon.processing(p))) \(Int(p * 100))%").monospacedDigit()
            } else {
                Image(nsImage: MenuBarIcon.processing(nil))
            }
        } else if model.phase == .settingUp {
            Image(nsImage: MenuBarIcon.processing(model.setupProgress))
        } else {
            Image(nsImage: MenuBarIcon.idle)
        }
    }
}
