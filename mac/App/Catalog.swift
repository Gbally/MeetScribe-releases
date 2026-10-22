// Hardware detection + the catalog of tested AI models, so each Mac gets models that fit it.
// The catalog ships inside the app and is refreshed weekly from the public releases repo.

import Foundation

struct Hardware {
    var chip: String
    var memoryGB: Int
    var freeDiskGB: Int

    static let current: Hardware = {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Hardware(chip: sysctlString("machdep.cpu.brand_string"),
                        memoryGB: Int((Double(mem) / 1_073_741_824).rounded()),
                        freeDiskGB: Int(Double(free) / 1e9))
    }()

    var summary: String { "\(chip) · \(memoryGB) GB memory · \(freeDiskGB) GB free" }
    var localizedSummary: String { tr("%@ · %@ GB memory · %@ GB free", chip, "\(memoryGB)", "\(freeDiskGB)") }
}

struct CatalogModel: Codable, Identifiable, Hashable {
    var id: String
    var repo: String
    var name: String
    var sizeGB: Double
    var minRamGB: Int
    var recommendedRamGB: Int
    var quality: Int
    var speed: Int
    var license: String
    var tested: String?
    var description: String
    var descriptions: [String: String]? = nil   // translations, e.g. {"fr": "…"}

    var localizedDescription: String {
        let lang = AppLanguage.current
        return descriptions?[lang] ?? descriptions?[String(lang.prefix(2))] ?? tr(description)
    }

    enum CodingKeys: String, CodingKey {
        case id, repo, name, license, tested, description, descriptions, quality, speed
        case sizeGB = "size_gb", minRamGB = "min_ram_gb", recommendedRamGB = "recommended_ram_gb"
    }

    func fits(_ hw: Hardware) -> Bool { hw.memoryGB >= minRamGB }
}

struct ModelCatalog: Codable {
    var version: Int
    var updated: String
    var notes: [CatalogModel]
    var speech: [CatalogModel]

    /// Best quality that runs comfortably on this Mac (then the fastest, then the smallest).
    static func recommended(_ list: [CatalogModel], for hw: Hardware) -> CatalogModel? {
        let comfortable = list.filter { $0.recommendedRamGB <= hw.memoryGB }
        let pool = comfortable.isEmpty ? list.filter { $0.fits(hw) } : comfortable
        return (pool.isEmpty ? list : pool).max { a, b in
            (a.quality, a.speed, -a.sizeGB) < (b.quality, b.speed, -b.sizeGB)
        }
    }

    // MARK: - Loading

    static var cacheFile: URL { Engine.support.appendingPathComponent("models.json") }
    static var bundled: URL? { Bundle.main.url(forResource: "models", withExtension: "json") }

    /// The newer of the bundled catalog and the last downloaded one.
    static func load() -> ModelCatalog {
        let candidates = [cacheFile, bundled].compactMap { $0 }.compactMap { url -> ModelCatalog? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ModelCatalog.self, from: data)
        }
        return candidates.max { ($0.version, $0.updated) < ($1.version, $1.updated) }
            ?? ModelCatalog(version: 0, updated: "", notes: [], speech: [])
    }

    /// Downloads the latest catalog; returns it if it parsed.
    static func refresh() async -> ModelCatalog? {
        guard let url = Releases.url("models.json") else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else { return nil }
        try? data.write(to: cacheFile, options: .atomic)
        return catalog
    }
}

/// Where releases (latest.json, models.json, installers) are published.
enum Releases {
    static var repo: String { Bundle.main.object(forInfoDictionaryKey: "MSReleasesRepo") as? String ?? "" }

    static func url(_ file: String) -> URL? {
        repo.isEmpty ? nil : URL(string: "https://raw.githubusercontent.com/\(repo)/main/\(file)")
    }

    static var pageURL: URL? { repo.isEmpty ? nil : URL(string: "https://github.com/\(repo)/releases") }
}

/// What we can tell about a model the user pasted (any Hugging Face repo), before using it.
struct CustomModelCheck: Equatable {
    var repo: String
    var sizeGB: Double = 0
    var isMLX = false
    var pipeline = ""
    var error: String?
    /// The engine's verdict (reads the model's config): true / false / nil = couldn't tell.
    var compatible: Bool?
    var compatibilityReason = ""

    /// "https://huggingface.co/org/name/tree/main" or "org/name" → "org/name".
    static func repoID(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "huggingface.co/") { s = String(s[r.upperBound...]) }
        let parts = s.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2, parts[0] != "api", parts[0] != "spaces", parts[0] != "datasets" else { return nil }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts[0].unicodeScalars.allSatisfy(ok.contains), parts[1].unicodeScalars.allSatisfy(ok.contains) else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    static func inspect(_ input: String) async -> CustomModelCheck {
        guard let repo = repoID(from: input),
              let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else {
            return CustomModelCheck(repo: input, error: tr("That doesn't look like a Hugging Face model link (huggingface.co/organisation/model)."))
        }
        guard let (data, resp) = try? await URLSession.shared.data(from: url) else {
            return CustomModelCheck(repo: repo, error: tr("Couldn't reach Hugging Face. Check your internet connection."))
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CustomModelCheck(repo: repo, error: tr("No public model called “%@” on Hugging Face.", repo))
        }
        let siblings = json["siblings"] as? [[String: Any]] ?? []
        let bytes = siblings.compactMap { $0["size"] as? Double }.reduce(0, +)
        let tags = (json["tags"] as? [String] ?? []).map { $0.lowercased() }
        return CustomModelCheck(repo: repo, sizeGB: bytes / 1e9,
                                isMLX: tags.contains("mlx") || (json["library_name"] as? String) == "mlx",
                                pipeline: json["pipeline_tag"] as? String ?? "")
    }

    /// Plain-language risks of using this model.
    func warnings(speech: Bool, hw: Hardware) -> [String] {
        var w = [speech ? tr("Not tested with MeetNouse: transcripts may be less accurate or slower.")
                        : tr("Not tested with MeetNouse: notes may come out in the wrong format, slowly, or not at all.")]
        if compatible == nil {
            if !isMLX { w.append(tr("It isn't in MLX format (made for Apple silicon) — it may not load. Look for a version from “mlx-community”.")) }
            if speech && pipeline != "automatic-speech-recognition" { w.append(tr("It doesn't look like a speech-to-text model.")) }
            if !speech && !["text-generation", "image-text-to-text", ""].contains(pipeline) {
                w.append(tr("It doesn't look like a text model (it's “%@”).", pipeline))
            }
        } else if !speech && !isMLX {
            w.append(tr("It isn't converted for Apple silicon (MLX): it will be larger and slower than an mlx-community version."))
        }
        if sizeGB > Double(hw.memoryGB) * 0.6 {
            w.append(tr("It's %@ GB and this Mac has %@ GB of memory — it will probably run out of memory.",
                        String(format: "%.1f", sizeGB), "\(hw.memoryGB)"))
        }
        if sizeGB > Double(hw.freeDiskGB) - 5 { w.append(tr("There isn't enough free disk space for it.")) }
        return w
    }

    /// Asks the engine whether it can run this model as a notes or speech model.
    mutating func checkCompatibility(speech: Bool) async {
        var verdict: [String: Any]?
        _ = await Engine.meetscribe(["models", "check", repo, "--kind", speech ? "speech" : "notes"]) { line in
            if line.hasPrefix("@@result "), let data = line.dropFirst(9).data(using: .utf8) {
                verdict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }
        compatible = verdict?["compatible"] as? Bool
        // The engine sends an English sentence plus its translatable form (key + args).
        if let key = verdict?["key"] as? String {
            let args = (verdict?["args"] as? [String]) ?? []
            compatibilityReason = args.isEmpty ? tr(key) : String(format: tr(key), arguments: args.map { $0 as CVarArg })
        } else {
            compatibilityReason = verdict?["reason"] as? String ?? ""
        }
    }

    func asCatalogModel() -> CatalogModel {
        CatalogModel(id: "custom", repo: repo, name: repo.components(separatedBy: "/").last ?? repo, sizeGB: sizeGB,
                     minRamGB: 0, recommendedRamGB: 0, quality: 0, speed: 0, license: "", tested: nil,
                     description: "Custom model")
    }
}
