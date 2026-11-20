using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Hesper;

/// Runs the Python engine (python -m hesper …) with Hesper's environment, and reads its progress
/// lines: "@@step {"key": "Transcribing (%@ min)", "args": ["9"]}" and "@@progress 0.42".
static class EngineRunner
{
    /// OutOfMemory: the errors show a model didn't fit (in the GPU's memory or the PC's).
    public record Result(bool Ok, string ErrorTail, bool OutOfMemory = false);

    /// What Python, CUDA and llama.cpp print when a model doesn't fit in memory.
    static readonly string[] MemorySigns = ["out of memory", "OutOfMemory", "MemoryError", "cudaMalloc", "failed to allocate", "Insufficient Memory", "Not enough memory"];

    public static Dictionary<string, string?> Environment()
    {
        var site = Path.Combine(Paths.Venv, "Lib", "site-packages", "nvidia");
        // faster-whisper's CUDA libraries (cuBLAS, cuDNN) come as wheels: their DLLs must be on PATH
        var cuda = new[] { "cublas", "cudnn", "cuda_nvrtc" }.Select(p => Path.Combine(site, p, "bin")).Where(Directory.Exists);
        return new()
        {
            ["HESPER_HOME"] = Paths.Home,
            ["HF_HOME"] = Path.Combine(Paths.Home, "hf"),
            ["PYTHONPATH"] = Path.Combine(Paths.Engine, "src"),
            ["PYTHONUNBUFFERED"] = "1",
            ["PYTHONUTF8"] = "1",
            ["UV_PROJECT_ENVIRONMENT"] = Paths.Venv,
            ["UV_PYTHON_INSTALL_DIR"] = Path.Combine(Paths.Home, "python"),
            ["UV_CACHE_DIR"] = Path.Combine(Paths.Home, "uv-cache"),
            ["UV_PYTHON_PREFERENCE"] = "only-managed",
            ["UV_SYSTEM_CERTS"] = "1",  // company networks that inspect HTTPS add their certificate to Windows' store
            ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1",
            ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1",  // Windows without Developer Mode: copies instead, fine
            ["TOKENIZERS_PARALLELISM"] = "false",
            ["PATH"] = string.Join(';', cuda.Append(System.Environment.GetEnvironmentVariable("PATH") ?? "")),
        };
    }

    /// Runs exe with args; onLine gets each stdout line (on a worker thread).
    public static async Task<Result> Run(string exe, IEnumerable<string> args, Action<string>? onLine = null,
                                         CancellationToken cancel = default)
    {
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Paths.Home,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        foreach (var (k, v) in Environment()) info.Environment[k] = v;
        using var p = new Process { StartInfo = info };
        var errors = new Queue<string>();
        p.OutputDataReceived += (_, e) => { if (e.Data != null) onLine?.Invoke(e.Data.Trim()); };
        p.ErrorDataReceived += (_, e) =>
        {
            if (e.Data == null) return;
            lock (errors) { errors.Enqueue(e.Data); if (errors.Count > 40) errors.Dequeue(); }
        };
        try { p.Start(); }
        catch (Exception e)
        {
            Paths.WriteLog($"could not start {exe}: {e.Message}");
            return new(false, e.Message);
        }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        using (cancel.Register(() => { try { p.Kill(true); } catch (InvalidOperationException) { } }))
            await p.WaitForExitAsync(CancellationToken.None);
        string[] tail;
        lock (errors) tail = [.. errors];
        Paths.WriteLog($"{Path.GetFileName(exe)} {string.Join(' ', info.ArgumentList.Take(3))} → exit {p.ExitCode}"
                       + (p.ExitCode == 0 ? "" : "\n" + string.Join("\n", tail.TakeLast(20))));
        var shown = tail.Where(l => !l.StartsWith("Fetching") && !l.Contains("Warning")).TakeLast(6);
        var memory = p.ExitCode != 0 && tail.Any(l => MemorySigns.Any(s => l.Contains(s, StringComparison.OrdinalIgnoreCase)));
        return new(p.ExitCode == 0, string.Join("\n", shown), memory);
    }

    public static Task<Result> Hesper(IEnumerable<string> args, Action<string>? onLine = null, CancellationToken cancel = default)
        => Run(Paths.Python, new[] { "-m", "hesper" }.Concat(args), onLine, cancel);

    /// A progress line, as (status text, fraction): either may be null.
    public static (string? Step, double? Progress) Parse(string line)
    {
        if (line.StartsWith("@@progress ") && double.TryParse(line[11..], System.Globalization.CultureInfo.InvariantCulture, out var f))
            return (null, f);
        if (!line.StartsWith("@@step ")) return (null, null);
        try
        {
            using var doc = JsonDocument.Parse(line[7..]);
            var text = doc.RootElement.GetProperty("key").GetString() ?? "";
            if (doc.RootElement.TryGetProperty("args", out var args))
                foreach (var a in args.EnumerateArray())
                {
                    var i = text.IndexOf("%@", StringComparison.Ordinal);
                    if (i >= 0) text = text[..i] + a.GetString() + text[(i + 2)..];
                }
            return (text, null);
        }
        catch (JsonException) { return (null, null); }
    }
}
