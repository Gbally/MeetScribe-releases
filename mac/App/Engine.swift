// Runs the Python engine (bundled in the app) in its own environment under
// ~/Library/Application Support/MeetScribe. The first launch installs Python + packages with
// the bundled `uv`, then downloads the models; after that everything works offline.

import Foundation

enum Engine {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("MeetScribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var engineSource: URL { Bundle.main.resourceURL!.appendingPathComponent("engine") }
    static var uv: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/uv") }
    static var venv: URL { support.appendingPathComponent("venv") }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var configFile: URL { support.appendingPathComponent("config.toml") }
    private static var marker: URL { support.appendingPathComponent("installed-version") }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] ?? "0")+\(info?["CFBundleVersion"] ?? "0")"
    }

    /// True when Python, packages and models for this app version are in place.
    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: python.path),
              let v = try? String(contentsOf: marker) else { return false }
        return v == appVersion
    }

    static func markInstalled() { try? appVersion.write(to: marker, atomically: true, encoding: .utf8) }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MEETSCRIBE_HOME"] = support.path
        env["PYTHONPATH"] = engineSource.appendingPathComponent("src").path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1" // never write into the (signed) app bundle
        env["UV_PROJECT_ENVIRONMENT"] = venv.path
        env["UV_PYTHON_INSTALL_DIR"] = support.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = support.appendingPathComponent("uv-cache").path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    struct Result {
        var ok: Bool
        var errorTail: String
    }

    /// Runs a process, calling `onLine` (main thread) for each stdout line. Cancellable.
    static func run(_ exe: URL, _ args: [String], onLine: @escaping (String) -> Void) async -> Result {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = support
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let errLines = LineBuffer()
        let outLines = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let lines = outLines.feed(h.availableData)
            if !lines.isEmpty { DispatchQueue.main.async { lines.forEach(onLine) } }
        }
        err.fileHandleForReading.readabilityHandler = { h in _ = errLines.feed(h.availableData) }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    let rest = outLines.feed(out.fileHandleForReading.readDataToEndOfFile()) + outLines.flush()
                    _ = errLines.feed(err.fileHandleForReading.readDataToEndOfFile())
                    _ = errLines.flush()
                    DispatchQueue.main.async { rest.forEach(onLine) }
                    let tail = errLines.recent.filter { !$0.hasPrefix("Fetching") && !$0.contains("Warning") }
                        .suffix(6).joined(separator: "\n")
                    log("\(exe.lastPathComponent) \(args.prefix(2).joined(separator: " ")) → exit \(p.terminationStatus)"
                        + (p.terminationStatus == 0 ? "" : "\n" + errLines.recent.suffix(20).joined(separator: "\n")))
                    cont.resume(returning: Result(ok: p.terminationStatus == 0, errorTail: tail))
                }
                do { try process.run() } catch {
                    log("could not start \(exe.path): \(error.localizedDescription)")
                    cont.resume(returning: Result(ok: false, errorTail: error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Appends to ~/Library/Application Support/MeetScribe/engine.log (kept under ~1 MB).
    static func log(_ message: String) {
        let url = support.appendingPathComponent("engine.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func meetscribe(_ args: [String], onLine: @escaping (String) -> Void) async -> Result {
        await run(python, ["-m", "meetscribe"] + args, onLine: onLine)
    }

    /// Writes the user's settings where the Python engine reads them.
    static func writeConfig(_ s: AppSettings) {
        func q(_ v: String) -> String {
            "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let toml = """
        notes_dir = \(q(s.notesFolder.path))
        me = \(q(s.myName.isEmpty ? "Me" : s.myName))
        language = \(q(s.languages.joined(separator: ",")))
        summary_language = \(q(s.notesLanguage))
        vocabulary = \(q(s.vocabulary))
        summary_style = \(q(s.summaryStyle.rawValue))
        template = \(q(s.defaultTemplate))

        """
        try? toml.write(to: configFile, atomically: true, encoding: .utf8)
    }
}

/// Splits a byte stream into lines; keeps the last lines for error reports.
final class LineBuffer {
    private var pending = Data()
    private(set) var recent: [String] = []
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        remember(lines)
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        remember([line])
        return [line]
    }

    private func remember(_ lines: [String]) {
        recent.append(contentsOf: lines.filter { !$0.isEmpty })
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
    }
}
