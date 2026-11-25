using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// ApprovePluginLogicTests.swift of the Mac app: the decisions of
// ApprovePlugin that need no key: which request it refuses, where a
// notification action goes, and whether this computer can approve at all.
public class ApprovePluginLogicTests
{
    static ApproveRequest Request(ApproveKind kind = ApproveKind.Approve, long time = 1_790_000_000) =>
        new("pc1", "omarchy-xps", "req1", kind, "omarchy-xps", "alice", kind == ApproveKind.Approve ? "sudo" : "", "", "",
            time, ApproveMessageTests.Nonce, 20);

    static string? Refusal(ApproveRequest? r, long now = 1_790_000_010, bool hasKey = true, bool busy = false, bool secureHardware = true) =>
        ApprovePlugin.Refusal(r, now, hasKey, busy, secureHardware);

    [Fact]
    public void Refusals()
    {
        Assert.Null(Refusal(Request())); // a fresh request with a key opens the prompt
        Assert.Null(Refusal(Request(ApproveKind.Enroll), hasKey: false)); // an enrollment needs no key
        Assert.Equal("The request is not valid", Refusal(null));
        Assert.Equal(ApproveTexts.ClockSkew, Refusal(Request(), now: 1_790_000_000 + 601));
        Assert.Equal(ApproveTexts.ClockSkew, Refusal(Request(), now: 1_790_000_000 - 601));
        Assert.Equal(ApproveTexts.NoKey, Refusal(Request(), hasKey: false));
        Assert.Equal(ApproveTexts.AnotherOpen, Refusal(Request(), busy: true));
    }

    // Without Windows Hello, no request opens the prompt, and the computer
    // learns why at once. Flux never makes a key outside Windows Hello.
    [Fact]
    public void NoSecureHardwareRefusesEveryRequest()
    {
        Assert.Equal(ApproveTexts.NoSecureHardware, Refusal(Request(ApproveKind.Enroll), hasKey: false, secureHardware: false));
        Assert.Equal(ApproveTexts.NoSecureHardware, Refusal(Request(), hasKey: false, secureHardware: false)); // the missing Windows Hello explains the missing key
        Assert.Equal("The request is not valid", Refusal(null, secureHardware: false));
    }

    // Only the computer of the open request can cancel it, as in the Android
    // app.
    [Fact]
    public void OnlyTheComputerOfTheRequestCancelsIt()
    {
        var plugin = new ApprovePlugin(new ApproveSoftwareSigner());
        plugin.Model.Current = Request();
        var cancel = new Packet(PacketType.Approve, new JsonObject { ["kind"] = "cancel", ["id"] = "req1" });
        plugin.Receive(cancel, "pc2", "other");
        Assert.Equal("req1", plugin.Model.Current?.Id); // another computer cannot close the request
        plugin.Receive(cancel, "pc1", "omarchy-xps");
        Assert.Null(plugin.Model.Current);
    }

    // An unpair ends the open request of the computer, so that it does not
    // stay on the screen or refuse the requests of other computers.
    [Fact]
    public void AnUnpairEndsTheRequestOfTheComputer()
    {
        var plugin = new ApprovePlugin(new ApproveSoftwareSigner());
        plugin.Model.Current = Request();
        plugin.Model.Shown = Request();
        plugin.Unpaired("pc2");
        Assert.Equal("req1", plugin.Model.Current?.Id); // the unpair of another computer leaves the request
        plugin.Unpaired("pc1");
        Assert.Null(plugin.Model.Current);
        Assert.Null(plugin.Model.Shown); // the prompt closes
    }

    // An enrollment that replaces the current key says so.
    [Fact]
    public void AnEnrollmentThatReplacesAKeySaysSo()
    {
        const string replaces = "This replaces the current approval key for omarchy-xps.";
        Assert.DoesNotContain(replaces, ApprovePlugin.Details(Request(ApproveKind.Enroll)));
        Assert.Equal(replaces, ApprovePlugin.Details(Request(ApproveKind.Enroll), replacesKey: true)[^1]);
        Assert.DoesNotContain(replaces, ApprovePlugin.Details(Request(), replacesKey: true)); // an approval has no such line

        var plugin = new ApprovePlugin(new ApproveSoftwareSigner());
        Assert.False(plugin.ReplacesKey(Request(ApproveKind.Enroll)));
        plugin.Model.Keys = ValueList.From(new[] { new ApproveKeyInfo("pc1", "omarchy-xps", "alice", "AA==", DateTimeOffset.Now) });
        Assert.True(plugin.ReplacesKey(Request(ApproveKind.Enroll)));
        Assert.False(plugin.ReplacesKey(Request()));
    }

    // The details of an approval name the terminal and the remote host only
    // when the computer sent them.
    [Fact]
    public void TheDetailsOfAnApproval()
    {
        var plain = ApprovePlugin.Details(Request());
        Assert.Single(plain);
        Assert.StartsWith("Asked at ", plain[0]);
        Assert.EndsWith(" by omarchy-xps", plain[0]);
        var full = ApprovePlugin.Details(Request() with { Tty = "/dev/pts/3", Rhost = "10.0.0.2" });
        Assert.Equal(["Terminal: /dev/pts/3", "From: 10.0.0.2"], full.Take(2));
        // A time after the year 9999 does not throw.
        Assert.EndsWith("by omarchy-xps", ApprovePlugin.Details(Request(time: 1L << 40))[^1]);
    }

    // Approve in the notification asks for Windows Hello at once, as on the
    // Mac.
    [Fact]
    public void NotificationRoutes()
    {
        Assert.Equal(ApprovePlugin.NotificationRoute.Approve, ApprovePlugin.Route("approve"));
        Assert.Equal(ApprovePlugin.NotificationRoute.Deny, ApprovePlugin.Route("deny"));
        Assert.Equal(ApprovePlugin.NotificationRoute.Present, ApprovePlugin.Route(Notifier.DefaultAction));
        Assert.Equal(ApprovePlugin.NotificationRoute.Present, ApprovePlugin.Route("other"));
    }

    [Fact]
    public void NotificationActions()
    {
        Assert.Equal(["approve", "deny"], ApprovePlugin.NotificationActions.Select(a => a.Id));
        Assert.Equal(["Approve", "Deny"], ApprovePlugin.NotificationActions.Select(a => a.Title));
        Assert.All(ApprovePlugin.NotificationActions, a => Assert.False(a.TextInput));
    }

    [Fact]
    public void Availability()
    {
        Assert.Equal(ApproveAvailability.Ready, ApprovePlugin.Availability(true, null));
        Assert.Equal(new ApproveAvailability(ApproveAvailabilityKind.NoSecureHardware, ApproveTexts.NoSecureHardware), ApprovePlugin.Availability(false, null));
        // Without Windows Hello, no other check matters, so it comes first.
        Assert.Equal(ApproveAvailabilityKind.NoSecureHardware, ApprovePlugin.Availability(false, ApproveTexts.NotSetUp).Kind);
        Assert.Equal(new ApproveAvailability(ApproveAvailabilityKind.UserCheck, ApproveTexts.NotSetUp), ApprovePlugin.Availability(true, ApproveTexts.NotSetUp));
    }

    [Fact]
    public async Task AvailabilityAsksThePlatform()
    {
        Assert.Equal(ApproveAvailabilityKind.NoSecureHardware, (await new ApprovePlugin().AvailabilityAsync()).Kind); // without a signer
        using var signer = new ApproveSoftwareSigner();
        var plugin = new ApprovePlugin(signer);
        Assert.Equal(ApproveAvailability.Ready, await plugin.AvailabilityAsync());
        signer.UserCheck = ApproveUserCheck.LockedOut;
        Assert.Equal(new ApproveAvailability(ApproveAvailabilityKind.UserCheck, ApproveTexts.LockedOut), await plugin.AvailabilityAsync());
        signer.HasSecureHardware = false;
        Assert.Equal(ApproveAvailabilityKind.NoSecureHardware, (await plugin.AvailabilityAsync()).Kind);
    }

    // This computer lists flux.approve only when the app gives a signer, so
    // fluxd does not send a request that nothing can sign.
    [Fact]
    public void ListsTheTypeOnlyWithASigner()
    {
        using var signer = new ApproveSoftwareSigner();
        var with = new ApprovePlugin(signer);
        Assert.Equal([PacketType.Approve], with.Incoming);
        Assert.Equal([PacketType.Approve], with.Outgoing);
        var without = new ApprovePlugin();
        Assert.Empty(without.Incoming);
        Assert.Empty(without.Outgoing);
        Assert.Equal([PacketType.Approve], ((IFluxPlugin)without).HandledTypes);
    }

    [Fact]
    public void OutcomeTexts()
    {
        Assert.Equal("Waiting", ApproveOutcome.Open.Text);
        Assert.Equal("Approved", ApproveOutcome.Approved.Text);
        Assert.Equal("Enrolled", ApproveOutcome.Enrolled.Text);
        Assert.Equal("Denied", ApproveOutcome.Denied.Text);
        Assert.Equal("Failed: x", ApproveOutcome.Failed("x").Text);
        Assert.Equal("Refused: x", ApproveOutcome.Refused("x").Text);
        Assert.Equal("Cancelled by the computer", ApproveOutcome.Cancelled.Text);
        Assert.Equal("Timed out", ApproveOutcome.Expired.Text);
        Assert.Equal("Ended by the unpair", ApproveOutcome.Unpaired.Text);
    }

    // The history keeps the 20 newest requests, the newest first.
    [Fact]
    public void TheHistoryKeepsTheNewest()
    {
        var plugin = new ApprovePlugin(new ApproveSoftwareSigner());
        for (var i = 0; i < 25; i++)
        {
            plugin.Model.Record(new ApproveRecord(Guid.NewGuid(), $"r{i}", "pc1", ApproveKind.Approve, "q", DateTimeOffset.Now, ApproveOutcome.Open));
        }
        Assert.Equal(20, plugin.Model.History.Count);
        Assert.Equal("r24", plugin.Model.History[0].RequestId);
        plugin.Model.Resolve("r24", ApproveOutcome.Denied);
        Assert.Equal(ApproveOutcome.Denied, plugin.Model.History[0].Outcome);
        Assert.NotNull(plugin.Model.History[0].Resolved);
        plugin.Model.Resolve("r24", ApproveOutcome.Approved);
        Assert.Equal(ApproveOutcome.Denied, plugin.Model.History[0].Outcome); // an ended request keeps its outcome
    }
}
