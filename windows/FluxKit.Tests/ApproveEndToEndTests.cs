using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// An error that fluxd returns, with its code.
public sealed class ApproveIpcException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

// A client of the socket of a test fluxd. It calls the same methods as
// flux-cli approve enroll and the flux-approve helper: approve.enroll,
// approve.request, approve.wait, and approve.cancel. These commands need
// root, /dev/tty, and the socket in /run/user, so the test calls the methods
// itself. fluxd ends a request when the connection that started it closes.
public sealed class ApproveIpc : IDisposable
{
    readonly Socket socket;
    readonly NetworkStream stream;
    readonly StreamReader reader;
    long next;

    ApproveIpc(Socket socket)
    {
        this.socket = socket;
        stream = new NetworkStream(socket, ownsSocket: false);
        reader = new StreamReader(stream, Encoding.UTF8);
    }

    public static async Task<ApproveIpc> ConnectAsync(Fluxd fluxd)
    {
        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        await socket.ConnectAsync(new UnixDomainSocketEndPoint(Path.Combine(fluxd.Root, "run", "flux", "fluxd.sock")));
        return new ApproveIpc(socket);
    }

    // Sends 1 call and waits for its answer. An error of fluxd throws.
    public async Task<JsonObject> CallAsync(string method, JsonObject parameters, double seconds = 10)
    {
        var id = ++next;
        var line = new JsonObject { ["id"] = id, ["method"] = method, ["params"] = parameters }.ToJsonString() + "\n";
        await stream.WriteAsync(Encoding.UTF8.GetBytes(line));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        while (true)
        {
            var text = await reader.ReadLineAsync(timeout.Token) ?? throw new IOException("fluxd closed the socket");
            if (JsonNode.Parse(text) is not JsonObject answer || Json.Long(answer["id"]) != id)
            {
                // An event or an old answer.
                continue;
            }
            if (answer["error"] is JsonObject error)
            {
                throw new ApproveIpcException(Json.String(error["code"]) ?? "", Json.String(error["message"]) ?? "");
            }
            return answer["result"] as JsonObject ?? [];
        }
    }

    public void Dispose()
    {
        reader.Dispose();
        stream.Dispose();
        socket.Dispose();
    }
}

// A request of the helper or the enrollment command: its fields, its own
// nonce, and the time of now.
public sealed record ApproveAsk(string Host, string User, string Service, string Tty, string Rhost, long Time, string Nonce)
{
    public static ApproveAsk New(string service = "sudo", string tty = "/dev/pts/9") =>
        new("omarchy-e2e", "alice", service, tty, "", DateTimeOffset.UtcNow.ToUnixTimeSeconds(), RandomNumberGenerator.GetHexString(64, lowercase: true));

    public JsonObject Params(string device) => new()
    {
        ["device"] = device,
        ["host"] = Host,
        ["user"] = User,
        ["service"] = Service,
        ["tty"] = Tty,
        ["rhost"] = Rhost,
        ["time"] = Time,
        ["nonce"] = Nonce,
    };

    public byte[] Approval => ApproveExpect.Approval(Host, User, Service, Tty, Rhost, Time, Nonce);
}

// A headless fluxd, a paired Windows core with the approve plugin, and a
// software key in place of Windows Hello.
public sealed class ApproveFluxdRig : IAsyncDisposable
{
    public required Fluxd Fluxd { get; init; }
    public required TestCore T { get; init; }
    public required ApprovePlugin Plugin { get; init; }
    public required ApproveSoftwareSigner Signer { get; init; }
    public required DeviceSnapshot Computer { get; init; }

    public string WindowsId => T.Core.Local.DeviceId;

    // The fluxd uses first and first + 4. The core uses first + 15 and the
    // TCP ports from first + 24 to first + 32.
    public static async Task<ApproveFluxdRig> StartAsync(int first, bool withSigner = true)
    {
        var fluxd = await Fluxd.StartAsync(first, first + 4);
        var signer = new ApproveSoftwareSigner();
        var plugin = new ApprovePlugin(withSigner ? signer : null);
        var t = new TestCore(new LanConfig
        {
            UdpPort = first + 15,
            PeerUdpPort = fluxd.UdpPort,
            FirstTcpPort = first + 24,
            LastTcpPort = first + 32,
            LoopbackOnly = true,
        }, [plugin]);
        var computer = await EndToEndTests.PairFromWindowsAsync(fluxd, t);
        return new ApproveFluxdRig { Fluxd = fluxd, T = t, Plugin = plugin, Signer = signer, Computer = computer };
    }

    public void Ui(Action action) => T.Core.Host.Post(action);

    // Enrolls this computer as flux-cli approve enroll does, and returns the
    // public key after the checks of the command.
    public async Task<byte[]> EnrollAsync(ApproveIpc ipc)
    {
        var ask = ApproveAsk.New();
        var parameters = ask.Params(WindowsId);
        parameters.Remove("service");
        var started = await ipc.CallAsync("approve.enroll", parameters);
        Assert.Equal(WindowsId, Json.String(started["device"]));
        Assert.Equal("Windows Test", Json.String(started["name"]));
        Assert.Equal(120, Json.Int(started["timeout"]));
        await Wait.UntilAsync(() => Plugin.Model.Current is { Kind: ApproveKind.Enroll }, "the enrollment on this computer", Fluxd);
        var r = Plugin.Model.Current!;
        Assert.Equal((Computer.Id, Computer.Name, "omarchy-e2e", "alice", ask.Time, ask.Nonce, 120),
            (r.ComputerId, r.ComputerName, r.Host, r.User, r.Time, r.Nonce, r.TimeoutSeconds));
        Ui(Plugin.Approve);
        var result = await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = Json.String(started["id"]) }, 30);
        Assert.Equal("enrolled", Json.String(result["state"]));
        var spki = Convert.FromBase64String(Json.String(result["publicKey"])!);
        var proof = Convert.FromBase64String(Json.String(result["signature"])!);
        // approve.VerifyEnrollment and the key code check of the command.
        Assert.True(ApproveExpect.Verify(spki, ApproveExpect.Enrollment(ask.Host, ask.User, spki, ask.Time, ask.Nonce), proof));
        await Wait.UntilAsync(() => Plugin.Model.Phase.Kind == ApprovePhaseKind.Enrolled, "the key code on this computer", Fluxd);
        Assert.Equal(Convert.ToHexString(SHA256.HashData(spki), 0, 8), Plugin.Model.Phase.Text.Replace(" ", ""));
        Ui(Plugin.CloseResult);
        return spki;
    }

    // Starts an approval as the helper does, and waits until this computer
    // shows it.
    public async Task<string> RequestAsync(ApproveIpc ipc, ApproveAsk ask)
    {
        var started = await ipc.CallAsync("approve.request", ask.Params(WindowsId));
        var id = Json.String(started["id"])!;
        Assert.Equal(20, Json.Int(started["timeout"]));
        Assert.Equal("Windows Test", Json.String(started["name"]));
        await Wait.UntilAsync(() => Plugin.Model.Current?.Id == id, "the request on this computer", Fluxd);
        return id;
    }

    public ApproveOutcome? Outcome(string id) => Plugin.Model.History.FirstOrDefault(r => r.RequestId == id)?.Outcome;

    public async ValueTask DisposeAsync()
    {
        T.Dispose();
        Signer.Dispose();
        await Fluxd.DisposeAsync();
    }
}

// The approve plugin against a headless fluxd, with blocks of 50 ports from
// 36750. The test checks each signature as the Go helper checks it.
public class ApproveEndToEndTests
{
    // An enrollment through fluxd gives the public key and its proof. An
    // approval through fluxd then gives a signature over the message that
    // the helper builds from its own fields.
    [FluxdFact]
    public async Task EnrollsAndApprovesThroughFluxd()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(36750);
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);
        var spki = await rig.EnrollAsync(ipc);

        var ask = ApproveAsk.New();
        var id = await rig.RequestAsync(ipc, ask);
        var r = rig.Plugin.Model.Current!;
        Assert.Equal(("sudo", "/dev/pts/9", "", 20), (r.Service, r.Tty, r.Rhost, r.TimeoutSeconds));
        rig.Ui(rig.Plugin.Approve);
        var result = await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = id }, 30);
        Assert.Equal("approved", Json.String(result["state"]));
        var signature = Convert.FromBase64String(Json.String(result["signature"])!);
        Assert.True(ApproveExpect.Verify(spki, ask.Approval, signature));
        // A changed field or another nonce does not verify.
        Assert.False(ApproveExpect.Verify(spki, (ask with { Service = "polkit-1" }).Approval, signature));
        Assert.False(ApproveExpect.Verify(spki, (ask with { Nonce = new string('a', 64) }).Approval, signature));
        await Wait.UntilAsync(() => rig.Outcome(id) == ApproveOutcome.Approved, "the approved outcome", rig.Fluxd);
        Assert.Equal(2, rig.Signer.Checks);
    }

    // The same flow with an RSA 2048 key of Windows Hello. The test checks
    // each signature with RSASSA-PKCS1-v1_5, as rsa.VerifyPKCS1v15 of the Go
    // helper does.
    [FluxdFact]
    public async Task EnrollsAndApprovesWithAWindowsHelloKeyThroughFluxd()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(37000);
        rig.Signer.Rsa = true;
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);
        var spki = await rig.EnrollAsync(ipc);
        Assert.True(ApproveExpect.IsRsa(spki));

        var ask = ApproveAsk.New();
        var id = await rig.RequestAsync(ipc, ask);
        rig.Ui(rig.Plugin.Approve);
        var result = await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = id }, 30);
        Assert.Equal("approved", Json.String(result["state"]));
        var signature = Convert.FromBase64String(Json.String(result["signature"])!);
        Assert.True(ApproveExpect.Verify(spki, ask.Approval, signature));
        Assert.False(ApproveExpect.Verify(spki, (ask with { Tty = "/dev/pts/1" }).Approval, signature));
    }

    // A denial, a failure with its reason, a second request while one is
    // open, approve.cancel, and the close of the connection of the helper.
    [FluxdFact]
    public async Task DeniesFailsAndCancelsThroughFluxd()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(36800);
        using (var enroll = await ApproveIpc.ConnectAsync(rig.Fluxd))
        {
            await rig.EnrollAsync(enroll);
        }
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);

        var denied = await rig.RequestAsync(ipc, ApproveAsk.New());
        rig.Ui(rig.Plugin.Deny);
        Assert.Equal("denied", Json.String((await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = denied }))["state"]));

        rig.Signer.CheckFails = ApproveKeyError.NotRecognized;
        var failed = await rig.RequestAsync(ipc, ApproveAsk.New());
        rig.Ui(rig.Plugin.Approve);
        var result = await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = failed });
        Assert.Equal(("failed", ApproveTexts.NotRecognized), (Json.String(result["state"]), Json.String(result["message"])));
        rig.Signer.CheckFails = null;

        // fluxd sends 1 request at a time to this computer.
        var open = await rig.RequestAsync(ipc, ApproveAsk.New());
        var busy = await Assert.ThrowsAsync<ApproveIpcException>(() => ipc.CallAsync("approve.request", ApproveAsk.New().Params(rig.WindowsId)));
        Assert.Equal("busy", busy.Code);
        using (var other = await ApproveIpc.ConnectAsync(rig.Fluxd))
        {
            await other.CallAsync("approve.cancel", new JsonObject { ["id"] = open });
        }
        await Wait.UntilAsync(() => rig.Outcome(open) == ApproveOutcome.Cancelled, "the cancel from fluxd", rig.Fluxd);
        Assert.Null(rig.Plugin.Model.Current);

        // The helper stops, for example after a kill of sudo.
        string closed;
        using (var helper = await ApproveIpc.ConnectAsync(rig.Fluxd))
        {
            closed = await rig.RequestAsync(helper, ApproveAsk.New());
        }
        await Wait.UntilAsync(() => rig.Outcome(closed) == ApproveOutcome.Cancelled, "the cancel after the close", rig.Fluxd);
        Assert.Equal(1, rig.Signer.Signatures); // only the enrollment signed
    }

    // A request that is not valid on this computer fails at once in fluxd
    // with the reason: an approval without an enrolled key.
    [FluxdFact]
    public async Task AnApprovalWithoutAKeyFailsAtOnce()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(36850);
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);
        var started = await ipc.CallAsync("approve.request", ApproveAsk.New().Params(rig.WindowsId));
        var result = await ipc.CallAsync("approve.wait", new JsonObject { ["id"] = Json.String(started["id"]) });
        Assert.Equal(("failed", ApproveTexts.NoKey), (Json.String(result["state"]), Json.String(result["message"])));
        Assert.Equal(0, rig.Signer.Checks);
    }

    // An app without a signer does not list flux.approve, and fluxd does not
    // send it a request.
    [FluxdFact]
    public async Task AComputerWithoutASignerGetsNoRequest()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(36900, withSigner: false);
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);
        var parameters = ApproveAsk.New().Params(rig.WindowsId);
        parameters.Remove("service");
        var error = await Assert.ThrowsAsync<ApproveIpcException>(() => ipc.CallAsync("approve.enroll", parameters));
        Assert.Equal("unsupported", error.Code);
        Assert.Empty(rig.Plugin.Model.History);
    }
}

// The wait of fluxd ends after approve_timeout, 20 seconds by default. fluxd
// then sends a cancel, and this computer closes the request. The test has its
// own class, so that it runs next to the other tests.
public class ApproveExpiryEndToEndTests
{
    [FluxdFact]
    public async Task TheRequestEndsWithTheWaitOfFluxd()
    {
        await using var rig = await ApproveFluxdRig.StartAsync(36950);
        using var ipc = await ApproveIpc.ConnectAsync(rig.Fluxd);
        await rig.EnrollAsync(ipc);
        var id = await rig.RequestAsync(ipc, ApproveAsk.New());
        var timeout = await Assert.ThrowsAsync<ApproveIpcException>(() => ipc.CallAsync("approve.wait", new JsonObject { ["id"] = id }, 40));
        Assert.Equal("timeout", timeout.Code);
        await Wait.UntilAsync(() => rig.Plugin.Model.Current is null, "the end of the request", rig.Fluxd);
        // fluxd and this computer count the same 20 seconds, so either end
        // can come first.
        Assert.Contains(rig.Outcome(id), new[] { ApproveOutcome.Cancelled, ApproveOutcome.Expired });
        Assert.Equal(1, rig.Signer.Signatures);
    }
}
