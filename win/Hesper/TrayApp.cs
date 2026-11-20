namespace Hesper;

/// The app: an icon in the notification area. A click opens the popover (as the Mac's menu bar
/// icon does); a right click a short menu. Meetings and Settings open in their own windows.
sealed class TrayApp : ApplicationContext
{
    readonly AppModel model = new();
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly ToolStripMenuItem record = new("Record"), stop = new("Stop and create notes") { Visible = false };
    readonly System.Windows.Forms.Timer live = new() { Interval = 200 }, coalesce = new() { Interval = 150 };
    readonly Icon idleIcon = Brand.Icon(32), recordingIcon = Brand.Icon(32, recording: true);
    readonly Popover popover;
    Action? onBalloonClick;  // what a click on the last notification does
    readonly Hotkey hotkey = new();

    public TrayApp()
    {
        popover = new Popover(model);
        menu.Items.Add("Open Hesper", null, (_, _) => popover.Toggle());
        menu.Items.Add(record);
        menu.Items.Add(stop);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings(""));
        menu.Items.Add("Quit Hesper", null, (_, _) => Quit());
        record.Click += (_, _) => model.StartRecording("");
        stop.Click += (_, _) => model.StopRecording();

        tray.Icon = idleIcon;
        tray.Text = "Hesper";
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) popover.Toggle(); };
        tray.BalloonTipClicked += (_, _) => onBalloonClick?.Invoke();
        tray.BalloonTipClosed += (_, _) => onBalloonClick = null;

        model.Changed += () => { if (!coalesce.Enabled) coalesce.Start(); };  // progress lines come fast: at most ~6 redraws a second
        coalesce.Tick += (_, _) => { coalesce.Stop(); OnChanged(); };
        model.Notify += (title, text, action) =>
        {
            onBalloonClick = action;
            tray.ShowBalloonTip(10_000, title, text, ToolTipIcon.None);
        };
        hotkey.Pressed += model.ToggleRecording;
        hotkey.Set(model.Settings.Hotkey);
        model.HotkeyChanged += () => hotkey.Set(model.Settings.Hotkey);
        model.OpenMeetingWindow += ShowMeeting;
        model.OpenSettingsWindow += ShowSettings;
        model.OpenWelcomeWindow += ShowWelcome;
        model.QuitRequested += Quit;
        model.BriefRequested += key => popover.ShowPage("brief/" + key);
        live.Tick += (_, _) => WebWindow.Broadcast("live", model.Live);

        model.Settings.WriteConfig();
        if (!model.Ready || !model.Settings.Welcomed) ShowWelcome();
    }

    void OnChanged()
    {
        var recording = model.Recorder != null;
        tray.Icon = recording ? recordingIcon : idleIcon;
        record.Visible = !recording;
        stop.Visible = recording;
        record.Enabled = model.Ready;
        if (recording) live.Start(); else live.Stop();
        WebWindow.Broadcast("state", model.State);
    }

    void Show(string page, Size size, string title)
    {
        if (WebWindow.Find(page) is { } w)
        {
            w.WindowState = FormWindowState.Normal;
            w.Activate();
            return;
        }
        popover.Hide();
        new WebWindow(model, page, size) { Text = title, MinimumSize = new Size(480, 420) }.Show();
    }

    void ShowMeeting(string id) => Show("meeting/" + Uri.EscapeDataString(id), new Size(760, 760), "Hesper");
    void ShowSettings(string pane) => Show("settings" + (pane.Length > 0 ? "/" + pane : ""), new Size(780, 580), "Hesper settings");
    void ShowWelcome() => Show("welcome", new Size(640, 600), "Welcome to Hesper");

    void Quit()
    {
        if (model.Recorder != null && MessageBox.Show("A meeting is being recorded. Stop it and quit? Its notes won't be created now.",
                "Hesper", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            return;
        model.Recorder?.Stop();
        model.Recorder?.Dispose();
        tray.Visible = false;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            tray.Dispose();
            menu.Dispose();
            live.Dispose();
            popover.Dispose();
            hotkey.Dispose();
        }
        base.Dispose(disposing);
    }
}
