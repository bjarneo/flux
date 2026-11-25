using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using FluxKit;
using Microsoft.Win32;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using WinRT;

namespace Flux;

// The displays of this computer with Windows.Graphics.Capture. Win32 lists
// the monitors and their modes. A capture copies each new frame of the
// display from the graphics card, scales it to the size of the stream on
// the CPU, and gives at most 30 frames each second. Windows sends no frame
// while the screen does not change. ScreenCapture.swift of the Mac app does
// the same work with ScreenCaptureKit.
public sealed class WindowsScreens : IScreenSource
{
    // Windows reports a new setup of the displays, on a thread of its own.
    public static event EventHandler? Changed
    {
        add => SystemEvents.DisplaySettingsChanged += value;
        remove => SystemEvents.DisplaySettingsChanged -= value;
    }

    public IReadOnlyList<DisplayInfo> Displays()
    {
        var list = new List<(DisplayInfo Info, bool Main)>();
        foreach (var m in Monitors.All())
        {
            var (w, h) = Monitors.Mode(m.Device) ?? (m.Width, m.Height);
            list.Add((new DisplayInfo(m.Device, Monitors.Name(m.Device), w, h), m.Main));
        }
        return list.OrderBy(d => d.Main ? 0 : 1).Select(d => d.Info).ToArray();
    }

    public (int Width, int Height)? PixelSize(string displayId) => Monitors.Mode(displayId);

    // False when this version of Windows has no screen capture.
    public bool HasAccess
    {
        get
        {
            try
            {
                return GraphicsCaptureSession.IsSupported();
            }
            catch (Exception e) when (e is COMException or TypeLoadException or InvalidCastException)
            {
                return false;
            }
        }
    }

    public Task<IScreenCapture> PrepareAsync(string displayId, IFrameSink frames)
    {
        if (!HasAccess)
        {
            throw new StreamException("This version of Windows cannot record the screen");
        }
        var monitor = Monitors.All().FirstOrDefault(m => m.Device == displayId) ?? throw new StreamException("The display is not connected");
        try
        {
            var item = CaptureItems.ForMonitor(monitor.Handle);
            var device = Direct3D.CreateDevice();
            return Task.FromResult<IScreenCapture>(new WindowsScreenCapture(item, device, frames));
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException or UnauthorizedAccessException or DllNotFoundException)
        {
            throw new StreamException($"Windows cannot record the display: {e.Message}", e);
        }
    }
}

// The capture of 1 display. A thread of its own takes the newest frame of
// the frame pool, copies it, scales it, and gives it to the sink.
sealed class WindowsScreenCapture(GraphicsCaptureItem item, IDirect3DDevice device, IFrameSink frames) : IScreenCapture
{
    static readonly TimeSpan FrameTime = TimeSpan.FromSeconds(1.0 / 30);

    // The capture fails after this many failed frames in a row.
    const int MaxFailures = 30;

    readonly AutoResetEvent arrived = new(false);
    readonly FrameRing ring = new();
    Direct3D11CaptureFramePool? pool;
    GraphicsCaptureSession? session;
    SizeInt32 poolSize;
    volatile int width;
    volatile int height;
    volatile bool stopped;

    public Task StartAsync(int width, int height)
    {
        this.width = width;
        this.height = height;
        poolSize = item.Size;
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
        pool.FrameArrived += (_, _) => arrived.Set();
        item.Closed += (_, _) =>
        {
            if (!stopped)
            {
                frames.Failed("The display is not connected");
            }
        };
        session = pool.CreateCaptureSession(item);
        try
        {
            session.IsCursorCaptureEnabled = true;
        }
        catch (Exception e) when (e is COMException or InvalidCastException)
        {
            FluxLog.Info("stream", "this version of Windows always captures the cursor");
        }
        try
        {
            // Windows 11 can leave out the yellow border around the display.
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            {
                session.IsBorderRequired = false;
            }
        }
        catch (Exception e) when (e is COMException or InvalidCastException or UnauthorizedAccessException)
        {
            FluxLog.Debug("stream", "Windows keeps the border of the screen capture");
        }
        new Thread(Run) { IsBackground = true, Name = "Flux screen" }.Start();
        session.StartCapture();
        FluxLog.Info("stream", $"screen capture of {poolSize.Width}x{poolSize.Height} to {width}x{height}");
        return Task.CompletedTask;
    }

    public Task ResizeAsync(int width, int height)
    {
        this.width = width;
        this.height = height;
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        stopped = true;
        arrived.Set();
    }

    void Run()
    {
        var source = Array.Empty<byte>();
        var last = Stopwatch.GetTimestamp() - Stopwatch.Frequency;
        var failures = 0;
        try
        {
            while (!stopped)
            {
                arrived.WaitOne(250);
                if (stopped)
                {
                    return;
                }
                // At most 30 frames each second. The newest frame goes out
                // after the wait, so the last change of the screen is not lost.
                var wait = FrameTime - Stopwatch.GetElapsedTime(last);
                if (wait > TimeSpan.Zero)
                {
                    Thread.Sleep(wait);
                }
                try
                {
                    if (Next() is not { } frame)
                    {
                        continue;
                    }
                    using (frame)
                    {
                        last = Stopwatch.GetTimestamp();
                        Deliver(frame, ref source);
                    }
                    failures = 0;
                }
                catch (Exception e) when (e is COMException or InvalidOperationException or ArgumentException or ObjectDisposedException or UnauthorizedAccessException)
                {
                    FluxLog.Debug("stream", $"a screen frame did not copy: {e.Message}");
                    if (++failures >= MaxFailures && !stopped)
                    {
                        frames.Failed($"The screen capture failed: {e.Message}");
                        return;
                    }
                }
            }
        }
        finally
        {
            session?.Dispose();
            pool?.Dispose();
        }
    }

    // The newest frame of the pool. The older frames drop.
    Direct3D11CaptureFrame? Next()
    {
        Direct3D11CaptureFrame? newest = null;
        while (pool!.TryGetNextFrame() is { } frame)
        {
            newest?.Dispose();
            newest = frame;
        }
        return newest;
    }

    void Deliver(Direct3D11CaptureFrame frame, ref byte[] source)
    {
        int sw;
        int sh;
        using (var bitmap = SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Ignore).AsTask().GetAwaiter().GetResult())
        {
            sw = bitmap.PixelWidth;
            sh = bitmap.PixelHeight;
            if (source.Length != sw * sh * 4)
            {
                source = new byte[sw * sh * 4];
            }
            bitmap.CopyToBuffer(source.AsBuffer());
        }
        // A new resolution of the display needs a pool of the new size. The
        // pool changes after the copy, so that the frame stays valid.
        var content = frame.ContentSize;
        if (content.Width != poolSize.Width || content.Height != poolSize.Height)
        {
            poolSize = content;
            pool!.Recreate(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, poolSize);
        }
        var w = width;
        var h = height;
        var output = ring.Next(w, h);
        try
        {
            Bgra.Scale(source, sw, sh, output.Pixels, w, h);
        }
        finally
        {
            output.EndWrite();
        }
        frames.Frame(output, 0);
    }
}

// The monitors of Windows with Win32: the handle, the device name, such as
// \\.\DISPLAY1, the mode in pixels, and the name of the monitor.
static class Monitors
{
    public sealed record Monitor(IntPtr Handle, string Device, bool Main, int Width, int Height);

    const int Primary = 1;
    const int CurrentSettings = -1;

    public static IReadOnlyList<Monitor> All()
    {
        var list = new List<Monitor>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (handle, _, ref rect, _) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(handle, ref info))
            {
                list.Add(new Monitor(handle, info.Device, (info.Flags & Primary) != 0, rect.Right - rect.Left, rect.Bottom - rect.Top));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // The size of the current mode in pixels, or null when the display is gone.
    public static (int Width, int Height)? Mode(string device)
    {
        var mode = new DevMode { Size = (short)Marshal.SizeOf<DevMode>() };
        return EnumDisplaySettings(device, CurrentSettings, ref mode) && mode.PelsWidth > 0 && mode.PelsHeight > 0
            ? (mode.PelsWidth, mode.PelsHeight)
            : null;
    }

    // The name of the monitor from its driver, or "Display 2" for the
    // generic driver of Windows.
    public static string Name(string device)
    {
        var info = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>() };
        var name = EnumDisplayDevices(device, 0, ref info, 0) ? info.DeviceString.Trim() : "";
        if (name.Length > 0 && !name.StartsWith("Generic ", StringComparison.OrdinalIgnoreCase))
        {
            return name;
        }
        var number = new string(device.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray());
        return number.Length > 0 ? $"Display {number}" : "Display";
    }

    delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public int Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string Device;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DisplayDevice
    {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    // DEVMODEW with the fields of a display.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        public short SpecVersion;
        public short DriverVersion;
        public short Size;
        public short DriverExtra;
        public int Fields;
        public int PositionX;
        public int PositionY;
        public int DisplayOrientation;
        public int DisplayFixedOutput;
        public short Color;
        public short Duplex;
        public short YResolution;
        public short TTOption;
        public short Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FormName;
        public short LogPixels;
        public int BitsPerPel;
        public int PelsWidth;
        public int PelsHeight;
        public int DisplayFlags;
        public int DisplayFrequency;
        public int IcmMethod;
        public int IcmIntent;
        public int MediaType;
        public int DitherType;
        public int Reserved1;
        public int Reserved2;
        public int PanningWidth;
        public int PanningHeight;
    }

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc proc, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetMonitorInfoW")]
    static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsW")]
    static extern bool EnumDisplaySettings(string device, int mode, ref DevMode devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
    static extern bool EnumDisplayDevices(string device, int index, ref DisplayDevice info, int flags);
}

// Makes the capture item of a monitor through the interop interface of
// GraphicsCaptureItem, because the WinRT API has no item for a monitor on
// Windows 10.
static class CaptureItems
{
    const string ClassName = "Windows.Graphics.Capture.GraphicsCaptureItem";
    static readonly Guid ItemId = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    public static GraphicsCaptureItem ForMonitor(IntPtr monitor)
    {
        Marshal.ThrowExceptionForHR(WindowsCreateString(ClassName, ClassName.Length, out var name));
        try
        {
            var interopId = typeof(IGraphicsCaptureItemInterop).GUID;
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref interopId, out var factory));
            try
            {
                var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(factory);
                try
                {
                    var itemId = ItemId;
                    var pointer = interop.CreateForMonitor(monitor, ref itemId);
                    try
                    {
                        return GraphicsCaptureItem.FromAbi(pointer);
                    }
                    finally
                    {
                        Marshal.Release(pointer);
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(interop);
                }
            }
            finally
            {
                Marshal.Release(factory);
            }
        }
        finally
        {
            _ = WindowsDeleteString(name);
        }
    }

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow(IntPtr window, ref Guid id);
        IntPtr CreateForMonitor(IntPtr monitor, ref Guid id);
    }

    [DllImport("combase.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int WindowsCreateString(string source, int length, out IntPtr text);

    [DllImport("combase.dll", ExactSpelling = true)]
    static extern int WindowsDeleteString(IntPtr text);

    [DllImport("combase.dll", ExactSpelling = true)]
    static extern int RoGetActivationFactory(IntPtr className, ref Guid id, out IntPtr factory);
}

// The Direct3D 11 device of the frame pool, as the WinRT type that
// Windows.Graphics.Capture takes. A computer without a graphics card, such
// as a virtual machine, gets the software device of Windows.
static class Direct3D
{
    const int Hardware = 1;
    const int Warp = 5;
    const uint BgraSupport = 0x20;
    const uint SdkVersion = 7;
    static readonly Guid DxgiDeviceId = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");

    public static IDirect3DDevice CreateDevice()
    {
        var hr = D3D11CreateDevice(IntPtr.Zero, Hardware, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, SdkVersion, out var d3d, out _, out var context);
        if (hr < 0)
        {
            hr = D3D11CreateDevice(IntPtr.Zero, Warp, IntPtr.Zero, BgraSupport, IntPtr.Zero, 0, SdkVersion, out d3d, out _, out context);
        }
        Marshal.ThrowExceptionForHR(hr);
        try
        {
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3d, in DxgiDeviceId, out var dxgi));
            try
            {
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
                try
                {
                    return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
                }
                finally
                {
                    Marshal.Release(inspectable);
                }
            }
            finally
            {
                Marshal.Release(dxgi);
            }
        }
        finally
        {
            Marshal.Release(context);
            Marshal.Release(d3d);
        }
    }

    [DllImport("d3d11.dll", ExactSpelling = true)]
    static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint levelCount,
                                        uint sdkVersion, out IntPtr device, out int level, out IntPtr context);

    [DllImport("d3d11.dll", ExactSpelling = true)]
    static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
