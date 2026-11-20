using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Hesper;

/// One recording: the microphone and the PC's sound (WASAPI loopback) into mic.wav and system.wav,
/// 16 kHz mono 16-bit, on one timeline (as mic.caf / system.caf on the Mac). Starts whatever it can.
sealed class Recorder : IDisposable
{
    public string Folder { get; }
    public DateTime Started { get; private set; }
    public List<string> Notices { get; } = [];

    readonly System.Diagnostics.Stopwatch clock = new();
    Track? mic, system;
    WasapiOut? keepAlive;

    readonly string micName, speakerName;

    readonly string appOnly;
    bool appStarted;

    /// micName / speakerName: a device's name (Settings), or "" for Windows' default one.
    /// appOnly: "teams" to record only Microsoft Teams' sound, not everything the PC plays.
    public Recorder(string folder, string micName = "", string speakerName = "", string appOnly = "")
    {
        Folder = folder;
        this.micName = micName;
        this.speakerName = speakerName;
        this.appOnly = appOnly;
    }

    /// The device named so (or whose name contains it), else Windows' default. The default, not the
    /// "communications" one: on PCs with a monitor's speakers or a virtual device (SteelSeries Sonar,
    /// Nahimic…) the communications choice is often one nothing plays to.
    public static MMDevice Device(MMDeviceEnumerator devices, DataFlow flow, string name)
    {
        if (name.Length > 0)
            foreach (var d in devices.EnumerateAudioEndPoints(flow, DeviceState.Active))
                if (d.FriendlyName.Contains(name, StringComparison.OrdinalIgnoreCase)) return d;
        return devices.GetDefaultAudioEndpoint(flow, Role.Console);
    }

    public static List<string> DeviceNames(DataFlow flow)
    {
        using var devices = new MMDeviceEnumerator();
        return devices.EnumerateAudioEndPoints(flow, DeviceState.Active).Select(d => d.FriendlyName).ToList();
    }

    /// Throws only when nothing at all can be recorded.
    public void Start()
    {
        Directory.CreateDirectory(Folder);
        Started = DateTime.Now;
        clock.Start();
        using var devices = new MMDeviceEnumerator();
        if (appOnly.Length > 0)  // "teams", or "process:NAME" (a test)
        {
            string[] names = appOnly == "teams" ? ["ms-teams", "Teams"] : [appOnly.Replace("process:", "")];
            var teams = ProcessLoopbackCapture.Supported ? ProcessLoopbackCapture.FindProcess(names) : null;
            if (teams is int pid)
                try
                {
                    Paths.WriteLog($"recording one app's sound only ({names[0]}, process {pid})");
                    // An app only sends sound while it plays: the gaps are filled to keep one timeline
                    system = new Track(new ProcessLoopbackCapture(pid), Path.Combine(Folder, "system.wav"), clock, fillGaps: true);
                    system.Start();  // now: if the app's sound can't be captured, all the PC's is
                    appStarted = true;
                }
                catch (Exception e) when (e is COMException or InvalidOperationException)
                {
                    Paths.WriteLog("one app only: " + e.Message);
                    system?.Dispose();
                    system = null;
                }
            if (system == null)
                Notices.Add(ProcessLoopbackCapture.Supported ? "Microsoft Teams isn't running — recording all PC audio instead."
                                                              : "Recording one app only needs Windows 11 — recording all PC audio instead.");
        }
        if (system == null)
        try
        {
            var speaker = Device(devices, DataFlow.Render, speakerName);
            Paths.WriteLog($"recording PC sound from {speaker.FriendlyName}");
            var loopback = new WasapiLoopbackCapture(speaker);
            // Loopback only sends data while something plays: play silence so the track never stops
            keepAlive = new WasapiOut(speaker, AudioClientShareMode.Shared, true, 100);
            keepAlive.Init(new SilenceProvider(loopback.WaveFormat));
            keepAlive.Play();
            system = new Track(loopback, Path.Combine(Folder, "system.wav"), clock);
        }
        catch (Exception e)
        {
            Notices.Add($"PC sound can't be recorded ({e.Message}): only your microphone is.");
        }
        try
        {
            var microphone = Device(devices, DataFlow.Capture, micName);
            Paths.WriteLog($"recording the microphone {microphone.FriendlyName}");
            mic = new Track(new WasapiCapture(microphone, true, 100), Path.Combine(Folder, "mic.wav"), clock);
        }
        catch (Exception e)
        {
            Notices.Add($"Microphone: {e.Message}");
        }
        if (mic == null && system == null)
            throw new InvalidOperationException(string.Join("\n", Notices));
        File.WriteAllText(Path.Combine(Folder, "meeting.json"),
            $"{{\"title\": \"\", \"started\": \"{Started:yyyy-MM-ddTHH:mm:ss}\"}}");
        if (!appStarted) system?.Start();
        mic?.Start();
    }

    public TimeSpan Elapsed => clock.Elapsed;

    /// How loud each track is now (RMS of the last chunk, 0…1); null when that track isn't recorded.
    public float? MicLevel => mic?.Level;
    public float? SystemLevel => system?.Level;

    /// When something was last heard, in seconds since the start (to notice a forgotten recording).
    public double LastSound => Math.Max(mic?.LastSound ?? 0, system?.LastSound ?? 0);

    /// After Stop: drops the audio after that many seconds (the quiet tail of a forgotten recording).
    public void Trim(double seconds)
    {
        foreach (var name in new[] { "mic.wav", "system.wav" })
        {
            var path = Path.Combine(Folder, name);
            if (!File.Exists(path)) continue;
            var tmp = path + ".tmp";
            using (var reader = new WaveFileReader(path))
            using (var writer = new WaveFileWriter(tmp, reader.WaveFormat))
            {
                var keep = (long)(seconds * reader.WaveFormat.AverageBytesPerSecond) / reader.WaveFormat.BlockAlign * reader.WaveFormat.BlockAlign;
                var buffer = new byte[1 << 16];
                int n;
                while (keep > 0 && (n = reader.Read(buffer, 0, (int)Math.Min(buffer.Length, keep))) > 0) { writer.Write(buffer, 0, n); keep -= n; }
            }
            File.Move(tmp, path, true);
        }
    }

    /// Stops both tracks together. Await it on the UI thread, never wait on it there: NAudio says a
    /// capture has stopped through the UI thread, so blocking it held each track for its whole timeout.
    public async Task StopAsync()
    {
        await Task.WhenAll(mic?.StopAsync() ?? Task.CompletedTask, system?.StopAsync() ?? Task.CompletedTask);
        keepAlive?.Stop();
        clock.Stop();
    }

    /// For the console test (--record), which has no UI thread.
    public void Stop() => StopAsync().GetAwaiter().GetResult();

    public void Dispose()
    {
        mic?.Dispose();
        system?.Dispose();
        keepAlive?.Dispose();
    }

    /// One capture device → 16 kHz mono WAV, converted as it comes (an hour of 48 kHz float stereo
    /// would be 1.4 GB). Its first sound is placed at its time since the recording started.
    sealed class Track : IDisposable
    {
        const int Rate = 16_000;
        readonly IWaveIn capture;
        readonly BufferedWaveProvider buffer;
        readonly ISampleProvider converted;
        readonly WaveFileWriter writer;
        readonly System.Diagnostics.Stopwatch clock;
        readonly float[] chunk = new float[Rate];
        readonly TaskCompletionSource stopped = new();
        readonly bool fillGaps;
        bool started;
        long written;  // samples
        public volatile float Level;
        public double LastSound;  // seconds

        public Track(IWaveIn capture, string path, System.Diagnostics.Stopwatch clock, bool fillGaps = false)
        {
            this.fillGaps = fillGaps;
            this.capture = capture;
            this.clock = clock;
            buffer = new BufferedWaveProvider(capture.WaveFormat)
            {
                BufferDuration = TimeSpan.FromSeconds(10), DiscardOnBufferOverflow = true, ReadFully = false,
            };
            var mono = Mono(buffer.ToSampleProvider());
            converted = mono.WaveFormat.SampleRate == Rate ? mono : new WdlResamplingSampleProvider(mono, Rate);
            writer = new WaveFileWriter(path, new WaveFormat(Rate, 16, 1));
            capture.DataAvailable += OnData;
            capture.RecordingStopped += (_, e) =>
            {
                if (e.Exception != null) Paths.WriteLog($"{Path.GetFileName(path)}: {e.Exception.Message}");
                stopped.TrySetResult();
            };
        }

        static ISampleProvider Mono(ISampleProvider source) => source.WaveFormat.Channels switch
        {
            1 => source,
            2 => new StereoToMonoSampleProvider(source) { LeftVolume = 0.5f, RightVolume = 0.5f },
            _ => new DownmixToMono(source),
        };

        public void Start() => capture.StartRecording();

        void OnData(object? sender, WaveInEventArgs e)
        {
            if (!started)
            {
                started = true;
                var lead = (int)(clock.Elapsed.TotalSeconds * Rate);  // silence before this device's first sound
                if (lead > 0) { writer.WriteSamples(new float[lead], 0, lead); written += lead; }
            }
            if (fillGaps)
            {
                // Silence while the app played nothing: what's missing before this chunk (beyond half a second)
                var incoming = (long)((double)e.BytesRecorded / capture.WaveFormat.AverageBytesPerSecond * Rate);
                var missing = (long)(clock.Elapsed.TotalSeconds * Rate) - incoming - written;
                if (missing > Rate / 2) { var pad = (int)Math.Min(missing, int.MaxValue); writer.WriteSamples(new float[pad], 0, pad); written += pad; }
            }
            buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
            int n;
            while ((n = converted.Read(chunk, 0, chunk.Length)) > 0)
            {
                writer.WriteSamples(chunk, 0, n);
                double sum = 0;
                for (var i = 0; i < n; i++) sum += chunk[i] * chunk[i];
                Level = (float)Math.Sqrt(sum / n);
                written += n;
                if (Level > 0.01f) LastSound = (double)written / Rate;  // about -40 dB: speech, not room noise
            }
        }

        public async Task StopAsync()
        {
            capture.StopRecording();
            await Task.WhenAny(stopped.Task, Task.Delay(3000));
            writer.Flush();
        }

        public void Dispose()
        {
            writer.Dispose();
            capture.Dispose();
        }
    }

    /// The mean of all channels (5.1 / 7.1 devices).
    sealed class DownmixToMono(ISampleProvider source) : ISampleProvider
    {
        readonly int channels = source.WaveFormat.Channels;
        float[] wide = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(float[] buffer, int offset, int count)
        {
            if (wide.Length < count * channels) wide = new float[count * channels];
            var frames = source.Read(wide, 0, count * channels) / channels;
            for (var i = 0; i < frames; i++)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++) sum += wide[i * channels + c];
                buffer[offset + i] = sum / channels;
            }
            return frames;
        }
    }
}
