namespace FluxKit;

// Serves the IStreamStarter of StreamRequestPlugin with the webcam and the
// microphone of this computer. The app makes 1 after the core, and its
// IStreamStarter calls it: Streams from Streams, and Begin from Start after
// the app opened the page of the stream. A start waits up to
// PendingStart.Wait for the link to the computer, because a click on the
// notification opens Flux, and the link can come back a moment later.
// StreamRequestFeature of the Mac app has the same rules.
public sealed class StreamStarts
{
    readonly FluxCore core;
    readonly Action<string> show;
    PendingStart? pending;
    CancellationTokenSource? timer;

    // show gets the message when a stream did not start. The default is a
    // toast of the core.
    public StreamStarts(FluxCore core, Action<string>? show = null)
    {
        this.core = core;
        this.show = show ?? core.Toast;
        // The core reports each change on the UI thread, also a link that
        // comes back.
        core.Changed += _ => Check();
    }

    // True when the app gave the platform parts of both streams. The app
    // gives StreamRequestPlugin its starter only then, so that this
    // computer lists flux.stream.request only then.
    public static bool StreamsBoth(WebcamPlugin webcam, MicPlugin mic) => webcam.Supported && mic.Supported;

    // True while a stream of the kind runs or starts to the computer.
    public bool Streams(StreamRequestKind kind, string computerId) => kind switch
    {
        StreamRequestKind.Webcam => core.Plugin<WebcamPlugin>()?.CurrentStatus.ActiveFor(computerId) == true,
        _ => core.Plugin<MicPlugin>()?.CurrentStatus.ActiveFor(computerId) == true,
    };

    // Starts the stream of a request after the click on start, when the
    // computer is connected. Call it on the UI thread.
    public void Begin(StreamRequest request) => Begin(request, StreamRequest.Now);

    // now is the time of the click. A test gives an earlier time.
    internal void Begin(StreamRequest request, TimeSpan now)
    {
        var p = PendingStart.Of(request, now);
        pending = p;
        timer?.Cancel();
        var t = new CancellationTokenSource();
        timer = t;
        var wait = p.Deadline - StreamRequest.Now;
        _ = Task.Delay(wait > TimeSpan.Zero ? wait : TimeSpan.Zero, t.Token).ContinueWith(x =>
        {
            if (!x.IsCanceled)
            {
                core.Host.Post(Check);
            }
        }, TaskScheduler.Default);
        Check();
    }

    // Starts the waiting stream when the computer is connected. An unpair
    // ends the start at once. Call it on the UI thread.
    public void Check() => Check(StreamRequest.Now);

    internal void Check(TimeSpan now)
    {
        if (pending is not { } p)
        {
            return;
        }
        var device = core.State.Devices.FirstOrDefault(d => d.Id == p.ComputerId && d.Paired);
        // The camera and the microphone of this computer also work while
        // Flux is not the active app.
        var step = p.Step(active: true, online: device?.Online == true, now);
        if (step == PendingStep.Wait && device is not null)
        {
            return;
        }
        pending = null;
        timer?.Cancel();
        timer = null;
        if (device is null)
        {
            return;
        }
        if (step != PendingStep.Start)
        {
            show(p.FailedText);
            return;
        }
        // A stream that the user started in the meantime keeps running.
        if (Streams(p.Kind, p.ComputerId))
        {
            return;
        }
        if (p.Kind == StreamRequestKind.Webcam)
        {
            core.Plugin<WebcamPlugin>()?.Start(p.ComputerId);
        }
        else
        {
            core.Plugin<MicPlugin>()?.Start(p.ComputerId);
        }
    }

    // True while a start waits for the link.
    internal bool Waiting => pending is not null;
}
