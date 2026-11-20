using System.Diagnostics;

namespace Hesper;

/// The app: an icon in the notification area. Record → Stop and create notes → "Notes ready".
sealed class TrayApp : ApplicationContext
{
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly ToolStripMenuItem status = new() { Enabled = false, Visible = false };
    readonly ToolStripMenuItem record = new("Record");
    readonly ToolStripMenuItem stop = new("Stop and create notes") { Visible = false };
    readonly System.Windows.Forms.Timer tick = new() { Interval = 1000 };
    readonly Icon idleIcon = Brand.Icon(32), recordingIcon = Brand.Icon(32, recording: true);
    AppSettings settings = AppSettings.Load();
    Recorder? recorder;
    int processing;          // meetings being turned into notes
    string? lastNotes;       // what a click on the last notification opens

    public TrayApp()
    {
        menu.Items.Add(status);
        menu.Items.Add(record);
        menu.Items.Add(stop);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open notes folder", null, (_, _) => Open(settings.NotesFolder));
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit Hesper", null, (_, _) => Quit());
        record.Click += (_, _) => StartRecording();
        stop.Click += (_, _) => StopRecording();
        tick.Tick += (_, _) => ShowElapsed();

        tray.Icon = idleIcon;
        tray.Text = "Hesper";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)  // a left click opens the menu too
                typeof(NotifyIcon).GetMethod("ShowContextMenu", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                    ?.Invoke(tray, null);
        };
        tray.BalloonTipClicked += (_, _) => { if (lastNotes != null) Open(lastNotes); };
        settings.WriteConfig();
    }

    void StartRecording()
    {
        if (recorder != null) return;
        var folder = Paths.NewSession(settings.NotesFolder, DateTime.Now);
        var rec = new Recorder(folder, settings.Microphone, settings.Speakers);
        try { rec.Start(); }
        catch (Exception e)
        {
            rec.Dispose();
            try { Directory.Delete(folder); } catch (IOException) { }
            Notify("Recording failed", e.Message, ToolTipIcon.Error);
            return;
        }
        recorder = rec;
        foreach (var n in rec.Notices) Notify("Hesper", n, ToolTipIcon.Warning);
        tray.Icon = recordingIcon;
        record.Visible = false;
        stop.Visible = true;
        tick.Start();
        ShowElapsed();
    }

    void ShowElapsed()
    {
        if (recorder == null) return;
        var t = recorder.Elapsed;
        var text = $"Recording — {(int)t.TotalHours:0}:{t.Minutes:00}:{t.Seconds:00}";
        status.Text = text;
        status.Visible = true;
        tray.Text = "Hesper: " + text;
    }

    async void StopRecording()
    {
        var rec = recorder;
        if (rec == null) return;
        recorder = null;
        tick.Stop();
        rec.Stop();
        rec.Dispose();
        tray.Icon = idleIcon;
        record.Visible = true;
        stop.Visible = false;
        await MakeNotes(rec.Folder);
    }

    /// python -m hesper process FOLDER, its progress in the menu and the icon's tooltip.
    async Task MakeNotes(string folder)
    {
        processing++;
        void Show(string text)
        {
            status.Text = text;
            status.Visible = true;
            tray.Text = ("Hesper: " + text)[..Math.Min(127, text.Length + 8)];
        }
        Show("Creating notes…");
        string step = "Creating notes";
        var ui = SynchronizationContext.Current;
        var result = await EngineRunner.Hesper(["process", folder], line =>
        {
            var (s, p) = EngineRunner.Parse(line);
            if (s != null) step = s;
            if (s != null || p != null)
                ui?.Post(_ => { if (recorder == null) Show(p is double f ? $"{step} — {f:P0}" : step); }, null);
        });
        processing--;
        if (recorder == null)
        {
            status.Visible = false;
            tray.Text = "Hesper";
        }
        var notes = Path.Combine(folder, "notes.md");
        if (result.Ok && File.Exists(notes))
        {
            lastNotes = notes;
            Notify("Notes ready", "Click to open them.", ToolTipIcon.Info);
        }
        else
        {
            lastNotes = Path.Combine(Paths.Home, "hesper.log");
            Notify("Notes failed", result.ErrorTail.Length > 0 ? result.ErrorTail[^Math.Min(200, result.ErrorTail.Length)..] : "See hesper.log.",
                   ToolTipIcon.Error);
        }
    }

    void ShowSettings()
    {
        using var form = new SettingsForm(settings);
        if (form.ShowDialog() == DialogResult.OK) settings = AppSettings.Load();
    }

    void Notify(string title, string text, ToolTipIcon icon) => tray.ShowBalloonTip(10_000, title, text, icon);

    static void Open(string path)
    {
        if (!File.Exists(path)) Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    void Quit()
    {
        if (recorder != null && MessageBox.Show("A meeting is being recorded. Stop it and quit? Its notes won't be created now.",
                "Hesper", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;
        if (processing > 0 && MessageBox.Show("Notes are being created. Quit anyway? They'll be lost.",
                "Hesper", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;
        recorder?.Stop();
        recorder?.Dispose();
        tray.Visible = false;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            tray.Dispose();
            menu.Dispose();
            tick.Dispose();
        }
        base.Dispose(disposing);
    }
}
