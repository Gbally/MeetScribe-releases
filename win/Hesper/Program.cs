namespace Hesper;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // A test without the tray icon: record N seconds into the notes folder, then make the notes
        if (args.Length >= 2 && args[0] == "--record" && int.TryParse(args[1], out var seconds))
            return RecordTest(seconds, args.Length > 2 ? args[2] : Paths.DefaultNotesFolder(), args.Length > 3 ? args[3] : "")
                .GetAwaiter().GetResult();
        if (args.Length >= 1 && args[0] == "--devices")
            return Devices();
        if (args.Length >= 2 && args[0] == "--write-icon")  // Hesper.ico, and PNGs to look at
        {
            Brand.WriteIco(args[1]);
            Brand.Draw(256).Save(Path.ChangeExtension(args[1], ".png"));
            Brand.Draw(256, recording: true).Save(Path.ChangeExtension(args[1], ".recording.png"));
            return 0;
        }
        using var single = new Mutex(true, @"Local\Hesper", out var first);
        if (!first) return 0;  // already running: its icon is in the notification area
        ApplicationConfiguration.Initialize();
        if (!Setup.IsInstalled)
        {
            AppSettings.Load().WriteConfig();  // the notes folder and defaults, before the engine's first run
            using var setup = new SetupForm();
            Application.Run(setup);
            if (!setup.Done) return 1;
        }
        Application.Run(new TrayApp());
        return 0;
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

    static async Task<int> RecordTest(int seconds, string notesFolder, string mic)
    {
        var folder = Paths.NewSession(notesFolder, DateTime.Now);
        using var rec = new Recorder(folder, mic);
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
