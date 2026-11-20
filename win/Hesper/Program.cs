namespace Hesper;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // A test without the tray icon: record N seconds into the notes folder, then make the notes
        if (args.Length >= 2 && args[0] == "--record" && int.TryParse(args[1], out var seconds))
            return RecordTest(seconds, args.Length > 2 ? args[2] : Paths.DefaultNotesFolder(), args.Length > 3 ? args[3] : "", args.Length > 4 ? args[4] : "")
                .GetAwaiter().GetResult();
        if (args.Length >= 1 && args[0] == "--devices")
            return Devices();
        if (args.Length >= 1 && args[0] == "--calendar")  // today's and tomorrow's events, as Hesper reads them from Outlook
        {
            Console.WriteLine($"classic Outlook: {OutlookCalendar.Available}");
            foreach (var e in OutlookCalendar.Read())
                Console.WriteLine($"{e.Start:g}–{e.End:t}  {e.Title}  online={e.IsOnline}  people={string.Join(", ", e.Attendees.Select(a => a.Name + (a.Email.Length > 0 ? " <" + a.Email + ">" : "")))}");
            return 0;
        }
        if (args.Length >= 2 && args[0] == "--write-icon")  // Hesper.ico, and PNGs to look at
        {
            Brand.WriteIco(args[1]);
            Brand.Draw(256).Save(Path.ChangeExtension(args[1], ".png"));
            Brand.Draw(256, recording: true).Save(Path.ChangeExtension(args[1], ".recording.png"));
            return 0;
        }
        if (args.Length >= 2 && args[0] == "--capture")  // PNGs of every screen, light and dark
        {
            ApplicationConfiguration.Initialize();
            var form = new Form { ShowInTaskbar = false, Opacity = 0 };
            form.Shown += async (_, _) => { await Capture(args[1]); Application.Exit(); };
            Application.Run(form);
            return 0;
        }
        if (args.Length >= 1 && args[0] == "--notify")  // a test notification, as Hesper's (support: "no notifications")
            return NotifyTest();
        // One Hesper per data folder: a test setup (HESPER_HOME) runs beside the real one
        var instance = Environment.GetEnvironmentVariable("HESPER_HOME") == null ? "" : "-" + Convert.ToHexString(
            System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Paths.Home.ToLowerInvariant())))[..12];
        using var single = new Mutex(true, @"Local\Hesper" + instance, out var first);
        if (!first) return 0;  // already running: its icon is in the notification area
        Identity.Register();  // before the notification icon: Windows then knows whose notifications they are
        ApplicationConfiguration.Initialize();
        // Never vanish without a word: say what went wrong, and keep it in hesper.log
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Fail(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Fail((Exception)e.ExceptionObject);
        try { return Run(); }
        catch (Exception e) { Fail(e); return 1; }
    }

    static void Fail(Exception e)
    {
        Paths.WriteLog("crash: " + e);
        MessageBox.Show($"Hesper stopped: {e.Message}\n\nDetails are in {Paths.Log}.", "Hesper",
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    /// Shows one notification the way the app does (its app ID, its icon in the notification area),
    /// then says under which name Windows lists it in Settings → Notifications.
    static int NotifyTest()
    {
        Identity.Register();
        ApplicationConfiguration.Initialize();
        using var tray = new NotifyIcon { Icon = Brand.Icon(32), Text = "Hesper", Visible = true };
        tray.ShowBalloonTip(5000, "Hesper", "Notifications work.", ToolTipIcon.None);
        var until = DateTime.Now.AddSeconds(4);
        while (DateTime.Now < until) { Application.DoEvents(); Thread.Sleep(50); }
        using var settings = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\" + Identity.AppId);
        Console.WriteLine(settings != null ? $"listed in Settings → Notifications as {Identity.AppId}" : $"not listed as {Identity.AppId}");
        tray.Visible = false;
        return 0;
    }

    static int Run()
    {
        Application.Run(new TrayApp());  // the first launch opens the welcome window, which sets up
        return 0;
    }

    static async Task Capture(string dir)
    {
        Directory.CreateDirectory(dir);
        var model = new AppModel();
        var latest = Meetings.List(model.Settings.NotesFolder).FirstOrDefault(m => m!["hasNotes"]!.GetValue<bool>())?["id"]?.GetValue<string>();
        (string Page, Size Size)[] pages =
        [
            ("home", new(400, 600)), ("meeting/" + latest, new(760, 760)), ("welcome", new(640, 600)),
            .. new[] { "general", "recording", "notes", "models", "privacy", "about" }.Select(p => ("settings/" + p, new Size(780, 580))),
        ];
        foreach (var (page, size) in pages)
        {
            var w = new WebWindow(model, page, size) { StartPosition = FormStartPosition.Manual, Location = new Point(40, 40) };
            if (page == "home") w.FormBorderStyle = FormBorderStyle.None;
            w.Show();
            for (var i = 0; i < 100 && !w.Loaded; i++) await Task.Delay(100);
            await Task.Delay(800);
            var name = page.Split('/')[0] + (page.StartsWith("settings/") ? "-" + page.Split('/')[1] : "");
            await w.CapturePng(Path.Combine(dir, name + "-light.png"), false);
            await w.CapturePng(Path.Combine(dir, name + "-dark.png"), true);
            w.Close();
        }
    }

    /// The default devices for each role, and how loud each active one is over 5 s (for a support log).
    static int Devices()
    {
        using var e = new NAudio.CoreAudioApi.MMDeviceEnumerator();
        foreach (var flow in new[] { NAudio.CoreAudioApi.DataFlow.Render, NAudio.CoreAudioApi.DataFlow.Capture })
            foreach (var role in new[] { NAudio.CoreAudioApi.Role.Console, NAudio.CoreAudioApi.Role.Communications })
                Console.WriteLine($"default {flow} {role}: {e.GetDefaultAudioEndpoint(flow, role).FriendlyName}");
        var peaks = new List<(string, NAudio.Wave.IWaveIn, float[])>();
        foreach (var d in e.EnumerateAudioEndPoints(NAudio.CoreAudioApi.DataFlow.All, NAudio.CoreAudioApi.DeviceState.Active))
        {
            NAudio.Wave.IWaveIn cap = d.DataFlow == NAudio.CoreAudioApi.DataFlow.Render
                ? new NAudio.Wave.WasapiLoopbackCapture(d) : new NAudio.CoreAudioApi.WasapiCapture(d);
            var peak = new float[1];
            cap.DataAvailable += (_, a) =>
            {
                var f = cap.WaveFormat;
                for (var i = 0; i + 3 < a.BytesRecorded; i += 4)
                {
                    var v = f.Encoding == NAudio.Wave.WaveFormatEncoding.IeeeFloat || f.BitsPerSample == 32 && f.Encoding == NAudio.Wave.WaveFormatEncoding.Extensible
                        ? Math.Abs(BitConverter.ToSingle(a.Buffer, i)) : Math.Abs(BitConverter.ToInt16(a.Buffer, i) / 32768f);
                    if (v > peak[0]) peak[0] = v;
                }
            };
            try { cap.StartRecording(); peaks.Add(($"{d.DataFlow} {d.FriendlyName} ({cap.WaveFormat})", cap, peak)); }
            catch (Exception ex) { Console.WriteLine($"{d.FriendlyName}: {ex.Message}"); }
        }
        Thread.Sleep(5000);
        foreach (var (name, cap, peak) in peaks) { cap.StopRecording(); Console.WriteLine($"peak {peak[0]:F3}  {name}"); }
        return 0;
    }

    static async Task<int> RecordTest(int seconds, string notesFolder, string mic, string app)
    {
        var folder = Paths.NewSession(notesFolder, DateTime.Now);
        using var rec = new Recorder(folder, mic, "", app);
        rec.Start();
        foreach (var n in rec.Notices) Console.WriteLine(n);
        Console.WriteLine($"recording {seconds}s into {folder}");
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        rec.Stop();
        rec.Dispose();
        Console.WriteLine($"stopped at {rec.Elapsed.TotalSeconds:F1}s; processing");
        var r = await EngineRunner.Hesper(["process", folder], line =>
        {
            var (step, progress) = EngineRunner.Parse(line);
            if (step != null) Console.WriteLine($"  {step}");
            else if (progress == null && line.Length > 0) Console.WriteLine($"  | {line}");
        });
        Console.WriteLine(r.Ok ? $"notes: {Path.Combine(folder, "notes.md")}" : $"failed:\n{r.ErrorTail}");
        return r.Ok ? 0 : 1;
    }
}
