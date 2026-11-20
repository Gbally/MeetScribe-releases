using System.Text;

namespace Hesper;

/// Where Hesper keeps its things: everything in %LOCALAPPDATA%\Hesper (the engine, Python, models,
/// settings), the meetings in the notes folder. HESPER_HOME moves the first (a test setup).
static class Paths
{
    public static string Home { get; } = Environment.GetEnvironmentVariable("HESPER_HOME")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hesper");

    public static string Engine => Path.Combine(Home, "engine");          // the Python engine's source (src/, pyproject.toml, uv.lock)
    public static string Venv => Path.Combine(Home, "venv");
    public static string Python => Path.Combine(Venv, "Scripts", "python.exe");
    public static string Uv => Path.Combine(Home, "uv", "uv.exe");
    public static string ConfigFile => Path.Combine(Home, "config.toml");
    public static string Log => Path.Combine(Home, "hesper.log");

    /// Documents\MeetingNotes; %USERPROFILE%\MeetingNotes when Documents is synced by OneDrive
    /// (meetings stay on this PC unless the user picks a synced folder).
    public static string DefaultNotesFolder()
    {
        var docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var synced = docs.Contains("OneDrive", StringComparison.OrdinalIgnoreCase);
        var root = synced ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : docs;
        return Path.Combine(root, "MeetingNotes");
    }

    /// A new meeting folder, named as the engine names them (hesper.cli.new_session_dir).
    public static string NewSession(string notesFolder, DateTime when, string title = "")
    {
        var slug = System.Text.RegularExpressions.Regex.Replace(title, @"[^\w-]+", "-").Trim('-');
        var name = when.ToString("yyyy-MM-dd_HHmm") + (slug.Length > 0 ? "_" + slug[..Math.Min(50, slug.Length)] : "");
        var path = Path.Combine(notesFolder, name);
        for (var n = 2; Directory.Exists(path) && Directory.EnumerateFileSystemEntries(path).Any(); n++)
            path = Path.Combine(notesFolder, $"{name}-{n}");
        Directory.CreateDirectory(path);
        return path;
    }

    /// Appends to hesper.log (kept under ~1 MB).
    public static void WriteLog(string message)
    {
        try
        {
            Directory.CreateDirectory(Home);
            if (File.Exists(Log) && new FileInfo(Log).Length > 1_000_000) File.Delete(Log);
            File.AppendAllText(Log, $"[{DateTime.Now:s}] {message}{Environment.NewLine}", Encoding.UTF8);
        }
        catch (IOException) { }
    }
}
