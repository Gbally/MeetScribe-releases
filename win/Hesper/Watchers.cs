using System.Runtime.InteropServices;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Hesper;

/// Notices when a call starts and ends: a meeting app (Teams, Zoom, a browser…) has an active
/// capture session on a microphone (Windows' audio sessions say which process). Hesper's own
/// recording doesn't count. Needs no permission and never touches the audio.
sealed class CallMonitor : IDisposable
{
    /// Process names whose microphone use means "a call".
    static readonly string[] MeetingApps =
        ["ms-teams", "teams", "zoom", "webex", "ciscocollabhost", "slack", "discord", "skype", "chrome", "msedge", "firefox", "brave", "opera", "arc", "vivaldi"];
    static readonly Dictionary<string, string> Names = new()
    {
        ["ms-teams"] = "Microsoft Teams", ["teams"] = "Microsoft Teams", ["zoom"] = "Zoom", ["webex"] = "Webex", ["ciscocollabhost"] = "Webex",
        ["slack"] = "Slack", ["discord"] = "Discord", ["skype"] = "Skype", ["chrome"] = "Google Chrome", ["msedge"] = "Microsoft Edge",
        ["firefox"] = "Firefox", ["brave"] = "Brave", ["opera"] = "Opera", ["arc"] = "Arc", ["vivaldi"] = "Vivaldi",
    };

    public event Action<string>? CallStarted;  // the app's name
    public event Action? CallEnded;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 3000 };
    DateTime? busySince, idleSince;
    bool inCall;

    public CallMonitor()
    {
        timer.Tick += (_, _) => Tick();
        timer.Start();
    }

    void Tick()
    {
        string? app;
        try { app = CallApp(); }
        catch (Exception e) when (e is COMException or InvalidOperationException) { return; }
        if (app != null)
        {
            idleSince = null;
            busySince ??= DateTime.Now;
            if (!inCall && DateTime.Now - busySince >= TimeSpan.FromSeconds(4))
            {
                inCall = true;
                CallStarted?.Invoke(app);
            }
        }
        else
        {
            busySince = null;
            if (!inCall) return;
            idleSince ??= DateTime.Now;
            if (DateTime.Now - idleSince >= TimeSpan.FromSeconds(45))  // a short drop isn't the end of the call
            {
                inCall = false;
                CallEnded?.Invoke();
            }
        }
    }

    /// The meeting app with an active capture session right now, or null.
    static string? CallApp()
    {
        var me = Environment.ProcessId;
        using var devices = new MMDeviceEnumerator();
        foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            var sessions = device.AudioSessionManager.Sessions;
            for (var i = 0; i < sessions.Count; i++)
            {
                var s = sessions[i];
                if (s.State != AudioSessionState.AudioSessionStateActive || s.IsSystemSoundsSession) continue;
                var pid = (int)s.GetProcessID;
                if (pid == me || pid == 0) continue;
                string name;
                try { name = System.Diagnostics.Process.GetProcessById(pid).ProcessName.ToLowerInvariant(); }
                catch (ArgumentException) { continue; }
                var app = MeetingApps.FirstOrDefault(a => name == a || name.StartsWith(a));
                if (app != null) return Names[app];
            }
        }
        return null;
    }

    public void Dispose() => timer.Dispose();
}

/// The start / stop recording shortcut, for the whole of Windows ("Ctrl+Alt+R").
sealed class Hotkey : NativeWindow, IDisposable
{
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    const int WmHotkey = 0x0312;
    public event Action? Pressed;
    bool registered;

    public Hotkey() => CreateHandle(new CreateParams());

    /// Registers the shortcut; false when it's not valid or another app already has it.
    public bool Set(string shortcut)
    {
        if (registered) UnregisterHotKey(Handle, 1);
        registered = false;
        if (Parse(shortcut) is not var (mods, key)) return shortcut.Length == 0;
        registered = RegisterHotKey(Handle, 1, mods | 0x4000 /* MOD_NOREPEAT */, key);
        return registered;
    }

    /// "Ctrl+Alt+R" → (MOD_CONTROL | MOD_ALT, 'R'); at least one of Ctrl, Alt, Win (a plain key would break typing).
    public static (uint, uint)? Parse(string s)
    {
        uint mods = 0, key = 0;
        foreach (var part in s.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= 2; break;
                case "alt": mods |= 1; break;
                case "shift": mods |= 4; break;
                case "win": mods |= 8; break;
                default:
                    if (Enum.TryParse<Keys>(part.Length == 1 && char.IsDigit(part[0]) ? "D" + part : part, true, out var k)) key = (uint)k;
                    else return null;
                    break;
            }
        }
        return key != 0 && (mods & (1 | 2 | 8)) != 0 ? (mods, key) : null;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WmHotkey) Pressed?.Invoke();
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (registered) UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}

/// Whether nobody is using the PC right now, by the user's rules (Settings → Notes → When to
/// write the notes): set hours, no keyboard or mouse for a while, or the screen locked — and
/// always on power. As MacUse on the Mac.
static class PcUse
{
    [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint Size, Time; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput li);

    static bool locked;
    static PcUse() => SystemEvents.SessionSwitch += (_, e) =>
        locked = e.Reason is SessionSwitchReason.SessionLock ? true : e.Reason is SessionSwitchReason.SessionUnlock ? false : locked;

    public static double IdleMinutes
    {
        get
        {
            var li = new LastInput { Size = (uint)Marshal.SizeOf<LastInput>() };
            return GetLastInputInfo(ref li) ? (Environment.TickCount - (int)li.Time) / 60000.0 : 0;
        }
    }

    public static bool OnPower => SystemInformation.PowerStatus.PowerLineStatus != PowerLineStatus.Offline;

    public static bool Free(AppSettings s)
    {
        if (!OnPower) return false;
        var minute = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        bool InWindow(int[] w) => w[0] <= w[1] ? minute >= w[0] && minute < w[1] : minute >= w[0] || minute < w[1];
        return (s.LaterInWindows && s.LaterWindows.Any(InWindow))
            || (s.LaterWhenIdle && IdleMinutes >= s.LaterIdleMinutes)
            || (s.LaterWhenLocked && locked);
    }

    /// Someone came back (to stop between two meetings' notes).
    public static bool InUse => !locked && IdleMinutes < 1;
}
