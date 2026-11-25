using System.Threading.Channels;

namespace FluxKit;

// The encoded stream on its way to the computer. The encoder pushes bytes
// from its own thread, and 1 task writes them to the TLS stream in order.
// When the network falls behind by about a second of video, Backlogged turns
// true, and the capture skips frames until the network catches up, as a
// camera drops frames when its encoder is busy. VideoSink.swift of the Mac
// app has the same rules.
internal sealed class VideoSink
{
    readonly TlsStream stream;
    readonly Channel<byte[]> chunks = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource closed = new();
    readonly long limit;
    long pending;
    int ended;

    public VideoSink(TlsStream stream, int bitrate)
    {
        this.stream = stream;
        limit = Math.Max(bitrate / 8, 256 * 1024);
    }

    // The most bytes that wait for the network before Backlogged turns true.
    public long Limit => limit;

    public void Push(byte[] bytes)
    {
        Interlocked.Add(ref pending, bytes.Length);
        if (!chunks.Writer.TryWrite(bytes))
        {
            Interlocked.Add(ref pending, -bytes.Length);
        }
    }

    public bool Backlogged => Interlocked.Read(ref pending) > limit;

    // Writes the pushed bytes until Close. It throws IOException when the
    // connection fails, for example because the computer closed it. After
    // Close, it returns.
    public async Task RunAsync()
    {
        var token = closed.Token;
        try
        {
            // The computer sends nothing. Its side ends when it closes the
            // connection, also while no frame goes out.
            var read = DrainAsync(token);
            var write = WriteAsync(token);
            var first = await Task.WhenAny(read, write).ConfigureAwait(false);
            Observe(first == read ? write : read);
            await first.ConfigureAwait(false);
            if (!token.IsCancellationRequested)
            {
                throw new IOException("the computer closed the stream");
            }
        }
        catch (Exception e) when (StreamErrors.Expected(e) && token.IsCancellationRequested)
        {
        }
        finally
        {
            Close();
        }
    }

    async Task WriteAsync(CancellationToken token)
    {
        await foreach (var bytes in chunks.Reader.ReadAllAsync(token).ConfigureAwait(false))
        {
            await stream.Stream.WriteAsync(bytes, token).ConfigureAwait(false);
            Interlocked.Add(ref pending, -bytes.Length);
        }
    }

    async Task DrainAsync(CancellationToken token)
    {
        var buffer = new byte[1024];
        while (await stream.Stream.ReadAsync(buffer, token).ConfigureAwait(false) > 0)
        {
        }
    }

    // Closes the connection at once, also in the middle of a write, and ends
    // RunAsync.
    public void Close()
    {
        if (Interlocked.Exchange(ref ended, 1) == 1)
        {
            return;
        }
        chunks.Writer.TryComplete();
        closed.Cancel();
        _ = stream.DisposeAsync().AsTask();
    }

    // Reads the failure of a task that nobody waits for, so that it does not
    // show as an unobserved exception.
    internal static void Observe(Task task) =>
        _ = task.ContinueWith(t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
}
