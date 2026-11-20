using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Hesper;

/// "Open Hesper at login": a value in the user's Run key (no admin rights).
static class Startup
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool Enabled
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Hesper") is string;
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            if (value) k.SetValue("Hesper", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("Hesper", false);
        }
    }
}

/// A meeting's notes as text, for an e-mail or the clipboard (Meeting.shareText on the Mac).
static class Share
{
    /// labels: the headings in the app's language ({"Summary": "Résumé", …}), from the page.
    public static string Text(JsonObject m, JsonObject? labels)
    {
        string tr(string k) => labels?[k]?.GetValue<string>() ?? k;
        var title = m["title"]?.GetValue<string>() is { Length: > 0 } t ? t : tr("Meeting");
        var n = m["notes"];
        var date = DateTime.TryParse(m["date"]?.GetValue<string>(), out var d) ? d.ToString("g") : "";
        var out_ = new List<string> { $"{title} — {date}", "" };
        void Bullets(string label, JsonNode? items)
        {
            if (items is not JsonArray a || a.Count == 0) return;
            out_.Add(tr(label));
            out_.AddRange(a.Select(i => "• " + i));
            out_.Add("");
        }
        Bullets("Summary", n?["summary"]);
        Bullets("Decisions", n?["decisions"]);
        if (n?["actions"] is JsonArray acts && acts.Count > 0)
        {
            out_.Add(tr("Action items"));
            foreach (var a in acts)
            {
                var extra = new[] { a?["owner"]?.GetValue<string>(), a?["due"]?.GetValue<string>() }.Where(s => !string.IsNullOrEmpty(s));
                out_.Add($"☐ {a?["task"]}" + (extra.Any() ? $" ({string.Join(", ", extra)})" : ""));
            }
            out_.Add("");
        }
        Bullets("Open questions", n?["questions"]);
        return string.Join("\n", out_).TrimEnd();
    }

    /// A draft in the chosen mail app: the default one (mailto), Outlook, Gmail or Outlook on the web.
    public static void Email(string app, string gmailAccount, string subject, string body)
    {
        string Q(string s) => Uri.EscapeDataString(s);
        switch (app)
        {
            case "gmail":
                var account = gmailAccount.Trim().Length > 0 ? $"authuser={Q(gmailAccount.Trim())}&" : "";
                Open($"https://mail.google.com/mail/?{account}view=cm&fs=1&su={Q(subject)}&body={Q(body)}");
                break;
            case "outlookWeb":
                Open($"https://outlook.office.com/mail/deeplink/compose?subject={Q(subject)}&body={Q(body)}");
                break;
            case "outlook" when OutlookPath() is { } outlook:
                Process.Start(new ProcessStartInfo(outlook) { ArgumentList = { "/c", "ipm.note", "/m", $"?subject={Q(subject)}&body={Q(body)}" } });
                break;
            default:
                Open($"mailto:?subject={Q(subject)}&body={Q(body)}");
                break;
        }
    }

    /// Classic Outlook's exe, from its App Paths entry.
    public static string? OutlookPath() =>
        Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE")?.GetValue("") as string;

    public static void Open(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}

/// The notes as Markdown for a notes app's folder (Obsidian…), as mac/App/Export.swift writes them.
static class Export
{
    public static string? Markdown(string folder, JsonObject m)
    {
        var notes = Path.Combine(folder, "notes.md");
        if (!File.Exists(notes)) return null;
        var day = DateTime.TryParse(m["date"]?.GetValue<string>(), out var d) ? d.ToString("yyyy-MM-dd") : "";
        var people = (m["notes"]?["participants"] as JsonArray ?? []).Select(p => $"\"{p?.GetValue<string>().Replace("\"", "'")}\"");
        var front = new[] { "---", $"date: {day}", $"participants: [{string.Join(", ", people)}]", "tags: [meeting]",
                            "source: Hesper", $"hesper_id: \"{m["id"]}\"", "---", "" };
        var lines = File.ReadAllLines(notes).Where(l => !l.Contains("(transcript.md)"));  // only works in the meeting's folder
        return string.Join("\n", front.Concat(lines));
    }

    /// "2026-10-23 Weekly sync.md", or "… 2.md" when that name is another meeting's copy.
    static string FileFor(JsonObject m, string dir)
    {
        var day = DateTime.TryParse(m["date"]?.GetValue<string>(), out var d) ? d.ToString("yyyy-MM-dd") : "";
        var title = Regex.Replace(m["title"]?.GetValue<string>() ?? "", @"[/\\:*?""<>|]", "-").Trim();
        var name = $"{day} {(title.Length > 0 ? title[..Math.Min(80, title.Length)] : "Meeting")}";
        var id = m["id"]!.GetValue<string>();
        for (var n = 1; n < 100; n++)
        {
            var file = Path.Combine(dir, n == 1 ? $"{name}.md" : $"{name} {n}.md");
            if (!File.Exists(file)) return file;
            var front = File.ReadLines(file).Skip(1).TakeWhile(l => l != "---");
            var owner = front.FirstOrDefault(l => l.StartsWith("hesper_id:") || l.StartsWith("meetscribe_id:"));
            if (owner == null || owner.Split(':', 2)[1].Trim(' ', '"', '\'') == id) return file;
        }
        return Path.Combine(dir, $"{name} {id}.md");
    }

    public static string? Save(string folder, JsonObject m, string dir)
    {
        if (Markdown(folder, m) is not { } text) return null;
        Directory.CreateDirectory(dir);
        var file = FileFor(m, dir);
        File.WriteAllText(file, text, new UTF8Encoding(false));
        return file;
    }
}

/// Where the notes folder can be: this PC, a OneDrive account, another folder.
static class Storage
{
    /// OneDrive accounts signed in on this PC (personal and work), as (name, folder).
    public static List<(string Name, string Path)> OneDriveAccounts()
    {
        var found = new List<(string, string)>();
        using var accounts = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\OneDrive\Accounts");
        foreach (var name in accounts?.GetSubKeyNames() ?? [])
        {
            using var k = accounts!.OpenSubKey(name);
            if (k?.GetValue("UserFolder") is string folder && Directory.Exists(folder))
                found.Add((k.GetValue("DisplayName") as string is { Length: > 0 } dn ? $"OneDrive – {dn}" : Path.GetFileName(folder), folder));
        }
        return found.DistinctBy(a => a.Item2.ToLowerInvariant()).ToList();
    }

    public static string? SyncService(string folder)
    {
        foreach (var (name, path) in OneDriveAccounts())
            if (folder.StartsWith(path, StringComparison.OrdinalIgnoreCase)) return name;
        foreach (var s in new[] { "Dropbox", "Google Drive", "iCloudDrive", "Box" })
            if (folder.Contains(s, StringComparison.OrdinalIgnoreCase)) return s;
        return null;
    }

    public static string FolderFor(AppSettings s) => s.Storage switch
    {
        "onedrive" when s.OneDrivePath.Length > 0 => Path.Combine(s.OneDrivePath, "MeetingNotes"),
        "custom" when s.CustomFolderPath.Length > 0 => s.CustomFolderPath,
        _ => Paths.DefaultNotesFolder(),
    };

    /// Moves the meeting folders from one notes folder to another; returns how many couldn't be.
    public static int Move(string from, string to)
    {
        Directory.CreateDirectory(to);
        var failed = 0;
        foreach (var dir in Directory.Exists(from) ? Directory.GetDirectories(from) : [])
        {
            var dest = Path.Combine(to, Path.GetFileName(dir));
            try
            {
                if (Directory.Exists(dest)) { failed++; continue; }
                if (Path.GetPathRoot(dir)!.Equals(Path.GetPathRoot(dest), StringComparison.OrdinalIgnoreCase)) Directory.Move(dir, dest);
                else { Microsoft.VisualBasic.FileIO.FileSystem.CopyDirectory(dir, dest); Directory.Delete(dir, true); }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { failed++; }
        }
        return failed;
    }
}

/// Deletes the recordings (and voice samples) of processed meetings after the chosen number of days.
static class Retention
{
    static readonly string[] Audio = ["mic.wav", "system.wav", "mic.caf", "system.caf", "clips.json"];

    public static void DeleteAudio(string folder)
    {
        foreach (var f in Audio) File.Delete(Path.Combine(folder, f));
        var clips = Path.Combine(folder, "clips");
        if (Directory.Exists(clips)) Directory.Delete(clips, true);
    }

    public static int CleanUp(string notesFolder, int days, ICollection<string> busy)
    {
        if (days <= 0 || !Directory.Exists(notesFolder)) return 0;
        var limit = DateTime.Now.AddDays(-days);
        var n = 0;
        foreach (var dir in Directory.GetDirectories(notesFolder))
        {
            if (busy.Contains(dir) || !File.Exists(Path.Combine(dir, "notes.json")) || !Meetings.HasAudio(dir)) continue;
            if (Directory.GetCreationTime(dir) > limit) continue;
            DeleteAudio(dir);
            n++;
        }
        if (n > 0) Paths.WriteLog($"retention: deleted audio of {n} meeting(s) older than {days} days");
        return n;
    }
}

/// Self-update from the public releases repo: latest-windows.json (or -beta) says which build is
/// current; the new exe is downloaded, checked against its SHA-256, swapped in and started.
static class Updater
{
    const string Raw = "https://raw.githubusercontent.com/Gbally/Hesper/main/";
    /// This exe's build number (the 4th part of its version, set by scripts/release_windows.ps1),
    /// compared with the feed's; 0 for a build made by hand.
    public static int Build => Math.Max(0, typeof(Updater).Assembly.GetName().Version?.Revision ?? 0);

    public static async Task<JsonObject?> Check(bool testVersions)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        async Task<JsonObject?> Get(string f)
        {
            try { return JsonNode.Parse(await http.GetStringAsync(Raw + f + "?t=" + DateTime.UtcNow.Ticks))?.AsObject(); }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException) { return null; }
        }
        var release = await Get("latest-windows.json");
        var test = testVersions ? await Get("latest-windows-beta.json") : null;
        var best = new[] { release, test }.OfType<JsonObject>().MaxBy(i => i["build"]?.GetValue<int>() ?? 0);
        return best != null && (best["build"]?.GetValue<int>() ?? 0) > Build ? best : null;
    }

    /// Downloads and checks the new exe, then swaps it with this one and restarts.
    public static async Task Install(JsonObject info, Action<double> progress)
    {
        var url = info["url"]!.GetValue<string>();
        var sha = info["sha256"]!.GetValue<string>().ToLowerInvariant();
        if (!url.StartsWith("https://github.com/Gbally/Hesper/", StringComparison.Ordinal)) throw new InvalidOperationException("Unexpected download address.");
        var exe = Environment.ProcessPath!;
        var tmp = exe + ".new";
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) })
        using (var r = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
        {
            r.EnsureSuccessStatusCode();
            var size = r.Content.Headers.ContentLength ?? 0;
            await using var from = await r.Content.ReadAsStreamAsync();
            await using var to = File.Create(tmp);
            var buf = new byte[1 << 20];
            long got = 0;
            int n;
            while ((n = await from.ReadAsync(buf)) > 0) { await to.WriteAsync(buf.AsMemory(0, n)); got += n; if (size > 0) progress((double)got / size); }
        }
        string actual;
        await using (var f = File.OpenRead(tmp)) actual = Convert.ToHexString(await SHA256.HashDataAsync(f)).ToLowerInvariant();
        if (actual != sha) { File.Delete(tmp); throw new InvalidOperationException("The download isn't the expected file."); }
        var old = exe + ".old";
        File.Delete(old);
        File.Move(exe, old);   // a running exe can be renamed, not overwritten
        File.Move(tmp, exe);
        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, ArgumentList = { "--after-update" } });
    }

    /// The previous exe, left by an update.
    public static void CleanUp()
    {
        try { File.Delete(Environment.ProcessPath + ".old"); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// Settings → Privacy → Remove Hesper: the engine, models, settings and voices (all of
/// %LOCALAPPDATA%\Hesper), the login item, optionally the notes (to the Recycle Bin), then the exe.
static class Uninstall
{
    public static long Size(string dir)
    {
        try { return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
    }

    public static void Run(string notesFolder, bool removeNotes)
    {
        Startup.Enabled = false;
        if (removeNotes && Directory.Exists(notesFolder))
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(notesFolder, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                                                                   Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        // After Hesper has quit: delete its folder and the exe (a running exe can't delete itself)
        var script = $"/c timeout /t 3 /nobreak >nul & rmdir /s /q \"{Paths.Home}\" & del /f /q \"{Environment.ProcessPath}\"";
        Process.Start(new ProcessStartInfo("cmd.exe", script) { CreateNoWindow = true, UseShellExecute = false });
    }
}
