using System.Net;
using System.Collections.Concurrent;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using Flux.Protocol;

namespace Flux.Windows;

internal sealed class TransferEpoch
{
    private string reason = "";
    public CancellationTokenSource Source { get; } = new();
    public string Reason => Volatile.Read(ref reason);
    public void Stop(string why)
    {
        Interlocked.CompareExchange(ref reason, why, "");
        Source.Cancel();
    }
}

internal sealed class PeerSession(Identity remote, IPAddress address, int port,
    SslStream stream, X509Certificate2 certificate, ReadLifetime reads, IPAddress? local = null)
{
    public Identity Remote { get; } = remote;
    public IPAddress Address { get; } = address;
    public int Port { get; } = port;
    public IPAddress LocalAddress { get; } = local ?? IPAddress.Loopback;
    public SslStream Stream { get; } = stream;
    public X509Certificate2 Certificate { get; } = certificate;
    public ReadLifetime Reads { get; } = reads;
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public Pairing Pairing { get; } = new();
    public SemaphoreSlim Gate { get; } = new(1, 1);
    public SemaphoreSlim Write { get; } = new(1, 1);
    public volatile bool Paired = false;
    public volatile bool Closed = false;
    public SemaphoreSlim FileSlots { get; } = new(4, 4);
    public TransferEpoch TransferLifetime { get; private set; } = new();
    public void RevokeTransfers(string reason) { TransferLifetime.Stop(reason); TransferLifetime = new(); }
    public void StopTransfers(string reason) => TransferLifetime.Stop(reason);
    public ConcurrentDictionary<string, TaskCompletionSource<int>> Tunnels { get; } = new();
    public bool Outgoing { get; init; }
    public DateTimeOffset Started { get; } = DateTimeOffset.UtcNow;
}

internal sealed record PeerView(string DeviceId, string ConnectionId, DiscoveredPeer Peer,
    string Status, string Detail, string Key, bool CanPair, bool CanAccept);

internal sealed record FileTransferView(string Id, string DeviceId, string Device, string Name, string Direction,
    long Bytes, long Size, string Status, string Path = "", string Error = "")
{
    public bool IsActive => Status is "Sending" or "Receiving";
    public FileTransferView WithFailure(Exception ex, bool cancelledByUser, TransferEpoch epoch, bool shuttingDown)
    {
        var forgotten = epoch.Reason == "Pairing removed.";
        return this with {Status=cancelledByUser || forgotten ? "Cancelled" : "Failed",
            Error=cancelledByUser ? "Cancelled by you." : epoch.Reason.Length > 0 ? epoch.Reason :
                shuttingDown ? "App is closing." : ex is OperationCanceledException ? "Transfer timed out." : ex.Message};
    }
    public double Progress => Size > 0 ? Math.Clamp(100.0 * Bytes / Size, 0, 100) : 0;
    public string Summary => $"{Direction} · {Device} · {Status}";
    public string ByteSummary => $"{Bytes:N0} / {Size:N0} bytes";
    public override string ToString() => $"{Direction}: {Name} — {Device} — {Status} ({Bytes:N0}/{Size:N0} bytes)" +
        (Error.Length == 0 ? "" : " — " + Error);
}
