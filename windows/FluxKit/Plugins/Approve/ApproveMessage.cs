using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace FluxKit;

// What a computer asks: approve a login, or make the key for approvals.
public enum ApproveKind
{
    Approve,
    Enroll,
}

// A request from a computer: approve a login with Windows Hello, or make the
// key for approvals. docs/approve.md is the security design.
public sealed record ApproveRequest(
    string ComputerId,
    string ComputerName,
    string Id,
    ApproveKind Kind,
    string Host,
    string User,
    string Service,
    string Tty,
    string Rhost,
    // The Unix time in seconds when the computer made the request.
    long Time,
    // 32 random bytes as 64 lowercase hex digits.
    string Nonce,
    int TimeoutSeconds);

// The signed messages and the packets of approvals. The tests check that it
// builds the same bytes as the Go helper, Flux for Android, and the Mac app.
// ApproveMessage.swift of the Mac app has the same rules.
public static class ApproveMessage
{
    internal const int MaxField = 256;

    // The longest request ID in UTF-16 code units.
    internal const int MaxId = 64;

    // The longest error text in text elements that goes to the computer.
    internal const int MaxError = 200;

    // How far the time of a request can be from the clock of this computer.
    public const long MaxSkewSeconds = 600;

    // The wait for this computer when the packet has no timeout, and its
    // limits. fluxd uses the same values.
    internal const int DefaultTimeout = 20;
    internal const int MinTimeout = 5;
    internal const int MaxTimeout = 120;

    // At most 256 bytes of UTF-8, and no control character. A .NET string can
    // hold a lone surrogate, which is not valid UTF-8, so such a string fails
    // too. The Go helper refuses invalid UTF-8 in the same way.
    public static bool ValidField(string v)
    {
        var bytes = 0;
        var rest = v.AsSpan();
        while (!rest.IsEmpty)
        {
            if (Rune.DecodeFromUtf16(rest, out var r, out var used) != System.Buffers.OperationStatus.Done)
            {
                return false;
            }
            if (r.Value < 0x20 || r.Value == 0x7F || r.Value is >= 0x80 and <= 0x9F)
            {
                return false;
            }
            bytes += r.Utf8SequenceLength;
            if (bytes > MaxField)
            {
                return false;
            }
            rest = rest[used..];
        }
        return true;
    }

    // Exactly 64 lowercase hex digits.
    public static bool ValidNonce(string n) => n.Length == 64 && n.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    // The exact bytes that this computer signs to approve the request.
    public static byte[] Approval(ApproveRequest r)
    {
        var s = new StringBuilder();
        s.Append("flux-approve-v1\n");
        s.Append("host=").Append(r.Host).Append('\n');
        s.Append("user=").Append(r.User).Append('\n');
        s.Append("service=").Append(r.Service).Append('\n');
        s.Append("tty=").Append(r.Tty).Append('\n');
        s.Append("rhost=").Append(r.Rhost).Append('\n');
        s.Append("time=").Append(r.Time.ToString(CultureInfo.InvariantCulture)).Append('\n');
        s.Append("nonce=").Append(r.Nonce).Append('\n');
        return Encoding.UTF8.GetBytes(s.ToString());
    }

    // The exact bytes that the new key signs to prove that this computer
    // holds it. spki is the public key in DER.
    public static byte[] Enrollment(ApproveRequest r, byte[] spki)
    {
        var s = new StringBuilder();
        s.Append("flux-approve-enroll-v1\n");
        s.Append("host=").Append(r.Host).Append('\n');
        s.Append("user=").Append(r.User).Append('\n');
        s.Append("key=").Append(Convert.ToHexStringLower(SHA256.HashData(spki))).Append('\n');
        s.Append("time=").Append(r.Time.ToString(CultureInfo.InvariantCulture)).Append('\n');
        s.Append("nonce=").Append(r.Nonce).Append('\n');
        return Encoding.UTF8.GetBytes(s.ToString());
    }

    // The key code that this computer and the terminal show: the first 8
    // bytes of the SHA-256 of the key in DER, as 4 groups of 4 hex digits.
    public static string Fingerprint(byte[] spki)
    {
        var h = Convert.ToHexString(SHA256.HashData(spki), 0, 8);
        return string.Join(' ', h.Chunk(4).Select(c => new string(c)));
    }

    // Reads a request or an enrollment. It returns null for a packet that
    // breaks a rule.
    public static ApproveRequest? Parse(Packet p, string computerId, string computerName)
    {
        ApproveKind kind;
        switch (p.String("kind"))
        {
            case "request":
                kind = ApproveKind.Approve;
                break;
            case "enroll":
                kind = ApproveKind.Enroll;
                break;
            default:
                return null;
        }
        if (p.String("id") is not { Length: > 0 and <= MaxId } id || !ValidField(id) ||
            p.String("host") is not { } host || p.String("user") is not { } user ||
            p.Long("time") is not { } time || !ValidTime(time) || p.String("nonce") is not { } nonce)
        {
            return null;
        }
        var service = "";
        if (kind == ApproveKind.Approve)
        {
            if (p.String("service") is not { } s)
            {
                return null;
            }
            service = s;
        }
        var r = new ApproveRequest(
            computerId,
            computerName,
            id,
            kind,
            host,
            user,
            service,
            p.String("tty") ?? "",
            p.String("rhost") ?? "",
            time,
            nonce,
            Math.Clamp(p.Int("timeout") ?? DefaultTimeout, MinTimeout, MaxTimeout));
        if (!new[] { r.Host, r.User, r.Service, r.Tty, r.Rhost }.All(ValidField) ||
            r.Host.Length == 0 || r.User.Length == 0 || !ValidNonce(r.Nonce))
        {
            return null;
        }
        if (kind == ApproveKind.Approve && r.Service.Length == 0)
        {
            return null;
        }
        return r;
    }

    // Reports whether the time of the request is within 10 minutes of the
    // clock of this computer. The difference uses 128 bits, so a time near
    // the limits of a long cannot overflow.
    public static bool Fresh(ApproveRequest r, long now) => Int128.Abs((Int128)now - r.Time) <= MaxSkewSeconds;

    // Reports whether a request time in seconds is possible: above 0 and at
    // most 2^40, about the year 36812. The helper sends the time of now.
    internal static bool ValidTime(long t) => t > 0 && t <= 1L << 40;

    // The question, for example "Approve sudo for user alice on host omarchy-xps?".
    public static string Question(ApproveRequest r) => r.Kind == ApproveKind.Approve
        ? $"Approve {r.Service} for user {r.User} on host {r.Host}?"
        : ApproveTexts.EnrollQuestion(r.User, r.Host);

    public static Packet Approved(string id, byte[] signature) => new(PacketType.Approve, new JsonObject
    {
        ["kind"] = "response",
        ["id"] = id,
        ["signature"] = Convert.ToBase64String(signature),
    });

    // The denial is a JSON boolean, as the Go handler decodes it.
    public static Packet Denied(string id) => new(PacketType.Approve, new JsonObject
    {
        ["kind"] = "response",
        ["id"] = id,
        ["denied"] = true,
    });

    // The error goes to the computer, which prints it after a failed
    // enrollment. It keeps the first 200 text elements, so that a cut does
    // not split a character.
    public static Packet Failed(string id, string message)
    {
        var info = new StringInfo(message);
        var text = info.LengthInTextElements > MaxError ? info.SubstringByTextElements(0, MaxError) : message;
        return new Packet(PacketType.Approve, new JsonObject
        {
            ["kind"] = "response",
            ["id"] = id,
            ["error"] = text,
        });
    }

    public static Packet Enrolled(string id, byte[] spki, byte[] signature) => new(PacketType.Approve, new JsonObject
    {
        ["kind"] = "enrolled",
        ["id"] = id,
        ["publicKey"] = Convert.ToBase64String(spki),
        ["signature"] = Convert.ToBase64String(signature),
    });

    // Reports whether signature is a valid signature of the key spki over
    // the SHA-256 of message: an ASN.1 DER ECDSA signature for an EC P-256
    // key, or an RSASSA-PKCS1-v1_5 signature for an RSA 2048 key with the
    // exponent 65537, which is the key of Windows Hello. The helper on the
    // computer accepts the same 2 kinds, see docs/approve.md. This computer
    // checks each signature of the platform before it sends it. So a
    // signature in another format or from another key fails here with a
    // clear message.
    public static bool Verify(byte[] spki, byte[] message, byte[] signature) =>
        VerifyEc(spki, message, signature) || VerifyRsa(spki, message, signature);

    static bool VerifyEc(byte[] spki, byte[] message, byte[] signature)
    {
        try
        {
            using var key = ECDsa.Create();
            key.ImportSubjectPublicKeyInfo(spki, out var read);
            if (read != spki.Length || key.KeySize != 256 || key.ExportParameters(false).Curve.Oid.Value != ECCurve.NamedCurves.nistP256.Oid.Value)
            {
                return false;
            }
            return key.VerifyData(message, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    // Names the scheme of a signature that failed the check, for the log:
    // a valid RSA-PSS signature means that Windows Hello signs with PSS and
    // not with PKCS#1 v1.5, which the helper needs. It returns "" for other
    // failures.
    public static string Scheme(byte[] spki, byte[] message, byte[] signature)
    {
        try
        {
            using var key = RSA.Create();
            key.ImportSubjectPublicKeyInfo(spki, out _);
            return key.VerifyData(message, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)
                ? ": the platform signs with RSA-PSS, and the helper takes only RSASSA-PKCS1-v1_5"
                : "";
        }
        catch (CryptographicException)
        {
            return "";
        }
    }

    static bool VerifyRsa(byte[] spki, byte[] message, byte[] signature)
    {
        try
        {
            using var key = RSA.Create();
            key.ImportSubjectPublicKeyInfo(spki, out var read);
            var exponent = key.ExportParameters(false).Exponent;
            if (read != spki.Length || key.KeySize != 2048 || exponent is null || !exponent.AsSpan().SequenceEqual(new byte[] { 1, 0, 1 }) ||
                signature.Length != 256)
            {
                return false;
            }
            return key.VerifyData(message, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }
}
