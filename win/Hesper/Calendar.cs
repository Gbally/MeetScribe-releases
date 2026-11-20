using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace Hesper;

/// A calendar meeting, as the Mac's CalendarEvent (meeting.json → "calendar": the engine reads its
/// title and attendees to name speakers).
sealed record CalendarEvent(string Title, DateTime Start, DateTime End, string Organizer, List<(string Name, string Email)> Attendees,
                            bool IsOnline, string? Id, string? SeriesKey)
{
    public JsonObject ToJson() => new()
    {
        ["title"] = Title, ["start"] = Start.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), ["end"] = End.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"),
        ["organizer"] = Organizer, ["isOnlineMeeting"] = IsOnline, ["id"] = Id, ["seriesKey"] = SeriesKey,
        ["attendees"] = new JsonArray(Attendees.Select(a => (JsonNode)new JsonObject { ["name"] = a.Name, ["email"] = a.Email }).ToArray()),
    };
}

/// The user's calendar in classic Outlook (its COM object model: the new Outlook has none on the
/// PC). Read on a thread of its own every minute, so Outlook being slow never freezes Hesper.
/// As mac/App/Calendar.swift: the meeting now, today's real meetings, the ones about to start.
sealed class OutlookCalendar : IDisposable
{
    /// Classic Outlook is installed and has a mail profile (installed but never set up, it can't be read).
    public static bool Available =>
        Type.GetTypeFromProgID("Outlook.Application") != null
        && (Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Office\16.0\Outlook\Profiles")?.SubKeyCount ?? 0) > 0;

    /// Installed but with no account: say so in Settings.
    public static bool Installed => Type.GetTypeFromProgID("Outlook.Application") != null;

    /// Today's events (and tomorrow morning's), from the last read; [] when off or unavailable.
    public List<CalendarEvent> Events { get; private set; } = [];
    public string? Error { get; private set; }
    public event Action? Changed;

    readonly Thread thread;
    readonly AutoResetEvent wake = new(false);
    volatile bool enabled, stopping;
    readonly SynchronizationContext? ui = SynchronizationContext.Current;

    public OutlookCalendar(bool on)
    {
        enabled = on;
        thread = new Thread(Loop) { IsBackground = true, Name = "Outlook calendar" };
        thread.SetApartmentState(ApartmentState.STA);  // Outlook's objects want a single-threaded apartment
        thread.Start();
    }

    public void SetEnabled(bool on)
    {
        enabled = on;
        wake.Set();
    }

    public void Refresh() => wake.Set();

    void Loop()
    {
        while (!stopping)
        {
            List<CalendarEvent> found = [];
            string? error = null;
            if (enabled && Available)
            {
                try { found = Read(); }
                catch (Exception e) when (e is COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
                {
                    error = e.Message;
                    Paths.WriteLog("calendar: " + e.Message);
                }
            }
            ui?.Post(_ => { Events = found; Error = error; Changed?.Invoke(); }, null);
            wake.WaitOne(TimeSpan.FromMinutes(1));
        }
    }

    static readonly string[] CallLinks = ["teams.microsoft.com", "zoom.us", "webex.com", "meet.google.com"];

    /// The events from midnight today to midnight tomorrow, recurrences included.
    public static List<CalendarEvent> Read()
    {
        dynamic app = Activator.CreateInstance(Type.GetTypeFromProgID("Outlook.Application")!)!;
        dynamic ns = app.GetNamespace("MAPI");
        dynamic folder = ns.GetDefaultFolder(9);  // olFolderCalendar
        dynamic items = folder.Items;
        items.IncludeRecurrences = true;
        items.Sort("[Start]");
        var from = DateTime.Today;
        var to = from.AddDays(2);
        string Fmt(DateTime d) => d.ToString("g", System.Globalization.CultureInfo.CurrentCulture);
        dynamic found = items.Restrict($"[Start] < '{Fmt(to)}' AND [End] > '{Fmt(from)}'");
        var me = ((string?)ns.CurrentUser?.Name ?? "").Trim();
        var events = new List<CalendarEvent>();
        foreach (dynamic e in found)
        {
            if ((bool)e.AllDayEvent || (int)e.MeetingStatus is 5 or 7) continue;  // all day, canceled
            var people = new List<(string, string)>();
            foreach (dynamic r in e.Recipients)
            {
                var name = (string)(r.Name ?? "");
                if (name.Length == 0 || name.Equals(me, StringComparison.OrdinalIgnoreCase) || (int)r.Type == 3) continue;  // olResource
                string email = "";
                try { email = (string)(r.Address ?? ""); } catch (COMException) { }
                people.Add((name, email.Contains('@') ? email : ""));
            }
            var text = $"{e.Location} {e.Body}".ToLowerInvariant();
            events.Add(new CalendarEvent((string)(e.Subject ?? "Meeting"), (DateTime)e.Start, (DateTime)e.End, (string)(e.Organizer ?? ""), people,
                                         CallLinks.Any(text.Contains), $"{e.GlobalAppointmentID}/{((DateTime)e.Start):s}",
                                         (string?)e.GlobalAppointmentID));
            if (events.Count > 60) break;
        }
        return events;
    }

    static bool Real(CalendarEvent e) => e.IsOnline || e.Attendees.Count > 0;

    /// The meeting happening now (or starting within 10 minutes), real meetings first.
    public CalendarEvent? Current(DateTime? at = null)
    {
        var now = at ?? DateTime.Now;
        return Events.Where(e => e.End > now && e.Start <= now.AddMinutes(10) && (e.End - e.Start) < TimeSpan.FromHours(6))
                     .OrderByDescending(e => (e.IsOnline ? 3 : 0) + (e.Attendees.Count > 0 ? 2 : 0) - Math.Abs((e.Start - now).TotalHours))
                     .FirstOrDefault();
    }

    /// Today's real meetings (with other people or a call link), in order.
    public List<CalendarEvent> Today() => Events.Where(e => e.Start.Date == DateTime.Today && Real(e)).OrderBy(e => e.Start).ToList();

    /// Real meetings starting within the next minutes.
    public List<CalendarEvent> Upcoming(double minutes) =>
        Events.Where(e => e.Start >= DateTime.Now && e.Start <= DateTime.Now.AddMinutes(minutes) && Real(e)).OrderBy(e => e.Start).ToList();

    public void Dispose()
    {
        stopping = true;
        wake.Set();
    }
}
