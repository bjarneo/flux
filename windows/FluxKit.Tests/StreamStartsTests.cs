using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// StreamStarts: how the IStreamStarter of the app starts the webcam and the
// microphone after a click on start, with a computer on loopback.
public class StreamStartsTests
{
    // An IStreamStarter as the app makes it: the plugins serve Streams and
    // Start through StreamStarts.
    sealed class AppStarter : IStreamStarter
    {
        public StreamStarts? Starts { get; set; }
        public List<string> Pages { get; } = [];
        public bool IsAppActive => false;

        public void Present()
        {
        }

        public bool Streams(StreamRequestKind kind, string computerId) => Starts?.Streams(kind, computerId) == true;

        public void Start(StreamRequest request)
        {
            OpenPage(request.ComputerId, request.Kind);
            Starts?.Begin(request);
        }

        public void OpenPage(string computerId, StreamRequestKind kind) => Pages.Add($"{kind.WireName()} {computerId}");
    }

    [Fact]
    public async Task AClickOnStartStartsTheMicrophoneWhenTheLinkIsUp()
    {
        const int first = 35875;
        using var computer = new SystemTestComputer(first, first + 1, [PacketType.Mic, PacketType.Webcam], [PacketType.StreamRequest]);
        var source = new FakeMicSource();
        // Nobody connects to the streams here, so they wait for a long time.
        var mic = new MicPlugin(source) { PayloadPorts = (first + 30, first + 34), ConnectTimeout = TimeSpan.FromSeconds(60) };
        var webcam = new WebcamPlugin(new FakeCameraSource(), new FakeRenderer(), new FakeEncoderFactory()) { PayloadPorts = (first + 6, first + 9) };
        var starter = new AppStarter();
        Assert.True(StreamStarts.StreamsBoth(webcam, mic));
        Assert.False(StreamStarts.StreamsBoth(new WebcamPlugin(), mic));
        var requests = new StreamRequestPlugin(starter);
        using var t = new TestCore(SystemTestComputer.CoreLan(first + 10), [mic, webcam, requests]);
        var shown = new ConcurrentQueue<string>();
        var starts = new StreamStarts(t.Core, shown.Enqueue);
        starter.Starts = starts;
        Assert.Contains(PacketType.StreamRequest, t.Core.IncomingCapabilities);
        var snapshot = await computer.PairAsync(t);

        // The computer asks while the link is up. A click on the notification
        // starts the stream at once.
        computer.Send(new Packet(PacketType.StreamRequest, new JsonObject { ["kind"] = "mic" }));
        await Wait.UntilAsync(() => requests.Model.Current is not null, "the request");
        var id = requests.Model.Current!.Id;
        t.Core.Host.Post(() => requests.Start(id));
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Any(p => p.String("state") == "start"), "the start of the microphone");
        Assert.Equal([$"mic {snapshot.Id}"], starter.Pages);
        Assert.True(starts.Streams(StreamRequestKind.Mic, snapshot.Id));
        Assert.False(starts.Streams(StreamRequestKind.Webcam, snapshot.Id));

        // A second request while the stream runs does nothing.
        await Task.Delay(StreamRequest.MinInterval);
        computer.Send(new Packet(PacketType.StreamRequest, new JsonObject { ["kind"] = "mic" }));
        await Task.Delay(300);
        Assert.Null(requests.Model.Current);

        // A start that waits for the link starts the stream when the link
        // comes back.
        mic.Stop();
        await Wait.UntilAsync(() => !starts.Streams(StreamRequestKind.Mic, snapshot.Id), "the stop");
        computer.Disconnect();
        await Wait.UntilAsync(() => computer.Snapshot(t) is { Online: false }, "the drop of the link");
        var request = new StreamRequest(snapshot.Id, snapshot.Name, StreamRequestKind.Mic, StreamRequest.Now);
        t.Core.Host.Post(() => starts.Begin(request));
        await Wait.UntilAsync(() => starts.Waiting, "the wait for the link");
        await computer.ReconnectAsync(t);
        await Wait.UntilAsync(() => computer.Got(PacketType.Mic).Count(p => p.String("state") == "start") == 2, "the start after the reconnect");
        await Wait.UntilAsync(() => !starts.Waiting, "the end of the wait");
        Assert.Empty(shown);

        // A start whose deadline passed while the link was down shows why.
        mic.Stop();
        computer.Disconnect();
        await Wait.UntilAsync(() => computer.Snapshot(t) is { Online: false }, "the second drop of the link");
        var late = new StreamRequest(snapshot.Id, snapshot.Name, StreamRequestKind.Webcam, StreamRequest.Now);
        t.Core.Host.Post(() => starts.Begin(late, StreamRequest.Now - PendingStart.Wait - TimeSpan.FromSeconds(1)));
        await Wait.UntilAsync(() => !shown.IsEmpty, "the message");
        Assert.Equal([$"The webcam did not start, because {snapshot.Name} is not connected."], shown);
        Assert.False(starts.Waiting);

        // An unpair ends a start that waits, without a message.
        t.Core.Host.Post(() => starts.Begin(request));
        await Wait.UntilAsync(() => starts.Waiting, "the second wait");
        t.Core.Unpair(snapshot.Id);
        await Wait.UntilAsync(() => !starts.Waiting, "the end after the unpair");
        Assert.Single(shown);
        Assert.Empty(computer.Got(PacketType.Webcam));
    }
}
