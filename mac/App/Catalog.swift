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

    enum CodingKeys: String, CodingKey {
        case id, repo, name, license, tested, description, quality, speed
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
