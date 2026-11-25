namespace FluxKit;

// One video capture device of this computer, as the app finds it.
// DeviceId is the ID of the system, such as the symbolic link of Media
// Foundation. BuiltIn is true for a camera in the case of the computer.
public sealed record CameraDevice(string DeviceId, string Name, bool BuiltIn);

// One camera as Flux offers it. Id is the camera in the protocol: its name
// in lower case. The computer lists it and sends it back in the "camera"
// setting. Name is the name for the UI.
public sealed record CameraInfo(string Id, string Name, CameraDevice Device);

// The cameras of this computer. The WPF app implements it with Media
// Foundation, and tests use a fake. FluxKit calls the members on threads of
// the pool, and 1 open or 1 stop at a time. The object that OpenAsync
// returns stops the camera on Dispose, and does not block.
public interface ICameraSource
{
    // The video capture devices of this computer, in the order of the system.
    IReadOnlyList<CameraDevice> Devices();

    // The app raises it on any thread after a camera came or went.
    event Action? DevicesChanged;

    // True when the privacy settings of Windows do not let Flux use the camera.
    bool AccessDenied { get; }

    // Opens the camera with the smallest format that covers shortSide pixels
    // on its short side at 30 frames per second, or else the largest format.
    // Each frame goes to frames.Frame on a thread of the camera, with the
    // clockwise rotation that makes it upright. A failure after the start,
    // such as a camera that was disconnected, goes to frames.Failed. It
    // returns when the camera runs, with the object that stops the camera.
    // It throws StreamException with a message for the user when the camera
    // does not open.
    Task<IDisposable> OpenAsync(CameraDevice device, int shortSide, IFrameSink frames);
}

// The names of the cameras in the protocol.
public static class CameraNames
{
    // The cameras that Flux offers, built-in cameras first. 2 cameras with
    // the same name get a number, such as "USB Camera 2". CameraSource.swift
    // of the Mac app names them in the same way.
    public static IReadOnlyList<CameraInfo> Name(IReadOnlyList<CameraDevice> devices)
    {
        var seen = new Dictionary<string, int>();
        var named = new List<CameraInfo>();
        foreach (var d in devices.Select((d, i) => (d, i)).OrderBy(x => x.d.BuiltIn ? 0 : 1).ThenBy(x => x.i).Select(x => x.d))
        {
            var name = d.Name.Trim();
            var key = name.ToLowerInvariant();
            var n = seen.GetValueOrDefault(key) + 1;
            seen[key] = n;
            var label = n == 1 ? name : $"{name} {n}";
            named.Add(new CameraInfo(label.ToLowerInvariant(), label, d));
        }
        return named;
    }
}

// Brings the camera to the state that the streams want. Callers set the
// wanted camera, and 1 call at a time brings the camera to the last wanted
// state, so that calls from different streams cannot leave the camera on.
// Each open has an owner, the number of the stream attempt, and only the
// owner of the last open closes the camera. CameraSource.swift of the Mac
// app has the same rules.
internal sealed class CameraControl(ICameraSource source, IFrameSink frames)
{
    sealed record Want(CameraInfo Camera, int ShortSide, int Owner);

    // Runs the open and close calls of the app in order.
    readonly SemaphoreSlim control = new(1, 1);
    readonly Lock gate = new();
    Want? desired;

    // Owned by control.
    IDisposable? session;
    CameraInfo? open;
    int openShortSide;

    // Opens camera for owner, or switches to it. It returns when the camera
    // runs, or when a later call replaced this one.
    public async Task OpenAsync(CameraInfo camera, int shortSide, int owner)
    {
        lock (gate)
        {
            desired = new Want(camera, shortSide, owner);
        }
        await ReconcileAsync().ConfigureAwait(false);
    }

    // Switches the open camera to camera. It does nothing when no camera is open.
    public async Task SwitchAsync(CameraInfo camera, int shortSide)
    {
        lock (gate)
        {
            if (desired is not { } d)
            {
                return;
            }
            desired = d with { Camera = camera, ShortSide = shortSide };
        }
        await ReconcileAsync().ConfigureAwait(false);
    }

    // Stops the camera when owner opened it last. It does not wait.
    public void Close(int owner)
    {
        lock (gate)
        {
            if (desired?.Owner != owner)
            {
                return;
            }
            desired = null;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await ReconcileAsync().ConfigureAwait(false);
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                FluxLog.Info("stream", $"the camera did not stop: {e.Message}");
            }
        });
    }

    public bool IsOpen
    {
        get
        {
            lock (gate)
            {
                return desired is not null;
            }
        }
    }

    async Task ReconcileAsync()
    {
        await control.WaitAsync().ConfigureAwait(false);
        try
        {
            Want? want;
            lock (gate)
            {
                want = desired;
            }
            if (want is null)
            {
                CloseNow();
                return;
            }
            try
            {
                await OpenNowAsync(want).ConfigureAwait(false);
            }
            catch (Exception e) when (StreamErrors.Expected(e))
            {
                CloseNow();
                throw;
            }
        }
        finally
        {
            control.Release();
        }
    }

    async Task OpenNowAsync(Want want)
    {
        if (session is not null && open?.Device.DeviceId == want.Camera.Device.DeviceId && openShortSide == want.ShortSide)
        {
            return;
        }
        CloseNow();
        session = await source.OpenAsync(want.Camera.Device, want.ShortSide, frames).ConfigureAwait(false);
        open = want.Camera;
        openShortSide = want.ShortSide;
        FluxLog.Info("stream", $"camera {want.Camera.Name} runs for a short side of {want.ShortSide} pixels");
    }

    void CloseNow()
    {
        if (session is not { } s)
        {
            return;
        }
        session = null;
        open = null;
        try
        {
            s.Dispose();
        }
        catch (Exception e) when (StreamErrors.Expected(e))
        {
            FluxLog.Info("stream", $"the camera did not stop cleanly: {e.Message}");
        }
        FluxLog.Info("stream", "camera stopped");
    }
}
