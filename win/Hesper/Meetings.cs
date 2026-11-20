using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hesper;

/// Meeting folders in the notes folder (as mac/App/Meetings.swift reads them):
///   meeting.json (title, start), mic/system .wav or .caf, transcript.json/.md, notes.json/.md
///   (written by the engine), todo.json (the action items ticked off), error.txt.
static class Meetings
{
    static JsonNode? Read(string folder, string name)
    {
        try { return JsonNode.Parse(File.ReadAllText(Path.Combine(folder, name))); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    public static bool HasAudio(string folder) =>
        new[] { "mic.wav", "system.wav", "mic.caf", "system.caf" }.Any(f => File.Exists(Path.Combine(folder, f)));

    public static List<int> Done(string folder) =>
        Read(folder, "todo.json")?.AsArray().Select(n => n?.GetValue<int>() ?? -1).Where(i => i >= 0).ToList() ?? [];

    static DateTime Date(string folder, JsonNode? info, JsonNode? notes)
    {
        foreach (var s in new[] { info?["started"]?.GetValue<string>(), notes?["date"]?.GetValue<string>() })
            if (s != null && DateTime.TryParse(s.Length > 19 ? s[..19] : s, out var d)) return d;
        return Directory.GetCreationTime(folder);
    }

    static string Title(JsonNode? info, JsonNode? notes)
    {
        var t = notes?["title"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(t)) t = info?["title"]?.GetValue<string>();
        return string.IsNullOrWhiteSpace(t) ? "" : t;
    }

    /// One meeting as the list shows it, with its to-dos (the To-dos tab).
    static JsonObject? Summary(string folder)
    {
        var info = Read(folder, "meeting.json");
        var notes = Read(folder, "notes.json");
        var transcript = File.Exists(Path.Combine(folder, "transcript.json"));
        if (info == null && notes == null && !transcript && !HasAudio(folder)) return null;
        var error = File.Exists(Path.Combine(folder, "error.txt")) ? File.ReadAllText(Path.Combine(folder, "error.txt")).Trim() : null;
        return new JsonObject
        {
            ["id"] = Path.GetFileName(folder),
            ["title"] = Title(info, notes),
            ["date"] = Date(folder, info, notes).ToString("s"),
            ["duration"] = notes?["duration"]?.GetValue<double>() ?? info?["duration"]?.GetValue<double>(),
            ["hasNotes"] = notes != null,
            ["hasTranscript"] = transcript,
            ["hasAudio"] = HasAudio(folder),
            ["error"] = error,
            ["actions"] = notes?["actions"]?.DeepClone() ?? new JsonArray(),
            ["done"] = new JsonArray(Done(folder).Select(i => (JsonNode)i).ToArray()),
            ["template"] = notes?["template"]?.GetValue<string>() ?? info?["template"]?.GetValue<string>(),
            ["later"] = File.Exists(Path.Combine(folder, "notes_later.json")),
            ["roomOnly"] = notes?["tracks"] is JsonArray tr && tr.Any(t => t?.GetValue<string>() == "room"),
            ["guessed"] = notes?["guessed_names"] is JsonArray g && g.Count > 0 ? g.DeepClone() : null,
            ["edited"] = File.Exists(Path.Combine(folder, "notes.original.json")),
            ["calendar"] = info?["calendar"] is JsonObject cal ? new JsonObject
            {
                ["id"] = cal["id"]?.DeepClone(), ["title"] = cal["title"]?.DeepClone(), ["seriesKey"] = cal["seriesKey"]?.DeepClone(),
                ["start"] = cal["start"]?.DeepClone(), ["attendees"] = cal["attendees"]?.DeepClone(),
            } : null,
        };
    }

    public static JsonArray List(string root)
    {
        if (!Directory.Exists(root)) return [];
        var items = Directory.EnumerateDirectories(root).Select(Summary).OfType<JsonObject>()
            .OrderByDescending(m => m["date"]!.GetValue<string>(), StringComparer.Ordinal);
        return new JsonArray(items.ToArray<JsonNode>());
    }

    /// Everything a meeting window shows: the list entry, the notes and the transcript's lines.
    public static JsonObject? Detail(string root, string id)
    {
        var folder = FolderOf(root, id);
        if (folder == null || Summary(folder) is not { } m) return null;
        m["notes"] = Read(folder, "notes.json");
        m["folder"] = folder;
        var lines = new JsonArray();
        if (Read(folder, "transcript.json")?["utterances"] is JsonArray utts)
            foreach (var u in utts)
                lines.Add(new JsonObject
                {
                    ["start"] = u?["start"]?.GetValue<double>() ?? 0,
                    ["speaker"] = u?["speaker"]?.GetValue<string>() ?? "",
                    ["text"] = u?["text"]?.GetValue<string>() ?? "",
                });
        m["transcript"] = lines;
        return m;
    }

    /// The meeting's folder, only if it really is one of the notes folder (ids come from the page).
    public static string? FolderOf(string root, string id)
    {
        if (id.Length == 0 || id.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || id is "." or "..") return null;
        var folder = Path.Combine(root, id);
        return Directory.Exists(folder) ? folder : null;
    }

    public static void SetDone(string folder, int index, bool done)
    {
        var set = Done(folder).ToHashSet();
        if (done) set.Add(index); else set.Remove(index);
        File.WriteAllText(Path.Combine(folder, "todo.json"), JsonSerializer.Serialize(set.Order().ToList()));
    }

    /// Sets one field of meeting.json (the template, the duration…).
    public static void SetInfo(string folder, string key, JsonNode? value)
    {
        var info = Read(folder, "meeting.json") as JsonObject ?? [];
        info[key] = value;
        File.WriteAllText(Path.Combine(folder, "meeting.json"), info.ToJsonString());
    }

    /// Notes edited in the meeting window. The model's own notes are kept once, at the first edit
    /// (notes.original.json, as on the Mac); the engine then rewrites notes.md (hesper render).
    public static void SaveNotes(string folder, JsonObject edited)
    {
        var path = Path.Combine(folder, "notes.json");
        var original = Path.Combine(folder, "notes.original.json");
        if (File.Exists(path) && !File.Exists(original)) File.Copy(path, original);
        var notes = Read(folder, "notes.json") as JsonObject ?? [];
        foreach (var (k, v) in edited) notes[k] = v?.DeepClone();
        File.WriteAllText(path, notes.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
    }

    /// Removes one to-do; the ticks of the ones after it move up with them.
    public static void DeleteTodo(string folder, int index)
    {
        if (Read(folder, "notes.json") is not JsonObject notes || notes["actions"] is not JsonArray actions || index >= actions.Count) return;
        var path = Path.Combine(folder, "notes.json");
        var original = Path.Combine(folder, "notes.original.json");
        if (!File.Exists(original)) File.Copy(path, original);
        actions.RemoveAt(index);
        File.WriteAllText(path, notes.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
        var done = Done(folder).Where(i => i != index).Select(i => i > index ? i - 1 : i).ToList();
        File.WriteAllText(Path.Combine(folder, "todo.json"), JsonSerializer.Serialize(done));
    }

    /// "They're right": the names guessed from the calendar are kept, the banner goes.
    public static void ConfirmGuessedNames(string folder)
    {
        if (Read(folder, "notes.json") is not JsonObject notes) return;
        notes.Remove("guessed_names");
        File.WriteAllText(Path.Combine(folder, "notes.json"), notes.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
    }

    /// The meetings whose title, notes or transcript contain every word.
    public static JsonArray Search(string root, string query)
    {
        var words = query.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var hits = new JsonArray();
        if (words.Length == 0 || !Directory.Exists(root)) return hits;
        foreach (var folder in Directory.EnumerateDirectories(root))
        {
            var text = string.Join("\n", new[] { "meeting.json", "notes.json", "transcript.md" }
                .Select(f => Path.Combine(folder, f)).Where(File.Exists).Select(File.ReadAllText)).ToLowerInvariant();
            if (words.All(text.Contains)) hits.Add(Path.GetFileName(folder));
        }
        return hits;
    }

    /// The first things each speaker said (to tell who is who when naming them).
    public static JsonObject Samples(string folder, int perSpeaker = 3)
    {
        var outp = new JsonObject();
        if (Read(folder, "transcript.json")?["utterances"] is not JsonArray utts) return outp;
        foreach (var u in utts)
        {
            var spk = u?["speaker"]?.GetValue<string>();
            var text = u?["text"]?.GetValue<string>() ?? "";
            if (spk == null || text.Split(' ').Length < 4) continue;
            var list = outp[spk] as JsonArray ?? (JsonArray)(outp[spk] = new JsonArray());
            if (list.Count < perSpeaker) list.Add(text.Length > 140 ? text[..140] + "…" : text);
        }
        return outp;
    }
}
