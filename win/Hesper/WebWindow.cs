using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Hesper;

/// A window showing one of the app's pages (HTML in the exe, served as https://hesper.app/), and
/// the bridge to it: the page posts {id, cmd, args}, gets {id, result}; the app pushes {event, data}.
class WebWindow : Form
{
    const string Origin = "https://hesper.app/";
    static Task<CoreWebView2Environment>? environment;
    static readonly List<WebWindow> open = [];

    protected readonly WebView2 web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Brand.DuskInk };
    readonly AppModel model;
    readonly string page;
    bool ready;

    public WebWindow(AppModel model, string page, Size size)
    {
        this.model = model;
        this.page = page;
        Text = "Hesper";
        Icon = Brand.Icon(32);
        ClientSize = size;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Brand.DuskInk;
        Controls.Add(web);
        open.Add(this);
        FormClosed += (_, _) => open.Remove(this);
        _ = Init();
    }

    async Task Init()
    {
        // WebView2's own data (cache, local storage) in Hesper's folder, not next to the exe
        environment ??= CoreWebView2Environment.CreateAsync(null, Path.Combine(Paths.Home, "webview"));
        await web.EnsureCoreWebView2Async(await environment);
        var core = web.CoreWebView2;
        core.Settings.AreDevToolsEnabled = Environment.GetEnvironmentVariable("HESPER_DEVTOOLS") == "1";
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        core.AddWebResourceRequestedFilter(Origin + "*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) => e.Response = Serve(core.Environment, new Uri(e.Request.Uri).AbsolutePath.TrimStart('/'), model);
        core.NavigationStarting += (_, e) => { if (!e.Uri.StartsWith(Origin)) e.Cancel = true; };  // links open nowhere inside
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.WebMessageReceived += (_, e) => OnMessage(e.WebMessageAsJson);
        core.NavigationCompleted += (_, _) => ready = true;
        core.DocumentTitleChanged += (_, _) => Text = core.DocumentTitle;  // the page's title, in the app's language
        core.Navigate(Origin + "index.html#" + page);
    }

    static CoreWebView2WebResourceResponse Serve(CoreWebView2Environment env, string path, AppModel model)
    {
        // A meeting's voice sample (naming the speakers): clip/MEETING/FILE.wav
        if (path.StartsWith("clip/"))
        {
            var parts = path.Split('/');
            var file = parts.Length == 3 ? Meetings.ClipFile(model.Settings.NotesFolder, Uri.UnescapeDataString(parts[1]), Uri.UnescapeDataString(parts[2])) : null;
            return file == null ? env.CreateWebResourceResponse(null, 404, "Not found", "")
                                : env.CreateWebResourceResponse(File.OpenRead(file), 200, "OK", "Content-Type: audio/wav");
        }
        var stream = typeof(WebWindow).Assembly.GetManifestResourceStream("ui/" + (path.Length > 0 ? path : "index.html"));
        if (stream == null) return env.CreateWebResourceResponse(null, 404, "Not found", "");
        var type = Path.GetExtension(path) switch
        {
            ".html" => "text/html", ".css" => "text/css", ".js" => "text/javascript", ".json" => "application/json",
            ".svg" => "image/svg+xml", ".woff2" => "font/woff2", _ => "application/octet-stream",
        };
        return env.CreateWebResourceResponse(stream, 200, "OK", $"Content-Type: {type}; charset=utf-8");
    }

    async void OnMessage(string json)
    {
        var msg = JsonNode.Parse(json)!.AsObject();
        var id = msg["id"]?.GetValue<int>();
        var cmd = msg["cmd"]?.GetValue<string>() ?? "";
        JsonNode? result = null;
        string? error = null;
        try
        {
            result = cmd switch
            {
                "close" => Do(Close),
                "hide" => Do(Hide),
                _ => await model.HandleAsync(cmd, msg["args"] as JsonObject ?? []),
            };
        }
        catch (Exception e)
        {
            Paths.WriteLog($"{cmd}: {e}");
            error = e.Message;
        }
        if (id != null && !IsDisposed)  // also before NavigationCompleted: the page asks for its state while loading
            web.CoreWebView2.PostWebMessageAsJson(new JsonObject { ["id"] = id, ["result"] = result, ["error"] = error }.ToJsonString());
    }

    static JsonNode? Do(Action a) { a(); return null; }

    public bool Loaded => ready;

    /// A PNG of the page, in the given colour scheme (Hesper.exe --capture, to compare with the Mac).
    public async Task CapturePng(string path, bool dark)
    {
        web.CoreWebView2.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
        await Task.Delay(700);
        await using var f = File.Create(path);
        await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, f);
    }

    public void Push(string name, JsonNode? data)
    {
        if (ready && !IsDisposed && Visible)
            web.CoreWebView2.PostWebMessageAsJson(new JsonObject { ["event"] = name, ["data"] = data }.ToJsonString());
    }

    /// Sends an event to every open page.
    public static void Broadcast(string name, Func<JsonNode?> data)
    {
        var shown = open.Where(w => w.Visible && w.ready).ToList();
        if (shown.Count == 0) return;
        var d = data();
        foreach (var w in shown) w.Push(name, d?.DeepClone());
    }

    public static WebWindow? Find(string page) => open.FirstOrDefault(w => w.page == page && !w.IsDisposed);

    // Windows 11: rounded corners, and a dark title bar when Windows is dark
    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var round = 2;  // DWMWCP_ROUND
        DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int));
        var dark = DarkMode ? 1 : 0;
        DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int));  // DWMWA_USE_IMMERSIVE_DARK_MODE
    }

    public static bool DarkMode =>
        Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                                          "AppsUseLightTheme", 1) is int light && light == 0;
}

/// The window the icon opens, like the Mac's popover: borderless, above the notification area,
/// gone when it loses focus.
sealed class Popover : WebWindow
{
    public Popover(AppModel model) : base(model, "home", new Size(400, 600))
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Deactivate += (_, _) => { if (!hold) Hide(); };
    }

    bool hold;  // a dialog of ours (folder picker…) took the focus: stay

    public void Hold(bool on) => hold = on;

    /// Opens the popover on one of its views (a meeting's brief, from its notification).
    public void ShowPage(string view)
    {
        if (!Visible) Toggle();
        Push("view", view);
    }

    public void Toggle()
    {
        if (Visible) { Hide(); return; }
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        // Next to the notification area: the corner of the work area nearest the taskbar
        var x = Cursor.Position.X > area.Left + area.Width / 2 ? area.Right - Width - 12 : area.Left + 12;
        var y = Cursor.Position.Y > area.Top + area.Height / 2 ? area.Bottom - Height - 12 : area.Top + 12;
        Location = new Point(x, y);
        Show();
        Activate();
        Push("state", null);  // the page asks for the full state on this event
    }
}
