using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.Wave;

namespace Hesper;

/// One app's sound only (Settings → Recording → Record: Microsoft Teams only), with Windows'
/// process loopback (Windows 11; build 20348 or later): the app and its child processes, nothing
/// else the PC plays. An IWaveIn like NAudio's captures, for Recorder's tracks.
sealed class ProcessLoopbackCapture : IWaveIn
{
    public static bool Supported => Environment.OSVersion.Version.Build >= 20348;

    public WaveFormat WaveFormat { get; set; } = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    readonly int pid;
    IAudioClient? client;
    IAudioCaptureClient? capture;
    readonly AutoResetEvent ready = new(false);
    Thread? thread;
    volatile bool stopping;

    public ProcessLoopbackCapture(int processId) => pid = processId;

    /// The app's main process (the oldest one of that name), or null when it isn't running.
    public static int? FindProcess(params string[] names)
    {
        var all = names.SelectMany(Process.GetProcessesByName).ToList();
        try { return all.OrderBy(p => { try { return p.StartTime; } catch (Exception) { return DateTime.MaxValue; } }).FirstOrDefault()?.Id; }
        finally { all.ForEach(p => p.Dispose()); }
    }

    /// Starts on a thread of its own (in the COM multithreaded apartment, where the activation's
    /// result arrives); throws here if the app's sound can't be captured.
    public void StartRecording()
    {
        Exception? failed = null;
        using var started = new ManualResetEventSlim(false);
        thread = new Thread(() =>
        {
            try { Open(); }
            catch (Exception e) { failed = e; }
            started.Set();
            if (failed == null) Loop();
        }) { IsBackground = true, Name = "App sound" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        started.Wait();
        if (failed != null) throw new InvalidOperationException(failed.Message, failed);
    }

    void Open()
    {
        client = Activate(pid);
        var format = WaveFormat;
        var formatPtr = Marshal.AllocHGlobal(Marshal.SizeOf(format));
        try
        {
            Marshal.StructureToPtr(format, formatPtr, false);
            const uint flags = 0x00020000 /* LOOPBACK */ | 0x00040000 /* EVENTCALLBACK */ | 0x80000000 /* AUTOCONVERTPCM */ | 0x08000000 /* SRC_DEFAULT_QUALITY */;
            Check(client.Initialize(0, flags, 2_000_000, 0, formatPtr, IntPtr.Zero));
        }
        finally { Marshal.FreeHGlobal(formatPtr); }
        Check(client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle()));
        var iid = typeof(IAudioCaptureClient).GUID;
        Check(client.GetService(ref iid, out var service));
        capture = (IAudioCaptureClient)service;
        Check(client.Start());
    }

    void Loop()
    {
        Exception? error = null;
        var buffer = Array.Empty<byte>();
        try
        {
            while (!stopping)
            {
                ready.WaitOne(200);
                while (!stopping && capture!.GetNextPacketSize(out var frames) == 0 && frames > 0)
                {
                    Check(capture.GetBuffer(out var data, out var n, out var flags, out _, out _));
                    var bytes = (int)n * WaveFormat.BlockAlign;
                    if (buffer.Length < bytes) buffer = new byte[bytes];
                    if ((flags & 0x2) != 0) Array.Clear(buffer, 0, bytes);  // AUDCLNT_BUFFERFLAGS_SILENT
                    else Marshal.Copy(data, buffer, 0, bytes);
                    capture.ReleaseBuffer(n);
                    DataAvailable?.Invoke(this, new WaveInEventArgs(buffer, bytes));
                }
            }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException) { error = e; }
        client?.Stop();
        if (capture != null) Marshal.ReleaseComObject(capture);
        if (client != null) Marshal.ReleaseComObject(client);
        (capture, client) = (null, null);
        RecordingStopped?.Invoke(this, new StoppedEventArgs(error));
    }

    public void StopRecording()
    {
        stopping = true;
        ready.Set();
    }

    public void Dispose()
    {
        StopRecording();
        thread?.Join(1000);
    }

    static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

    // ---- activation: ActivateAudioInterfaceAsync on the process loopback virtual device ----

    [StructLayout(LayoutKind.Sequential)]
    struct ActivationParams { public int Type; public uint ProcessId; public int Mode; }  // PROCESS_LOOPBACK, INCLUDE_TARGET_PROCESS_TREE

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariantBlob { public ushort Vt; ushort r1, r2, r3; public uint Size; public IntPtr Data; }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = true)]
    static extern int ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid iid, IntPtr activationParams,
                                                  IActivationHandler handler, out IActivationOperation operation);

    static IAudioClient Activate(int pid)
    {
        var p = new ActivationParams { Type = 1, ProcessId = (uint)pid, Mode = 0 };
        var pParams = Marshal.AllocHGlobal(Marshal.SizeOf<ActivationParams>());
        var pVariant = Marshal.AllocHGlobal(Marshal.SizeOf<PropVariantBlob>());
        try
        {
            Marshal.StructureToPtr(p, pParams, false);
            Marshal.StructureToPtr(new PropVariantBlob { Vt = 65 /* VT_BLOB */, Size = (uint)Marshal.SizeOf<ActivationParams>(), Data = pParams }, pVariant, false);
            var iid = typeof(IAudioClient).GUID;
            var handler = new ActivationHandler();
            Check(ActivateAudioInterfaceAsync(@"VAD\Process_Loopback", ref iid, pVariant, handler, out _));
            if (!handler.Done.Wait(TimeSpan.FromSeconds(5))) throw new InvalidOperationException("The app's sound didn't start.");
            return handler.Client ?? throw new InvalidOperationException("The app's sound can't be recorded.");
        }
        finally
        {
            Marshal.FreeHGlobal(pVariant);
            Marshal.FreeHGlobal(pParams);
        }
    }

    [ComVisible(true)]
    sealed class ActivationHandler : IActivationHandler, IAgileObject
    {
        public readonly ManualResetEventSlim Done = new(false);
        public IAudioClient? Client;

        public void ActivateCompleted(IActivationOperation operation)
        {
            if (operation.GetActivateResult(out var hr, out var iface) == 0 && hr >= 0) Client = (IAudioClient)iface;
            Done.Set();
        }
    }

    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivationHandler { void ActivateCompleted(IActivationOperation operation); }

    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivationOperation { [PreserveSig] int GetActivateResult(out int hr, [MarshalAs(UnmanagedType.IUnknown)] out object iface); }

    [ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAgileObject { }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, uint flags, long bufferDuration, long periodicity, IntPtr format, IntPtr session);
        [PreserveSig] int GetBufferSize(out uint frames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint padding);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr handle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong position, out ulong qpc);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
}
