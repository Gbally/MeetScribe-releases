// meeting-recorder — command-line front end to the shared capture engine (used by
// `meetscribe record`). Records until Ctrl+C.
//
//   meeting-recorder <output-dir> [--app "Microsoft Teams"] [--no-mic] [--no-system]

import Foundation

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

var signalSources: [DispatchSourceSignal] = []

@main
struct RecorderCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func flag(_ name: String) -> Bool {
            if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
            return false
        }
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
        }
        let appName = option("--app")
        let noMic = flag("--no-mic")
        let noSystem = flag("--no-system")
        guard let outDir = args.first else {
            log("usage: meeting-recorder <output-dir> [--app NAME] [--no-mic] [--no-system]")
            exit(2)
        }

        let recorder = MeetingRecorder(folder: URL(fileURLWithPath: outDir))
        recorder.onNotice = { log("⚠️  \($0)") }
        do {
            try await recorder.start(appName: appName, captureMic: !noMic, captureSystem: !noSystem)
        } catch {
            log("❌ Nothing could be recorded.")
            exit(1)
        }
        log("🔴 Recording… press Ctrl+C to stop.")

        let status = DispatchSource.makeTimerSource(queue: .global())
        status.schedule(deadline: .now() + 5, repeating: 5)
        status.setEventHandler {
            let e = Int(recorder.elapsed)
            func meter(_ w: TrackWriter?) -> String {
                guard let p = w?.takePeak() else { return "off" }
                return p < 0.001 ? "silent" : String(repeating: "▮", count: max(1, min(10, Int(p * 10) + 1)))
            }
            log(String(format: "  %02d:%02d  mic %@  system %@", e / 60, e % 60,
                       meter(recorder.mic?.writer), meter(recorder.system?.writer)))
        }
        status.resume()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var fired = false
            signalSources = [SIGINT, SIGTERM].map { sig in
                let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                s.setEventHandler { if !fired { fired = true; cont.resume() } }
                s.resume()
                return s
            }
        }

        status.cancel()
        await recorder.stop()
        log(String(format: "⏹  Stopped. mic %.0fs, system %.0fs → %@",
                   recorder.mic?.writer.seconds ?? 0, recorder.system?.writer.seconds ?? 0, outDir))
    }
}
