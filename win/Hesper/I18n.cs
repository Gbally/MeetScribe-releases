using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hesper;

/// The app's texts outside its pages (notifications, error.txt) in the app's language, with the
/// pages' translations: the Mac's (English text → translation, "Mac" said "PC"), then Windows' own.
static class I18n
{
    static readonly string[] Supported = ["fr", "es", "pt", "ja", "zh-Hans"];
    static (string Lang, Dictionary<string, string> Words)? loaded;

    /// The language the pages show: the one chosen in Settings, else Windows'.
    public static string Language(string appLanguage)
    {
        var want = appLanguage.Length > 0 ? appLanguage : CultureInfo.CurrentUICulture.Name;
        if (want.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) return "zh-Hans";
        return Supported.FirstOrDefault(l => want.StartsWith(l, StringComparison.OrdinalIgnoreCase)) ?? "en";
    }

    public static string T(string appLanguage, string key, params object[] args)
    {
        var s = Words(Language(appLanguage)).TryGetValue(key, out var t) ? t : key;
        s = Regex.Replace(s, @"\bMac\b", "PC");
        // Numbered slots ("%2$@ … %1$@": a language that says them in another order), else in order
        if (Regex.IsMatch(s, @"%\d\$@"))
            return Regex.Replace(s, @"%(\d)\$@", m => int.Parse(m.Groups[1].Value) is var n && n >= 1 && n <= args.Length ? $"{args[n - 1]}" : "");
        foreach (var a in args)
        {
            var i = s.IndexOf("%@", StringComparison.Ordinal);
            if (i >= 0) s = s[..i] + a + s[(i + 2)..];
        }
        return s;
    }

    static Dictionary<string, string> Words(string lang)
    {
        if (loaded is { } l && l.Lang == lang) return l.Words;
        var words = new Dictionary<string, string>();
        if (lang != "en")
        {
            var asm = typeof(I18n).Assembly;
            void Add(JsonNode? table)
            {
                foreach (var (k, v) in table as JsonObject ?? [])
                    if (v?.GetValueKind() == System.Text.Json.JsonValueKind.String) words.TryAdd(k, v.GetValue<string>());
            }
            using (var mac = asm.GetManifestResourceStream($"i18n/{lang}.json"))
                if (mac != null) Add(JsonNode.Parse(mac));
            using (var win = asm.GetManifestResourceStream("ui/i18n-windows.json"))
                if (win != null) Add(JsonNode.Parse(win)?[lang]);
        }
        loaded = (lang, words);
        return words;
    }
}
