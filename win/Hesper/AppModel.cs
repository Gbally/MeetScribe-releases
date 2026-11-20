using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

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
    bool autoStarted;
    readonly CallMonitor calls = new();
    readonly System.Windows.Forms.Timer minute = new() { Interval = 60_000 }, second = new() { Interval = 1000 };
    DateTime lastCleanup = DateTime.MinValue, lastCatalog = DateTime.MinValue, lastUpdateCheck = DateTime.MinValue;
    Catalog catalog = Catalog.Load();
    readonly OutlookCalendar calendar;
    CalendarEvent? recordingEvent;
    bool endReminderSent;
    readonly HashSet<string> briefed = [];

    // A recording that goes on after the meeting (MeetingOverWatch on the Mac)
    const double QuietAsk = 10 * 60, QuietStop = 30 * 60, QuietAfterSignal = 5 * 60, AfterCall = 10 * 60;
    double? callEndedAt, signalAt, keptAt;
    bool askedQuiet;
    int hoursReminded;

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
        var first = new System.Windows.Forms.Timer { Interval = 5000 };
        first.Tick += (_, _) => { first.Dispose(); EveryMinute(); };
        first.Start();
    }

    void Emit() => Changed?.Invoke();

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
        } : null,
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
        ["meetings"] = Meetings.List(Settings.NotesFolder),
        ["settings"] = JsonSerializer.SerializeToNode(Settings),
        ["launchAtLogin"] = Startup.Enabled,
        ["version"] = Setup.AppVersion,
        ["build"] = Updater.Build,
        ["gpu"] = Setup.HasNvidia,
        ["notesModel"] = NotesModel,
        ["speechModel"] = SpeechModel,
        ["laterPending"] = LaterNotes.Pending(Settings.NotesFolder).Count,
        ["oneDrive"] = new JsonArray(Storage.OneDriveAccounts().Select(a => (JsonNode)new JsonObject { ["name"] = a.Name, ["path"] = a.Path }).ToArray()),
        ["outlook"] = Share.OutlookPath() != null,
        ["home"] = Paths.Home,
        ["calendar"] = CalendarState(),
        ["appLoopback"] = ProcessLoopbackCapture.Supported,
    };

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
        return Meetings.List(Settings.NotesFolder).OfType<JsonObject>().Where(m =>
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

    /// What's still open from the earlier meetings like this one, and the last of them.
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
        return new JsonObject { ["last"] = previous[0]["id"]!.GetValue<string>(), ["lastDate"] = previous[0]["date"]!.GetValue<string>(), ["open"] = open };
    }

    string NotesModel => Settings.LlmModel.Length > 0 ? Settings.LlmModel : catalog.Recommended(false)?.Repo ?? "";
    string SpeechModel => Settings.WhisperModel.Length > 0 ? Settings.WhisperModel : catalog.Recommended(true)?.Repo ?? "";

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

    public JsonNode? Handle(string cmd, JsonObject a)
    {
        string S(string k) => a[k]?.GetValue<string>() ?? "";
        bool B(string k) => a[k]?.GetValue<bool>() == true;
        string? Folder() => Meetings.FolderOf(Settings.NotesFolder, S("id"));
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
            case "saveNotes":  // edited in the meeting window: notes.json, then notes.md again
                if (Folder() is { } en && a["notes"] is JsonObject notes)
                {
                    Meetings.SaveNotes(en, notes);
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
                    Share.Email(Settings.EmailApp, Settings.GmailAccount, S("subject"), Share.Text(em, a["labels"] as JsonObject));
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
            case "process": if (Folder() is { } p) Enqueue(new("process", p, ["process", p])); return null;
            case "importFile": ImportFile(B("transcript"), S("title")); return null;
            case "samples": return Folder() is { } sm ? Meetings.Samples(sm) : null;
            case "rename":
                if (Folder() is { } rf && a["mapping"] is JsonObject map && map.Count > 0)
                    Enqueue(new("rename", rf, ["rename", rf, .. map.Select(kv => $"{kv.Key}={kv.Value!.GetValue<string>()}")]));
                return null;
            case "confirmNames": if (Folder() is { } cn) Meetings.ConfirmGuessedNames(cn); Emit(); return null;
            case "delete":
                if (Folder() is { } del && Recorder?.Folder != del && !IsBusy(del))
                {
                    Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(del, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                                                                           Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
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
            // AI models
            case "catalog":
                return new JsonObject { ["catalog"] = catalog.ToJson(S("lang")), ["installed"] = JsonSerializer.SerializeToNode(InstalledModels()) };
            case "useModel": UseModel(S("repo"), B("speech")); return null;
            case "deleteModel": Enqueue(new("model", Paths.Home, ["models", "delete", S("repo")], Model: S("repo"))); return null;
            case "checkModel": CheckModel(S("repo"), B("speech")); return null;
            case "clearModelJob": modelJob = null; Emit(); return null;
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
            await Setup.Run((text, p) => ui?.Post(_ => { setup = (text, p); Emit(); }, null), CancellationToken.None);
        }
        catch (Exception e)
        {
            Paths.WriteLog("setup failed: " + e);
            setupError = e.Message;
        }
        setup = null;
        Emit();
    }

    // MARK: recording

    public void ToggleRecording()
    {
        if (Recorder != null) StopRecording();
        else StartRecording("");
    }

    public void StartRecording(string template, bool auto = false)
    {
        if (Recorder != null || !Ready) return;
        var ev = Settings.UseCalendar ? calendar.Current() : null;
        var folder = Paths.NewSession(Settings.NotesFolder, DateTime.Now, ev?.Title ?? "");
        var rec = new Recorder(folder, Settings.Microphone, Settings.Speakers, Settings.AppOnly);
        try { rec.Start(); }
        catch (Exception e)
        {
            rec.Dispose();
            try { Directory.Delete(folder); } catch (IOException) { }
            Notify?.Invoke("Recording failed", e.Message, null);
            return;
        }
        recordingTemplate = template.Length > 0 ? template : Settings.Template;
        Meetings.SetInfo(folder, "template", recordingTemplate);
        if (ev != null) { Meetings.SetInfo(folder, "title", ev.Title); Meetings.SetInfo(folder, "calendar", ev.ToJson()); }
        recordingEvent = ev;
        endReminderSent = false;
        notices.Clear();
        notices.AddRange(rec.Notices);
        Recorder = rec;
        autoStarted = auto;
        (callEndedAt, signalAt, keptAt, askedQuiet, hoursReminded) = (null, null, null, false, 0);
        Emit();
    }

    /// trimTo: drop the audio after that many seconds (the quiet tail of a forgotten recording).
    public void StopRecording(bool discard = false, double? trimTo = null)
    {
        var rec = Recorder;
        if (rec == null) return;
        Recorder = null;
        rec.Stop();
        rec.Dispose();
        if (discard)
        {
            try { Directory.Delete(rec.Folder, true); } catch (IOException) { }
        }
        else
        {
            if (trimTo is double t) rec.Trim(t);
            Meetings.SetInfo(rec.Folder, "duration", Math.Min(rec.Elapsed.TotalSeconds, trimTo ?? double.MaxValue));
            if (Settings.NotesTiming != "now") LaterNotes.Mark(rec.Folder, polish: Settings.NotesTiming == "both");
            Enqueue(new("process", rec.Folder,
                        ["process", rec.Folder, "--template", recordingTemplate, .. Settings.NotesTiming == "later" ? new[] { "--no-summary" } : []],
                        NewMeeting: true));
        }
        Emit();
    }

    /// The calendar says the meeting ended 5 minutes ago: a signal that it's over, and a question.
    void CheckEventEnd(Recorder rec)
    {
        if (recordingEvent is not { } e || DateTime.Now <= e.End.AddMinutes(5)) return;
        signalAt ??= rec.Elapsed.TotalSeconds;
        if (Settings.EndReminders && !endReminderSent)
        {
            endReminderSent = true;
            Notify?.Invoke($"Is “{e.Title}” over?", "Hesper is still recording. Click here to stop.", () => StopRecording());
        }
    }

    void KeepRecording()
    {
        if (Recorder is not { } r) return;
        keptAt = r.Elapsed.TotalSeconds;
        askedQuiet = false;
    }

    void CallStarted(string app)
    {
        if (Recorder is { } rec && callEndedAt != null)  // back in a call: not over after all
        {
            (callEndedAt, signalAt, keptAt) = (null, null, rec.Elapsed.TotalSeconds);
            return;
        }
        if (!Ready || Recorder != null) return;
        if (Settings.AutoRecord) StartRecording("", auto: true);
        else if (Settings.CallReminders)
            Notify?.Invoke("Record this call?", $"{app} is using the microphone. Click here to take notes with Hesper.", () => StartRecording(""));
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
        Notify?.Invoke("The call has ended — stop recording?",
                       Settings.StopWhenOver ? $"Hesper stops by itself in {AfterCall / 60:0} min. Click here to stop now." : "Hesper is still recording. Click here to stop.",
                       () => StopRecording());
    }

    /// Notices a recording that goes on after the meeting (Stop forgotten): asks, then stops by
    /// itself and drops the quiet tail. As checkMeetingOver on the Mac.
    void CheckMeetingOver(Recorder rec)
    {
        var now = rec.Elapsed.TotalSeconds;
        var heard = Math.Max(rec.LastSound, keptAt ?? 0);
        var quiet = now - heard;
        var cut = heard + 60;  // keep a minute after the last sound
        if (quiet < 60) askedQuiet = false;
        if ((Settings.EndReminders || Settings.StopWhenOver) && quiet >= QuietAsk && !askedQuiet)
        {
            askedQuiet = true;
            Notify?.Invoke("Is the meeting over?",
                           $"Nothing heard for {quiet / 60:0} min." + (Settings.StopWhenOver ? $" Hesper stops by itself after {QuietStop / 60:0} min of quiet." : "")
                           + " Click here to stop now.", () => StopRecording());
        }
        var hours = (int)(now / 3600);
        if ((Settings.EndReminders || Settings.StopWhenOver) && hours >= 2 && hours > hoursReminded)
        {
            hoursReminded = hours;
            Notify?.Invoke($"Still recording after {hours} h", "Is the meeting still going on? Click here to stop.", () => StopRecording());
        }
        if (!Settings.StopWhenOver) return;
        void AutoStop(string why, double? trim)
        {
            Notify?.Invoke("Recording stopped", why + " The notes are on their way.", null);
            StopRecording(trimTo: trim);
        }
        if (quiet >= QuietStop) { AutoStop($"Nothing heard for {quiet / 60:0} min.", cut); return; }
        if (signalAt is double sig && (keptAt == null || keptAt < sig) && quiet >= QuietAfterSignal && now - sig >= QuietAfterSignal)
        { AutoStop($"The meeting is over and it's been quiet for {quiet / 60:0} min.", cut); return; }
        if (callEndedAt is double ended && (keptAt == null || keptAt < ended) && now - ended >= AfterCall)
            AutoStop($"The call ended {(now - ended) / 60:0} min ago.", quiet >= 60 ? cut : null);
    }

    // MARK: jobs (one at a time, as on the Mac)

    bool IsBusy(string folder) => current?.Folder == folder || queue.Any(q => q.Folder == folder);

    void Enqueue(Job job)
    {
        queue.Enqueue(job);
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
            Emit();
            if (job.Kind == "later" && job.Model is { } llm) Settings.WriteConfig(llm);  // the "later" notes model, for this job only
            string? result = null;
            var r = await EngineRunner.Hesper(job.Args, line =>
            {
                if (line.StartsWith("@@result ")) { result = line[9..]; return; }
                var (s, p) = EngineRunner.Parse(line);
                if (s == null && p == null) return;
                ui?.Post(_ =>
                {
                    if (s != null) jobStep = s;
                    if (p != null) jobProgress = p;
                    if (modelJob != null && job.Kind == "model") { modelJob["status"] = jobStep; modelJob["progress"] = jobProgress; }
                    Emit();
                }, null);
            });
            if (job.Kind == "later") Settings.WriteConfig();
            Finished(job, r, result);
            current = null;
            Emit();
        }
        _ = WriteLaterNotes(force: false);  // the PC may be free now
    }

    void Finished(Job job, EngineRunner.Result r, string? result)
    {
        switch (job.Kind)
        {
            case "ask":
                answer = new JsonObject
                {
                    ["question"] = job.Args.Last(), ["busy"] = false,
                    ["result"] = result != null ? JsonNode.Parse(result) : null, ["error"] = r.Ok ? null : r.ErrorTail,
                };
                return;
            case "model":
                modelJob = r.Ok ? null : new JsonObject { ["error"] = r.ErrorTail, ["repo"] = job.Model };
                if (r.Ok && job.Args[1] == "download" && pendingModel is { } pm && pm.Repo == job.Model)
                {
                    if (pm.Speech) Settings.WhisperModel = pm.Repo; else Settings.LlmModel = pm.Repo;
                    Settings.Save();
                }
                pendingModel = null;
                return;
            case "check":
                modelJob = new JsonObject { ["check"] = result != null ? JsonNode.Parse(result) : null, ["repo"] = job.Model,
                                            ["error"] = r.Ok ? null : r.ErrorTail, ["speech"] = job.Args.Contains("speech") };
                return;
            case "import":
                if (!r.Ok) Notify?.Invoke("Couldn't process the meeting", r.ErrorTail, null);
                return;
        }
        var error = Path.Combine(job.Folder, "error.txt");
        if (r.Ok) File.Delete(error);
        else File.WriteAllText(error, r.ErrorTail.Length > 0 ? r.ErrorTail : "The engine stopped.");
        var notes = Path.Combine(job.Folder, "notes.md");
        if (job.Kind == "later" && r.Ok) LaterNotes.Clear(job.Folder);
        if (job.Kind == "process" && job.NewMeeting && r.Ok)
        {
            LaterNotes.Seal(job.Folder);  // quick notes made: better ones replace them only if unedited
            if (Settings.AudioRetentionDays == 0) Retention.DeleteAudio(job.Folder);
            if (File.Exists(notes) && LaterNotes.Read(job.Folder) is null or { Polish: true }) AutoExport(job.Folder);
        }
        if (job.Kind == "later" && r.Ok) AutoExport(job.Folder);
        var announce = job.Kind == "later" || (job.Kind == "process" && job.NewMeeting && Settings.NotesTiming != "later");
        if (announce && Settings.NotifyWhenReady)
        {
            var id = Path.GetFileName(job.Folder);
            if (r.Ok && File.Exists(notes))
                Notify?.Invoke("Notes ready", (Meetings.Detail(Settings.NotesFolder, id)?["title"]?.GetValue<string>() ?? "") + " — click to see the summary and to-dos.",
                               () => OpenMeetingWindow?.Invoke(id));
            else if (!r.Ok) Notify?.Invoke("Couldn't process the meeting", "Open Hesper to try again.", () => OpenMeetingWindow?.Invoke(id));
        }
    }

    void AutoExport(string folder)
    {
        if (!Settings.AutoExport || Settings.ExportFolder.Length == 0) return;
        if (Meetings.Detail(Settings.NotesFolder, Path.GetFileName(folder)) is { } m) Export.Save(folder, m, Settings.ExportFolder);
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
        Enqueue(new("import", Settings.NotesFolder, ["process", dlg.FileName]));
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
        foreach (var m in Meetings.List(Settings.NotesFolder).OfType<JsonObject>())
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
                Notify?.Invoke(label, $"{a["task"]} — from “{m["title"]}”", () => OpenMeetingWindow?.Invoke(id));
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
            Notify?.Invoke($"In {minutes} min: {e.Title}",
                           (n == 0 ? "No open to-dos from last time" : n == 1 ? "1 open to-do from last time" : $"{n} open to-dos from last time") + ". Click to review.",
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
        if (current != null || queue.Count > 0 || Recorder != null || !Ready) return;
        if (!force && !PcUse.Free(Settings)) return;
        foreach (var folder in LaterNotes.Pending(Settings.NotesFolder))
        {
            if (!File.Exists(Path.Combine(folder, "transcript.json"))) continue;
            var item = LaterNotes.Read(folder)!;
            if (item.Polish && item.NotesHash != null && item.NotesHash != LaterNotes.Hash(folder))
            {
                LaterNotes.Clear(folder);  // edited since the quick notes: keep them
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
            foreach (var f in Directory.EnumerateFiles(dir, "*.gguf", SearchOption.AllDirectories))
            {
                var m = System.Text.RegularExpressions.Regex.Match(Path.GetFileName(f), @"-((?:UD-)?I?Q\d\w*|BF16|F16|F32)\.gguf$",
                                                                   System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (m.Success && !f.Contains("mmproj")) found[$"{repo}:{m.Groups[1].Value}"] = Math.Round(new FileInfo(f).Length / 1e9, 2);
            }
        }
        return found;
    }

    void UseModel(string repo, bool speech)
    {
        if (InstalledModels().ContainsKey(repo) || !Ready)
        {
            if (speech) Settings.WhisperModel = repo; else Settings.LlmModel = repo;
            Settings.Save();
            Emit();
            return;
        }
        pendingModel = new(repo, speech);
        Enqueue(new("model", Paths.Home, ["models", "download", repo], Model: repo));
    }

    void CheckModel(string link, bool speech)
    {
        // "https://huggingface.co/org/name" (+ ":Q4_K_M") → "org/name:Q4_K_M"
        var repo = System.Text.RegularExpressions.Regex.Replace(link.Trim(), @"^(https?://)?(www\.)?huggingface\.co/", "").Trim('/');
        modelJob = new JsonObject { ["status"] = "Checking…", ["repo"] = repo };
        Enqueue(new("check", Paths.Home, ["models", "check", repo, "--kind", speech ? "speech" : "notes"], Model: repo));
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
        if (update?["available"] is not JsonObject info || Recorder != null || current != null) return;
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

    public static List<string> Pending(string notesFolder) =>
        Directory.Exists(notesFolder) ? Directory.GetDirectories(notesFolder).Where(d => File.Exists(Path.Combine(d, FileName))).Order().ToList() : [];
}
