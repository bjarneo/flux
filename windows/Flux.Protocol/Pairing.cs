using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Flux.Protocol;

// Bind approval to the exact connection/certificate whose key was displayed.
public sealed class Pairing
{
    private byte[]? certificate;
    private string? connection;
    private DateTimeOffset expires;
    public string Key { get; private set; } = "";
    public bool IsOutgoing { get; private set; }
    public bool RemoteAccepted { get; private set; }
    public void Begin(X509Certificate2 own, X509Certificate2 peer, string connectionId,
        long timestamp, DateTimeOffset now, bool outgoing = false)
    {
        if (timestamp < now.ToUnixTimeSeconds() - 1800 || timestamp > now.ToUnixTimeSeconds() + 1800)
            throw new InvalidDataException("Pairing clock differs by more than 30 minutes.");
        certificate = peer.RawData; connection = connectionId;
        expires = now.AddSeconds(30); Key = PairKey.Compute(own, peer, timestamp);
        IsOutgoing = outgoing; RemoteAccepted = false;
    }
    private bool Matches(string key, X509Certificate2 peer, string connectionId, DateTimeOffset now) =>
        certificate is not null && connection == connectionId && now < expires && key == Key &&
        CryptographicOperations.FixedTimeEquals(certificate, peer.RawData);
    public bool CanAccept(string key, X509Certificate2 peer, string connectionId, DateTimeOffset now) =>
        (!IsOutgoing || RemoteAccepted) && Matches(key, peer, connectionId, now);
    public bool Acknowledge(X509Certificate2 peer, string connectionId, DateTimeOffset now)
    {
        if (!IsOutgoing || !Matches(Key, peer, connectionId, now)) return false;
        RemoteAccepted = true; return true;
    }
    public void Reset() { certificate = null; connection = null; Key = ""; IsOutgoing = RemoteAccepted = false; }
}
