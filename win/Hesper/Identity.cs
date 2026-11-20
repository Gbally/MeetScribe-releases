using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Microsoft.Win32;

namespace Hesper;

/// Who Hesper is to Windows, for its notifications: one app ID (AppUserModelID) set on the process,
/// registered with its name and icon, and a Start menu shortcut carrying it. Without it, Windows makes
/// up an ID from the exe's path when the first notification comes, and a first launch may show none
/// (Hesper then isn't in Settings → Notifications either). All per user, no admin rights.
static class Identity
{
    public const string AppId = "Gbally.Hesper";
    static string RegistryKey => @"Software\Classes\AppUserModelId\" + AppId;
    public static string Shortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Hesper.lnk");

    [DllImport("shell32.dll", PreserveSig = false)]
    static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);

    /// At start, before any window or the notification icon.
    public static void Register()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppId);
            Directory.CreateDirectory(Paths.Home);
            var icon = Path.Combine(Paths.Home, "hesper.png");
            if (!File.Exists(icon)) Brand.Draw(256).Save(icon, ImageFormat.Png);
            using (var k = Registry.CurrentUser.CreateSubKey(RegistryKey))
            {
                k.SetValue("DisplayName", "Hesper");
                k.SetValue("IconUri", icon);
            }
            // A test setup (HESPER_HOME) mustn't take the Start menu's shortcut from the real one
            if (Environment.GetEnvironmentVariable("HESPER_HOME") == null && Environment.ProcessPath is { } exe)
                WriteShortcut(exe);
        }
        catch (Exception e)  // never a reason not to start: notifications then work as before
        {
            Paths.WriteLog("app identity: " + e.Message);
        }
    }

    /// Why Hesper's notifications might not be seen (Settings → Notifications), as an English text
    /// the pages translate; null when Windows shows them.
    public static string? NotificationProblem()
    {
        using var push = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\PushNotifications");
        if (push?.GetValue("ToastEnabled") is int on && on == 0) return "Notifications are turned off in Windows, so you won't see these.";
        using var app = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\" + AppId);
        if (app?.GetValue("Enabled") is int enabled && enabled == 0) return "Notifications are turned off for Hesper in Windows, so you won't see these.";
        if (app?.GetValue("ShowBanner") is int banner && banner == 0) return "Windows only lists Hesper's notifications in the notification center — no pop-up.";
        return null;
    }

    /// Uninstalling: the registration and the shortcut go too.
    public static void Remove()
    {
        try { Registry.CurrentUser.DeleteSubKeyTree(RegistryKey, false); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        try { File.Delete(Shortcut); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    static PropertyKey AppIdKey => new() { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };  // PKEY_AppUserModel_ID

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    /// Start menu → Hesper, pointing at this exe (again if it was moved), with the app ID (again if
    /// it changed).
    static void WriteShortcut(string exe)
    {
        var link = (IShellLinkW)new ShellLink();
        if (File.Exists(Shortcut))
        {
            ((IPersistFile)link).Load(Shortcut, 0);
            var current = new char[1024];
            link.GetPath(current, current.Length, IntPtr.Zero, 0);
            var key0 = AppIdKey;
            ((IPropertyStore)link).GetValue(ref key0, out var id);
            var currentId = id.Type == 31 /* VT_LPWSTR */ ? Marshal.PtrToStringUni(id.Value) : null;
            PropVariantClear(ref id);
            var same = string.Equals(new string(current).TrimEnd('\0'), exe, StringComparison.OrdinalIgnoreCase) && currentId == AppId;
            Marshal.ReleaseComObject(link);
            if (same) return;
            link = (IShellLinkW)new ShellLink();
        }
        link.SetPath(exe);
        link.SetWorkingDirectory(Path.GetDirectoryName(exe)!);
        link.SetDescription("Private meeting notes, fully offline");
        var store = (IPropertyStore)link;
        var key = AppIdKey;
        var value = new PropVariant { Type = 31 /* VT_LPWSTR */, Value = Marshal.StringToCoTaskMemUni(AppId) };
        try
        {
            store.SetValue(ref key, ref value);
            store.Commit();
        }
        finally { Marshal.FreeCoTaskMem(value.Value); }
        Directory.CreateDirectory(Path.GetDirectoryName(Shortcut)!);
        ((IPersistFile)link).Save(Shortcut, true);
        Marshal.ReleaseComObject(link);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] file, int max, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid Format; public uint Id; }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant { public ushort Type; ushort r1, r2, r3; public IntPtr Value; IntPtr extra; }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
}
