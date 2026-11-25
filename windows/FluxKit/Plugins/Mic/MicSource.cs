using System.Diagnostics;

namespace FluxKit;

// One audio input of this computer: a capture endpoint of WASAPI.
public sealed record MicInput(string Id, string Name);

// The microphone permission of Flux in the privacy settings of Windows.
public enum MicPermission
{
    Granted,

    // Windows did not ask the user yet.
    Undetermined,

    Denied,
}

// The microphones of this computer. The WPF app implements it with WASAPI,
// and tests use a fake. FluxKit calls the members on the UI thread and on
// threads of the pool. MicCapture.swift of the Mac app does the same work
// with AVFoundation.
public interface IMicSource
{
    // The audio inputs of this computer, including external and virtual
    // devices.
    IReadOnlyList<MicInput> Inputs();

    // The app raises it on any thread after an input came or went, or after
    // the default input changed.
    event Action? InputsChanged;

    // The microphone permission of Flux now.
    MicPermission Permission { get; }

    // Asks for the permission when Windows did not ask yet. It returns true
    // when Flux can record.
    Task<bool> AuthorizeAsync();

    // Starts to record from the input with the ID. An empty ID, or an input
    // that is gone, records from the default input. The capture writes each
    // buffer to feed.Write in the format of the device, and a failure after
    // the start to feed.Fail. It returns when the capture runs. It throws
    // StreamException with a message for the user when it cannot record, or
    // OperationCanceledException after ct ends.
    Task<IMicCapture> StartAsync(string inputId, MicFeed feed, CancellationToken ct);
}

// A running capture. Dispose stops it and does not block. FluxKit can call
// Dispose on any thread, also while the capture writes to the feed.
public interface IMicCapture : IDisposable
{
    // Records from the input with the ID from now on, while the stream keeps
    // running. An empty ID, or an input that is gone, records from the
    // default input. A failure goes to MicFeed.Fail.
    void Use(string inputId);
}

// Where a capture writes its audio. FluxKit makes 1 feed per stream. The
// capture calls it on its own thread, 1 call at a time.
public sealed class MicFeed
{
    readonly Action<short[]> onSamples;
    readonly Action<string> onError;
    MicConverter? converter;
    bool failed;

    internal MicFeed(Action<short[]> onSamples, Action<string> onError)
    {
        this.onSamples = onSamples;
        this.onError = onError;
    }

    // Takes 1 buffer of interleaved audio in the format of the device.
    // FluxKit mixes the channels into 1 and converts the rate to 48 kHz. A
    // format that FluxKit cannot convert ends the stream with an error.
    public void Write(ReadOnlySpan<byte> data, AudioFormat format)
    {
        if (failed)
        {
            return;
        }
        short[] samples;
        try
        {
            samples = MicConvert.S16Mono48k(data, format, ref converter);
        }
        catch (StreamException e)
        {
            Fail($"The microphone gave audio that Flux cannot send. {e.Message}");
            return;
        }
        if (samples.Length > 0)
        {
            onSamples(samples);
        }
    }

    // Ends the stream with a message for the user, after the capture failed.
    public void Fail(string message)
    {
        failed = true;
        onError(message);
    }
}

// The audio chunks that wait for the network. A chunk holds about 10 to 35
// ms of audio, so at most MaxChunks is 1 to 3.5 seconds. MaxBytes keeps the
// wait at 3.5 seconds or less for a capture with larger buffers. The oldest
// chunks drop when the connection is slower than the microphone, so that
// the delay does not grow. MicPlugin.swift of the Mac app keeps the same
// number of chunks.
internal sealed class MicQueue
{
    public const int MaxChunks = 100;
    public const int MaxBytes = MicPackets.Rate * 2 * 7 / 2;

    readonly Lock gate = new();
    readonly Queue<byte[]> chunks = new();
    int bytes;
    bool done;
    TaskCompletionSource? waiter;

    // The number of chunks that dropped.
    public int Dropped { get; private set; }

    // Adds a chunk. It returns true when older chunks dropped.
    public bool Push(byte[] chunk)
    {
        TaskCompletionSource? wake;
        var dropped = false;
        lock (gate)
        {
            if (done)
            {
                return false;
            }
            chunks.Enqueue(chunk);
            bytes += chunk.Length;
            while (chunks.Count > MaxChunks || (bytes > MaxBytes && chunks.Count > 1))
            {
                bytes -= chunks.Dequeue().Length;
                Dropped++;
                dropped = true;
            }
            wake = waiter;
            waiter = null;
        }
        wake?.TrySetResult();
        return dropped;
    }

    // Returns the oldest chunk, and waits for one when none waits. It returns
    // null after Complete, when no chunk waits. 1 reader at a time.
    public async Task<byte[]?> TakeAsync(CancellationToken ct)
    {
        while (true)
        {
            Task wait;
            lock (gate)
            {
                if (chunks.TryDequeue(out var chunk))
                {
                    bytes -= chunk.Length;
                    return chunk;
                }
                if (done)
                {
                    return null;
                }
                waiter ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                wait = waiter.Task;
            }
            await wait.WaitAsync(ct).ConfigureAwait(false);
        }
    }

    // Ends the queue. The chunks that wait are dropped.
    public void Complete()
    {
        TaskCompletionSource? wake;
        lock (gate)
        {
            done = true;
            chunks.Clear();
            bytes = 0;
            wake = waiter;
            waiter = null;
        }
        wake?.TrySetResult();
    }

    // The chunks that wait now.
    public int Count
    {
        get
        {
            lock (gate)
            {
                return chunks.Count;
            }
        }
    }
}

// Lets through at most 1 level report per interval: about 15 per second.
internal sealed class LevelThrottle
{
    static readonly long Interval = Stopwatch.Frequency * 66 / 1000;
    long last;
    bool any;

    public bool Due()
    {
        var now = Stopwatch.GetTimestamp();
        if (any && now - last < Interval)
        {
            return false;
        }
        any = true;
        last = now;
        return true;
    }
}
