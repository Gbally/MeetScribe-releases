using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hesper;

/// This PC: its NVIDIA GPU (name, memory) if it has one, and its RAM.
static class Hardware
{
    static (string Name, double VramGB)? gpu;
    static bool probed;

    public static (string Name, double VramGB)? Gpu
    {
        get
        {
            if (probed) return gpu;
            probed = true;
            var smi = Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe");
            if (!File.Exists(smi)) return gpu = null;
            try
            {
                using var p = Process.Start(new ProcessStartInfo(smi, "--query-gpu=name,memory.total --format=csv,noheader,nounits")
                    { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
                var line = p.StandardOutput.ReadLine() ?? "";
                p.WaitForExit(5000);
                var i = line.LastIndexOf(',');
                if (i > 0 && double.TryParse(line[(i + 1)..].Trim(), System.Globalization.CultureInfo.InvariantCulture, out var mib))
                    gpu = (line[..i].Trim(), mib / 1024);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { }
            return gpu;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MemoryStatus { public uint Length, Load; public ulong Total, Avail, PageTotal, PageAvail, VirtTotal, VirtAvail, ExtAvail; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MemoryStatus s);

    public static double RamGB
    {
        get { var s = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() }; return GlobalMemoryStatusEx(ref s) ? s.Total / 1073741824.0 : 8; }
    }

    public static string Summary =>
        (Gpu is { } g ? $"{g.Name} ({g.VramGB:0} GB) · " : "") + $"{Math.Round(RamGB):0} GB RAM";
}

/// The models tested with Hesper: catalog/models.json's "windows" section (GGUF notes models for
/// llama.cpp, faster-whisper speech models). The copy inside the exe, or a newer one downloaded.
sealed class Catalog
{
    public record Model(string Id, string Repo, string Name, double SizeGB, double MinVramGB, double MinRamGB, int Quality, int Speed,
                        string? Tested, string Description, Dictionary<string, string> Descriptions);

    public string Updated { get; init; } = "";
    public List<Model> Notes { get; init; } = [];
    public List<Model> Speech { get; init; } = [];

    static string CacheFile => Path.Combine(Paths.Home, "models.json");
    const string Url = "https://raw.githubusercontent.com/Gbally/Hesper/main/models.json";

    static Catalog? Parse(string json)
    {
        try
        {
            var d = JsonNode.Parse(json)!;
            if (d["windows"] is not JsonObject w) return null;
            List<Model> List(string key) => (w[key] as JsonArray ?? []).Select(m => new Model(
                m!["id"]!.GetValue<string>(), m["repo"]!.GetValue<string>(), m["name"]!.GetValue<string>(),
                m["size_gb"]?.GetValue<double>() ?? 0, m["min_vram_gb"]?.GetValue<double>() ?? 0, m["min_ram_gb"]?.GetValue<double>() ?? 0,
                m["quality"]?.GetValue<int>() ?? 0, m["speed"]?.GetValue<int>() ?? 0, m["tested"]?.GetValue<string>(),
                m["description"]?.GetValue<string>() ?? "",
                m["descriptions"]?.Deserialize<Dictionary<string, string>>() ?? [])).ToList();
            return new Catalog { Updated = d["updated"]?.GetValue<string>() ?? "", Notes = List("notes"), Speech = List("speech") };
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NullReferenceException) { return null; }
    }

    /// The newer of the bundled catalog and the last downloaded one.
    public static Catalog Load()
    {
        using var s = typeof(Catalog).Assembly.GetManifestResourceStream("models.json");
        var bundled = s == null ? null : Parse(new StreamReader(s).ReadToEnd());
        var cached = File.Exists(CacheFile) ? Parse(File.ReadAllText(CacheFile)) : null;
        return new[] { bundled, cached }.OfType<Catalog>().MaxBy(c => c.Updated) ?? new Catalog();
    }

    /// Fetches the published catalog (once a day is enough; failures are quiet).
    public static async Task Refresh()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var json = await http.GetStringAsync(Url);
            if (Parse(json) != null) await File.WriteAllTextAsync(CacheFile, json);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException) { }
    }

    public static bool Fits(Model m) => Hardware.Gpu is { } g ? m.MinVramGB + 0 <= g.VramGB || m.MinRamGB <= Hardware.RamGB : m.MinRamGB <= Hardware.RamGB;

    /// The best tested model that fits this PC: in the GPU's memory (1.5 GB to spare) when there's
    /// an NVIDIA GPU, else in RAM; then the fastest, then the smallest.
    public Model? Recommended(bool speech)
    {
        var list = speech ? Speech : Notes;
        var fits = list.Where(m => Hardware.Gpu is { } g ? m.MinVramGB + 1.5 <= g.VramGB : m.MinRamGB <= Hardware.RamGB).ToList();
        if (fits.Count == 0) fits = list.Where(m => m.MinRamGB <= Hardware.RamGB).ToList();
        // Only models measured with Hesper are recommended; the others are offered, at the user's choice
        return (fits.Count > 0 ? fits : list).OrderByDescending(m => m.Tested != null).ThenByDescending(m => m.Quality)
                                              .ThenByDescending(m => m.Speed).ThenBy(m => m.SizeGB).FirstOrDefault();
    }

    public JsonObject ToJson(string lang) => new()
    {
        ["updated"] = Updated,
        ["notes"] = Json(Notes, lang),
        ["speech"] = Json(Speech, lang),
        ["recommendedNotes"] = Recommended(false)?.Repo,
        ["recommendedSpeech"] = Recommended(true)?.Repo,
        ["hardware"] = Hardware.Summary,
    };

    static JsonArray Json(List<Model> list, string lang) => new(list.Select(m => (JsonNode)new JsonObject
    {
        ["repo"] = m.Repo, ["name"] = m.Name, ["size"] = m.SizeGB, ["tested"] = m.Tested, ["fits"] = Fits(m),
        ["quality"] = m.Quality, ["speed"] = m.Speed,
        ["description"] = m.Descriptions.TryGetValue(lang, out var d) ? d : m.Description,
    }).ToArray());
}
