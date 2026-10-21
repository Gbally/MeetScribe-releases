import SwiftUI

@main
struct MeetScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon: waveform when idle, ● + timer while recording, hourglass while processing.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isRecording {
            Text("\(Image(systemName: "record.circle.fill")) \(formatDuration(model.elapsed))")
                .monospacedDigit()
        } else if model.currentJob != nil || model.phase == .settingUp {
            Image(systemName: "hourglass")
        } else {
            Image(systemName: "waveform")
        }
    }
}
