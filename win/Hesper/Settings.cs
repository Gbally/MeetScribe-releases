using System.Text;
using System.Text.Json;

namespace Hesper;

/// The user's settings (settings.json), and the part the engine reads (config.toml, as Engine.swift
/// writes it on the Mac). The models aren't set here: the engine's defaults for a PC apply.
sealed class AppSettings
{
    public string MyName { get; set; } = "";
    public string NotesFolder { get; set; } = Paths.DefaultNotesFolder();
    public string Languages { get; set; } = "";      // "" = detected; "en,fr" = the meeting may switch between these
    public string TodoFilter { get; set; } = "standard";
    public string Microphone { get; set; } = "";     // a device's name; "" = Windows' default
    public string Speakers { get; set; } = "";

    static string File => Path.Combine(Paths.Home, "settings.json");

    public static AppSettings Load()
    {
        try { return JsonSerializer.Deserialize<AppSettings>(System.IO.File.ReadAllText(File)) ?? new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Paths.Home);
        System.IO.File.WriteAllText(File, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        WriteConfig();
    }

    /// Writes the settings where the Python engine reads them.
    public void WriteConfig()
    {
        static string Q(string v) => "\"" + v.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        var toml = new StringBuilder()
            .AppendLine($"notes_dir = {Q(NotesFolder)}")
            .AppendLine($"me = {Q(MyName.Trim().Length > 0 ? MyName.Trim() : "Me")}")
            .AppendLine($"language = {Q(Languages.Replace(" ", ""))}")
            .AppendLine($"todo_filter = {Q(TodoFilter)}");
        System.IO.File.WriteAllText(Paths.ConfigFile, toml.ToString(), new UTF8Encoding(false));
    }
}
