using System.Text;
using System.Text.Json;

namespace Hesper;

/// A model that ran out of memory (as the Mac's MemoryWarning): the speech model, else the notes
/// model; failed: a meeting couldn't be processed, else its notes were written in parts, more slowly.
sealed class MemoryWarning
{
    public string Model { get; set; } = "";
    public bool Speech { get; set; }
    public bool Failed { get; set; }
}

/// The user's settings (settings.json, as the Mac's AppSettings), and the part the engine reads
/// (config.toml, as Engine.swift writes it).
sealed class AppSettings
{
    // General
    public string MyName { get; set; } = Environment.UserName;
    public string AppLanguage { get; set; } = "";     // "" = Windows' language
    public string Hotkey { get; set; } = "Ctrl+Alt+R"; // start / stop recording; "" = none
    public string EmailApp { get; set; } = "default";  // default, outlook, gmail, outlookWeb
    public string GmailAccount { get; set; } = "";
    // Recording
    public string Microphone { get; set; } = "";       // a device's name; "" = Windows' default
    public string Speakers { get; set; } = "";
    public bool AutoRecord { get; set; }               // start when a call starts, stop when it ends
    public string AppOnly { get; set; } = "";          // "teams": only Microsoft Teams' sound, not all the PC plays
    public string Languages { get; set; } = "";        // "" = detected; "en,fr" = the meeting may switch between these
    public string Vocabulary { get; set; } = "";
    // Notes
    public string Template { get; set; } = "general";
    public string SummaryStyle { get; set; } = "standard";
    public string TodoFilter { get; set; } = "standard";
    public string NotesLanguage { get; set; } = "auto";
    public string NotesTiming { get; set; } = "now";   // now, later, both (LaterNotes.cs)
    public string LaterModel { get; set; } = "";        // the notes model then; "" = the usual one
    public List<int[]> LaterWindows { get; set; } = [[12 * 60, 13 * 60 + 30]];  // minutes from midnight
    public bool LaterInWindows { get; set; } = true;
    public bool LaterWhenIdle { get; set; } = true;
    public int LaterIdleMinutes { get; set; } = 10;
    public bool LaterWhenLocked { get; set; } = true;
    public string ExportFolder { get; set; } = "";
    public bool AutoExport { get; set; }
    // AI models ("" = the catalog's recommendation for this PC)
    public string LlmModel { get; set; } = "";
    public string WhisperModel { get; set; } = "";
    // Notifications
    public bool NotifyWhenReady { get; set; } = true;
    public bool CallReminders { get; set; } = true;
    public bool EndReminders { get; set; } = true;
    public bool StopWhenOver { get; set; } = true;
    public bool DueReminders { get; set; } = true;
    public bool Briefs { get; set; } = true;
    public bool UseCalendar { get; set; } = true;
    // Privacy and storage
    public string Storage { get; set; } = "local";     // local, onedrive, custom
    public string OneDrivePath { get; set; } = "";
    public string CustomFolderPath { get; set; } = "";
    public int AudioRetentionDays { get; set; } = 7;   // 0 = right after the notes, -1 = never
    // About
    public bool TestVersions { get; set; }
    public bool Welcomed { get; set; }
    /// A model that ran out of memory on this PC, said in the popover until dismissed or replaced.
    public MemoryWarning? Memory { get; set; }

    /// No settings.json yet: the very first launch.
    [System.Text.Json.Serialization.JsonIgnore] public bool IsNew { get; private set; }

    /// Where the meetings are (from Storage); kept in the file for older versions.
    public string NotesFolder { get; set; } = Paths.DefaultNotesFolder();

    static string File => Path.Combine(Paths.Home, "settings.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        AppSettings s;
        try { s = JsonSerializer.Deserialize<AppSettings>(System.IO.File.ReadAllText(File)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { s = new() { IsNew = !System.IO.File.Exists(File) }; }
        // Settings from before Storage existed: a folder other than the default one is a custom one
        if (s.Storage == "local" && !s.NotesFolder.Equals(Paths.DefaultNotesFolder(), StringComparison.OrdinalIgnoreCase)
            && s.CustomFolderPath.Length == 0)
            (s.Storage, s.CustomFolderPath) = ("custom", s.NotesFolder);
        s.NotesFolder = Hesper.Storage.FolderFor(s);
        return s;
    }

    public void Save()
    {
        NotesFolder = Hesper.Storage.FolderFor(this);
        Directory.CreateDirectory(Paths.Home);
        System.IO.File.WriteAllText(File, JsonSerializer.Serialize(this, Json));
        WriteConfig();
    }

    /// Writes the settings where the Python engine reads them; llm overrides the notes model
    /// (the "later" model for notes written when the PC is free).
    public void WriteConfig(string? llm = null)
    {
        static string Q(string v) => "\"" + v.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        var catalog = Catalog.Load();
        var notesModel = llm ?? (LlmModel.Length > 0 ? LlmModel : catalog.Recommended(false)?.Repo ?? "unsloth/Qwen3.5-4B-GGUF:Q4_K_M");
        var speechModel = WhisperModel.Length > 0 ? WhisperModel : catalog.Recommended(true)?.Repo ?? "large-v3-turbo";
        var toml = new StringBuilder()
            .AppendLine($"notes_dir = {Q(NotesFolder)}")
            .AppendLine($"me = {Q(MyName.Trim().Length > 0 ? MyName.Trim() : "Me")}")
            .AppendLine($"language = {Q(Languages.Replace(" ", ""))}")
            .AppendLine($"summary_language = {Q(NotesLanguage)}")
            .AppendLine($"vocabulary = {Q(Vocabulary)}")
            .AppendLine($"summary_style = {Q(SummaryStyle)}")
            .AppendLine($"template = {Q(Template)}")
            .AppendLine($"todo_filter = {Q(TodoFilter)}")
            .AppendLine($"llm_model = {Q(notesModel)}")
            .AppendLine($"whisper_model = {Q(speechModel)}");
        Directory.CreateDirectory(Paths.Home);  // the very first launch: nothing there yet
        System.IO.File.WriteAllText(Paths.ConfigFile, toml.ToString(), new UTF8Encoding(false));
    }
}
