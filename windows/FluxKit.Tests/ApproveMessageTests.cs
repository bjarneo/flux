using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ApproveMessageTests.swift of the Mac app. The Go test
// internal/approve/message_test.go and the Android test ApproveMessageTest
// have the same vectors. So this computer signs the bytes that the helper
// checks.
public class ApproveMessageTests
{
    internal const string Nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    internal static readonly ApproveRequest Request = new(
        "pc1", "omarchy-xps", "req1", ApproveKind.Approve,
        "omarchy-xps", "alice", "sudo", "/dev/pts/3", "",
        1_790_000_000, Nonce, 20);

    // A P-256 key, its SubjectPublicKeyInfo, and signatures that Go made with
    // x509.MarshalPKIXPublicKey and ecdsa.SignASN1.
    const string GoScalar = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721";
    const string GoSpki = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5A/4QCLi8maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimQ==";
    const string GoApproval = "MEQCIC9nhVHDkdMjLMD2zhHiL3z6g5BTHJJja1ab9OBsZ/ItAiAbjR9eAaoWgvL+8lQhHo4oYVYGxUyOqiI6xcw9gZDgVA==";
    const string GoEnrollment = "MEYCIQCRP4zk0TYxBaRM30naSWJ52MvOcMIvNw6rFQKxhT+96gIhAO7ZR5DQk4uvPQo6eX0twkl8aT2RMJteb0yORkgFfxJ5";

    [Fact]
    public void ApprovalBytes()
    {
        var want = $"flux-approve-v1\nhost=omarchy-xps\nuser=alice\nservice=sudo\ntty=/dev/pts/3\nrhost=\ntime=1790000000\nnonce={Nonce}\n";
        Assert.Equal(want, Encoding.UTF8.GetString(ApproveMessage.Approval(Request)));
    }

    [Fact]
    public void EnrollmentBytes()
    {
        var e = Request with { Kind = ApproveKind.Enroll, Service = "", Tty = "" };
        var want = "flux-approve-enroll-v1\nhost=omarchy-xps\nuser=alice\n" +
                   "key=62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef\n" +
                   $"time=1790000000\nnonce={Nonce}\n";
        Assert.Equal(want, Encoding.UTF8.GetString(ApproveMessage.Enrollment(e, "test-key"u8.ToArray())));
    }

    // The time goes out without a group separator or a culture sign in each
    // culture of the user.
    [Fact]
    public void TheBytesDoNotDependOnTheCulture()
    {
        var before = Thread.CurrentThread.CurrentCulture;
        try
        {
            foreach (var name in new[] { "ar-SA", "fa-IR", "de-DE", "sv-SE" })
            {
                Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo(name);
                Assert.Contains("\ntime=1790000000\n", Encoding.UTF8.GetString(ApproveMessage.Approval(Request)));
            }
        }
        finally
        {
            Thread.CurrentThread.CurrentCulture = before;
        }
    }

    [Fact]
    public void Fingerprint()
    {
        Assert.Equal("62AF 8704 764F AF8E", ApproveMessage.Fingerprint("test-key"u8.ToArray()));
        Assert.Equal("5A7A 78CC A4A0 F420", ApproveMessage.Fingerprint(Convert.FromBase64String(GoSpki)));
    }

    // .NET writes the same SubjectPublicKeyInfo DER as Go for the same key.
    [Fact]
    public void PublicKeyDerMatchesGo()
    {
        using var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = Convert.FromHexString(GoScalar) });
        Assert.Equal(GoSpki, Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()));
    }

    [Fact]
    public void GoSignaturesVerifyOverTheSameBytes()
    {
        var spki = Convert.FromBase64String(GoSpki);
        var approval = Convert.FromBase64String(GoApproval);
        Assert.True(ApproveMessage.Verify(spki, ApproveMessage.Approval(Request), approval));

        var e = Request with { Kind = ApproveKind.Enroll };
        var enrollment = Convert.FromBase64String(GoEnrollment);
        Assert.True(ApproveMessage.Verify(spki, ApproveMessage.Enrollment(e, spki), enrollment));

        // A signature for an enrollment is never a valid approval.
        Assert.False(ApproveMessage.Verify(spki, ApproveMessage.Approval(Request), enrollment));
        Assert.False(ApproveMessage.Verify(spki, ApproveMessage.Approval(Request with { Service = "polkit-1" }), approval));
    }

    // A signature in the P1363 format, a key of another curve, and a key with
    // extra bytes do not verify, as in the Go helper.
    [Fact]
    public void VerifyTakesOnlyDerSignaturesOfP256Keys()
    {
        using var p256 = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var message = ApproveMessage.Approval(Request);
        var spki = p256.ExportSubjectPublicKeyInfo();
        Assert.True(ApproveMessage.Verify(spki, message, p256.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
        Assert.False(ApproveMessage.Verify(spki, message, p256.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)));
        Assert.False(ApproveMessage.Verify([.. spki, 0], message, p256.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
        Assert.False(ApproveMessage.Verify(spki, message, []));
        Assert.False(ApproveMessage.Verify("test-key"u8.ToArray(), message, [1, 2, 3]));

        using var p384 = ECDsa.Create(ECCurve.NamedCurves.nistP384);
        Assert.False(ApproveMessage.Verify(p384.ExportSubjectPublicKeyInfo(), message,
            p384.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)));
    }

    [Fact]
    public void FieldRules()
    {
        Assert.True(ApproveMessage.ValidField("/dev/pts/3"));
        Assert.True(ApproveMessage.ValidField(""));
        Assert.True(ApproveMessage.ValidField("Pixel 8 · Office"));
        Assert.False(ApproveMessage.ValidField("alice\nservice=sshd"));
        Assert.False(ApproveMessage.ValidField("tab\there"));
        Assert.False(ApproveMessage.ValidField("c1\u0085"));
        Assert.False(ApproveMessage.ValidField("del\u007f"));
        Assert.False(ApproveMessage.ValidField(new string('x', 257)));
        Assert.True(ApproveMessage.ValidField(new string('x', 256)));
        // 129 characters of 2 bytes each are 258 bytes.
        Assert.False(ApproveMessage.ValidField(new string('é', 129)));
        // A lone surrogate is not valid UTF-8. A pair is 1 character of 4 bytes.
        Assert.False(ApproveMessage.ValidField("a\ud800b"));
        Assert.True(ApproveMessage.ValidField("🙂"));
        Assert.True(ApproveMessage.ValidNonce(Nonce));
        Assert.False(ApproveMessage.ValidNonce(Nonce.ToUpperInvariant()));
        Assert.False(ApproveMessage.ValidNonce(Nonce[..^2]));
    }

    internal static Packet RequestPacket(params (string Key, JsonNode? Value)[] extra)
    {
        var body = new JsonObject
        {
            ["kind"] = "request",
            ["id"] = "req1",
            ["host"] = "omarchy-xps",
            ["user"] = "alice",
            ["service"] = "sudo",
            ["tty"] = "/dev/pts/3",
            ["rhost"] = "",
            ["time"] = 1_790_000_000L,
            ["nonce"] = Nonce,
            ["timeout"] = 20,
        };
        foreach (var (key, value) in extra)
        {
            if (value is null)
            {
                body.Remove(key);
            }
            else
            {
                body[key] = value;
            }
        }
        return new Packet(PacketType.Approve, body);
    }

    [Fact]
    public void ParseRequest()
    {
        var r = ApproveMessage.Parse(RequestPacket(), "pc1", "omarchy-xps");
        Assert.Equal(Request, r);
        Assert.Equal("Approve sudo for user alice on host omarchy-xps?", ApproveMessage.Question(r!));
    }

    [Fact]
    public void ParseSurvivesTheWireFormat()
    {
        var back = Packet.Parse(RequestPacket().Serialize());
        Assert.NotNull(back);
        Assert.Equal(Request, ApproveMessage.Parse(back, "pc1", "omarchy-xps"));
    }

    [Fact]
    public void ParseRefusesBadRequests()
    {
        Assert.Null(ApproveMessage.Parse(RequestPacket(("user", "alice\nservice=sshd")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("nonce", "abcd")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("host", "")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("service", "")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("kind", "other")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("id", "")), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("id", new string('a', 65))), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("tty", "tty\0")), "pc1", "pc"));
        // A field of another JSON kind is missing.
        Assert.Null(ApproveMessage.Parse(RequestPacket(("host", 7)), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("service", null)), "pc1", "pc"));
        Assert.Null(ApproveMessage.Parse(RequestPacket(("nonce", null)), "pc1", "pc"));
        Assert.NotNull(ApproveMessage.Parse(RequestPacket(("id", new string('a', 64))), "pc1", "pc"));
    }

    [Fact]
    public void ParseTimeoutLimits()
    {
        Assert.Equal(5, ApproveMessage.Parse(RequestPacket(("timeout", 1)), "pc1", "pc")?.TimeoutSeconds);
        Assert.Equal(120, ApproveMessage.Parse(RequestPacket(("timeout", 600)), "pc1", "pc")?.TimeoutSeconds);
        Assert.Equal(20, ApproveMessage.Parse(RequestPacket(("timeout", null)), "pc1", "pc")?.TimeoutSeconds);
    }

    [Fact]
    public void ParseEnrollment()
    {
        var r = ApproveMessage.Parse(RequestPacket(("kind", "enroll"), ("service", null)), "pc1", "omarchy-xps");
        Assert.NotNull(r);
        Assert.Equal(ApproveKind.Enroll, r.Kind);
        Assert.Equal("", r.Service);
        Assert.Equal("Use this computer to approve sudo for user alice on host omarchy-xps?", ApproveMessage.Question(r));
        // An enrollment ignores a service.
        Assert.Equal("", ApproveMessage.Parse(RequestPacket(("kind", "enroll")), "pc1", "pc")?.Service);
    }

    [Fact]
    public void Freshness()
    {
        Assert.True(ApproveMessage.Fresh(Request, Request.Time + 30));
        Assert.True(ApproveMessage.Fresh(Request, Request.Time - 30));
        Assert.True(ApproveMessage.Fresh(Request, Request.Time + 600));
        Assert.False(ApproveMessage.Fresh(Request, Request.Time + 601));
        Assert.False(ApproveMessage.Fresh(Request, Request.Time - 601));
    }

    // A time near long.MinValue made the subtraction trap on the Mac. Such a
    // time is not fresh.
    [Fact]
    public void FreshnessCannotOverflow()
    {
        foreach (var time in new[] { long.MinValue, long.MinValue + 1, long.MaxValue, 0, -1 })
        {
            Assert.False(ApproveMessage.Fresh(Request with { Time = time }, 1_790_000_000), $"{time}");
        }
        Assert.False(ApproveMessage.Fresh(Request, long.MinValue));
        Assert.False(ApproveMessage.Fresh(Request, long.MaxValue));
    }

    [Fact]
    public void ParseRefusesImpossibleTimes()
    {
        foreach (var time in new JsonNode[] { long.MinValue, 0L, -1L, 1L << 41, "1e19", 1e300, 1.5 })
        {
            Assert.Null(ApproveMessage.Parse(RequestPacket(("time", time)), "pc1", "pc"));
        }
        Assert.NotNull(ApproveMessage.Parse(RequestPacket(("time", 1L << 40)), "pc1", "pc"));
    }

    [Fact]
    public void AnswerPackets()
    {
        byte[] sig = [1, 2, 3];
        var a = ApproveMessage.Approved("req1", sig);
        Assert.Equal(PacketType.Approve, a.Type);
        Assert.Equal("response", a.String("kind"));
        Assert.Equal("req1", a.String("id"));
        Assert.Equal(Convert.ToBase64String(sig), a.String("signature"));
        Assert.Null(a.Bool("denied"));

        var d = ApproveMessage.Denied("req1");
        Assert.Equal("response", d.String("kind"));
        Assert.True(d.Bool("denied"));
        Assert.Null(d.String("signature"));

        var e = ApproveMessage.Enrolled("req1", "key"u8.ToArray(), sig);
        Assert.Equal("enrolled", e.String("kind"));
        Assert.Equal(Convert.ToBase64String("key"u8.ToArray()), e.String("publicKey"));
        Assert.Equal(Convert.ToBase64String(sig), e.String("signature"));

        var f = ApproveMessage.Failed("req1", new string('x', 500));
        Assert.Equal(200, f.String("error")?.Length);
        // The cut keeps whole characters.
        Assert.Equal(400, ApproveMessage.Failed("req1", string.Concat(Enumerable.Repeat("🙂", 300))).String("error")?.Length);

        // The denial is a JSON boolean, as the Go handler decodes it.
        var line = Encoding.UTF8.GetString(d.Serialize());
        Assert.Contains("\"denied\":true", line);
        var back = Packet.Parse(a.Serialize());
        Assert.Equal(a.String("signature"), back?.String("signature"));
    }

    [Fact]
    public void AWindowsHelloKeyPassesTheCheck()
    {
        using var rsa = RSA.Create(2048);
        var spki = rsa.ExportSubjectPublicKeyInfo();
        var message = System.Text.Encoding.UTF8.GetBytes("flux-approve-v1\nhost=h\n");
        var signature = rsa.SignData(message, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        Assert.True(ApproveMessage.Verify(spki, message, signature));
        Assert.False(ApproveMessage.Verify(spki, [.. message, 1], signature));
        // PSS is not the scheme of Windows Hello.
        Assert.False(ApproveMessage.Verify(spki, message, rsa.SignData(message, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)));
        using var small = RSA.Create(1024);
        Assert.False(ApproveMessage.Verify(small.ExportSubjectPublicKeyInfo(), message,
            small.SignData(message, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)));
    }
}
