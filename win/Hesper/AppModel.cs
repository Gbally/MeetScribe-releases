using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.VisualBasic.FileIO;

namespace Hesper;

/// What the app is doing (setting up, recording, the job queue) and what its pages may ask of it.
/// Runs on the UI thread; pages get its state as JSON (State()) and call Handle(command, args).
/// As mac/App/AppModel.swift.
sealed class AppModel
{
    public AppSettings Settings { get; private set; } = AppSettings.Load();
    public Recorder? Recorder { get; private set; }
    public bool Ready => Setup.IsInstalled;

    /// Something the pages show changed (the meetings, a job's progress, the recording…).
    public event Action? Changed;
    /// A Windows notification: title, text, and what a click on it does (or null).
    public event Action<string, string, Action?>? Notify;
    public event Action<string>? OpenMeetingWindow;
    public event Action<string>? OpenSettingsWindow;
    public event Action? OpenWelcomeWindow;
    public event Action? QuitRequested;
    public event Action? HotkeyChanged;
    public event Action<string>? BriefRequested;  // the brief of a calendar meeting about to start, in the popover

    /// Kind: process, import, summarize, later (notes when the PC is free), copy (notes with another
    /// model, in a copy), rename, render, ask, model, check. Model: the notes model for this job only.
    record Job(string Kind, string Folder, string[] Args, bool NewMeeting = false, string? Model = null);
    readonly Queue<Job> queue = new();
    Job? current;
    string jobStep = "";
    double? jobProgress;
    DateTime jobStarted;
    (string Text, double? Progress)? setup;
    string? setupError;
    JsonObject? answer;           // the last "ask": {question, busy, result}
    JsonObject? modelJob;         // a model download / check: {status, progress, error, check}
    JsonObject? update;           // {available: {...}, state, error, checked}
    readonly List<string> notices = [];
    string recordingTemplate = "";
    bool autoStarted, starting, stopping, resumed;
    readonly CallMonitor calls = new();
    readonly System.Windows.Forms.Timer minute = new() { Interval = 60_000 }, second = new() { Interval = 1000 };
    DateTime lastCleanup = DateTime.MinValue, lastCatalog = DateTime.MinValue, lastUpdateCheck = DateTime.MinValue;
    Catalog catalog = Catalog.Load();
    readonly OutlookCalendar calendar;
    CalendarEvent? recordingEvent;
    bool endReminderSent;
    readonly HashSet<string> briefed = [];
    JsonArray? meetingsCache;
    DateTime meetingsRead;

    // A recording that goes on after the meeting (MeetingOverWatch on the Mac)
    const double QuietAsk = 10 * 60, QuietStop = 30 * 60, QuietAfterSignal = 5 * 60, AfterCall = 10 * 60;
    double? callEndedAt, signalAt, keptAt;
    bool askedQuiet;
    int hoursReminded;
    /// The "is it over?" question asked about the recording (text key and its arguments), shown in
    /// the popover with "Keep recording" until answered: Windows' notifications have no buttons.
    (string Key, string[] Args)? overQuestion;

    public AppModel()
    {
        calendar = new OutlookCalendar(Settings.UseCalendar);
        calendar.Changed += Emit;
        calls.CallStarted += CallStarted;
        calls.CallEnded += CallEnded;
        minute.Tick += (_, _) => EveryMinute();
        second.Tick += (_, _) => { if (Recorder != null) { CheckEventEnd(Recorder); CheckMeetingOver(Recorder); } };
        minute.Start();
        second.Start();
        Updater.CleanUp();
        PinModels();
        var first = new System.Windows.Forms.Timer { Interval = 5000 };
        first.Tick += (_, _) => { first.Dispose(); ResumeUnprocessed(); EveryMinute(); };
        first.Start();
    }

    void Emit() => Changed?.Invoke();

    /// A text for a notification or a file, in the app's language (the pages translate their own).
    string T(string key, params object[] args) => I18n.T(Settings.AppLanguage, key, args);

    // MARK: state

    public JsonObject State() => new()
    {
        ["ready"] = Ready,
        ["welcomed"] = Settings.Welcomed,
        ["setup"] = setup is { } s ? new JsonObject { ["text"] = s.Text, ["progress"] = s.Progress } : null,
        ["setupError"] = setupError,
        ["recording"] = Recorder is { } r ? new JsonObject
        {
            ["elapsed"] = r.Elapsed.TotalSeconds,
            ["mic"] = r.MicLevel,
            ["system"] = r.SystemLevel,
            ["notices"] = new JsonArray(notices.Select(n => (JsonNode)n).ToArray()),
            ["id"] = Path.GetFileName(r.Folder),
            ["template"] = recordingTemplate,
            ["event"] = recordingEvent?.ToJson(),
            ["asking"] = overQuestion is { } q ? new JsonObject { ["key"] = q.Key, ["args"] = new JsonArray(q.Args.Select(a => (JsonNode)a).ToArray()) } : null,
        } : null,
        ["starting"] = starting,
        ["stopping"] = stopping,
        ["job"] = current is { } j ? new JsonObject
        {
            ["kind"] = j.Kind, ["id"] = Path.GetFileName(j.Folder), ["step"] = jobStep, ["progress"] = jobProgress,
            ["waiting"] = queue.Count, ["remaining"] = Remaining(),
            ["question"] = j.Kind == "ask" ? j.Args.Last() : null, ["file"] = j.Kind == "import" ? Path.GetFileName(j.Args[1]) : null,
        } : null,
        ["busy"] = new JsonArray(queue.Append(current).OfType<Job>().Where(x => x.Kind is not ("ask" or "model" or "check" or "import"))
                                      .Select(x => (JsonNode)Path.GetFileName(x.Folder)).ToArray()),
        ["answer"] = answer?.DeepClone(),
        ["modelJob"] = modelJob?.DeepClone(),
        ["update"] = update?.DeepClone(),
        ["meetings"] = MeetingList().DeepClone(),
        ["settings"] = JsonSerializer.SerializeToNode(Settings),
        ["launchAtLogin"] = Startup.Enabled,
        ["version"] = Setup.AppVersion,
        ["build"] = Updater.Build,
        ["gpu"] = Setup.HasNvidia,
        ["notesModel"] = NotesModel,
        ["speechModel"] = SpeechModel,
        ["laterPending"] = PendingLater().Count,
        ["memory"] = Settings.Memory is { } w && w.Model == (w.Speech ? SpeechModel : NotesModel)
            ? new JsonObject { ["model"] = w.Model, ["name"] = ModelName(w.Model), ["speech"] = w.Speech, ["failed"] = w.Failed } : null,
        ["notificationProblem"] = Identity.NotificationProblem(),
        ["oneDrive"] = new JsonArray(Storage.OneDriveAccounts().Select(a => (JsonNode)new JsonObject { ["name"] = a.Name, ["path"] = a.Path }).ToArray()),
        ["outlook"] = Share.OutlookPath() != null,
        ["home"] = Paths.Home,
        ["calendar"] = CalendarState(),
        ["appLoopback"] = ProcessLoopbackCapture.Supported,
    };

    /// The meetings as the list shows them: read again at most every 10 s, or when something here
    /// changed them. The pages ask for the state several times a second while a job runs, and each
    /// read opens every meeting's files (in OneDrive, maybe downloading them).
    JsonArray MeetingList()
    {
        if (meetingsCache == null || DateTime.Now - meetingsRead > TimeSpan.FromSeconds(10))
            (meetingsCache, meetingsRead) = (Meetings.List(Settings.NotesFolder), DateTime.Now);
        return meetingsCache;
    }

    void MeetingsChanged() => meetingsCache = null;
    IEnumerable<JsonObject> AllMeetings => MeetingList().OfType<JsonObject>();
    string? FolderOf(JsonObject m) => Meetings.FolderOf(Settings.NotesFolder, m["id"]!.GetValue<string>());

    /// Meetings waiting for their notes (or better notes) until the PC is free, oldest first.
    List<string> PendingLater() =>
        AllMeetings.Where(m => m["later"]?.GetValue<bool>() == true).OrderBy(m => m["date"]!.GetValue<string>(), StringComparer.Ordinal)
                   .Select(FolderOf).OfType<string>().ToList();

    /// The calendar for the pages: is there one, the meeting now (or next), today's timeline, and the
    /// brief of the next meeting (what's still open from the last one like it).
    JsonObject CalendarState()
    {
        var next = calendar.Current() ?? calendar.Upcoming(30).FirstOrDefault();
        return new JsonObject
        {
            ["available"] = OutlookCalendar.Available, ["installed"] = OutlookCalendar.Installed, ["on"] = Settings.UseCalendar, ["error"] = calendar.Error,
            ["next"] = next?.ToJson(), ["nextBrief"] = next != null ? Brief(next) : null,
            ["today"] = new JsonArray(calendar.Today().Select(e => (JsonNode)e.ToJson()).ToArray()),
            ["recordingEvent"] = recordingEvent?.ToJson(),
            ["briefs"] = new JsonObject(calendar.Upcoming(30).Concat(calendar.Today()).DistinctBy(e => e.Id)
                .Select(e => KeyValuePair.Create(e.Id ?? e.Title, (JsonNode?)new JsonObject { ["event"] = e.ToJson(), ["brief"] = Brief(e) }))),
        };
    }

    /// Earlier meetings that were the same meeting: same series, same (not generic) title, or mostly
    /// the same people. As previousMeetings on the Mac.
    List<JsonObject> PreviousMeetings(CalendarEvent e)
    {
        static string Norm(string s) => s.Trim().ToLowerInvariant();
        string[] generic = ["meeting", "call", "sync", "teams meeting", "réunion"];
        var emails = e.Attendees.Select(a => a.Email.ToLowerInvariant()).Where(m => m.Length > 0).ToHashSet();
        return AllMeetings.Where(m =>
        {
            if (m["hasNotes"]?.GetValue<bool>() != true || m["calendar"] is not JsonObject c) return false;
            if (!DateTime.TryParse(m["date"]?.GetValue<string>(), out var d) || d >= e.Start.AddMinutes(-10)) return false;
            if (c["seriesKey"]?.GetValue<string>() is { } a && a == e.SeriesKey) return true;
            var title = Norm(c["title"]?.GetValue<string>() ?? "");
            if (title == Norm(e.Title) && !generic.Contains(title) && e.Title.Length > 3) return true;
            var theirs = (c["attendees"] as JsonArray ?? []).Select(x => (x?["email"]?.GetValue<string>() ?? "").ToLowerInvariant())
                                                           .Where(x => x.Length > 0).ToHashSet();
            var shared = emails.Intersect(theirs).Count();
            return shared >= 2 && shared >= 0.5 * Math.Min(emails.Count, theirs.Count);
        }).ToList();
    }

    /// What's still open from the earlier meetings like this one, and the last of them (with what
    /// was decided there).
    JsonObject? Brief(CalendarEvent e)
    {
        var previous = PreviousMeetings(e);
        if (previous.Count == 0) return null;
        var open = new JsonArray();
        foreach (var m in previous)
        {
            var done = m["done"]!.AsArray().Select(x => x!.GetValue<int>()).ToHashSet();
            var actions = m["actions"]!.AsArray();
            for (var i = 0; i < actions.Count; i++)
                if (!done.Contains(i))
                    open.Add(new JsonObject { ["id"] = m["id"]!.GetValue<string>(), ["index"] = i, ["action"] = actions[i]!.DeepClone(), ["title"] = m["title"]!.GetValue<string>() });
        }
        var last = previous[0];
        return new JsonObject
        {
            ["last"] = last["id"]!.GetValue<string>(), ["lastDate"] = last["date"]!.GetValue<string>(), ["open"] = open,
            ["highlights"] = FolderOf(last) is { } f ? Meetings.Highlights(f) : new JsonArray(),
        };
    }

    string NotesModel => Settings.LlmModel.Length > 0 ? Settings.LlmModel : catalog.Recommended(false)?.Repo ?? "";
    string SpeechModel => Settings.WhisperModel.Length > 0 ? Settings.WhisperModel : catalog.Recommended(true)?.Repo ?? "";

    /// "Qwen3.5 9B" for a listed model, else the end of its repo.
    string ModelName(string repo) =>
        catalog.Notes.Concat(catalog.Speech).FirstOrDefault(m => m.Repo == repo)?.Name ?? repo.Split('/').Last();

    /// Seconds left for the current job, from its progress so far (null until it's meaningful).
    double? Remaining()
    {
        if (jobProgress is not double p || p < 0.05 || p >= 1) return null;
        var spent = (DateTime.Now - jobStarted).TotalSeconds;
        return spent * (1 - p) / p;
    }

    /// The light part of the state, several times a second while recording.
    public JsonObject Live() => new()
    {
        ["elapsed"] = Recorder?.Elapsed.TotalSeconds,
        ["mic"] = Recorder?.MicLevel,
        ["system"] = Recorder?.SystemLevel,
    };

    // MARK: commands from the pages

    /// The commands whose answer takes a while; the others answer at once (Handle).
    public async Task<JsonNode?> HandleAsync(string cmd, JsonObject a)
    {
        if (cmd != "makeClips") return Handle(cmd, a);
        // Voice samples for a meeting processed before they existed (a few seconds), as on the Mac
        if (Meetings.FolderOf(Settings.NotesFolder, a["id"]?.GetValue<string>() ?? "") is not { } folder || !Ready) return null;
        var r = await EngineRunner.Hesper(["clips", folder]);
        if (!r.Ok) Paths.WriteLog("voice samples: " + r.ErrorTail);
        return Meetings.Clips(folder);
    }

    /// Commands that only read: the others may change the meetings, read again then.
    static readonly HashSet<string> ReadOnly = ["state", "meeting", "search", "samples", "i18n", "catalog", "devices", "voices",
                                                "engineSize", "syncService", "notesModels", "refreshCalendar", "openMeeting", "openSettings"];

    public JsonNode? Handle(string cmd, JsonObject a)
    {
        string S(string k) => a[k]?.GetValue<string>() ?? "";
        bool B(string k) => a[k]?.GetValue<bool>() == true;
        string? Folder() => Meetings.FolderOf(Settings.NotesFolder, S("id"));
        if (!ReadOnly.Contains(cmd)) MeetingsChanged();
        switch (cmd)
        {
            case "state": return State();
            case "refreshCalendar": calendar.Refresh(); return null;
            case "record": StartRecording(S("template")); return null;
            case "stop": StopRecording(B("discard")); return null;
            case "keepRecording": KeepRecording(); return null;
            case "meeting": return Meetings.Detail(Settings.NotesFolder, S("id"));
            case "openMeeting": OpenMeetingWindow?.Invoke(S("id")); return null;
            case "openSettings": OpenSettingsWindow?.Invoke(S("pane")); return null;
            case "openWelcome": OpenWelcomeWindow?.Invoke(); return null;
            case "setDone":
                if (Folder() is { } f) Meetings.SetDone(f, a["index"]!.GetValue<int>(), B("done"));
                Emit();
                return null;
            case "saveNotes":  // edited in the meeting window: notes.json (and the ticks, which follow their to-dos), then notes.md again
                if (Folder() is { } en && a["notes"] is JsonObject notes)
                {
                    Meetings.SaveNotes(en, notes);
                    if (a["done"] is JsonArray ticks) Meetings.SetAllDone(en, ticks.Select(t => t!.GetValue<int>()));
                    // The name in meeting.json too, so transcribing again keeps it (as on the Mac)
                    if (notes["title"]?.GetValue<string>() is { Length: > 0 } named) Meetings.SetInfo(en, "title", named);
                    Enqueue(new("render", en, ["render", en]));
                }
                return null;
            case "deleteTodo":
                if (Folder() is { } dt) { Meetings.DeleteTodo(dt, a["index"]!.GetValue<int>()); Enqueue(new("render", dt, ["render", dt])); }
                return null;
            case "search": return Meetings.Search(Settings.NotesFolder, S("q"));
            case "ask": Ask(S("q")); return null;
            case "clearAnswer": answer = null; Emit(); return null;
            case "openFolder": Open(Folder() ?? Settings.NotesFolder); return null;
            case "showInExplorer":
                if (Folder() is { } sx) System.Diagnostics.Process.Start("explorer.exe", $"\"{sx}\"");
                return null;
            case "openFile":
                if (Folder() is { } d && S("name") is "notes.md" or "transcript.md") Open(Path.Combine(d, S("name")));
                return null;
            case "copyNotes":
                if (Meetings.Detail(Settings.NotesFolder, S("id")) is { } cm) Clipboard.SetText(Share.Text(cm, a["labels"] as JsonObject));
                return null;
            case "email":
                if (Meetings.Detail(Settings.NotesFolder, S("id")) is { } em)
                    Share.Email(Settings.EmailApp, Settings.GmailAccount, Share.Attendees(em), S("subject"), Share.Text(em, a["labels"] as JsonObject));
                return null;
            case "export":
            {
                var dir = Settings.ExportFolder.Length > 0 ? Settings.ExportFolder : ChooseFolder(S("title"));
                if (dir != null && Meetings.Detail(Settings.NotesFolder, S("id")) is { } ex && Folder() is { } exf
                    && Export.Save(exf, ex, dir) is { } file)
                    System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{file}\"");
                return null;
            }
            case "regenerate":
                if (Folder() is { } g)
                {
                    var template = S("template");
                    if (template.Length > 0) Meetings.SetInfo(g, "template", template);
                    Enqueue(new("summarize", g, ["summarize", g, .. template.Length > 0 ? new[] { "--template", template } : []]));
                }
                return null;
            case "notesModels": return NotesModels();
            case "regenerateInCopy": if (Folder() is { } rc) RegenerateInCopy(rc, S("repo")); return null;
            case "process":  // Create notes now, Try again, Transcribe again (the notes later if they're waiting for the PC to be free)
                if (Folder() is { } p) Enqueue(new("process", p, ProcessArgs(p, noSummary: LaterNotes.Read(p) is { Polish: false })));
                return null;
            case "importFile": ImportFile(B("transcript"), S("title")); return null;
            case "samples":
                return Folder() is { } sm ? new JsonObject { ["samples"] = Meetings.Samples(sm), ["clips"] = Meetings.Clips(sm) } : null;
            case "rename":
                if (Folder() is { } rf && a["mapping"] is JsonObject map && map.Count > 0)
                    Enqueue(new("rename", rf, ["rename", rf, .. map.Select(kv => $"{kv.Key}={kv.Value!.GetValue<string>()}")]));
                return null;
            case "confirmNames":  // "They're right": the guessed names kept, and their voices learned (as on the Mac)
                if (Folder() is { } cn && Meetings.GuessedNames(cn) is { Count: > 0 } guessed)
                    Enqueue(new("rename", cn, ["rename", cn, .. guessed.Select(n => $"{n}={n}")]));
                return null;
            case "delete":
                if (Folder() is { } del && Recorder?.Folder != del && !IsBusy(del))
                {
                    FileSystem.DeleteDirectory(del, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                    Emit();
                }
                return null;
            case "devices":
                return new JsonObject
                {
                    ["mics"] = new JsonArray(Recorder.DeviceNames(NAudio.CoreAudioApi.DataFlow.Capture).Select(n => (JsonNode)n).ToArray()),
                    ["speakers"] = new JsonArray(Recorder.DeviceNames(NAudio.CoreAudioApi.DataFlow.Render).Select(n => (JsonNode)n).ToArray()),
                };
            case "saveSettings": SaveSettings(a["settings"].Deserialize<AppSettings>() ?? Settings); return null;
            case "setLaunchAtLogin": Startup.Enabled = B("on"); Emit(); return null;
            case "chooseFolder": return ChooseFolder(S("title"));
            case "changeStorage": return ChangeStorage(S("storage"), S("path"), a["move"]?.GetValue<bool>());
            case "syncService": return Storage.SyncService(Settings.NotesFolder);
            case "voices": return new JsonArray(Voices().Select(v => (JsonNode)v).ToArray());
            case "forgetVoice": ForgetVoice(S("name")); return null;
            case "i18n": return Translations(S("lang"));
            case "startSetup": _ = RunSetup(); return null;
            case "welcomed": Settings.Welcomed = true; Settings.Save(); Emit(); return null;
            case "openLog": Open(Paths.Log); return null;
            case "showHome": System.Diagnostics.Process.Start("explorer.exe", $"\"{Paths.Home}\""); return null;
            case "engineSize": return Uninstall.Size(Paths.Home);
            case "uninstall": Uninstall.Run(Settings.NotesFolder, B("notes")); QuitRequested?.Invoke(); return null;
            case "openUrl":
                if (S("url").StartsWith("https://github.com/Gbally/Hesper")) Share.Open(S("url"));
                return null;
            // Notifications
            case "openNotificationSettings": Share.Open("ms-settings:notifications"); return null;
            case "testNotification": Notify?.Invoke("Hesper", T("Notifications work."), null); return null;
            // AI models
            case "catalog":
                return new JsonObject { ["catalog"] = catalog.ToJson(S("lang")), ["installed"] = JsonSerializer.SerializeToNode(InstalledModels()) };
            case "useModel": UseModel(S("repo"), B("speech")); return null;
            case "deleteModel": Enqueue(new("model", Paths.Home, ["models", "delete", S("repo")], Model: S("repo"))); return null;
            case "checkModel": CheckModel(S("repo"), B("speech")); return null;
            case "clearModelJob": modelJob = null; Emit(); return null;
            case "dismissMemory": Settings.Memory = null; Settings.Save(); Emit(); return null;
            case "writeLaterNow": _ = WriteLaterNotes(force: true); return null;
            // Updates
            case "checkUpdate": _ = CheckUpdate(); return null;
            case "installUpdate": _ = InstallUpdate(); return null;
            case "quit": QuitRequested?.Invoke(); return null;
        }
        return null;
    }

    void SaveSettings(AppSettings n)
    {
        var hotkey = n.Hotkey != Settings.Hotkey;
        if (n.UseCalendar != Settings.UseCalendar) calendar.SetEnabled(n.UseCalendar);
        // only changeStorage moves the notes
        (n.NotesFolder, n.Storage, n.OneDrivePath, n.CustomFolderPath) = (Settings.NotesFolder, Settings.Storage, Settings.OneDrivePath, Settings.CustomFolderPath);
        Settings = n;
        Settings.Save();
        if (hotkey) HotkeyChanged?.Invoke();
        Emit();
    }

    static string? ChooseFolder(string title)
    {
        using var dlg = new FolderBrowserDialog { UseDescriptionForTitle = true, Description = title.Length > 0 ? title : "Choose a folder" };
        return dlg.ShowDialog() == DialogResult.OK ? dlg.SelectedPath : null;
    }

    /// Settings → Privacy: where the notes go. move: null = say how many meetings would move first.
    JsonNode? ChangeStorage(string storage, string path, bool? move)
    {
        if (Recorder != null || current != null) return "busy";
        var n = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(Settings))!;
        n.Storage = storage;
        if (storage == "onedrive") n.OneDrivePath = path.Length > 0 ? path : Storage.OneDriveAccounts().FirstOrDefault().Path ?? "";
        if (storage == "custom") n.CustomFolderPath = path;
        var to = Storage.FolderFor(n);
        var from = Settings.NotesFolder;
        var count = Directory.Exists(from) ? Directory.GetDirectories(from).Length : 0;
        if (move == null && count > 0 && !to.Equals(from, StringComparison.OrdinalIgnoreCase)) return count;  // ask first
        var failed = move == true ? Storage.Move(from, to) : 0;
        n.NotesFolder = to;
        Settings = n;
        Settings.Save();
        MeetingsChanged();
        Emit();
        return failed > 0 ? $"failed:{failed}" : "ok";
    }

    // MARK: setup

    public async Task RunSetup()
    {
        if (setup != null) return;
        setupError = null;
        setup = ("Preparing…", null);
        Emit();
        var ui = SynchronizationContext.Current;
        try
        {
            Settings.WriteConfig();
            var have = InstalledModels();
            var speakerModels = Path.Combine(Paths.Home, "models", "nemo_en_titanet_small.onnx");
            var modelsThere = Setup.WasInstalled && File.Exists(speakerModels)
                              && new[] { NotesModel, SpeechModel, "base" }.All(m => m.Length > 0 && have.ContainsKey(m));
            await Setup.Run((text, p) => ui?.Post(_ => { setup = (text, p); Emit(); }, null), CancellationToken.None, modelsThere);
            PinModels();
        }
        catch (Exception e)
        {
            Paths.WriteLog("setup failed: " + e);
            setupError = e.Message;
            if (Settings.Welcomed)  // set up again after an update, in the background: say so
                Notify?.Invoke(T("Hesper couldn't finish setting up"), T("Click here to try again."), () => OpenWelcomeWindow?.Invoke());
        }
        setup = null;
        Emit();
        ResumeUnprocessed();
    }

    /// The models in use stay the ones downloaded: a newer catalog only recommends, as on the Mac
    /// (which keeps the setup's choice). Else a new recommendation would switch every PC to a model
    /// it doesn't have, downloaded in the middle of a meeting's notes, or failing offline.
    void PinModels()
    {
        if (!Ready) return;
        var have = InstalledModels();
        var changed = false;
        if (Settings.LlmModel.Length == 0 && have.ContainsKey(NotesModel)) { Settings.LlmModel = NotesModel; changed = true; }
        if (Settings.WhisperModel.Length == 0 && have.ContainsKey(SpeechModel)) { Settings.WhisperModel = SpeechModel; changed = true; }
        if (changed) Settings.Save();
    }

    /// Recordings never processed (Hesper quit, crashed or was updated meanwhile) are processed
    /// now, once per launch, as on the Mac.
    void ResumeUnprocessed()
    {
        if (resumed || !Ready) return;
        resumed = true;
        foreach (var m in AllMeetings.ToList())
            if (m["hasAudio"]?.GetValue<bool>() == true && m["hasTranscript"]?.GetValue<bool>() != true && m["error"] == null
                && FolderOf(m) is { } f && f != Recorder?.Folder && !IsBusy(f))
                ProcessRecording(f);
    }

    // MARK: recording

    public void ToggleRecording()
    {
        if (Recorder != null) StopRecording();
        else StartRecording("");
    }

    public void StartRecording(string template, bool auto = false) => _ = StartRecordingAsync(template, auto);

    async Task StartRecordingAsync(string template, bool auto)
    {
        if (Recorder != null || starting || stopping || !Ready) return;
        starting = true;
        Emit();
        var ev = Settings.UseCalendar ? calendar.Current() : null;
        // Recorded in Hesper's folder; the meeting moves to the notes folder once processed
        var folder = Paths.NewSession(Paths.Recordings, DateTime.Now, ev?.Title ?? "");
        var rec = new Recorder(folder, Settings.Microphone, Settings.Speakers, Settings.AppOnly);
        try { await Task.Run(rec.Start); }  // opening the devices takes a moment: not on the UI thread
        catch (Exception e)
        {
            rec.Dispose();
            try { Directory.Delete(folder, true); } catch (IOException) { }
            starting = false;
            Notify?.Invoke(T("Couldn't start recording"), e.Message, null);
            Emit();
            return;
        }
        starting = false;
        recordingTemplate = template.Length > 0 ? template : Settings.Template;
        Meetings.SetInfo(folder, "template", recordingTemplate);
        if (ev != null) { Meetings.SetInfo(folder, "title", ev.Title); Meetings.SetInfo(folder, "calendar", ev.ToJson()); }
        recordingEvent = ev;
        endReminderSent = false;
        notices.Clear();
        notices.AddRange(rec.Notices);
        Recorder = rec;
        autoStarted = auto;
        (callEndedAt, signalAt, keptAt, askedQuiet, hoursReminded, overQuestion) = (null, null, null, false, 0, null);
        if (auto)
            Notify?.Invoke(T("Recording “%@”", ev?.Title is { Length: > 0 } t ? t : T("this call")),
                           T("Started automatically — it stops by itself when the call ends."), null);
        MeetingsChanged();
        KeepAwake();
        Emit();
    }

    /// trimTo: drop the audio after that many seconds (the quiet tail of a forgotten recording).
    public void StopRecording(bool discard = false, double? trimTo = null) => _ = StopRecordingAsync(discard, trimTo);

    async Task StopRecordingAsync(bool discard, double? trimTo)
    {
        var rec = Recorder;
        if (rec == null) return;
        Recorder = null;
        stopping = true;  // the pages show it at once; the tracks take a moment to close
        overQuestion = null;
        Emit();
        try { await rec.StopAsync(); }
        finally { rec.Dispose(); stopping = false; }
        recordingEvent = null;
        if (discard)
        {
            try { FileSystem.DeleteDirectory(rec.Folder, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin); }  // as the Mac's Trash
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or OperationCanceledException) { }
        }
        else
        {
            if (trimTo is double t) await Task.Run(() => rec.Trim(t));
            Meetings.SetInfo(rec.Folder, "duration", Math.Min(rec.Elapsed.TotalSeconds, trimTo ?? double.MaxValue));
            if (Settings.NotesTiming != "now") LaterNotes.Mark(rec.Folder, polish: Settings.NotesTiming == "both");
            ProcessRecording(rec.Folder);
        }
        MeetingsChanged();
        KeepAwake();
        Emit();
    }

    /// `hesper process FOLDER` with the meeting's name (the calendar's, or one typed), which the
    /// notes then keep (the engine doesn't read meeting.json's), as the Mac passes it.
    static string[] ProcessArgs(string folder, bool noSummary = false)
    {
        var title = Meetings.InfoTitle(folder);
        return ["process", folder, .. title.Length > 0 ? new[] { "--title", title } : [], .. noSummary ? new[] { "--no-summary" } : []];
    }

    /// A recording to process: its transcript now, its notes now or when the PC is free (marked at
    /// the stop, Settings → Notes → When to write the notes).
    void ProcessRecording(string folder) =>
        Enqueue(new("process", folder, ProcessArgs(folder, noSummary: LaterNotes.Read(folder) is { Polish: false }), NewMeeting: true));

    [DllImport("kernel32.dll")]
    static extern uint SetThreadExecutionState(uint flags);

    /// While recording or processing, Windows doesn't put the PC to sleep (a webinar listened to
    /// without touching anything, a lunch break during the notes); the screen may still turn off.
    /// As the Mac's beginActivity. Always called on the UI thread: the setting is per thread.
    void KeepAwake() =>
        SetThreadExecutionState(0x80000000u /* ES_CONTINUOUS */ | (Recorder != null || current != null || queue.Count > 0 ? 0x1u /* ES_SYSTEM_REQUIRED */ : 0u));

    /// The calendar says the meeting ended 5 minutes ago: a signal that it's over, and a question.
    void CheckEventEnd(Recorder rec)
    {
        if (recordingEvent is not { } e || DateTime.Now <= e.End.AddMinutes(5)) return;
        signalAt ??= rec.Elapsed.TotalSeconds;
        if (Settings.EndReminders && !endReminderSent)
        {
            endReminderSent = true;
            AskIfOver("Is “%@” over?", [e.Title], T("Hesper is still recording.") + " " + T("Click here to stop."));
        }
    }

    /// "Keep recording", in the popover: the meeting isn't over.
    void KeepRecording()
    {
        if (Recorder is not { } r) return;
        keptAt = r.Elapsed.TotalSeconds;
        askedQuiet = false;
        overQuestion = null;
        Emit();
    }

    /// A question about the recording going on: a notification (a click stops it) and, in the
    /// popover, the same question with "Keep recording".
    void AskIfOver(string key, string[] args, string body)
    {
        overQuestion = (key, args);
        Notify?.Invoke(T(key, args), body, () => StopRecording());
        Emit();
    }

    void CallStarted(string app)
    {
        if (Recorder is { } rec && callEndedAt != null)  // back in a call: not over after all
        {
            (callEndedAt, signalAt, keptAt) = (null, null, rec.Elapsed.TotalSeconds);
            if (overQuestion?.Key == "The call has ended — stop recording?") { overQuestion = null; Emit(); }
            return;
        }
        if (!Ready || Recorder != null || starting) return;
        if (Settings.AutoRecord) StartRecording("", auto: true);
        else if (Settings.CallReminders)
        {
            var ev = Settings.UseCalendar ? calendar.Current() : null;
            Notify?.Invoke(ev != null ? T("Record “%@”?", ev.Title) : T("Record this call?"),
                           T("%@ is using the microphone. Click here to take notes with Hesper.", app), () => StartRecording(""));
        }
    }

    /// The call app released the microphone for 45 s: an automatic recording stops by itself; one
    /// started by hand asks, then stops by itself too (CheckMeetingOver).
    void CallEnded()
    {
        if (Recorder is not { } rec) return;
        if (autoStarted) { StopRecording(); return; }
        callEndedAt = rec.Elapsed.TotalSeconds;
        signalAt ??= callEndedAt;
        if (!Settings.StopWhenOver && !Settings.EndReminders) return;
        AskIfOver("The call has ended — stop recording?", [],
            Settings.StopWhenOver ? T("Hesper stops by itself in %@ min unless you keep it going.", (int)(AfterCall / 60)) + " " + T("Click here to stop now.")
                                  : T("Hesper is still recording.") + " " + T("Click here to stop."));
    }

    /// Notices a recording that goes on after the meeting (Stop forgotten): asks, then stops by
    /// itself and drops the quiet tail. As checkMeetingOver on the Mac.
    void CheckMeetingOver(Recorder rec)
    {
        var now = rec.Elapsed.TotalSeconds;
        var heard = Math.Max(rec.LastSound, keptAt ?? 0);
        var quiet = now - heard;
        var cut = heard + 60;  // keep a minute after the last sound
        if (quiet < 60)
        {
            askedQuiet = false;
            if (overQuestion?.Key == "Is the meeting over?") { overQuestion = null; Emit(); }  // someone is talking again
        }
        if ((Settings.EndReminders || Settings.StopWhenOver) && quiet >= QuietAsk && !askedQuiet)
        {
            askedQuiet = true;
            var minutes = (int)(quiet / 60);
            AskIfOver("Is the meeting over?", [],
                (Settings.StopWhenOver ? T("Nothing heard for %@ min. Hesper stops by itself after %@ min of quiet.", minutes, (int)(QuietStop / 60))
                                       : T("Nothing heard for %@ min.", minutes)) + " " + T("Click here to stop now."));
        }
        var hours = (int)(now / 3600);
        if ((Settings.EndReminders || Settings.StopWhenOver) && hours >= 2 && hours > hoursReminded)
        {
            hoursReminded = hours;
            AskIfOver("Still recording after %@ h", [hours.ToString()], T("Is the meeting still going on?") + " " + T("Click here to stop."));
        }
        if (!Settings.StopWhenOver) return;
        void AutoStop(string why, double? trim)
        {
            Notify?.Invoke(T("Recording stopped"), why + " " + T("The notes are on their way."), null);
            StopRecording(trimTo: trim);
        }
        if (quiet >= QuietStop) { AutoStop(T("Nothing heard for %@ min.", (int)(quiet / 60)), cut); return; }
        if (signalAt is double sig && (keptAt == null || keptAt < sig) && quiet >= QuietAfterSignal && now - sig >= QuietAfterSignal)
        { AutoStop(T("The meeting is over and it's been quiet for %@ min.", (int)(quiet / 60)), cut); return; }
        if (callEndedAt is double ended && (keptAt == null || keptAt < ended) && now - ended >= AfterCall)
            AutoStop(T("The call ended %@ min ago.", (int)((now - ended) / 60)), quiet >= 60 ? cut : null);
    }

    // MARK: jobs (one at a time, as on the Mac)

    bool IsBusy(string folder) => current?.Folder == folder || queue.Any(q => q.Folder == folder);

    void Enqueue(Job job)
    {
        // The same job already waiting or running (a button clicked twice): once is enough. Not a
        // running render: notes saved again since then need theirs.
        var same = queue.Concat(current is { Kind: not "render" } c ? [c] : Array.Empty<Job>());
        if (job.Kind is not ("ask" or "model" or "check") && same.Any(q => q.Kind == job.Kind && q.Args.SequenceEqual(job.Args))) return;
        queue.Enqueue(job);
        MeetingsChanged();
        Emit();
        if (current == null) _ = RunJobs();
    }

    async Task RunJobs()
    {
        var ui = SynchronizationContext.Current;
        while (queue.Count > 0)
        {
            current = queue.Dequeue();
            (jobStep, jobProgress, jobStarted) = ("", null, DateTime.Now);
            var job = current;
            if (job.Kind == "model") modelJob = new JsonObject { ["status"] = job.Args[1] == "delete" ? "Deleting…" : "Starting…", ["repo"] = job.Model };
            MeetingsChanged();
            KeepAwake();
            Emit();
            var otherModel = job.Kind is "later" or "copy" && job.Model != null;
            if (otherModel) Settings.WriteConfig(job.Model);  // that notes model, for this job only
            string? result = null, memory = null, done = null;
            var transcribing = false;
            var r = await EngineRunner.Hesper(job.Args, line =>
            {
                if (line.StartsWith("@@result ")) { result = line[9..]; return; }
                if (line.StartsWith("@@memory ")) { memory = line[9..].Trim(); return; }  // a model ran out of memory: which one
                if (line.StartsWith("✅ Done") && line.Contains("→ ")) { done = line[(line.IndexOf("→ ", StringComparison.Ordinal) + 2)..].Trim(); return; }
                var (s, p) = EngineRunner.Parse(line);
                if (s == null && p == null) return;
                if (s != null) transcribing = s.Contains("ranscrib");
                ui?.Post(_ =>
                {
                    if (s != null) jobStep = s;
                    if (p != null) jobProgress = p;
                    if (modelJob != null && job.Kind == "model") { modelJob["status"] = jobStep; modelJob["progress"] = jobProgress; }
                    Emit();
                }, null);
            });
            if (otherModel) Settings.WriteConfig();
            memory ??= r.OutOfMemory ? (transcribing ? "speech" : "notes") : null;
            Finished(job, r, result, memory, done);
            current = null;
            MeetingsChanged();
            KeepAwake();
            Emit();
        }
        _ = WriteLaterNotes(force: false);  // the PC may be free now
    }

    void Finished(Job job, EngineRunner.Result r, string? result, string? memory, string? done)
    {
        // A model too big for this PC: said in the popover, and instead of the engine's errors
        string? memoryFailure = null;
        if (memory != null && job.Kind is not ("model" or "check"))
        {
            var speech = memory == "speech";
            Settings.Memory = new MemoryWarning { Model = speech ? SpeechModel : job.Model ?? NotesModel, Speech = speech, Failed = !r.Ok };
            Settings.Save();
            if (!r.Ok) memoryFailure = MemoryMessage(Settings.Memory);
        }
        switch (job.Kind)
        {
            case "ask":
                answer = new JsonObject
                {
                    ["question"] = job.Args.Last(), ["busy"] = false,
                    ["result"] = result != null ? JsonNode.Parse(result) : null, ["error"] = r.Ok ? null : memoryFailure ?? r.ErrorTail,
                };
                return;
            case "model":
                modelJob = r.Ok ? null : new JsonObject { ["error"] = r.ErrorTail, ["repo"] = job.Model };
                if (r.Ok && job.Args[1] == "download" && pendingModel is { } pm && pm.Repo == job.Model) ApplyModel(pm.Repo, pm.Speech);
                pendingModel = null;
                return;
            case "check":
                modelJob = new JsonObject { ["check"] = result != null ? JsonNode.Parse(result) : null, ["repo"] = job.Model,
                                            ["error"] = r.Ok ? null : r.ErrorTail, ["speech"] = job.Args.Contains("speech") };
                return;
            case "import":  // an audio file or a transcript: a new meeting, as a recording's
                if (r.Ok && done != null && Directory.Exists(done))
                {
                    if (Settings.NotesTiming != "now") LaterNotes.Mark(done, polish: Settings.NotesTiming == "both");
                    NewMeetingDone(done);
                    if (Settings.NotesTiming != "later") Announce(done, true, null);
                }
                else if (!r.Ok) Notify?.Invoke(T("Couldn't process the meeting"), memoryFailure ?? r.ErrorTail, null);
                return;
        }
        var folder = job.Folder;
        if (r.Ok && job.Kind == "process") folder = MoveToNotes(folder);
        var error = Path.Combine(folder, "error.txt");
        if (r.Ok) File.Delete(error);
        else File.WriteAllText(error, memoryFailure ?? (r.ErrorTail.Length > 0 ? r.ErrorTail : T("Processing failed.")));
        if (job.Kind == "later" && r.Ok)
        {
            var item = LaterNotes.Read(folder);
            LaterNotes.Clear(folder);
            if (item is not { Polish: true }) AutoExport(folder);  // the first notes of a meeting waiting for them
        }
        if (job.Kind == "process" && job.NewMeeting && r.Ok) NewMeetingDone(folder);
        var announce = job.Kind is "later" or "copy" || (job.Kind == "process" && job.NewMeeting && Settings.NotesTiming != "later");
        if (announce || memoryFailure != null) Announce(folder, r.Ok, memoryFailure);
    }

    /// A new meeting's transcript (and maybe its notes) are made: the later notes' mark, old audio,
    /// the copy in the export folder.
    void NewMeetingDone(string folder)
    {
        LaterNotes.Seal(folder);  // quick notes made: better ones replace them only if unedited
        if (Settings.AudioRetentionDays == 0) Retention.DeleteAudio(folder);
        if (File.Exists(Path.Combine(folder, "notes.md")) && LaterNotes.Read(folder) is null or { Polish: true }) AutoExport(folder);
    }

    /// "Notes ready" (or why not); not enough memory is said even with "When notes are ready" off.
    void Announce(string folder, bool ok, string? memoryFailure)
    {
        if (!Settings.NotifyWhenReady && memoryFailure == null) return;
        var id = Path.GetFileName(folder);
        var title = Meetings.TitleOf(folder) is { Length: > 0 } t ? t : T("Meeting");
        void open() => OpenMeetingWindow?.Invoke(id);
        if (ok && File.Exists(Path.Combine(folder, "notes.md")))
            Notify?.Invoke(T("Notes ready"), T("%@ — click to see the summary and to-dos.", title), open);
        else if (memoryFailure != null) Notify?.Invoke(T("Not enough memory"), title + " — " + memoryFailure, open);
        else if (!ok) Notify?.Invoke(T("Couldn't process the meeting"), title, open);
    }

    /// Running out of memory, said plainly, with what to do.
    string MemoryMessage(MemoryWarning w) => w.Speech
        ? T("Not enough memory to transcribe on this Mac. Close other apps, or choose a smaller speech model in Settings → AI models, then try again.")
        : T("Not enough memory for %@ on this Mac. Choose a smaller notes model in Settings → AI models, then try again.", ModelName(w.Model));

    /// A processed recording leaves Hesper's folder for the notes folder (maybe synced). Returns
    /// where the meeting is now.
    string MoveToNotes(string folder)
    {
        if (!string.Equals(Path.GetFullPath(Path.GetDirectoryName(folder)!), Path.GetFullPath(Paths.Recordings), StringComparison.OrdinalIgnoreCase))
            return folder;
        var name = Path.GetFileName(folder);
        var dest = Path.Combine(Settings.NotesFolder, name);
        for (var n = 2; Directory.Exists(dest); n++) dest = Path.Combine(Settings.NotesFolder, $"{name}-{n}");
        try
        {
            Storage.MoveFolder(folder, dest);
            return dest;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Paths.WriteLog($"couldn't move {name} to the notes folder: {e.Message}");
            return folder;
        }
    }

    /// A finished meeting's notes, copied to the export folder when that's switched on. Never over
    /// the meeting's existing copy (as on the Mac): it may have been edited in the notes app.
    void AutoExport(string folder)
    {
        if (!Settings.AutoExport || Settings.ExportFolder.Length == 0) return;
        if (Meetings.Detail(Settings.NotesFolder, Path.GetFileName(folder)) is not { } m || m["notes"] == null) return;
        if (File.Exists(Export.FileFor(m, Settings.ExportFolder))) return;
        Export.Save(folder, m, Settings.ExportFolder);
    }

    void Ask(string question)
    {
        if (question.Trim().Length == 0) return;
        answer = new JsonObject { ["question"] = question, ["busy"] = true };
        Enqueue(new("ask", Settings.NotesFolder, ["ask", "--json", question]));
    }

    /// ⋯ → Transcribe an audio file… / Import a transcript…: `hesper process FILE` makes its meeting.
    void ImportFile(bool transcript, string title)
    {
        using var dlg = new OpenFileDialog
        {
            Title = title,
            Filter = transcript ? "Transcripts|*.vtt;*.srt;*.sbv;*.docx;*.txt;*.md"
                                : "Audio, video|*.m4a;*.mp3;*.wav;*.mp4;*.mov;*.webm;*.ogg;*.flac;*.aac;*.caf;*.wma|*.*|*.*",
        };
        if (dlg.ShowDialog() != DialogResult.OK) return;
        Enqueue(new("import", Settings.NotesFolder, ["process", dlg.FileName, .. Settings.NotesTiming == "later" ? new[] { "--no-summary" } : []]));
    }

    // MARK: every minute: reminders, old audio, notes written later, the catalog, updates

    void EveryMinute()
    {
        if (Settings.DueReminders) DueReminders();
        if (Settings.Briefs && Settings.UseCalendar && Ready) CheckBriefs();
        if (DateTime.Now - lastCleanup > TimeSpan.FromHours(1))
        {
            lastCleanup = DateTime.Now;
            Retention.CleanUp(Settings.NotesFolder, Settings.AudioRetentionDays,
                              queue.Append(current).OfType<Job>().Select(j => j.Folder).Append(Recorder?.Folder ?? "").ToHashSet());
        }
        _ = WriteLaterNotes(force: false);
        if (DateTime.Now - lastCatalog > TimeSpan.FromDays(1))
        {
            lastCatalog = DateTime.Now;
            var ui = SynchronizationContext.Current;
            _ = Catalog.Refresh().ContinueWith(_ => ui?.Post(_ => catalog = Catalog.Load(), null));
        }
        if (DateTime.Now - lastUpdateCheck > TimeSpan.FromDays(1)) _ = CheckUpdate();
    }

    /// 9:00 the day before one of my open to-dos is due (or 9:00 on the day): a notification.
    void DueReminders()
    {
        var me = Settings.MyName.Trim().ToLowerInvariant().Split(' ').FirstOrDefault() ?? "";
        if (me.Length == 0 || DateTime.Now.Hour < 9) return;
        foreach (var m in AllMeetings.ToList())
        {
            var done = m["done"]!.AsArray().Select(d => d!.GetValue<int>()).ToHashSet();
            var actions = m["actions"]!.AsArray();
            for (var i = 0; i < actions.Count; i++)
            {
                var a = actions[i]!;
                if (done.Contains(i) || a["due_date"]?.GetValue<string>() is not { } due || !DateTime.TryParse(due, out var day)) continue;
                var owner = (a["owner"]?.GetValue<string>() ?? "").ToLowerInvariant();
                if (!owner.Split(' ', ',', '&', '+').Contains(me)) continue;
                var label = day.Date == DateTime.Today.AddDays(1) ? "Due tomorrow" : day.Date == DateTime.Today ? "Due today" : null;
                var key = $"{m["id"]}/{i}/{label}";
                if (label == null || Reminded(key)) continue;
                var id = m["id"]!.GetValue<string>();
                Notify?.Invoke(T(label), T("%@ — from “%@”", a["task"]?.GetValue<string>() ?? "", m["title"]?.GetValue<string>() ?? ""),
                               () => OpenMeetingWindow?.Invoke(id));
            }
        }
    }

    /// ~5 minutes before a meeting that happened before: a notification with what's still open.
    void CheckBriefs()
    {
        foreach (var e in calendar.Upcoming(6))
        {
            var key = e.Id ?? e.Title;
            if (!briefed.Add(key) || Brief(e) is not { } b) continue;
            var n = b["open"]!.AsArray().Count;
            var minutes = Math.Max(1, (int)(e.Start - DateTime.Now).TotalMinutes);
            Notify?.Invoke(T("In %@ min: %@", minutes, e.Title),
                           (n == 0 ? T("No open to-dos from last time") : n == 1 ? T("1 open to-do from last time") : T("%@ open to-dos from last time", n))
                           + ". " + T("Click to review."),
                           () => BriefRequested?.Invoke(key));
        }
    }

    /// Reminders already shown (reminders.txt), so a restart doesn't repeat them.
    static bool Reminded(string key)
    {
        var file = Path.Combine(Paths.Home, "reminders.txt");
        var seen = File.Exists(file) ? File.ReadAllLines(file).ToHashSet() : [];
        if (seen.Contains(key)) return true;
        File.AppendAllLines(file, [key]);
        return false;
    }

    /// Notes waiting for the PC to be free (Settings → Notes → When to write the notes): one meeting
    /// at a time, with the "later" model; edited notes aren't replaced.
    async Task WriteLaterNotes(bool force)
    {
        await Task.Yield();
        if (current != null || queue.Count > 0 || Recorder != null || starting || !Ready) return;
        if (!force && !PcUse.Free(Settings)) return;
        foreach (var folder in PendingLater())
        {
            if (!File.Exists(Path.Combine(folder, "transcript.json"))) continue;
            var item = LaterNotes.Read(folder)!;
            if (item.Polish && item.NotesHash != null && item.NotesHash != LaterNotes.Hash(folder))
            {
                LaterNotes.Clear(folder);  // edited since the quick notes: keep them
                MeetingsChanged();
                continue;
            }
            Enqueue(new("later", folder, ["summarize", folder], Model: Settings.LaterModel.Length > 0 ? Settings.LaterModel : NotesModel));
            return;
        }
    }

    // MARK: AI models

    record PendingModel(string Repo, bool Speech);
    PendingModel? pendingModel;

    /// The models on disk (name or "repo:quant" → GB): faster-whisper's in hf\hub, llama.cpp's GGUF files.
    static Dictionary<string, double> InstalledModels()
    {
        var found = new Dictionary<string, double>();
        var hub = Path.Combine(Paths.Home, "hf", "hub");
        var names = new Dictionary<string, string>
        {
            ["mobiuslabsgmbh/faster-whisper-large-v3-turbo"] = "large-v3-turbo", ["Systran/faster-whisper-large-v3"] = "large-v3",
            ["Systran/faster-whisper-base"] = "base", ["Systran/faster-whisper-medium"] = "medium", ["Systran/faster-whisper-small"] = "small",
        };
        foreach (var dir in Directory.Exists(hub) ? Directory.GetDirectories(hub, "models--*") : [])
        {
            var repo = Path.GetFileName(dir)["models--".Length..].Replace("--", "/");
            found[names.GetValueOrDefault(repo, repo)] = Math.Round(Uninstall.Size(dir) / 1e9, 2);
        }
        var gguf = Path.Combine(Paths.Home, "models", "gguf");
        foreach (var dir in Directory.Exists(gguf) ? Directory.GetDirectories(gguf, "models--*") : [])
        {
            var repo = Path.GetFileName(dir)["models--".Length..].Replace("--", "/");
            foreach (var f in Directory.EnumerateFiles(dir, "*.gguf", System.IO.SearchOption.AllDirectories))
            {
                var m = Regex.Match(Path.GetFileName(f), @"-((?:UD-)?I?Q\d\w*|BF16|F16|F32)\.gguf$", RegexOptions.IgnoreCase);
                if (m.Success && !f.Contains("mmproj")) found[$"{repo}:{m.Groups[1].Value}"] = Math.Round(new FileInfo(f).Length / 1e9, 2);
            }
        }
        return found;
    }

    void UseModel(string repo, bool speech)
    {
        if (InstalledModels().ContainsKey(repo) || !Ready)
        {
            ApplyModel(repo, speech);
            Emit();
            return;
        }
        pendingModel = new(repo, speech);
        Enqueue(new("model", Paths.Home, ["models", "download", repo], Model: repo));
    }

    void ApplyModel(string repo, bool speech)
    {
        if (speech) Settings.WhisperModel = repo; else Settings.LlmModel = repo;
        if (Settings.Memory?.Speech == speech) Settings.Memory = null;  // the model it was about is no longer used
        Settings.Save();
    }

    void CheckModel(string link, bool speech)
    {
        // "https://huggingface.co/org/name" (+ ":Q4_K_M") → "org/name:Q4_K_M"
        var repo = Regex.Replace(link.Trim(), @"^(https?://)?(www\.)?huggingface\.co/", "").Trim('/');
        modelJob = new JsonObject { ["status"] = "Checking…", ["repo"] = repo };
        Enqueue(new("check", Paths.Home, ["models", "check", repo, "--kind", speech ? "speech" : "notes"], Model: repo));
    }

    /// The notes models on this PC, for "Regenerate in a copy with…": {repo, name, current}.
    JsonArray NotesModels()
    {
        var have = InstalledModels().Keys.Where(r => r.Contains(':')).Append(NotesModel).Append(Settings.LaterModel)
                                        .Where(r => r.Length > 0).Distinct().ToList();
        var listed = catalog.Notes.Where(m => have.Contains(m.Repo)).Select(m => m.Repo);
        var order = listed.Concat(have.Where(r => catalog.Notes.All(m => m.Repo != r)).Order());
        return new JsonArray(order.Select(r => (JsonNode)new JsonObject { ["repo"] = r, ["name"] = ModelName(r), ["current"] = r == NotesModel }).ToArray());
    }

    /// New notes with another model in a copy of the meeting ("… (Qwen3.5 9B)"), the original kept
    /// as it is: to compare models, as the Mac's "Regenerate in a copy with…".
    void RegenerateInCopy(string folder, string repo)
    {
        if (repo.Length == 0) return;
        var name = ModelName(repo);
        var slug = Regex.Replace(name, "[^A-Za-z0-9.]+", "-").Trim('-');
        var parent = Path.GetDirectoryName(folder)!;
        var id = Path.GetFileName(folder);
        var (copy, n) = (Path.Combine(parent, $"{id}-{slug}"), 1);
        while (Directory.Exists(copy)) { n++; copy = Path.Combine(parent, $"{id}-{slug}-{n}"); }
        try
        {
            Directory.CreateDirectory(copy);
            foreach (var f in new[] { "transcript.json", "transcript.md", "speakers.json", "clips.json", "meeting.json" })
                if (File.Exists(Path.Combine(folder, f))) File.Copy(Path.Combine(folder, f), Path.Combine(copy, f));
            if (Directory.Exists(Path.Combine(folder, "clips"))) FileSystem.CopyDirectory(Path.Combine(folder, "clips"), Path.Combine(copy, "clips"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Notify?.Invoke(T("Couldn't copy the meeting: %@", e.Message), "", null);
            return;
        }
        var template = Meetings.Detail(Settings.NotesFolder, id)?["template"]?.GetValue<string>();
        if (template != null) Meetings.SetInfo(copy, "template", template);
        Meetings.SetInfo(copy, "label", n == 1 ? name : $"{name} {n}");
        Enqueue(new("copy", copy, ["summarize", copy], Model: repo));
    }

    // MARK: updates

    async Task CheckUpdate()
    {
        lastUpdateCheck = DateTime.Now;
        update = new JsonObject { ["state"] = "checking", ["available"] = update?["available"]?.DeepClone() };
        Emit();
        var info = await Updater.Check(Settings.TestVersions);
        update = new JsonObject { ["state"] = "idle", ["available"] = info, ["checked"] = DateTime.Now.ToString("HH:mm") };
        Emit();
    }

    async Task InstallUpdate()
    {
        if (update?["available"] is not JsonObject info || Recorder != null || current != null || stopping) return;
        update["state"] = "downloading";
        Emit();
        var ui = SynchronizationContext.Current;
        try
        {
            await Updater.Install(info, p => ui?.Post(_ => { update!["progress"] = p; Emit(); }, null));
            QuitRequested?.Invoke();
        }
        catch (Exception e)
        {
            update["state"] = "failed";
            update["error"] = e.Message;
            Emit();
        }
    }

    // MARK: voices (voices.json: {name: [voiceprints]})

    static string VoicesFile => Path.Combine(Paths.Home, "voices.json");

    static List<string> Voices()
    {
        try { return JsonNode.Parse(File.ReadAllText(VoicesFile))?.AsObject().Select(kv => kv.Key).Order().ToList() ?? []; }
        catch (Exception e) when (e is IOException or JsonException) { return []; }
    }

    void ForgetVoice(string name)
    {
        try
        {
            var lib = JsonNode.Parse(File.ReadAllText(VoicesFile))!.AsObject();
            lib.Remove(name);
            File.WriteAllText(VoicesFile, lib.ToJsonString());
        }
        catch (Exception e) when (e is IOException or JsonException) { }
        Emit();
    }

    /// The Mac app's translations (mac/Localization/xx.json, English text → translation), inside the exe.
    static JsonNode? Translations(string lang)
    {
        using var s = typeof(AppModel).Assembly.GetManifestResourceStream($"i18n/{lang}.json");
        return s == null ? null : JsonNode.Parse(s);
    }

    public static void Open(string path)
    {
        if (!File.Exists(path)) Directory.CreateDirectory(path);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
    }
}

/// A meeting waiting for its notes (or its better notes): notes_later.json in its folder, as on the Mac.
sealed class LaterNotes
{
    public bool Polish { get; set; }     // quick notes exist: replace them, unless edited since
    public string? NotesHash { get; set; }
    const string FileName = "notes_later.json";

    public static string? Hash(string folder)
    {
        var f = Path.Combine(folder, "notes.json");
        return File.Exists(f) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f))).ToLowerInvariant() : null;
    }

    public static LaterNotes? Read(string folder)
    {
        try
        {
            var n = JsonNode.Parse(File.ReadAllText(Path.Combine(folder, FileName)));
            return new LaterNotes { Polish = n?["polish"]?.GetValue<bool>() == true, NotesHash = n?["notesHash"]?.GetValue<string>() };
        }
        catch (Exception e) when (e is IOException or JsonException) { return null; }
    }

    public static void Mark(string folder, bool polish) =>
        File.WriteAllText(Path.Combine(folder, FileName), new JsonObject { ["polish"] = polish }.ToJsonString());

    /// After the quick notes: remember them, so that edits made since aren't replaced.
    public static void Seal(string folder)
    {
        if (Read(folder) is { Polish: true })
            File.WriteAllText(Path.Combine(folder, FileName), new JsonObject { ["polish"] = true, ["notesHash"] = Hash(folder) }.ToJsonString());
    }

    public static void Clear(string folder) => File.Delete(Path.Combine(folder, FileName));
}
