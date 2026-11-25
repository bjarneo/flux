using System.Runtime.InteropServices;
using FluxKit;

namespace Flux;

// Plays the sound of the remote desktop with WASAPI in shared mode: float
// stereo samples at 48 kHz, which Windows converts to the format of the
// default output device. DesktopAudio calls it on the thread that reads the
// stream, so Play only queues the frame. A thread of its own writes the
// frames to the device each time that the device asks for more. The device
// opens at the first frame of a stream and closes at Stop.
public sealed class DesktopSound : IDesktopAudioOutput
{
    const int ChannelCount = 2;
    const int SampleRate = 48_000;

    sealed record Frame(float[] Samples, float Volume, Action Played);

    readonly Lock gate = new();
    readonly Queue<Frame> frames = new();
    readonly AutoResetEvent wake = new(false);
    Thread? thread;
    // The samples of the first frame that went to the device already.
    int offset;
    // Each stop moves the generation forward, so that the thread closes the
    // device of the old stream.
    int generation;
    bool failed;

    public bool Play(float[] samples, float volume, Action played)
    {
        lock (gate)
        {
            if (failed)
            {
                return false;
            }
            frames.Enqueue(new Frame(samples, volume, played));
            if (thread is null)
            {
                thread = new Thread(Run) { IsBackground = true, Name = "Flux audio" };
                thread.Start();
            }
        }
        wake.Set();
        return true;
    }

    public void Stop()
    {
        Frame[] dropped;
        lock (gate)
        {
            dropped = frames.ToArray();
            frames.Clear();
            offset = 0;
            generation++;
            failed = false;
        }
        wake.Set();
        foreach (var f in dropped)
        {
            f.Played();
        }
    }

    void Run()
    {
        Endpoint? device = null;
        var seen = 0;
        // The failures of the device in a row. A device that fails again
        // after it opened counts as no device.
        var failures = 0;
        while (true)
        {
            bool idle;
            int now;
            lock (gate)
            {
                idle = frames.Count == 0;
                now = generation;
            }
            if (now != seen)
            {
                seen = now;
                device?.Dispose();
                device = null;
            }
            if (idle)
            {
                wake.WaitOne();
                continue;
            }
            if (device is null)
            {
                try
                {
                    device = Endpoint.Open(wake);
                }
                catch (Exception e) when (IsFailure(e))
                {
                    FluxLog.Error("desktop", $"remote desktop: no audio output: {e.Message}");
                    Fail();
                    continue;
                }
            }
            try
            {
                Fill(device, seen);
                failures = 0;
            }
            catch (Exception e) when (IsFailure(e))
            {
                // The device went away, for example a headset that the user
                // took off. The next turn opens the default device again.
                FluxLog.Info("desktop", $"remote desktop: the audio output failed: {e.Message}");
                device.Dispose();
                device = null;
                if (++failures >= 3)
                {
                    failures = 0;
                    Fail();
                }
                continue;
            }
            WaitHandle.WaitAny(device.Waits, 100);
        }
    }

    // Writes the queued samples that fit into the buffer of the device.
    void Fill(Endpoint device, int seen)
    {
        var free = device.BufferFrames - device.Padding();
        if (free <= 0)
        {
            return;
        }
        var done = new List<Action>();
        var written = 0;
        var at = device.GetBuffer(free);
        try
        {
            lock (gate)
            {
                while (generation == seen && written < free && frames.TryPeek(out var f))
                {
                    var take = Math.Min(free - written, (f.Samples.Length - offset) / ChannelCount);
                    var scaled = new float[take * ChannelCount];
                    for (var i = 0; i < scaled.Length; i++)
                    {
                        scaled[i] = f.Samples[offset + i] * f.Volume;
                    }
                    Marshal.Copy(scaled, 0, at + written * ChannelCount * sizeof(float), scaled.Length);
                    written += take;
                    offset += take * ChannelCount;
                    if (offset >= f.Samples.Length || take == 0)
                    {
                        frames.Dequeue();
                        offset = 0;
                        done.Add(f.Played);
                    }
                }
            }
        }
        finally
        {
            device.ReleaseBuffer(written);
        }
        if (written > 0)
        {
            device.Start();
        }
        foreach (var played in done)
        {
            played();
        }
    }

    // The device cannot play. The frames drop, and Play returns false until
    // the next stop.
    void Fail()
    {
        Frame[] dropped;
        lock (gate)
        {
            failed = true;
            dropped = frames.ToArray();
            frames.Clear();
            offset = 0;
        }
        foreach (var f in dropped)
        {
            f.Played();
        }
    }

    static bool IsFailure(Exception e) => e is COMException or InvalidCastException or InvalidComObjectException or ArgumentException or UnauthorizedAccessException;

    // 1 stream on the default output device.
    sealed class Endpoint : IDisposable
    {
        // The device buffer: 40 ms in units of 100 ns.
        const long BufferTime = 400_000;
        const int SharedMode = 0;
        const int EventCallback = 0x00040000;
        const int AutoConvert = unchecked((int)0x80000000);
        const int DefaultQuality = 0x08000000;
        const int All = 23;

        static readonly Guid EnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid FloatFormat = new("00000003-0000-0010-8000-00aa00389b71");

        readonly IAudioClient client;
        readonly IAudioRenderClient render;
        readonly AutoResetEvent ready = new(false);
        bool started;

        Endpoint(IAudioClient client, IAudioRenderClient render, int frames, WaitHandle wake)
        {
            this.client = client;
            this.render = render;
            BufferFrames = frames;
            Waits = [ready, wake];
        }

        public int BufferFrames { get; }

        // The event of the device that asks for more samples, and the wake of the thread.
        public WaitHandle[] Waits { get; }

        // Opens the default output device. wake is the wake of the thread,
        // which the thread also waits for.
        public static Endpoint Open(WaitHandle wake)
        {
            var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass, throwOnError: true)!)!;
            try
            {
                // eRender and eMultimedia: the device that plays music and video.
                enumerator.GetDefaultAudioEndpoint(0, 1, out var device);
                try
                {
                    var id = typeof(IAudioClient).GUID;
                    device.Activate(ref id, All, IntPtr.Zero, out var activated);
                    var client = (IAudioClient)activated;
                    try
                    {
                        var format = new WaveFormat
                        {
                            Tag = 0xFFFE,
                            Channels = ChannelCount,
                            Rate = SampleRate,
                            BytesPerSecond = SampleRate * ChannelCount * sizeof(float),
                            BlockAlign = ChannelCount * sizeof(float),
                            Bits = 32,
                            Extra = 22,
                            ValidBits = 32,
                            ChannelMask = 3,
                            Format = FloatFormat,
                        };
                        client.Initialize(SharedMode, EventCallback | AutoConvert | DefaultQuality, BufferTime, 0, ref format, IntPtr.Zero);
                        client.GetBufferSize(out var frames);
                        var serviceId = typeof(IAudioRenderClient).GUID;
                        client.GetService(ref serviceId, out var service);
                        var endpoint = new Endpoint(client, (IAudioRenderClient)service, frames, wake);
                        client.SetEventHandle(endpoint.ready.SafeWaitHandle.DangerousGetHandle());
                        return endpoint;
                    }
                    catch
                    {
                        Marshal.ReleaseComObject(client);
                        throw;
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(device);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(enumerator);
            }
        }

        public int Padding()
        {
            client.GetCurrentPadding(out var frames);
            return frames;
        }

        public IntPtr GetBuffer(int frames)
        {
            render.GetBuffer(frames, out var data);
            return data;
        }

        public void ReleaseBuffer(int frames) => render.ReleaseBuffer(frames, 0);

        public void Start()
        {
            if (!started)
            {
                client.Start();
                started = true;
            }
        }

        public void Dispose()
        {
            try
            {
                if (started)
                {
                    client.Stop();
                }
            }
            catch (COMException)
            {
                // A device that went away cannot stop.
            }
            Marshal.ReleaseComObject(render);
            Marshal.ReleaseComObject(client);
            ready.Dispose();
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    struct WaveFormat
    {
        public ushort Tag;
        public ushort Channels;
        public int Rate;
        public int BytesPerSecond;
        public ushort BlockAlign;
        public ushort Bits;
        public ushort Extra;
        public ushort ValidBits;
        public int ChannelMask;
        public Guid Format;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        void EnumAudioEndpoints();
        void GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        void Activate(ref Guid id, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        void Initialize(int mode, int flags, long bufferTime, long period, ref WaveFormat format, IntPtr session);
        void GetBufferSize(out int frames);
        void GetStreamLatency();
        void GetCurrentPadding(out int frames);
        void IsFormatSupported();
        void GetMixFormat();
        void GetDevicePeriod();
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr handle);
        void GetService(ref Guid id, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient
    {
        void GetBuffer(int frames, out IntPtr data);
        void ReleaseBuffer(int frames, int flags);
    }
}
