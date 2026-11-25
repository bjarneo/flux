using Flux;
using FluxKit;
using static Harness;

// The daily features: the clip, the files, the links, the media, the
// commands, and the battery.
public static class DailyChecks
{
    public static void Run(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        var core = h.Core;
        var paired = h.Paired;
        var mpris = core.Plugin<MprisPlugin>()!;
        var playing = new RemoteMedia().Apply(Packet.Parse(
            "{\"id\":1,\"type\":\"flux.mpris\",\"body\":{\"playerList\":[\"spotify\",\"mpv\"]}}")!, MprisPlugin.Now, out _);
        playing = playing.Apply(Packet.Parse(
            "{\"id\":2,\"type\":\"flux.mpris\",\"body\":{\"player\":\"spotify\",\"title\":\"Song\",\"artist\":\"Band\",\"isPlaying\":true,\"pos\":1000,\"length\":200000,\"canSeek\":true,\"volume\":40}}")!,
            MprisPlugin.Now, out _);
        mpris.Model.Devices = mpris.Model.Devices.SetItem(paired.Id, playing);
        core.Plugin<RunCommandPlugin>()!.Model.Lists = core.Plugin<RunCommandPlugin>()!.Model.Lists.SetItem(paired.Id,
            ValueList.From(new[] { new RemoteCommand("a", "Update", "omarchy-update") }));
        core.Plugin<BatteryPlugin>()!.Model.Computers = core.Plugin<BatteryPlugin>()!.Model.Computers.SetItem(paired.Id, new BatteryState(80, true));
        core.Plugin<ClipboardPlugin>()!.Model.Last = ClipEvent.ReceivedFrom(paired.Id, "omarchy-xps", "copied text");
        var share = core.Plugin<SharePlugin>()!;
        share.Model.Record(new SentItem(paired.Id, SentKind.Link, "https://omarchy.org"));
        share.Model.Start(new FileTransfer { DeviceId = paired.Id, Name = "report.pdf", Incoming = true, Size = 2000, Bytes = 500 });
        share.Model.Start(new FileTransfer { DeviceId = paired.Id, Name = "photo.png", Incoming = false, Size = 1000, Bytes = 1000, State = TransferState.Done, Ended = DateTimeOffset.Now });
        Pump();
        model.OpenChat(new ChatKey.Computer(paired.Id));
        Pump();
        h.Check(Shows(window, "copied text"), "the chat shows the clip from the computer");
        h.Check(Shows(window, "https://omarchy.org") && Shows(window, "Link · opened in the browser"), "the chat shows the sent link");
        h.Check(Shows(window, "report.pdf") && Shows(window, "Receiving"), "the chat shows the file that comes in");
        h.Check(Shows(window, "photo.png") && Shows(window, "Sent · "), "the chat shows the sent file");
        h.Check(Shows(window, "connected · 80%, charging"), "the top bar of the chat shows the battery");
        h.Check(Texts(window.Chats).Any(t => t.StartsWith("You: ", StringComparison.Ordinal) || t.StartsWith("Receiving ", StringComparison.Ordinal) ||
                                         t.StartsWith("Clipboard: ", StringComparison.Ordinal)),
            "the list shows the newest entry of the computer");

        model.Go(Destination.Control);
        Pump();
        h.Check(Shows(window, "Commands"), "Control shows the Commands tool");
        h.Check(Shows(window, "Song"), "Control shows the player in the dock");
        model.Push(new Route.Feature(Card.Media, paired.Id));
        Pump();
        h.Check(Shows(window, "Song") && Shows(window, "Band"), "the media page shows the player");
        h.Check(Shows(window, "40%"), "the media page shows the volume");
        model.Back();
        model.Push(new Route.Feature(Card.Commands, paired.Id));
        Pump();
        h.Check(Shows(window, "Update") && Shows(window, "omarchy-update"), "the commands page lists the command");
        model.Back();

        model.Go(Destination.Computers);
        Pump();
        h.Check(Shows(window, "battery 80%, charging"), "Computers shows the battery");
    }
}
