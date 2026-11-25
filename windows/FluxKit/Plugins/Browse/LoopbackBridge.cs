using System.Net;
using System.Net.Sockets;

namespace FluxKit;

// Bridges a TLS stream to a new listener on 127.0.0.1, so that a library
// that opens its own TCP connection can use the stream. The bridge accepts
// 1 connection and closes when either side closes. LoopbackBridge.swift of
// the Mac app has the same rules.
internal sealed class LoopbackBridge
{
    // How long the bridge waits for the local connection.
    static readonly TimeSpan AcceptTimeout = TimeSpan.FromSeconds(10);

    readonly TcpListener listener;
    readonly TlsStream remote;
    readonly CancellationTokenSource cts = new();
    int closed;

    LoopbackBridge(TcpListener listener, TlsStream remote)
    {
        this.listener = listener;
        this.remote = remote;
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    public string Host => "127.0.0.1";
    public int Port { get; }

    // Ends when the bridge closes.
    public Task Completion { get; private set; } = Task.CompletedTask;

    // Opens the listener and starts to wait for the 1 local connection. A
    // failure closes the tunnel.
    public static LoopbackBridge Open(TlsStream remote, TimeSpan? acceptTimeout = null)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        try
        {
            listener.Start(1);
        }
        catch (SocketException)
        {
            listener.Stop();
            _ = remote.DisposeAsync().AsTask();
            throw;
        }
        var bridge = new LoopbackBridge(listener, remote);
        var wait = acceptTimeout ?? AcceptTimeout;
        bridge.Completion = Task.Run(() => bridge.RunAsync(wait));
        return bridge;
    }

    async Task RunAsync(TimeSpan acceptTimeout)
    {
        try
        {
            Socket local;
            using (var wait = CancellationTokenSource.CreateLinkedTokenSource(cts.Token))
            {
                wait.CancelAfter(acceptTimeout);
                local = await listener.AcceptSocketAsync(wait.Token).ConfigureAwait(false);
            }
            // Only the first connection counts.
            listener.Stop();
            local.NoDelay = true;
            var near = new NetworkStream(local, ownsSocket: true);
            await using var nearScope = near.ConfigureAwait(false);
            var up = PumpAsync(remote.Stream, near, cts.Token);
            var down = PumpAsync(near, remote.Stream, cts.Token);
            await Task.WhenAny(up, down).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException or InvalidOperationException)
        {
        }
        finally
        {
            Close();
        }
    }

    // Copies bytes until the source ends or fails.
    static async Task PumpAsync(Stream from, Stream to, CancellationToken ct)
    {
        var buffer = new byte[32 * 1024];
        try
        {
            int n;
            while ((n = await from.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await to.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
            }
        }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException or NotSupportedException)
        {
        }
    }

    // Closes the listener and the tunnel. The local connection ends with
    // them.
    public void Close()
    {
        if (Interlocked.Exchange(ref closed, 1) == 1)
        {
            return;
        }
        cts.Cancel();
        listener.Stop();
        _ = remote.DisposeAsync().AsTask();
    }
}
