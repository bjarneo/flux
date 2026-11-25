using System.Security.Cryptography;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using Flux;
using FluxKit;
using Windows.Security.Credentials;
using static Harness;

// Fingerprint approval with Windows Hello: the prompt window with the
// countdown, Deny, and Approve, the key code of an enrollment, a failure, the
// cards of the open request in the list of chats and in the chat of the
// computer, the answer cards, the section of the
// computer page, the tray panel, the count of the items that need the user,
// and the map of the answers of Windows Hello. The paired sample computer
// has an open sudo request, 2 answers, and a key.
public static class ApproveChecks
{
    public static void Run(Harness h)
    {
        var plugin = h.Core.Plugin<ApprovePlugin>();
        h.Check(plugin is not null, "the approve plugin is in the plugin list");
        if (plugin is null)
        {
            return;
        }
        var window = h.Window;
        var model = h.Model;
        var paired = h.Paired;
        var m = plugin.Model;
        h.ApplyDevices();
        model.WatchEvents();

        using var rsa = RSA.Create(2048);
        var spki = rsa.ExportSubjectPublicKeyInfo();
        var code = ApproveMessage.Fingerprint(spki);
        var request = new ApproveRequest(paired.Id, paired.Name, "r1", ApproveKind.Approve, "omarchy-xps", "alice", "sudo", "/dev/pts/3", "",
            DateTimeOffset.UtcNow.ToUnixTimeSeconds(), new string('0', 64), 20);
        var polkit = request with { Id = "r0", Service = "polkit-1", Tty = "" };
        var earlier = DateTimeOffset.Now.AddMinutes(-5);
        m.Keys = ValueList.From(new[] { new ApproveKeyInfo(paired.Id, "omarchy-xps", "alice", Convert.ToBase64String(spki), earlier.AddDays(-2)) });
        m.History = ValueList.From(new[]
        {
            new ApproveRecord(Guid.NewGuid(), "r1", paired.Id, ApproveKind.Approve, ApproveMessage.Question(request), DateTimeOffset.Now, ApproveOutcome.Open, request),
            new ApproveRecord(Guid.NewGuid(), "r0", paired.Id, ApproveKind.Approve, ApproveMessage.Question(polkit), earlier, ApproveOutcome.Denied, polkit,
                earlier.AddSeconds(3)),
            new ApproveRecord(Guid.NewGuid(), "r9", paired.Id, ApproveKind.Approve, ApproveMessage.Question(request with { Id = "r9" }), earlier.AddMinutes(-1),
                ApproveOutcome.Approved, request with { Id = "r9" }, earlier.AddMinutes(-1).AddSeconds(4)),
        });
        Open(m, request);
        model.OpenChat(new ChatKey.Computer(paired.Id));
        Pump();

        // The list, the chat, and the counts: the open request and the pair request need the user.
        h.Check(Shows(window.Chats, "Approve sudo on omarchy-xps?") && Shows(window.Chats, "Needs approval"), "the list shows the open request");
        h.Check(Buttons(window.Chats).Any(b => AutomationProperties.GetName(b) == "Approve"), "the card of the list keeps Approve in place");
        h.Check(window.CurrentPage is { } page && Shows(page, "Approve sudo on omarchy-xps?"), "the chat of the computer shows the open request");
        h.Check(Shows(window, "user alice · /dev/pts/3"), "the card shows the user and the terminal");
        h.Check(Buttons(window).Any(b => AutomationProperties.GetName(b) == "Deny") && Buttons(window).Any(b => AutomationProperties.GetName(b) == "Approve"),
            "the card shows Deny and Approve");
        h.Check(Shows(window, "Approved sudo for alice") && Shows(window, "Denied polkit-1 for alice"), "the chat shows the answers");
        h.Check(Shows(window, "2 need you"), "the context line counts the approval and the pair request");
        h.Check(Flux.Inbox.NeedsYou(model) == 2, "the count of the items that need the user takes the approval");
        h.Check(model.Seen.ContainsKey($"approve|{paired.Id}|r1"), "the app model keeps the time of the approval");

        // Approve on the card opens the prompt. It does not approve.
        Click(window, "Approve");
        var prompt = ApprovePrompts.Open;
        h.Check(prompt is { IsVisible: true, Topmost: true }, "Approve on the card opens the prompt in front");
        h.Check(m.Phase == ApprovePhase.Ask, "Approve on the card does not approve");
        if (prompt is not null)
        {
            CheckPrompt(h, plugin, prompt, request);
        }

        // The tray panel shows the request as a card and the menu item of the computer.
        Open(m, request with { Id = "r3" });
        Pump();
        var panel = new TrayPanel(model, () => { }, () => { }, () => { });
        panel.Toggle();
        Pump();
        h.Check(Shows(panel, "2 items need you"), "the tray panel counts the approval");
        h.Check(Shows(panel, "Approve sudo on omarchy-xps?"), "the tray panel shows the approval card");
        h.Check(Buttons(panel).Any(b => AutomationProperties.GetName(b) == "Deny"), "the tray card shows Deny");
        h.Check(TrayActions.For(model, paired).Any(a => a.Title == "Approve sudo Request…"), "the menu of the computer shows the request");
        Click(panel, "Deny");
        h.Check(m.Current is null && m.History.Any(r => r.RequestId == "r3" && r.Outcome == ApproveOutcome.Denied), "Deny on the tray card denies");
        panel.Close();
        Pump();
        h.Check(Texts(window).Count(t => t == "Denied sudo for alice") == 2, "the chat shows each new answer");
        h.Check(Flux.Inbox.NeedsYou(model) == 1, "the count drops after the answer");

        // The page of the computer: the key, the PIN note, the requests, and the banner.
        Open(m, request with { Id = "r2" });
        model.Go(Destination.Computers);
        model.Push(new Route.Computer(paired.Id));
        Pump();
        h.Check(Shows(window, "Windows Hello Approval") && Shows(window, "Enrolled"), "the computer page shows the enrolled key");
        h.Check(Shows(window, code), "the computer page shows the key code");
        h.Check(Shows(window, "Approves sudo, polkit, and the lock screen for alice on omarchy-xps."), "the computer page names the user and the host");
        h.Check(Shows(window, ApproveTexts.PinNote), "the computer page tells that the PIN can approve");
        h.Check(Shows(window, "Recent requests") && Shows(window, "Denied"), "the computer page lists the recent requests");
        h.Check(Buttons(window).Any(b => AutomationProperties.GetName(b) == "Remove Key…"), "the computer page shows Remove Key");
        h.Check(Shows(window, "Approve sudo for user alice on host omarchy-xps?") && Buttons(window).Any(b => AutomationProperties.GetName(b) == "Show…"),
            "the computer page shows the banner of the open request");
        h.Check(model.UnpairMessage(paired).EndsWith(ApproveTexts.UnpairNote(paired.Name), StringComparison.Ordinal), "the unpair dialog names the key");
        m.Keys = ValueList<ApproveKeyInfo>.Empty;
        Pump();
        h.Check(Shows(window, "Not set up") && Shows(window, ApproveTexts.SetupCommand), "the computer page shows the setup without a key");
        h.Check(model.UnpairMessage(paired) == $"{paired.Name} and this computer forget each other. Pair again to use it.",
            "the unpair dialog without a key does not name one");
        model.Back();

        // The answers of Windows Hello.
        h.Check(WindowsHelloSigner.ErrorOf(KeyCredentialStatus.Success) is null, "a success of Windows Hello is no error");
        h.Check(WindowsHelloSigner.ErrorOf(KeyCredentialStatus.UserCanceled) == ApproveKeyError.Cancelled &&
                WindowsHelloSigner.ErrorOf(KeyCredentialStatus.UserPrefersPassword) == ApproveKeyError.Cancelled,
            "a closed prompt of Windows Hello asks again");
        h.Check(WindowsHelloSigner.ErrorOf(KeyCredentialStatus.NotFound) == ApproveKeyError.KeyInvalid, "a lost key makes the user enroll again");
        h.Check(WindowsHelloSigner.ErrorOf(KeyCredentialStatus.SecurityDeviceLocked) == ApproveKeyError.LockedOut, "a locked TPM is a lockout");
        h.Check(WindowsHelloSigner.ErrorOf(KeyCredentialStatus.UnknownError) == ApproveKeyError.Failed &&
                WindowsHelloSigner.ErrorOf(KeyCredentialStatus.CredentialAlreadyExists) == ApproveKeyError.Failed,
            "another answer of Windows Hello fails");

        // The scope is empty and nothing stays open.
        ApprovePrompts.Close();
        m.Current = null;
        m.Shown = null;
        m.Phase = ApprovePhase.Ask;
        m.History = ValueList<ApproveRecord>.Empty;
        m.Keys = ValueList<ApproveKeyInfo>.Empty;
        model.SetScope(null);
        model.Go(Destination.Chat);
        Pump();
    }

    // The prompt: the question, the details, the countdown, Deny, and
    // Approve. Enter does not approve, Escape denies, and the key code and a
    // failure stay until the user closes them.
    static void CheckPrompt(Harness h, ApprovePlugin plugin, Window prompt, ApproveRequest request)
    {
        var m = plugin.Model;
        h.Check(Shows(prompt, "Approve sudo for user alice on host omarchy-xps?"), "the prompt shows the question");
        h.Check(Shows(prompt, "Terminal: /dev/pts/3") && Shows(prompt, $"by {h.Paired.Name}"), "the prompt shows the terminal and the computer");
        h.Check(Shows(prompt, ApproveTexts.ApproveHint), "the prompt warns to approve only a typed command");
        h.Check(Shows(prompt, "Expires in 17 s"), "the prompt shows the countdown");
        h.Check(ApprovePrompts.Owner() != IntPtr.Zero, "the prompt gives its window to Windows Hello");
        var approve = Buttons(prompt).FirstOrDefault(b => AutomationProperties.GetName(b) == "Approve");
        h.Check(approve is { IsDefault: false } && !KeyboardNavigation.GetAcceptsReturn(approve), "Enter cannot reach Approve");
        m.SecondsLeft = 16;
        Pump();
        h.Check(Shows(prompt, "Expires in 16 s"), "the countdown goes down");
        h.Check(ReferenceEquals(approve, Buttons(prompt).FirstOrDefault(b => AutomationProperties.GetName(b) == "Approve")),
            "the countdown keeps the buttons, so that the focus stays");
        h.Check(Press(prompt, Key.Enter) && m.Phase == ApprovePhase.Ask && m.Current is not null, "Enter does not approve");
        m.Phase = ApprovePhase.Working;
        Pump();
        h.Check(Shows(prompt, ApproveTexts.Working), "the prompt asks to confirm with Windows Hello");
        h.Check(Buttons(prompt).Any(b => AutomationProperties.GetName(b) == "Approve" && !b.IsEnabled), "Approve is off while Windows Hello asks");
        h.Check(!prompt.Topmost, "the prompt lets Windows Hello come in front while it asks");
        Press(prompt, Key.Escape);
        h.Check(m.Current is null && m.History.Any(r => r.RequestId == "r1" && r.Outcome == ApproveOutcome.Denied), "Escape denies");
        h.Check(ApprovePrompts.Open is null && ApprovePrompts.Owner() == IntPtr.Zero, "the prompt closes when the request ends");

        // An enrollment shows the key code until Done.
        var enroll = request with { Id = "e1", Kind = ApproveKind.Enroll, Service = "" };
        m.Shown = enroll;
        m.Phase = ApprovePhase.Enrolled("ABCD 0123 4567 89EF");
        ApprovePrompts.Show(plugin);
        Pump();
        if (ApprovePrompts.Open is { } result)
        {
            h.Check(Shows(result, ApproveTexts.EnrolledTitle) && Shows(result, "ABCD 0123 4567 89EF"), "the prompt shows the key code");
            h.Check(Shows(result, ApproveTexts.EnrolledHint), "the prompt asks to type the code in the terminal");
            Click(result, "Done");
        }
        h.Check(m.Shown is null && ApprovePrompts.Open is null, "Done closes the key code");

        // A failure stays until the user closes it.
        m.Shown = enroll;
        m.Phase = ApprovePhase.Failed(ApproveTexts.NotSetUp);
        ApprovePrompts.Show(plugin);
        Pump();
        if (ApprovePrompts.Open is { } failed)
        {
            h.Check(Shows(failed, ApproveTexts.NotSetUp) && Shows(failed, ApproveTexts.FailedHint), "the prompt shows the failure");
            Press(failed, Key.Escape);
        }
        h.Check(m.Shown is null && ApprovePrompts.Open is null, "Escape closes the failure");
    }

    // Opens a request in the model, as the plugin does.
    static void Open(ApproveModel m, ApproveRequest r)
    {
        m.Current = r;
        m.Shown = r;
        m.Phase = ApprovePhase.Ask;
        m.Deadline = DateTimeOffset.Now.AddSeconds(17);
        m.SecondsLeft = 17;
        if (!m.History.Any(x => x.RequestId == r.Id))
        {
            m.History = ValueList.From(m.History.Prepend(new ApproveRecord(Guid.NewGuid(), r.Id, r.ComputerId, r.Kind, ApproveMessage.Question(r),
                DateTimeOffset.Now, ApproveOutcome.Open, r)));
        }
    }

    // Presses a key in the window. It returns true when a handler took it.
    static bool Press(Window w, Key key)
    {
        if (PresentationSource.FromVisual(w) is not { } source)
        {
            return false;
        }
        var e = new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        w.RaiseEvent(e);
        Pump();
        return e.Handled;
    }
}
