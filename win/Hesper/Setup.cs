using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;

namespace Hesper;

/// First launch (and after an update): everything into %LOCALAPPDATA%\Hesper, no admin rights.
/// The engine's source comes inside the exe; uv, llama.cpp and the models are downloaded (uv and
/// llama.cpp at the versions tested, checked by their SHA-256); uv brings Python 3.12.
static class Setup
{
    const string UvUrl = "https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-pc-windows-msvc.zip";
    const string UvSha = "a2a8820d5eea32f08ef467ef3b7f66883a9b076d5737a2fc2fbb5f458d1bb50f";
    const string Llama = "https://github.com/ggml-org/llama.cpp/releases/download/b12532/";
    static readonly (string File, string Sha)[] LlamaCuda =
    [
        ("llama-b12532-bin-win-cuda-12.4-x64.zip", "b7a05a4d20fdd3336746fa1cbf08f3e7f26030593a4e419d7a378757e3d1d213"),
        ("cudart-llama-bin-win-cuda-12.4-x64.zip", "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6"),
    ];
    static readonly (string File, string Sha)[] LlamaCpu =
        [("llama-b12532-bin-win-cpu-x64.zip", "beb8c051a782fb0970d4ae20fa276a6dfd3e7245685b185244a22570e9e473fa")];

    static string Marker => Path.Combine(Paths.Home, "installed-version");
    static string LlamaDir => Path.Combine(Paths.Home, "models", "llama.cpp");
    public static string AppVersion => Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0";

    public static bool IsInstalled =>
        File.Exists(Paths.Python) && File.Exists(Marker) && File.ReadAllText(Marker).Trim() == AppVersion;

    /// An NVIDIA GPU (its driver installs nvidia-smi): the CUDA builds then, else the CPU ones.
    public static bool HasNvidia => File.Exists(Path.Combine(Environment.SystemDirectory, "nvidia-smi.exe"));

    /// Runs every step; report(status, fraction 0..1 or null). Throws with a readable message.
    public static async Task Run(Action<string, double?> report, CancellationToken cancel)
    {
        Directory.CreateDirectory(Paths.Home);
        var gpu = HasNvidia;
        Paths.WriteLog($"setup {AppVersion}, NVIDIA GPU: {gpu}");

        report("Unpacking the engine…", null);
        UnpackEngine();

        if (!File.Exists(Paths.Uv))
        {
            report("Downloading uv…", 0);
            await Fetch(UvUrl, UvSha, Path.GetDirectoryName(Paths.Uv)!, f => report("Downloading uv…", f), cancel);
        }

        report("Installing Python and the engine's packages (a few minutes)…", null);
        var sync = await EngineRunner.Run(Paths.Uv, ["sync", "--frozen", "--python", "3.12", "--project", Paths.Engine, .. gpu ? ["--extra", "cuda"] : Array.Empty<string>()],
                                          null, cancel);
        if (!sync.Ok) throw new InvalidOperationException("Installing the engine failed:\n" + sync.ErrorTail);

        var llama = gpu ? LlamaCuda : LlamaCpu;
        var stamp = Path.Combine(LlamaDir, "build.txt");
        var want = string.Join(",", llama.Select(l => l.File));
        if (!File.Exists(stamp) || File.ReadAllText(stamp) != want)
        {
            if (Directory.Exists(LlamaDir)) Directory.Delete(LlamaDir, true);
            for (var i = 0; i < llama.Length; i++)
            {
                var label = $"Downloading llama.cpp ({(gpu ? "NVIDIA GPU" : "CPU")})…";
                var (k, n) = (i, llama.Length);
                await Fetch(Llama + llama[i].File, llama[i].Sha, LlamaDir, f => report(label, (k + f) / n), cancel);
            }
            File.WriteAllText(stamp, want);
        }

        report("Downloading the models…", 0);
        string step = "Downloading the models…";
        var models = await EngineRunner.Hesper(["setup"], line =>
        {
            var (s, p) = EngineRunner.Parse(line);
            if (s != null) step = s;
            if (s != null || p != null) report(step, p);
        }, cancel);
        if (!models.Ok) throw new InvalidOperationException("Downloading the models failed:\n" + models.ErrorTail);

        File.WriteAllText(Marker, AppVersion);
        report("Ready", 1);
    }

    /// The engine's source (src/hesper, pyproject.toml, uv.lock), embedded in the exe as engine.zip.
    static void UnpackEngine()
    {
        using var zip = Assembly.GetExecutingAssembly().GetManifestResourceStream("engine.zip")
            ?? throw new InvalidOperationException("This build has no engine inside.");
        var src = Path.Combine(Paths.Engine, "src");
        if (Directory.Exists(src)) Directory.Delete(src, true);  // files removed in this version mustn't linger
        ZipFile.ExtractToDirectory(zip, Paths.Engine, overwriteFiles: true);
    }

    /// Downloads a zip, checks its SHA-256, unpacks it into dest.
    static async Task Fetch(string url, string sha256, string dest, Action<double> progress, CancellationToken cancel)
    {
        var tmp = Path.Combine(Paths.Home, "download.part");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) })
        using (var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel))
        {
            response.EnsureSuccessStatusCode();
            var size = response.Content.Headers.ContentLength ?? 0;
            await using var from = await response.Content.ReadAsStreamAsync(cancel);
            await using var to = File.Create(tmp);
            var buffer = new byte[1 << 20];
            long got = 0;
            int n;
            while ((n = await from.ReadAsync(buffer, cancel)) > 0)
            {
                await to.WriteAsync(buffer.AsMemory(0, n), cancel);
                got += n;
                if (size > 0) progress((double)got / size);
            }
        }
        string actual;
        await using (var f = File.OpenRead(tmp))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(f, cancel)).ToLowerInvariant();
        if (actual != sha256)
        {
            File.Delete(tmp);
            throw new InvalidOperationException($"{Path.GetFileName(url)} isn't the expected file (SHA-256 {actual}).");
        }
        Directory.CreateDirectory(dest);
        ZipFile.ExtractToDirectory(tmp, dest, overwriteFiles: true);
        File.Delete(tmp);
    }
}
