using FluxKit;

namespace FluxKit.Tests;

// ApproveTextTests.swift of the Mac app: the Mac texts with "this computer"
// for "this Mac", and Windows Hello for Touch ID and the Secure Enclave.
// Windows has 1 user check, so the tests of the biometry names and symbols
// of the Mac and the iPhone become the tests of the Windows Hello texts.
public class ApproveTextTests
{
    [Fact]
    public void TheTextsOfThisComputer()
    {
        Assert.Equal("this computer", ApproveTexts.DeviceNoun);
        Assert.Equal("Windows Hello", ApproveTexts.UserCheck);
        Assert.Equal("The clocks of this computer and the computer differ by more than 10 minutes", ApproveTexts.ClockSkew);
        Assert.Equal("This computer has no key for the computer. Run: sudo flux-cli approve enroll", ApproveTexts.NoKey);
        Assert.Equal("Another request is open on this computer", ApproveTexts.AnotherOpen);
        Assert.Equal("Enroll this computer on omarchy-xps?", ApproveTexts.EnrollTitle("omarchy-xps"));
        Assert.Equal("Flux makes a key for roger in Windows Hello on this computer. Each approval then needs Windows Hello: a fingerprint, a face, or the PIN.",
            ApproveTexts.EnrollDetail("roger"));
        Assert.Equal("This replaces the current approval key for roger.", ApproveTexts.EnrollReplaces("roger"));
        Assert.Equal("Use this computer to approve sudo for user alice on host omarchy-xps?", ApproveTexts.EnrollQuestion("alice", "omarchy-xps"));
        Assert.Equal("enroll this computer to approve sudo for alice on omarchy-xps", ApproveTexts.EnrollReason("alice", "omarchy-xps"));
        Assert.Equal("approve sudo for alice on omarchy-xps", ApproveTexts.ApproveReason(ApproveMessageTests.Request));
        Assert.Equal("Windows Hello on this computer no longer has the approval key. Enroll again with: sudo flux-cli approve enroll", ApproveTexts.KeyInvalid);
        Assert.Equal("This computer could not save its approval key.", ApproveTexts.SaveFailed);
        Assert.Equal("Set up Windows Hello in Settings > Accounts > Sign-in options first.", ApproveTexts.NotSetUp);
        Assert.Equal("Windows Hello is locked. Unlock this computer with the password first.", ApproveTexts.LockedOut);
        Assert.Equal("Windows Hello is not available on this computer.", ApproveTexts.Unavailable);
        Assert.Equal("Windows Hello did not recognize you.", ApproveTexts.NotRecognized);
        Assert.Equal("This computer is locked, so it cannot use its approval key.", ApproveTexts.DeviceLocked);
        Assert.Equal("This computer could not make its approval key.", ApproveTexts.MakeFailed);
        Assert.Equal("This computer could not use its approval key.", ApproveTexts.UseFailed);
        Assert.Equal("The new key did not reach roger. The old key stays.", ApproveTexts.NotReached("roger", true));
        Assert.Equal("The new key did not reach roger.", ApproveTexts.NotReached("roger", false));
    }

    // docs/approvals.md: a Windows computer without Windows Hello refuses
    // each request, and the Windows Hello PIN can approve.
    [Fact]
    public void TheWindowsHelloTexts()
    {
        Assert.Equal("This computer has no Windows Hello, so it cannot keep an approval key. Set up a PIN in Settings > Accounts > Sign-in options.",
            ApproveTexts.NoSecureHardware);
        Assert.Equal("The Windows Hello PIN can approve too. Anyone who knows the PIN can approve at this computer.", ApproveTexts.PinNote);
        Assert.Equal("Windows Hello Approval", ApproveTexts.SectionTitle);
        foreach (var text in typeof(ApproveTexts).GetFields().Where(f => f.IsLiteral).Select(f => (string)f.GetRawConstantValue()!))
        {
            Assert.DoesNotContain("TPM", text);
            Assert.DoesNotContain("Touch ID", text);
            Assert.DoesNotContain("this Mac", text);
        }
    }

    // The hint while Windows Hello runs. An enrollment asks 2 times.
    [Fact]
    public void TheHintsWhileWindowsHelloRuns()
    {
        Assert.Equal("Confirm with Windows Hello.", ApproveTexts.Working);
        Assert.Equal("Confirm with Windows Hello 2 times: to make the key, and to sign with it.", ApproveTexts.EnrollWorking);
    }

    [Fact]
    public void TheTitlesOfTheNotification()
    {
        Assert.Equal("Approve sudo on omarchy-xps?", ApproveTexts.Title(ApproveMessageTests.Request));
        Assert.Equal("Enroll this computer on omarchy-xps?", ApproveTexts.Title(ApproveMessageTests.Request with { Kind = ApproveKind.Enroll }));
    }

    // The terminal asks for the code, so the prompt does not tell the user to
    // type y, see docs/approvals.md.
    [Fact]
    public void ThePromptAsksForTheCode()
    {
        Assert.Equal("Type this code in the terminal, all 16 characters.", ApproveTexts.EnrolledHint);
        Assert.DoesNotContain("type y", ApproveTexts.EnrolledHint);
        Assert.Equal("Expires in 7 s", ApproveTexts.Expires(7));
        Assert.Equal("Approve only if you just typed the command.", ApproveTexts.ApproveHint);
        Assert.Equal("The computer asks for the password.", ApproveTexts.FailedHint);
        Assert.Equal("Flux Approval", ApproveTexts.PromptTitle);
    }

    [Fact]
    public void TheUnpairDialogNamesTheKey()
    {
        Assert.Equal("This computer deletes its approval key for roger. The key file on the computer stays until you run: sudo flux-cli approve remove",
            ApproveTexts.UnpairNote("roger"));
        Assert.Equal("Remove the approval key for roger?", ApproveTexts.RemoveKeyQuestion("roger"));
        Assert.Equal("This computer can no longer approve requests of roger. Run sudo flux-cli approve remove on roger to delete its key file too.",
            ApproveTexts.RemoveKeyDetail("roger"));
    }

    // The texts of the approval card of a computer, as in ApproveSection.swift.
    [Fact]
    public void TheTextsOfTheComputerPage()
    {
        Assert.Equal("Approve sudo, polkit, and the lock screen of roger with Windows Hello on this computer. Run this command on roger, then select Enroll on this computer:",
            ApproveTexts.Setup("roger"));
        Assert.Equal("Approves sudo, polkit, and the lock screen for alice on omarchy-xps.", ApproveTexts.EnrolledFor("alice", "omarchy-xps"));
        Assert.Equal("To enroll again, run sudo flux-cli approve enroll on roger.", ApproveTexts.EnrollAgain("roger"));
        Assert.Equal("Approve sudo Request…", ApproveTexts.MenuTitle(ApproveMessageTests.Request));
        Assert.Equal("Enrollment Request…", ApproveTexts.MenuTitle(ApproveMessageTests.Request with { Kind = ApproveKind.Enroll }));
    }

    // The chat cards of a request and of an answer, as in ChatCards.swift.
    [Fact]
    public void TheTextsOfTheChatCards()
    {
        var r = ApproveMessageTests.Request;
        Assert.Equal("user alice · /dev/pts/3", ApproveTexts.RequestLine(r));
        Assert.Equal("user alice", ApproveTexts.RequestLine(r with { Tty = "" }));
        Assert.Equal("/dev/pts/3", ApproveTexts.RequestLine(r with { User = "" }));

        ApproveRecord Answer(ApproveOutcome outcome, ApproveRequest? request) =>
            new(Guid.NewGuid(), "req1", "pc1", request?.Kind ?? ApproveKind.Approve, "the summary", DateTimeOffset.UnixEpoch, outcome, request,
                DateTimeOffset.UnixEpoch.AddSeconds(5));
        var enroll = r with { Kind = ApproveKind.Enroll, Service = "" };
        Assert.Equal("Approved sudo for alice", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Approved, r)));
        Assert.Equal("Approved sudo", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Approved, r with { User = "" })));
        Assert.Equal("Denied sudo for alice", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Denied, r)));
        Assert.Equal("Enrolled this computer on omarchy-xps", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Enrolled, enroll)));
        Assert.Equal("Denied the enrollment on omarchy-xps", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Denied, enroll)));
        Assert.Equal("the summary", ApproveTexts.AnswerTitle(Answer(ApproveOutcome.Denied, null)));
        Assert.Equal("Approved", ApproveTexts.AnswerState(Answer(ApproveOutcome.Approved, r)));
        Assert.Equal("Enrolled", ApproveTexts.AnswerState(Answer(ApproveOutcome.Enrolled, enroll)));
        Assert.Equal("Denied", ApproveTexts.AnswerState(Answer(ApproveOutcome.Denied, r)));
    }

    // Each failure of the platform has its text. An unknown failure names
    // the step.
    [Fact]
    public void FailuresHaveTexts()
    {
        Assert.Equal(ApproveTexts.NotRecognized, ApproveTexts.Failure(ApproveKeyError.NotRecognized, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.LockedOut, ApproveTexts.Failure(ApproveKeyError.LockedOut, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.NotSetUp, ApproveTexts.Failure(ApproveKeyError.NotSetUp, ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.Unavailable, ApproveTexts.Failure(ApproveKeyError.Unavailable, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.KeyInvalid, ApproveTexts.Failure(ApproveKeyError.KeyInvalid, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.DeviceLocked, ApproveTexts.Failure(ApproveKeyError.DeviceLocked, ApproveKind.Approve));
        Assert.Equal(ApproveTexts.MakeFailed, ApproveTexts.Failure(ApproveKeyError.Failed, ApproveKind.Enroll));
        Assert.Equal(ApproveTexts.UseFailed, ApproveTexts.Failure(ApproveKeyError.Failed, ApproveKind.Approve));
        Assert.Null(ApproveTexts.Problem(ApproveUserCheck.Ready));
        Assert.Equal(ApproveTexts.NotSetUp, ApproveTexts.Problem(ApproveUserCheck.NotSetUp));
        Assert.Equal(ApproveTexts.LockedOut, ApproveTexts.Problem(ApproveUserCheck.LockedOut));
        Assert.Equal(ApproveTexts.Unavailable, ApproveTexts.Problem(ApproveUserCheck.Unavailable));
    }

    // Each text that goes to the computer passes the field rules of fluxd, so
    // that fluxd does not replace it with its own text.
    [Fact]
    public void ErrorTextsPassTheFieldRules()
    {
        foreach (var text in new[]
                 {
                     ApproveTexts.NotValid, ApproveTexts.ClockSkew, ApproveTexts.NoKey, ApproveTexts.AnotherOpen, ApproveTexts.NotConnected,
                     ApproveTexts.KeyInvalid, ApproveTexts.SaveFailed, ApproveTexts.NotSetUp, ApproveTexts.LockedOut, ApproveTexts.Unavailable,
                     ApproveTexts.NotRecognized, ApproveTexts.DeviceLocked, ApproveTexts.MakeFailed, ApproveTexts.UseFailed,
                     ApproveTexts.NoSecureHardware, ApproveTexts.NotReached(new string('x', 32), true),
                 })
        {
            Assert.True(ApproveMessage.ValidField(text), text);
        }
    }

    // The 2 names of the Windows Hello key of a computer take turns, so that
    // a new key never takes the name of the current key.
    [Fact]
    public void TheKeyNamesTakeTurns()
    {
        const string id = "0123456789abcdef0123456789abcdef";
        Assert.Equal("flux-approve-" + id, ApproveKeyNames.First(id));
        Assert.Equal("flux-approve-" + id + ".b", ApproveKeyNames.Second(id));
        Assert.Equal(ApproveKeyNames.First(id), ApproveKeyNames.Next(id, null));
        Assert.Equal(ApproveKeyNames.Second(id), ApproveKeyNames.Next(id, ApproveKeyNames.First(id)));
        Assert.Equal(ApproveKeyNames.First(id), ApproveKeyNames.Next(id, ApproveKeyNames.Second(id)));
        // A key of an earlier build with another name keeps its name.
        Assert.Equal(ApproveKeyNames.First(id), ApproveKeyNames.Next(id, "flux-approve-" + id + "-1f2e"));
    }
}
