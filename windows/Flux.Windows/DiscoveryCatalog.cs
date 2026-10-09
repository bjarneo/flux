using System.Net;
using System.Net.Sockets;
using Flux.Protocol;
using Makaretu.Dns;

namespace Flux.Windows;

internal sealed record DiscoveredPeer(Identity Identity, IPAddress Address, int Port)
{
    public override string ToString() => $"{Identity.Name} — {Address}:{Port}";
}

internal sealed record PeerConnection(string? DeviceId, IPAddress? Address, bool Paired, bool Connected = true);
internal sealed record SavedPeer(string DeviceId, string Name, string Address, int Port)
{
    public DiscoveredPeer ToPeer() => new(new(DeviceId, string.IsNullOrWhiteSpace(Name) ? DeviceId[..8] : Name, 8),
        IPAddress.TryParse(Address, out var address) && DiscoveryCatalog.IsLocalAddress(address)
            ? address : IPAddress.None, Port is >= 12100 and <= 12108 ? Port : 12100);
}
internal sealed record PeerRow(DiscoveredPeer Peer, string Status)
{
    public string Name => Peer.Identity.Name;
    public string ShortId => Peer.Identity.DeviceId[..8];
    public bool HasAddress => !Peer.Address.Equals(IPAddress.None);
    public string Endpoint => HasAddress ? $"{Peer.Address}:{Peer.Port}" : "No saved address";
    public bool IsConnected => Status is "Paired — connected" or "Connected — pairing needed";
    public bool IsPairedConnected => Status == "Paired — connected";
    public string ConnectionLabel => Status switch {
        "Paired — connected" => "connected",
        "Connected — pairing needed" => "not paired",
        "Pairing saved — not connected" => "offline",
        _ => "discovered"
    };
    public override string ToString() => $"{Peer.Identity.Name} — {Peer.Address}:{Peer.Port} ({Status})";
    public static PeerRow? RestoreSelection(IReadOnlyList<PeerRow> rows, DiscoveredPeer? selected)
    {
        if (selected is not null) {
            var sameDevice = rows.Where(r => r.Peer.Identity.DeviceId == selected.Identity.DeviceId);
            var exact = sameDevice.FirstOrDefault(r => r.Peer.Address.Equals(selected.Address) && r.Peer.Port == selected.Port);
            if (exact is not null) return exact;
            var alternative = sameDevice.FirstOrDefault();
            if (alternative is not null) return alternative;
        }
        return rows.FirstOrDefault();
    }
    public static PeerRow Create(DiscoveredPeer peer, PeerConnection connection, IReadOnlySet<string> saved)
    {
        var connected = connection.Connected && connection.DeviceId == peer.Identity.DeviceId && connection.Address?.Equals(peer.Address) == true;
        return new(peer, connected
            ? connection.Paired ? "Paired — connected" : "Connected — pairing needed"
            : saved.Contains(peer.Identity.DeviceId) ? "Pairing saved — not connected" : "Discovered — not connected");
    }
}

// Discovery is an untrusted hint. The TLS identity and pinned certificate must
// still match before pairing. Merge fragmented PTR/SRV/TXT/A answers by name.
internal sealed class DiscoveryCatalog
{
    private readonly Dictionary<string, (ResourceRecord Record, DateTimeOffset Expires)> records = new();
    private const string Suffix = "._flux._udp.local";
    internal static bool IsLocalAddress(IPAddress address) => address.AddressFamily == AddressFamily.InterNetwork &&
        !IPAddress.IsLoopback(address) && address.GetAddressBytes()[0] is > 0 and < 224 &&
        !address.Equals(IPAddress.Any);
    internal static bool IsLanAdvertisementAddress(IPAddress address)
    {
        if (!IsLocalAddress(address)) return false;
        var bytes = address.GetAddressBytes();
        // Tailscale's 100.64/10 addresses are reached through the overlay, not
        // the LAN interface on which this mDNS service is being announced.
        return !(bytes[0] == 100 && bytes[1] is >= 64 and <= 127);
    }
    private static string Name(DomainName name) => name.ToString().TrimEnd('.').ToLowerInvariant();
    public void Add(IEnumerable<ResourceRecord> incoming, DateTimeOffset now)
    {
        foreach (var record in incoming.Take(256)) {
            if (record is not (PTRRecord or SRVRecord or TXTRecord or ARecord)) continue;
            var key = $"{record.Type}:{Name(record.Name)}";
            if (record is ARecord a) key += ":" + a.Address;
            if (record is PTRRecord ptr) key += ":" + Name(ptr.DomainName);
            if (record.TTL <= TimeSpan.Zero) { records.Remove(key); continue; }
            if (records.Count >= 512 && !records.ContainsKey(key)) continue;
            records[key] = (record, now.Add(record.TTL > TimeSpan.FromMinutes(5) ? TimeSpan.FromMinutes(5) : record.TTL));
        }
        foreach (var key in records.Where(e => e.Value.Expires <= now).Select(e => e.Key).ToArray()) records.Remove(key);
    }
    public IReadOnlyList<DiscoveredPeer> Peers(string self, DateTimeOffset now)
    {
        var live = records.Values.Where(v => v.Expires > now).Select(v => v.Record).ToArray();
        var peers = new List<DiscoveredPeer>();
        foreach (var srv in live.OfType<SRVRecord>().Where(r => Name(r.Name).EndsWith(Suffix, StringComparison.Ordinal))) {
            if (srv.Port is < 12100 or > 12108) continue;
            var txt = live.OfType<TXTRecord>().FirstOrDefault(r => r.Name == srv.Name);
            if (txt is null) continue;
            var properties = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var value in txt.Strings) {
                var separator = value.IndexOf('=');
                if (separator > 0) properties[value[..separator]] = value[(separator + 1)..];
            }
            if (!properties.TryGetValue("id", out var id) || !Identity.ValidId(id) || id == self ||
                Name(srv.Name) != id.ToLowerInvariant() + Suffix ||
                !properties.TryGetValue("protocol", out var version) || version != "8") continue;
            var clean = Identity.Parse(Packet.Create("flux.identity", new {
                deviceId = id, deviceName = properties.GetValueOrDefault("name", "Flux device"), protocolVersion = 8
            }));
            foreach (var a in live.OfType<ARecord>().Where(r => r.Name == srv.Target && IsLocalAddress(r.Address)))
                peers.Add(new(clean, a.Address, srv.Port));
        }
        return peers.Distinct().ToArray();
    }
    public IEnumerable<(DomainName Name, DnsType Type)> Missing(DateTimeOffset now)
    {
        var live = records.Values.Where(v => v.Expires > now).Select(v => v.Record).ToArray();
        var instances = live.OfType<PTRRecord>().Where(r => Name(r.Name) == "_flux._udp.local").Select(r => r.DomainName)
            .Concat(live.OfType<SRVRecord>().Where(r => Name(r.Name).EndsWith(Suffix, StringComparison.Ordinal)).Select(r => r.Name)).Distinct();
        foreach (var instance in instances) {
            var srv = live.OfType<SRVRecord>().FirstOrDefault(r => r.Name == instance);
            if (srv is null) yield return (instance, DnsType.SRV);
            else if (!live.OfType<ARecord>().Any(r => r.Name == srv.Target)) yield return (srv.Target, DnsType.A);
            if (!live.OfType<TXTRecord>().Any(r => r.Name == instance)) yield return (instance, DnsType.TXT);
        }
    }
}
