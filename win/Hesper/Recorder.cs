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

    /// micName / speakerName: a device's name (Settings), or "" for Windows' default one.
    public Recorder(string folder, string micName = "", string speakerName = "")
    {
        Folder = folder;
        this.micName = micName;
        this.speakerName = speakerName;
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
        system?.Start();
        mic?.Start();
    }

    public TimeSpan Elapsed => clock.Elapsed;

    public void Stop()
    {
        mic?.Stop();
        system?.Stop();
        keepAlive?.Stop();
        clock.Stop();
    }

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
        bool started;

        public Track(IWaveIn capture, string path, System.Diagnostics.Stopwatch clock)
        {
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
                if (lead > 0) writer.WriteSamples(new float[lead], 0, lead);
            }
            buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
            int n;
            while ((n = converted.Read(chunk, 0, chunk.Length)) > 0)
                writer.WriteSamples(chunk, 0, n);
        }

        public void Stop()
        {
            capture.StopRecording();
            stopped.Task.Wait(TimeSpan.FromSeconds(3));
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
