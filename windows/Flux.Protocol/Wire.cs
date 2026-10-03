using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Flux.Protocol;

public sealed record Packet(
    [property: JsonPropertyName("id")] JsonElement Id,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("body")] JsonElement Body)
{
    [JsonPropertyName("payloadSize"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public long? PayloadSize { get; init; }
    [JsonPropertyName("payloadTransferInfo"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public PayloadInfo? PayloadTransferInfo { get; init; }
    public static Packet Create(string type, object body) => new(
        JsonSerializer.SerializeToElement(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),
        type, JsonSerializer.SerializeToElement(body));
    public byte[] Encode() => Encoding.UTF8.GetBytes(JsonSerializer.Serialize(this) + "\n");
    public static Packet Decode(ReadOnlySpan<byte> data)
    {
        var p = JsonSerializer.Deserialize<Packet>(data) ?? throw new InvalidDataException("Empty packet.");
        if (string.IsNullOrEmpty(p.Type) || p.Type.Length > 128 || p.Body.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Invalid packet.");
        return p;
    }
}

public sealed record Identity(string DeviceId, string Name, int Version)
{
    public bool CanTunnel { get; init; }
    public static bool ValidId(string id) => Regex.IsMatch(id, "\\A[A-Za-z0-9_-]{32,38}\\z");
    public static Identity Parse(Packet p)
    {
        if (p.Type != "flux.identity") throw new InvalidDataException("Expected identity.");
        var id = p.Body.GetProperty("deviceId").GetString() ?? "";
        if (!p.Body.TryGetProperty("protocolVersion", out var protocolVersion) ||
            protocolVersion.ValueKind != JsonValueKind.Number || !protocolVersion.TryGetInt32(out var version) || version != 8)
            throw new InvalidDataException("Unsupported protocol version.");
        if (!ValidId(id)) throw new InvalidDataException("Unsupported identity.");
        var name = p.Body.GetProperty("deviceName").GetString() ?? "Computer";
        name = string.Concat(name.Where(c => !char.IsControl(c) && c is not (>= '\u202a' and <= '\u202e') && c is not (>= '\u2066' and <= '\u2069')));
        var canTunnel = p.Body.TryGetProperty("outgoingCapabilities", out var capabilities) && capabilities.ValueKind == JsonValueKind.Array &&
            capabilities.EnumerateArray().Any(c => c.ValueKind == JsonValueKind.String && c.GetString() == "flux.tunnel");
        return new(id, name[..Math.Min(name.Length, 32)], version) { CanTunnel = canTunnel };
    }
    public Packet Packet(int tcpPort = 0, Identity? target = null)
    {
        var body = new Dictionary<string, object> {
            ["deviceId"] = DeviceId, ["deviceName"] = Name, ["deviceType"] = "laptop", ["protocolVersion"] = Version,
            ["app"] = "windows", ["appVersion"] = "0.1.0-prototype",
            ["incomingCapabilities"] = new[] { "flux.ping", "flux.share.request", "flux.tunnel", "flux.theme" },
            ["outgoingCapabilities"] = new[] { "flux.ping", "flux.share.request", "flux.tunnel" }
        };
        if (tcpPort > 0) body["tcpPort"] = tcpPort;
        if (target is not null) { body["targetDeviceId"] = target.DeviceId; body["targetProtocolVersion"] = target.Version; }
        return global::Flux.Protocol.Packet.Create("flux.identity", body);
    }
    public void VerifySecure(Identity secure, X509Certificate2 cert)
    {
        if (DeviceId != secure.DeviceId || Version != secure.Version ||
            cert.GetNameInfo(X509NameType.SimpleName, false) != DeviceId)
            throw new InvalidDataException("The identity and certificate do not match.");
    }
}

public sealed record PayloadInfo(
    [property: JsonPropertyName("port"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Port = null,
    [property: JsonPropertyName("tunnel"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Tunnel = null);

public static class PairKey
{
    public static string Compute(X509Certificate2 own, X509Certificate2 peer, long timestamp) =>
        Compute(own.PublicKey.ExportSubjectPublicKeyInfo(), peer.PublicKey.ExportSubjectPublicKeyInfo(), timestamp);
    public static string Compute(byte[] a, byte[] b, long timestamp)
    {
        if (a.AsSpan().SequenceCompareTo(b) < 0) (a, b) = (b, a);
        using var h = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        h.AppendData(a); h.AppendData(b);
        if (timestamp > 0) h.AppendData(Encoding.ASCII.GetBytes(timestamp.ToString(CultureInfo.InvariantCulture)));
        return Convert.ToHexString(h.GetHashAndReset().AsSpan(0, 8));
    }
    public static string Format(string key) => string.Join(" ", Enumerable.Range(0, key.Length / 4).Select(i => key.Substring(i * 4, 4)));
}

public static class Lines
{
    // Do not read ahead: the plaintext identity is followed by the TLS handshake.
    public static async Task<byte[]> ReadAsync(Stream stream, int limit, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        var one = new byte[1];
        while (await stream.ReadAsync(one, ct) != 0)
        {
            if (one[0] == 10) return buffer.ToArray();
            if (buffer.Length >= limit) throw new InvalidDataException("Packet exceeds its limit.");
            buffer.WriteByte(one[0]);
        }
        throw new EndOfStreamException();
    }
}

public sealed record DesktopFrame(byte Flags, byte[] Data)
{
    public const int MaxBytes = 16 << 20;
    public static async Task<DesktopFrame> ReadAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[5];
        await stream.ReadExactlyAsync(header, ct);
        var size = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (size > MaxBytes) throw new InvalidDataException("Desktop frame exceeds its limit.");
        if ((header[4] & ~7) != 0 || (header[4] & 4) != 0 && size != 4)
            throw new InvalidDataException("Invalid desktop frame.");
        var data = new byte[(int)size];
        await stream.ReadExactlyAsync(data, ct);
        return new(header[4], data);
    }
}
