using System.Runtime.InteropServices;
using FluxKit;

namespace Flux;

// The microphones of this computer with WASAPI in shared mode. The capture
// records in the mix format of the device, and FluxKit converts it to 48 kHz
// mono. A watcher of Windows reports the inputs that come and go and a new
// default input. MicCapture.swift of the Mac app does the same work with
// AVFoundation.
public sealed class WasapiMicSource : IMicSource
{
    // Holds the enumerator and the watcher, so that Windows keeps calling
    // the watcher.
    readonly List<object> held = [];

    public WasapiMicSource()
    {
        // Windows calls the watcher on its own threads. The registration
        // runs on a thread of the pool, in the MTA, so that the UI thread
        // does not wait for the audio service at the start.
        _ = Task.Run(Watch);
    }

    public event Action? InputsChanged;

    void Watch()
    {
        try
        {
            var enumerator = Wasapi.Enumerator();
            var c = new InputWatcher(() => InputsChanged?.Invoke());
            Marshal.ThrowExceptionForHR(enumerator.RegisterEndpointNotificationCallback(c));
            lock (held)
            {
                held.Add(enumerator);
                held.Add(c);
            }
        }
        catch (Exception e) when (Wasapi.IsFailure(e))
        {
            FluxLog.Info("mic", $"cannot watch the microphones: {e.Message}");
        }
    }

    public IReadOnlyList<MicInput> Inputs()
    {
        var enumerator = Wasapi.Enumerator();
        try
        {
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(Wasapi.Capture, Wasapi.Active, out var collection));
            try
            {
                collection.GetCount(out var count);
                var inputs = new List<MicInput>(count);
                for (var i = 0; i < count; i++)
                {
                    collection.Item(i, out var device);
                    try
                    {
                        device.GetId(out var id);
                        inputs.Add(new MicInput(id, Wasapi.Name(device) ?? "Microphone"));
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(device);
                    }
                }
                return inputs;
            }
            finally
            {
                Marshal.ReleaseComObject(collection);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(enumerator);
        }
    }

    // Windows does not ask a desktop app for the microphone. The privacy
    // settings let all desktop apps use it, or none.
    public MicPermission Permission => Privacy.Denied(Privacy.Microphone) ? MicPermission.Denied : MicPermission.Granted;

    public Task<bool> AuthorizeAsync() => Task.FromResult(Permission == MicPermission.Granted);

    public async Task<IMicCapture> StartAsync(string inputId, MicFeed feed, CancellationToken ct)
    {
        var capture = new WasapiCapture(inputId, feed);
        try
        {
            await capture.Started.WaitAsync(ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is OperationCanceledException or StreamException)
        {
            capture.Dispose();
            throw;
        }
        return capture;
    }

    // Reports each change of the capture inputs. Windows calls it on its own
    // threads, and it must not call WASAPI there. It is public, so that COM
    // can call it.
    [ComVisible(true)]
    public sealed class InputWatcher(Action changed) : Wasapi.IMMNotificationClient
    {
        public void OnDeviceStateChanged(string id, int state) => Report();

        public void OnDeviceAdded(string id) => Report();

        public void OnDeviceRemoved(string id) => Report();

        public void OnDefaultDeviceChanged(int flow, int role, string? id)
        {
            if (flow == Wasapi.Capture && role == Wasapi.Console)
            {
                Report();
            }
        }

        // The volume and other properties change often. The list of inputs
        // does not need them.
        public void OnPropertyValueChanged(string id, Wasapi.PropertyKey key)
        {
        }

        void Report()
        {
            try
            {
                changed();
            }
            catch (Exception e) when (e is InvalidOperationException or ObjectDisposedException)
            {
                FluxLog.Info("mic", $"the change of the microphones did not reach Flux: {e.Message}");
            }
        }
    }
}

// 1 capture on its own thread. It records from the chosen input, or from
// the default input when the chosen input is gone. A new choice, a new
// default input, or a device that went away opens the next device without
// a stop of the stream.
sealed class WasapiCapture : IMicCapture
{
    // The capture fails after this many failed opens in a row.
    const int MaxFailures = 3;

    readonly MicFeed feed;
    readonly AutoResetEvent wake = new(false);
    readonly TaskCompletionSource started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    volatile string wanted;
    // True after a new choice, so that the thread finds the device again.
    volatile bool moved = true;
    volatile bool stopped;

    public WasapiCapture(string inputId, MicFeed feed)
    {
        this.feed = feed;
        wanted = inputId;
        var thread = new Thread(Run) { IsBackground = true, Name = "Flux microphone" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    // Ends when the first device records, or throws StreamException.
    public Task Started => started.Task;

    public void Use(string inputId)
    {
        wanted = inputId;
        moved = true;
        wake.Set();
    }

    public void Dispose()
    {
        stopped = true;
        wake.Set();
    }

    void Run()
    {
        Wasapi.CaptureStream? open = null;
        var failures = 0;
        try
        {
            while (!stopped)
            {
                try
                {
                    if (open is null || moved)
                    {
                        moved = false;
                        var target = Wasapi.Resolve(wanted);
                        if (open is null || open.DeviceId != target)
                        {
                            open?.Dispose();
                            open = null;
                            open = Wasapi.CaptureStream.Open(target, wake);
                            FluxLog.Info("mic", $"the microphone records {open.Format.SampleRate} Hz with {open.Format.Channels} channels");
                            started.TrySetResult();
                        }
                    }
                    open.Read(feed);
                    failures = 0;
                    open.Wait();
                }
                catch (Exception e) when (Wasapi.IsFailure(e) || e is StreamException)
                {
                    open?.Dispose();
                    open = null;
                    if (!started.Task.IsCompleted)
                    {
                        started.TrySetException(Wasapi.UserError(e));
                        return;
                    }
                    // A device that went away, such as a headset that the
                    // user took off. The next turn opens the next device.
                    FluxLog.Info("mic", $"the microphone failed: {e.Message}");
                    if (++failures >= MaxFailures)
                    {
                        feed.Fail(Wasapi.UserError(e).Message);
                        return;
                    }
                    wake.WaitOne(200);
                }
            }
        }
        finally
        {
            // The wake stays, because Use and Dispose can still set it.
            open?.Dispose();
            started.TrySetException(new OperationCanceledException());
        }
    }
}

// The parts of WASAPI that the microphone uses. A method that Flux does not
// call has no parameters, but it keeps its place in the table of the
// interface.
public static class Wasapi
{
    public const int Capture = 1;
    public const int Console = 0;
    public const int Active = 1;
    const int SharedMode = 0;
    const int EventCallback = 0x00040000;
    const int ClsctxAll = 23;
    const int BufferSilent = 2;
    // The device buffer: 200 ms in units of 100 ns.
    const long BufferTime = 2_000_000;

    public const int NotFound = unchecked((int)0x80070490);
    public const int AccessDenied = unchecked((int)0x80070005);
    public const int DeviceInvalidated = unchecked((int)0x88890004);

    static readonly Guid EnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    static readonly Guid FloatFormat = new("00000003-0000-0010-8000-00aa00389b71");
    static readonly Guid PcmFormat = new("00000001-0000-0010-8000-00aa00389b71");
    static PropertyKey friendlyName = new() { Format = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Id = 14 };

    public static bool IsFailure(Exception e) =>
        e is COMException or InvalidCastException or InvalidComObjectException or ArgumentException or UnauthorizedAccessException;

    public static IMMDeviceEnumerator Enumerator() =>
        (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorClass, throwOnError: true)!)!;

    // The message for the user for a failure of WASAPI.
    public static StreamException UserError(Exception e) => e switch
    {
        StreamException s => s,
        UnauthorizedAccessException => new StreamException(MicPlugin.DeniedText, e),
        COMException { HResult: AccessDenied } => new StreamException(MicPlugin.DeniedText, e),
        COMException { HResult: NotFound } => new StreamException(MicPlugin.NoMicrophoneText, e),
        _ => new StreamException($"The microphone stopped: {e.Message}", e),
    };

    // The ID of the device to record: the input with the ID while it is
    // active, else the default input. It throws StreamException without an
    // input.
    public static string Resolve(string id)
    {
        var enumerator = Enumerator();
        try
        {
            if (id.Length > 0 && enumerator.GetDevice(id, out var chosen) >= 0 && chosen is not null)
            {
                try
                {
                    if (chosen.GetState(out var state) >= 0 && state == Active)
                    {
                        return id;
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(chosen);
                }
            }
            if (enumerator.GetDefaultAudioEndpoint(Capture, Console, out var device) < 0 || device is null)
            {
                throw new StreamException(MicPlugin.NoMicrophoneText);
            }
            try
            {
                device.GetId(out var defaultId);
                return defaultId;
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

    // The friendly name of the device, such as "USB Microphone".
    public static string? Name(IMMDevice device)
    {
        device.OpenPropertyStore(0, out var store);
        try
        {
            if (store.GetValue(ref friendlyName, out var value) < 0)
            {
                return null;
            }
            try
            {
                // VT_LPWSTR
                return value.Type == 31 && value.Pointer != IntPtr.Zero ? Marshal.PtrToStringUni(value.Pointer) : null;
            }
            finally
            {
                _ = PropVariantClear(ref value);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(store);
        }
    }

    // The format of the device from its WAVEFORMATEX or WAVEFORMATEXTENSIBLE.
    static AudioFormat ReadFormat(IntPtr format, out int blockAlign)
    {
        var tag = (ushort)Marshal.ReadInt16(format, 0);
        var channels = Marshal.ReadInt16(format, 2);
        var rate = Marshal.ReadInt32(format, 4);
        blockAlign = Marshal.ReadInt16(format, 12);
        var bits = Marshal.ReadInt16(format, 14);
        var extra = Marshal.ReadInt16(format, 16);
        var isFloat = tag == 3;
        var isPcm = tag == 1;
        if (tag == 0xFFFE && extra >= 22)
        {
            var sub = Marshal.PtrToStructure<Guid>(format + 24);
            isFloat = sub == FloatFormat;
            isPcm = sub == PcmFormat;
        }
        AudioSampleType? sample = (isFloat, isPcm, bits) switch
        {
            (true, _, 32) => AudioSampleType.Float32,
            (true, _, 64) => AudioSampleType.Float64,
            (_, true, 16) => AudioSampleType.Int16,
            (_, true, 24) => AudioSampleType.Int24,
            (_, true, 32) => AudioSampleType.Int32,
            _ => null,
        };
        if (sample is not { } s)
        {
            throw new StreamException($"The microphone uses {bits}-bit audio that Flux cannot read");
        }
        var result = new AudioFormat(rate, channels, s);
        if (result.BytesPerFrame != blockAlign)
        {
            throw new StreamException("The microphone uses a format that Flux cannot read");
        }
        return result;
    }

    // 1 stream on 1 capture device, in the mix format of the device.
    public sealed class CaptureStream : IDisposable
    {
        readonly IAudioClient client;
        readonly IAudioCaptureClient capture;
        readonly AutoResetEvent ready = new(false);
        readonly WaitHandle[] waits;
        readonly int blockAlign;
        byte[] buffer = [];

        CaptureStream(string deviceId, IAudioClient client, IAudioCaptureClient capture, AudioFormat format, int blockAlign, WaitHandle wake)
        {
            DeviceId = deviceId;
            this.client = client;
            this.capture = capture;
            Format = format;
            this.blockAlign = blockAlign;
            waits = [ready, wake];
        }

        public string DeviceId { get; }
        public AudioFormat Format { get; }

        public static CaptureStream Open(string deviceId, WaitHandle wake)
        {
            var enumerator = Enumerator();
            IMMDevice? device = null;
            IAudioClient? client = null;
            try
            {
                Marshal.ThrowExceptionForHR(enumerator.GetDevice(deviceId, out device));
                var iid = typeof(IAudioClient).GUID;
                device!.Activate(ref iid, ClsctxAll, IntPtr.Zero, out var activated);
                client = (IAudioClient)activated;
                client.GetMixFormat(out var mix);
                AudioFormat format;
                int blockAlign;
                try
                {
                    format = ReadFormat(mix, out blockAlign);
                    client.Initialize(SharedMode, EventCallback, BufferTime, 0, mix, IntPtr.Zero);
                }
                finally
                {
                    Marshal.FreeCoTaskMem(mix);
                }
                var serviceId = typeof(IAudioCaptureClient).GUID;
                client.GetService(ref serviceId, out var service);
                var stream = new CaptureStream(deviceId, client, (IAudioCaptureClient)service, format, blockAlign, wake);
                client.SetEventHandle(stream.ready.SafeWaitHandle.DangerousGetHandle());
                client.Start();
                return stream;
            }
            catch (Exception e) when (IsFailure(e) || e is StreamException)
            {
                if (client is not null)
                {
                    Marshal.ReleaseComObject(client);
                }
                throw;
            }
            finally
            {
                if (device is not null)
                {
                    Marshal.ReleaseComObject(device);
                }
                Marshal.ReleaseComObject(enumerator);
            }
        }

        // Waits for the next buffer of the device, or for a wake of the
        // capture thread, at most 100 ms.
        public void Wait() => WaitHandle.WaitAny(waits, 100);

        // Gives each buffer that waits to the feed.
        public void Read(MicFeed feed)
        {
            while (true)
            {
                capture.GetNextPacketSize(out var next);
                if (next <= 0)
                {
                    return;
                }
                var hr = capture.GetBuffer(out var data, out var frames, out var flags, out _, out _);
                Marshal.ThrowExceptionForHR(hr);
                if (hr != 0 || frames <= 0)
                {
                    // AUDCLNT_S_BUFFER_EMPTY.
                    return;
                }
                var length = frames * blockAlign;
                if (buffer.Length < length)
                {
                    buffer = new byte[length];
                }
                if ((flags & BufferSilent) != 0)
                {
                    Array.Clear(buffer, 0, length);
                }
                else
                {
                    Marshal.Copy(data, buffer, 0, length);
                }
                capture.ReleaseBuffer(frames);
                feed.Write(buffer.AsSpan(0, length), Format);
            }
        }

        public void Dispose()
        {
            try
            {
                client.Stop();
            }
            catch (COMException)
            {
                // A device that went away cannot stop.
            }
            Marshal.ReleaseComObject(capture);
            Marshal.ReleaseComObject(client);
            ready.Dispose();
        }
    }

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid Format;
        public int Id;
    }

    // A PROPVARIANT with the size of 64-bit Windows. Flux reads only strings.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant
    {
        [FieldOffset(0)]
        public ushort Type;
        [FieldOffset(8)]
        public IntPtr Pointer;
    }

    [ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMNotificationClient
    {
        void OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
        void OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
        void OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
        void OnDefaultDeviceChanged(int flow, int role, [MarshalAs(UnmanagedType.LPWStr)] string? id);
        void OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, PropertyKey key);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(int flow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig]
        int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice? device);
        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice? device);
        [PreserveSig]
        int RegisterEndpointNotificationCallback(IMMNotificationClient client);
        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        void GetCount(out int count);
        void Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        void Activate(ref Guid id, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        void OpenPropertyStore(int access, out IPropertyStore store);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig]
        int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        void GetCount();
        void GetAt();
        [PreserveSig]
        int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioClient
    {
        void Initialize(int mode, int flags, long bufferTime, long period, IntPtr format, IntPtr session);
        void GetBufferSize();
        void GetStreamLatency();
        void GetCurrentPadding();
        void IsFormatSupported();
        void GetMixFormat(out IntPtr format);
        void GetDevicePeriod();
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr handle);
        void GetService(ref Guid id, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185c395cd317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioCaptureClient
    {
        [PreserveSig]
        int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
        void ReleaseBuffer(int frames);
        void GetNextPacketSize(out int frames);
    }
}
