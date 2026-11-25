using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The bytes and the check of the Go helper, written out again without
// ApproveMessage, so that a test does not check the code with itself.
public static class ApproveExpect
{
    public static byte[] Approval(string host, string user, string service, string tty, string rhost, long time, string nonce) =>
        Encoding.UTF8.GetBytes($"flux-approve-v1\nhost={host}\nuser={user}\nservice={service}\ntty={tty}\nrhost={rhost}\ntime={time}\nnonce={nonce}\n");

    public static byte[] Enrollment(string host, string user, byte[] spki, long time, string nonce) =>
        Encoding.UTF8.GetBytes($"flux-approve-enroll-v1\nhost={host}\nuser={user}\nkey={Convert.ToHexStringLower(SHA256.HashData(spki))}\ntime={time}\nnonce={nonce}\n");

    // ecdsa.VerifyASN1 over the SHA-256 of the message with a P-256 key, or
    // rsa.VerifyPKCS1v15 with an RSA 2048 key of Windows Hello.
    public static bool Verify(byte[] spki, byte[] message, byte[] signature)
    {
        if (IsRsa(spki))
        {
            using var rsa = RSA.Create();
            rsa.ImportSubjectPublicKeyInfo(spki, out _);
            Assert.Equal(2048, rsa.KeySize);
            Assert.Equal(new byte[] { 1, 0, 1 }, rsa.ExportParameters(false).Exponent);
            return rsa.VerifyData(message, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }
        using var key = ECDsa.Create();
        key.ImportSubjectPublicKeyInfo(spki, out _);
        Assert.Equal(256, key.KeySize);
        return key.VerifyData(message, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
    }

    // True for a SubjectPublicKeyInfo of an RSA key.
    public static bool IsRsa(byte[] spki)
    {
        using var rsa = RSA.Create();
        try
        {
            rsa.ImportSubjectPublicKeyInfo(spki, out _);
            return true;
        }
        catch (CryptographicException)
        {
            return false;
        }
    }
}

// A core with the approve plugin, a software signer, and a computer on
// loopback that sends the packets of fluxd.
public sealed class ApproveRig : IDisposable
{
    int presented;

    public ApproveSoftwareSigner Signer { get; } = new();
    public ApprovePlugin Plugin { get; }
    public TestCore T { get; }
    public SystemTestComputer Computer { get; }
    public SystemNotificationRecorder Notes { get; } = new();
    public int Presented => Volatile.Read(ref presented);

    ApproveRig(int first, TimeSpan? second, string name)
    {
        Plugin = new ApprovePlugin(Signer);
        if (second is { } s)
        {
            Plugin.Second = s;
        }
        T = new TestCore(SystemTestComputer.CoreLan(first), [Plugin]);
        T.Core.Host.Notifier.Backend = Notes;
        Plugin.Model.PresentRequested += () => Interlocked.Increment(ref presented);
        Computer = new SystemTestComputer(first + 20, first + 21, [PacketType.Approve], [PacketType.Approve], name);
    }

    // first and the 29 ports after it belong to the rig.
    public static async Task<ApproveRig> StartAsync(int first, TimeSpan? second = null, string name = "omarchy-xps")
    {
        var rig = new ApproveRig(first, second, name);
        await rig.Computer.PairAsync(rig.T);
        return rig;
    }

    public ApproveModel Model => Plugin.Model;

    // Runs the action on the UI queue of the core, as the app does.
    public void Ui(Action action) => T.Core.Host.Post(action);

    public static long Now => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public static Packet Packet(string id, ApproveKind kind = ApproveKind.Approve, int timeout = 20, long? time = null) =>
        ApproveMessageTests.RequestPacket(("kind", kind == ApproveKind.Approve ? "request" : "enroll"), ("id", id), ("time", time ?? Now), ("timeout", timeout));

    // Sends a request and waits until it is open.
    public async Task<ApproveRequest> AskAsync(string id, ApproveKind kind = ApproveKind.Approve, int timeout = 20)
    {
        Computer.Send(Packet(id, kind, timeout));
        await Wait.UntilAsync(() => Model.Current?.Id == id, $"the open request {id}");
        return Model.Current!;
    }

    // The flux.approve packets with the id that the computer got.
    public IReadOnlyList<Packet> Answers(string id) => Computer.Got(PacketType.Approve).Where(p => p.String("id") == id).ToArray();

    // Waits for the first answer with the id.
    public async Task<Packet> AnswerAsync(string id)
    {
        await Wait.UntilAsync(() => Answers(id).Count > 0, $"the answer to {id}, log:\n{string.Join("\n", TestCore.Log)}");
        return Answers(id)[0];
    }

    // The outcome of the request in the history.
    public ApproveOutcome? Outcome(string id) => Model.History.FirstOrDefault(r => r.RequestId == id)?.Outcome;

    // Enrolls this computer and returns the public key that the computer got.
    public async Task<byte[]> EnrollAsync(string id = "enroll1")
    {
        await AskAsync(id, ApproveKind.Enroll);
        Ui(Plugin.Approve);
        var answer = await AnswerAsync(id);
        Assert.Equal("enrolled", answer.String("kind"));
        var spki = Convert.FromBase64String(answer.String("publicKey")!);
        await Wait.UntilAsync(() => Model.Current is null && Model.KeyFor(Computer.Id)?.PublicKey == Convert.ToBase64String(spki), "the stored key");
        return spki;
    }

    public void Dispose()
    {
        T.Dispose();
        Computer.Dispose();
        Signer.Dispose();
    }
}

// The approve plugin against a computer on loopback, with a software key in
// place of Windows Hello. Each test has its own block of 40 ports from 36000.
public class ApprovePluginTests
{
    // An enrollment makes a key, proves it with the enrollment message, and
    // stores it. An approval then signs the approval message with that key.
    // Each signature has its own user check.
    [Fact]
    public async Task EnrollsAndApproves()
    {
        using var rig = await ApproveRig.StartAsync(36000);
        var enroll = await rig.AskAsync("e1", ApproveKind.Enroll);
        Assert.Equal(ApprovePhase.Ask, rig.Model.Phase);
        Assert.Equal(enroll, rig.Model.Shown);
        Assert.Equal("Enroll this computer on omarchy-xps?", rig.Notes.Current["approve"].Title);
        rig.Ui(rig.Plugin.Approve);
        var enrolled = await rig.AnswerAsync("e1");
        Assert.Equal("enrolled", enrolled.String("kind"));
        var spki = Convert.FromBase64String(enrolled.String("publicKey")!);
        var proof = Convert.FromBase64String(enrolled.String("signature")!);
        Assert.True(ApproveExpect.Verify(spki, ApproveExpect.Enrollment("omarchy-xps", "alice", spki, enroll.Time, ApproveMessageTests.Nonce), proof));
        // The proof of an enrollment is never an approval.
        Assert.False(ApproveExpect.Verify(spki, ApproveExpect.Approval("omarchy-xps", "alice", "sudo", "/dev/pts/3", "", enroll.Time, ApproveMessageTests.Nonce), proof));
        await Wait.UntilAsync(() => rig.Model.Phase.Kind == ApprovePhaseKind.Enrolled, "the key code");
        Assert.Equal(ApproveMessage.Fingerprint(spki), rig.Model.Phase.Text);
        Assert.Equal(rig.Model.Phase.Text, rig.Model.KeyFor(rig.Computer.Id)?.Code);
        Assert.Equal(enroll, rig.Model.Shown); // the prompt shows the code until the user closes it
        Assert.Null(rig.Model.Current);
        Assert.Equal(ApproveOutcome.Enrolled, rig.Outcome("e1"));
        Assert.DoesNotContain("approve", rig.Notes.Current.Keys); // the notification goes
        rig.Ui(rig.Plugin.CloseResult);
        await Wait.UntilAsync(() => rig.Model.Shown is null, "the closed prompt");

        var request = await rig.AskAsync("r1");
        Assert.Equal("Approve sudo on omarchy-xps?", rig.Notes.Current["approve"].Title);
        Assert.StartsWith("Approve sudo for user alice on host omarchy-xps?\nTerminal: /dev/pts/3\nAsked at ", rig.Notes.Current["approve"].Body);
        rig.Ui(rig.Plugin.Approve);
        var approved = await rig.AnswerAsync("r1");
        Assert.Equal("response", approved.String("kind"));
        var signature = Convert.FromBase64String(approved.String("signature")!);
        Assert.True(ApproveExpect.Verify(spki, ApproveExpect.Approval("omarchy-xps", "alice", "sudo", "/dev/pts/3", "", request.Time, ApproveMessageTests.Nonce), signature));
        await Wait.UntilAsync(() => rig.Outcome("r1") == ApproveOutcome.Approved, "the approved outcome");
        Assert.Null(rig.Model.Shown); // an approval closes the prompt
        Assert.Equal(2, rig.Signer.Checks);
        Assert.Equal(2, rig.Signer.Signatures);
        Assert.Single(rig.Signer.Names); // 1 key for the computer
        Assert.True(rig.Presented >= 2);
    }

    [Fact]
    public async Task DenySendsADenial()
    {
        using var rig = await ApproveRig.StartAsync(36040);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Ui(rig.Plugin.Deny);
        var answer = await rig.AnswerAsync("r1");
        Assert.True(answer.Bool("denied"));
        Assert.Null(answer.String("signature"));
        await Wait.UntilAsync(() => rig.Outcome("r1") == ApproveOutcome.Denied, "the denied outcome");
        Assert.Equal(1, rig.Signer.Checks); // only the enrollment asked
    }

    // A request that breaks a rule fails at once with the reason. The prompt
    // does not open, and the history keeps the refusal.
    [Fact]
    public async Task RefusesBadRequests()
    {
        using var rig = await ApproveRig.StartAsync(36080);
        rig.Computer.Send(ApproveMessageTests.RequestPacket(("id", "bad"), ("user", "alice\nservice=sshd")));
        Assert.Equal(ApproveTexts.NotValid, (await rig.AnswerAsync("bad")).String("error"));
        rig.Computer.Send(ApproveRig.Packet("old", time: ApproveRig.Now - 601));
        Assert.Equal(ApproveTexts.ClockSkew, (await rig.AnswerAsync("old")).String("error"));
        rig.Computer.Send(ApproveRig.Packet("nokey"));
        Assert.Equal(ApproveTexts.NoKey, (await rig.AnswerAsync("nokey")).String("error"));
        Assert.Null(rig.Model.Current);
        Assert.Equal(0, rig.Presented);

        await rig.AskAsync("e1", ApproveKind.Enroll);
        rig.Computer.Send(ApproveRig.Packet("e2", ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.AnotherOpen, (await rig.AnswerAsync("e2")).String("error"));
        Assert.Equal("e1", rig.Model.Current?.Id); // the open request stays
        Assert.Equal(ApproveOutcome.Refused(ApproveTexts.NotValid), rig.Outcome("bad"));
        Assert.Equal(ApproveTexts.NotValidSummary, rig.Model.History.Single(r => r.RequestId == "bad").Summary);
        Assert.Equal(ApproveOutcome.Refused(ApproveTexts.AnotherOpen), rig.Outcome("e2"));
        Assert.Equal(0, rig.Signer.Checks);

        // The same request again only brings the prompt to the front.
        var before = rig.Presented;
        rig.Computer.Send(ApproveRig.Packet("e1", ApproveKind.Enroll));
        await Wait.UntilAsync(() => rig.Presented > before, "the prompt in front");
        Assert.Empty(rig.Answers("e1"));
    }

    // Without Windows Hello, Flux makes no key and refuses each request.
    [Fact]
    public async Task NoSecureHardwareRefusesEachRequest()
    {
        using var rig = await ApproveRig.StartAsync(36120);
        rig.Signer.HasSecureHardware = false;
        rig.Computer.Send(ApproveRig.Packet("e1", ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.NoSecureHardware, (await rig.AnswerAsync("e1")).String("error"));
        Assert.Empty(rig.Signer.Names);
    }

    // The computer ends the request, also while Windows Hello asks. The
    // prompt of Windows Hello closes, and nothing goes out.
    [Fact]
    public async Task TheComputerCancels()
    {
        using var rig = await ApproveRig.StartAsync(36160);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Computer.Send(new Packet(PacketType.Approve, new JsonObject { ["kind"] = "cancel", ["id"] = "r1" }));
        await Wait.UntilAsync(() => rig.Outcome("r1") == ApproveOutcome.Cancelled, "the cancelled outcome");
        Assert.Null(rig.Model.Shown);
        Assert.DoesNotContain("approve", rig.Notes.Current.Keys);

        rig.Signer.Hold = new TaskCompletionSource();
        rig.Signer.ResetCheckStarted();
        await rig.AskAsync("r2");
        rig.Ui(rig.Plugin.Approve);
        await rig.Signer.CheckStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(ApprovePhase.Working, rig.Model.Phase);
        rig.Computer.Send(new Packet(PacketType.Approve, new JsonObject { ["kind"] = "cancel", ["id"] = "r2" }));
        await Wait.UntilAsync(() => rig.Outcome("r2") == ApproveOutcome.Cancelled, "the cancelled outcome while Windows Hello asks");
        await Task.Delay(300);
        Assert.Equal(1, rig.Signer.Signatures); // only the enrollment signed
        Assert.Empty(rig.Answers("r2"));
        Assert.Equal(ApprovePhase.Ask, rig.Model.Phase);
    }

    // The countdown goes down once a second, and the request ends at the
    // timeout of the computer. This computer sends nothing then, because the
    // computer stopped its wait.
    [Fact]
    public async Task TheRequestExpires()
    {
        using var rig = await ApproveRig.StartAsync(36200, second: TimeSpan.FromMilliseconds(200));
        await rig.AskAsync("e1", ApproveKind.Enroll, timeout: 5);
        Assert.Equal("Expires in 5 s", rig.Model.ExpiresText);
        Assert.NotNull(rig.Model.Deadline);
        await Wait.UntilAsync(() => rig.Model.SecondsLeft is > 0 and < 5, "the countdown");
        await Wait.UntilAsync(() => rig.Outcome("e1") == ApproveOutcome.Expired, "the expired outcome");
        Assert.Null(rig.Model.Current);
        Assert.Equal(0, rig.Model.SecondsLeft);
        Assert.Null(rig.Model.ExpiresText);
        Assert.Null(rig.Model.Deadline);
        Assert.Empty(rig.Answers("e1"));
        Assert.DoesNotContain("approve", rig.Notes.Current.Keys);
    }

    // A user who closes Windows Hello gets the prompt again. The request
    // stays open, and nothing goes out.
    [Fact]
    public async Task ACancelOfWindowsHelloAsksAgain()
    {
        using var rig = await ApproveRig.StartAsync(36240);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Signer.CheckFails = ApproveKeyError.Cancelled;
        rig.Ui(rig.Plugin.Approve);
        await Wait.UntilAsync(() => rig.Signer.Checks == 2 && rig.Model.Phase == ApprovePhase.Ask, "the prompt again");
        Assert.Equal("r1", rig.Model.Current?.Id);
        Assert.Empty(rig.Answers("r1"));
        rig.Signer.CheckFails = null;
        rig.Ui(rig.Plugin.Approve);
        Assert.NotNull((await rig.AnswerAsync("r1")).String("signature"));
    }

    // A failed user check goes to the computer with its reason. The prompt
    // shows the failure until the user closes it.
    [Fact]
    public async Task FailuresGoToTheComputer()
    {
        using var rig = await ApproveRig.StartAsync(36280);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Signer.CheckFails = ApproveKeyError.NotRecognized;
        rig.Ui(rig.Plugin.Approve);
        Assert.Equal(ApproveTexts.NotRecognized, (await rig.AnswerAsync("r1")).String("error"));
        await Wait.UntilAsync(() => rig.Model.Phase == ApprovePhase.Failed(ApproveTexts.NotRecognized), "the failure in the prompt");
        Assert.NotNull(rig.Model.Shown);
        Assert.Equal(ApproveOutcome.Failed(ApproveTexts.NotRecognized), rig.Outcome("r1"));
        rig.Ui(rig.Plugin.CloseResult);
        await Wait.UntilAsync(() => rig.Model.Shown is null && rig.Model.Phase == ApprovePhase.Ask, "the closed prompt");

        // Windows Hello that is not set up fails before the platform asks.
        rig.Signer.CheckFails = null;
        rig.Signer.UserCheck = ApproveUserCheck.NotSetUp;
        await rig.AskAsync("r2");
        rig.Ui(rig.Plugin.Approve);
        Assert.Equal(ApproveTexts.NotSetUp, (await rig.AnswerAsync("r2")).String("error"));
        Assert.Equal(2, rig.Signer.Checks);
    }

    // A key that the platform lost goes, and the user enrolls again.
    [Fact]
    public async Task AnInvalidKeyGoes()
    {
        using var rig = await ApproveRig.StartAsync(36320);
        await rig.EnrollAsync();
        rig.Signer.Lose(rig.Signer.Names.Single());
        await rig.AskAsync("r1");
        rig.Ui(rig.Plugin.Approve);
        Assert.Equal(ApproveTexts.KeyInvalid, (await rig.AnswerAsync("r1")).String("error"));
        await Wait.UntilAsync(() => rig.Model.Keys.Count == 0, "the removed key");
        rig.Computer.Send(ApproveRig.Packet("r2"));
        Assert.Equal(ApproveTexts.NoKey, (await rig.AnswerAsync("r2")).String("error"));
    }

    // A signature that does not verify with the stored key does not go out.
    [Fact]
    public async Task ASignatureInAnotherFormatFails()
    {
        using var rig = await ApproveRig.StartAsync(36360);
        await rig.EnrollAsync();
        rig.Signer.WrongFormat = true;
        await rig.AskAsync("r1");
        rig.Ui(rig.Plugin.Approve);
        var answer = await rig.AnswerAsync("r1");
        Assert.Equal(ApproveTexts.UseFailed, answer.String("error"));
        Assert.Null(answer.String("signature"));

        // A new key whose proof does not verify goes, and no key is stored.
        await rig.AskAsync("e2", ApproveKind.Enroll);
        rig.Ui(rig.Plugin.Approve);
        Assert.Equal(ApproveTexts.MakeFailed, (await rig.AnswerAsync("e2")).String("error"));
        Assert.Single(rig.Signer.Names); // the first key stays, the new key goes
        Assert.Single(rig.Model.Keys);
    }

    // A failed enrollment keeps the old key. A new enrollment says that it
    // replaces the key, and the old key goes in the platform after the commit.
    [Fact]
    public async Task AnEnrollmentReplacesTheKeyOnlyAfterItWorks()
    {
        using var rig = await ApproveRig.StartAsync(36400);
        var first = await rig.EnrollAsync("e1");
        var firstName = rig.Signer.Names.Single();

        var again = await rig.AskAsync("e2", ApproveKind.Enroll);
        Assert.True(rig.Plugin.ReplacesKey(again));
        Assert.EndsWith("This replaces the current approval key for omarchy-xps.", rig.Notes.Current["approve"].Body);
        rig.Signer.CheckFails = ApproveKeyError.NotRecognized;
        rig.Ui(rig.Plugin.Approve);
        Assert.Equal(ApproveTexts.NotRecognized, (await rig.AnswerAsync("e2")).String("error"));
        await Wait.UntilAsync(() => rig.Signer.Deleted.Count == 1, "the deleted new key");
        Assert.Equal([firstName], rig.Signer.Names); // the old key stays
        Assert.Equal(Convert.ToBase64String(first), rig.Model.KeyFor(rig.Computer.Id)?.PublicKey);

        rig.Signer.CheckFails = null;
        rig.Ui(rig.Plugin.CloseResult);
        var second = await rig.EnrollAsync("e3");
        Assert.NotEqual(first, second);
        Assert.DoesNotContain(firstName, rig.Signer.Names); // the commit deletes the old key
        Assert.Contains(firstName, rig.Signer.Deleted);
        Assert.Single(rig.Signer.Names);
        Assert.Single(rig.Model.Keys);
    }

    // The request ends while Windows Hello asks: the new key of the
    // enrollment goes, and nothing goes out.
    [Fact]
    public async Task ALateEnrollmentDropsItsKey()
    {
        using var rig = await ApproveRig.StartAsync(36440);
        rig.Signer.Hold = new TaskCompletionSource();
        await rig.AskAsync("e1", ApproveKind.Enroll);
        rig.Ui(rig.Plugin.Approve);
        await rig.Signer.CheckStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Single(rig.Signer.Names);
        rig.Computer.Send(new Packet(PacketType.Approve, new JsonObject { ["kind"] = "cancel", ["id"] = "e1" }));
        await Wait.UntilAsync(() => rig.Signer.Names.Count == 0, "the deleted new key");
        Assert.Empty(rig.Answers("e1"));
        Assert.Empty(rig.Model.Keys);
        Assert.Equal(ApproveOutcome.Cancelled, rig.Outcome("e1"));
    }

    // An unpair from the computer ends the open request. The key stays, as in
    // the Mac app.
    [Fact]
    public async Task AnUnpairFromTheComputerEndsTheRequest()
    {
        using var rig = await ApproveRig.StartAsync(36480);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Computer.Send(new Packet(PacketType.Pair, new JsonObject { ["pair"] = false }));
        await Wait.UntilAsync(() => rig.Outcome("r1") == ApproveOutcome.Unpaired, "the unpaired outcome");
        Assert.Null(rig.Model.Shown);
        Assert.Single(rig.Model.Keys);
    }

    // An unpair on this computer deletes the key of the computer, also in
    // the platform, so that a new pairing needs a new enrollment.
    [Fact]
    public async Task AnUnpairOnThisComputerDeletesTheKey()
    {
        using var rig = await ApproveRig.StartAsync(36520);
        await rig.EnrollAsync();
        var name = rig.Signer.Names.Single();
        await rig.AskAsync("r1");
        rig.Ui(() => rig.Plugin.Unpair(rig.Computer.Id));
        await Wait.UntilAsync(() => rig.Model.Keys.Count == 0 && rig.Outcome("r1") == ApproveOutcome.Unpaired, "the deleted key");
        Assert.Contains(name, rig.Signer.Deleted);
        Assert.Empty(rig.Signer.Names);
        await Wait.UntilAsync(() => rig.Computer.Got(PacketType.Pair).Any(p => p.Bool("pair") == false), "the unpair on the computer");
        Assert.Null(rig.T.Core.Trust.Get(rig.Computer.Id));
    }

    // Remove Key deletes the key in the store and in the platform.
    [Fact]
    public async Task RemoveKeyDeletesTheKey()
    {
        using var rig = await ApproveRig.StartAsync(36560);
        await rig.EnrollAsync();
        rig.Ui(() => rig.Plugin.RemoveKey(rig.Computer.Id));
        await Wait.UntilAsync(() => rig.Model.Keys.Count == 0 && rig.Signer.Names.Count == 0, "the removed key");
        rig.Computer.Send(ApproveRig.Packet("r1"));
        Assert.Equal(ApproveTexts.NoKey, (await rig.AnswerAsync("r1")).String("error"));
    }

    // The buttons of the notification: Deny denies, and Approve asks Windows
    // Hello at once.
    [Fact]
    public async Task TheNotificationActions()
    {
        using var rig = await ApproveRig.StartAsync(36600);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        var note = rig.Notes.Current["approve"];
        Assert.Equal(ApprovePlugin.NotificationCategory, note.Category);
        rig.T.Core.Host.Notifier.Activate(note.Category, "deny", note.UserInfo);
        Assert.True((await rig.AnswerAsync("r1")).Bool("denied"));

        await rig.AskAsync("r2");
        note = rig.Notes.Current["approve"];
        // An action for another request does nothing.
        rig.T.Core.Host.Notifier.Activate(note.Category, "deny", new Dictionary<string, string> { ["id"] = "r1" });
        rig.T.Core.Host.Notifier.Activate(note.Category, "approve", note.UserInfo);
        Assert.NotNull((await rig.AnswerAsync("r2")).String("signature"));
        Assert.Equal(2, rig.Signer.Checks);
    }

    // Windows Hello makes RSA 2048 keys that sign with RSASSA-PKCS1-v1_5.
    // The keys take the 2 names of the computer in turn, and the commit of a
    // new key deletes the old key. A signature with PSS does not go out.
    [Fact]
    public async Task EnrollsAndApprovesWithAWindowsHelloKey()
    {
        using var rig = await ApproveRig.StartAsync(36710);
        rig.Signer.Rsa = true;
        var id = rig.Computer.Id;
        var first = await rig.EnrollAsync("e1");
        Assert.True(ApproveExpect.IsRsa(first));
        Assert.Equal([ApproveKeyNames.First(id)], rig.Signer.Names);

        var request = await rig.AskAsync("r1");
        rig.Ui(rig.Plugin.Approve);
        var signature = Convert.FromBase64String((await rig.AnswerAsync("r1")).String("signature")!);
        Assert.Equal(256, signature.Length);
        Assert.True(ApproveExpect.Verify(first, ApproveExpect.Approval("omarchy-xps", "alice", "sudo", "/dev/pts/3", "", request.Time, ApproveMessageTests.Nonce), signature));
        await Wait.UntilAsync(() => rig.Outcome("r1") == ApproveOutcome.Approved, "the approved outcome");

        var second = await rig.EnrollAsync("e2");
        Assert.NotEqual(first, second);
        await Wait.UntilAsync(() => rig.Signer.Deleted.Contains(ApproveKeyNames.First(id)), "the deleted first key");
        Assert.Equal([ApproveKeyNames.Second(id)], rig.Signer.Names);
        await rig.EnrollAsync("e3");
        await Wait.UntilAsync(() => rig.Signer.Deleted.Contains(ApproveKeyNames.Second(id)), "the deleted second key");
        Assert.Equal([ApproveKeyNames.First(id)], rig.Signer.Names);

        rig.Signer.WrongFormat = true;
        await rig.AskAsync("r2");
        rig.Ui(rig.Plugin.Approve);
        var answer = await rig.AnswerAsync("r2");
        Assert.Equal(ApproveTexts.UseFailed, answer.String("error"));
        Assert.Null(answer.String("signature"));
    }

    // A link that only drops leaves the request open, because the computer
    // can connect again before the request expires.
    [Fact]
    public async Task ALinkDropLeavesTheRequest()
    {
        using var rig = await ApproveRig.StartAsync(36640);
        await rig.EnrollAsync();
        await rig.AskAsync("r1");
        rig.Computer.Disconnect();
        await Wait.UntilAsync(() => rig.Computer.Snapshot(rig.T) is { Online: false }, "the dropped link");
        await Task.Delay(200);
        Assert.Equal("r1", rig.Model.Current?.Id);
        await rig.Computer.ReconnectAsync(rig.T);
        rig.Ui(rig.Plugin.Approve);
        Assert.NotNull((await rig.AnswerAsync("r1")).String("signature"));
    }

    // The keys of the model come from the store at the start, and a new start
    // drops the new key that an enrollment left.
    [Fact]
    public async Task TheKeysSurviveARestart()
    {
        string data;
        string computerId;
        string name;
        using (var rig = await ApproveRig.StartAsync(36680))
        {
            await rig.EnrollAsync();
            computerId = rig.Computer.Id;
            name = rig.Signer.Names.Single();
            data = CoreTests.TempDir();
            CopyDirectory(Path.Combine(rig.T.Data, "approve"), Path.Combine(data, "approve"));
        }
        File.WriteAllText(Path.Combine(data, "approve", computerId + ".pending"),
            new JsonObject { ["key"] = "left", ["publicKey"] = "AA==", ["host"] = "h", ["user"] = "u", ["enrolled"] = 1 }.ToJsonString());
        using var signer = new ApproveSoftwareSigner();
        var plugin = new ApprovePlugin(signer);
        using var core = new SystemPluginCore([plugin], data);
        Assert.Equal([computerId], plugin.Model.Keys.Select(k => k.ComputerId));
        Assert.Equal(["left"], signer.Deleted);
        Assert.False(File.Exists(Path.Combine(data, "approve", computerId + ".pending")));
        Assert.NotEqual("", name);
    }

    static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from))
        {
            File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
        }
    }
}
