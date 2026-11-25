using System.Net.Security;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using FluxKit;

namespace FluxKit.Tests;

// The remote desktop with a fake Omarchy computer on loopback. A headless
// fluxd shows no screen, so the fake computer sends flux.input, answers
// flux.desktop, connects to the listener, and writes frames as fluxd does.
// The tests drive DesktopController as the window does, with its pause
// rules.
public class DesktopStreamTests
{
    // A paired Omarchy computer that the test drives.
    sealed class FakeComputer : ILanBackendDelegate, IDisposable
    {
        readonly string dir = CoreTests.TempDir();
        readonly List<Packet> received = [];
        Link? link;

        public FakeComputer(int udpPort, int tcpPort)
        {
            Certificate = LocalCertificate.LoadOrCreate(dir, new PlainKeyProtector());
            // The announcements go to a port that nobody reads, so only the
            // dial of the test makes a link.
            var config = new LanConfig { UdpPort = udpPort, PeerUdpPort = udpPort + 90, FirstTcpPort = tcpPort, LastTcpPort = tcpPort + 4, LoopbackOnly = true };
            Backend = new LanBackend(new FluxTls(Certificate), config, port => new Identity(
                Certificate.DeviceId, "Fake Omarchy", "desktop", Identity.Version,
                [PacketType.Tunnel, PacketType.Desktop, PacketType.Shortcuts, PacketType.MousepadRequest],
                [PacketType.Input, PacketType.Desktop, PacketType.Shortcuts, PacketType.Tunnel], port, "fluxd", "0.0.0"), this);
        }

        public LocalCertificate Certificate { get; }
        public LanBackend Backend { get; }
        public byte[]? Trusted { get; set; }
        public Link? Link => Volatile.Read(ref link);

        public TrustedDevice Trust => new(Certificate.DeviceId, "Fake Omarchy", "desktop", Convert.ToBase64String(Certificate.CertificateDer), "127.0.0.1", true);

        public byte[]? TrustedCertificate(string deviceId) => Trusted;
        public bool HasLink(string deviceId) => Link is { IsOpen: true };
        public bool DialsFrom(string deviceId) => false;
        public IReadOnlyList<string> KnownAddresses() => [];

        public void OnLink(Link l)
        {
            Volatile.Write(ref link, l);
            l.SetPaired(true);
            l.Start(p =>
            {
                lock (received)
                {
                    received.Add(p);
                }
            }, () => { });
        }

        public void Send(Packet p) => Link!.Send(p);

        public void Send(string type, string json) => Send(new Packet(type, JsonNode.Parse(json)!.AsObject()));

        // Removes and returns the first packet that matches, or null.
        public Packet? Take(Func<Packet, bool> match)
        {
            lock (received)
            {
                var i = received.FindIndex(p => match(p));
                if (i < 0)
                {
                    return null;
                }
                var p = received[i];
                received.RemoveAt(i);
                return p;
            }
        }

        public async Task<Packet> WaitAsync(Func<Packet, bool> match, string what)
        {
            Packet? found = null;
            await Wait.UntilAsync(() => (found = Take(match)) is not null, what);
            return found!;
        }

        // Connects to the listener of the stream as fluxd does: this side is
        // the TLS client with the certificate of the computer.
        public async Task<(TcpClient Tcp, SslStream Stream)> ConnectAsync(int port)
        {
            var tcp = new TcpClient();
            await tcp.ConnectAsync("127.0.0.1", port);
            var ssl = await new FluxTls(Certificate).ClientAsync(tcp.GetStream(), "flux-payload", default);
            return (tcp, ssl);
        }

        public void Dispose()
        {
            Backend.Stop();
            Link?.Close();
            Certificate.Dispose();
            Directory.Delete(dir, true);
        }
    }

    sealed class Audio : IDesktopAudioOutput
    {
        readonly List<(float[] Samples, float Volume)> played = [];

        public int Count
        {
            get
            {
                lock (played)
                {
                    return played.Count;
                }
            }
        }

        public float LastVolume
        {
            get
            {
                lock (played)
                {
                    return played[^1].Volume;
                }
            }
        }

        public bool Play(float[] samples, float volume, Action done)
        {
            lock (played)
            {
                played.Add((samples, volume));
            }
            done();
            return true;
        }

        public void Stop()
        {
        }
    }

    // The core, the plugins, and the fake computer of 1 test.
    sealed class Rig : IDisposable
    {
        public required FakeComputer Computer { get; init; }
        public required ControlHarness H { get; init; }
        public required DesktopPlugin Desktop { get; init; }
        public required RemoteInputPlugin Input { get; init; }
        public DesktopTests.FakeVideo Video { get; } = new();
        public required Audio Sound { get; init; }
        public string Id => Computer.Certificate.DeviceId;

        public static async Task<Rig> StartAsync(int basePort)
        {
            var computer = new FakeComputer(basePort + 1, basePort + 10);
            var sound = new Audio();
            var desktop = new DesktopPlugin(sound);
            var input = new RemoteInputPlugin();
            var lan = new LanConfig { UdpPort = basePort + 2, PeerUdpPort = basePort + 92, FirstTcpPort = basePort + 20, LastTcpPort = basePort + 28, LoopbackOnly = true };
            var h = new ControlHarness(lan, [desktop, input], data => new TrustStore(Path.Combine(data, "trusted.json")).Put(computer.Trust));
            computer.Trusted = h.Core.Local.CertificateDer;
            var rig = new Rig { Computer = computer, H = h, Desktop = desktop, Input = input, Sound = sound };
            desktop.Video.Attach(rig.Video);
            computer.Backend.Start();
            h.Core.Start();
            await Wait.UntilAsync(() => h.Core.IsRunning && h.Core.State.TcpPort > 0, "the start of the core");
            await rig.LinkAsync();
            return rig;
        }

        // The fake computer dials the core and waits for the paired link.
        public async Task LinkAsync()
        {
            var old = Computer.Link;
            Computer.Backend.Connect("127.0.0.1", H.Core.State.TcpPort, null);
            await Wait.UntilAsync(() => H.Computer is { Online: true, Paired: true } && Computer.Link is { IsOpen: true } l && l != old,
                "the link of the fake computer");
        }

        public void Dispose()
        {
            H.Dispose();
            Computer.Dispose();
        }
    }

    static bool IsStart(Packet p) => p.Type == PacketType.Desktop && p.String("state") == "start";

    static bool IsStop(Packet p) => p.Type == PacketType.Desktop && p.String("state") == "stop";

    // True when the peer closed the stream: a read ends or fails.
    static async Task<bool> ClosedAsync(SslStream stream)
    {
        try
        {
            return await stream.ReadAsync(new byte[16]).AsTask().WaitAsync(TimeSpan.FromSeconds(10)) == 0;
        }
        catch (IOException)
        {
            return true;
        }
    }

    const string InputOn = """{"enabled": true, "desktop": true, "keyRepeat": true}""";

    [Fact]
    public async Task StreamShowsTheScreenAndPausesWithTheWindow()
    {
        using var rig = await Rig.StartAsync(34600);
        var (h, computer) = (rig.H, rig.Computer);
        computer.Send(PacketType.Input, InputOn);
        await Wait.UntilAsync(() => rig.Input.Model.IsDesktopOn(rig.Id), "flux.input of the computer");
        var c = await h.OnUi(() => new DesktopController(h.Core, rig.Desktop, rig.Input, h.Computer!) { ScreenPixels = 2880 });
        Assert.True(await h.OnUi(() => c.Ready && c.Control && c.WorkspaceKeys));

        // The start packet has the port of the listener and the size of the screen.
        await h.OnUi(c.Start);
        var start = await computer.WaitAsync(IsStart, "the start");
        Assert.Equal(2880, start.Int("maxSize"));
        Assert.False(start.Has("monitor"));
        Assert.False(start.Has("audio"));
        await Wait.UntilAsync(() => rig.Desktop.Model.Status is { Phase: DesktopPhase.Connecting, Message: "Waiting for Fake Omarchy…" }, "the wait");

        // The computer connects, reports the monitor, and writes the frames.
        var (tcp, payload) = await computer.ConnectAsync(start.Int("port")!.Value);
        using var _ = tcp;
        computer.Send(PacketType.Desktop, """{"state": "live", "monitor": "DP-1", "monitors": ["DP-1", "HDMI-A-1"], "width": 1280, "height": 720}""");
        await payload.WriteAsync(DesktopTests.Frames(
            (DesktopFrame.Format, [0x07, 0x80, 0x04, 0x38]),
            (DesktopFrame.Config, [.. DesktopTests.Sps, .. DesktopTests.Pps]),
            (DesktopFrame.Key, [0, 0, 0, 1, 0x65, 1, 2]),
            (0, [0, 0, 0, 1, 0x41, 3])));
        await payload.FlushAsync();
        await Wait.UntilAsync(() => rig.Video.Count == 2 && rig.Desktop.Model.Status is { Phase: DesktopPhase.Live, Width: 1920 }, "the video");
        var status = rig.Desktop.Model.Status;
        Assert.Equal("Shows Fake Omarchy", status.Message);
        Assert.Equal("DP-1", status.Monitor);
        Assert.Equal(["DP-1", "HDMI-A-1"], status.Monitors);
        // The size frame wins over the packet.
        Assert.Equal(1080, status.Height);
        Assert.True(await h.OnUi(() => c.Live));
        Assert.Equal([0x67, 0x64, 0x00, 0x32], rig.Video.Configured[^1].Sps);
        Assert.True(rig.Video.Decoded[0].Key);

        // The mouse over the video goes with positions.
        await h.OnUi(() =>
        {
            c.PointerInside = true;
            c.Hover(new DesktopPoint(0.25, 0.5));
            c.LeftDown(new RemotePoint(10, 10), new DesktopPoint(0.25, 0.5));
            c.LeftUp(new RemotePoint(10, 10), new DesktopPoint(0.25, 0.5), 1);
            c.Click(RemoteClick.Right, new DesktopPoint(0.5, 0.5));
            c.Wheel(0, 120, new DesktopPoint(0.5, 0.75));
        });
        var hover = await computer.WaitAsync(p => p.Type == PacketType.MousepadRequest && p.Body.Count == 2, "the hover");
        Assert.Equal(0.25, hover.Double("x"));
        var click = await computer.WaitAsync(p => p.Bool("singleclick") == true, "the click");
        Assert.Equal(0.5, click.Double("y"));
        await computer.WaitAsync(p => p.Bool("rightclick") == true && p.Double("x") == 0.5, "the right click");
        var wheel = await computer.WaitAsync(p => p.Bool("scroll") == true, "the scroll");
        Assert.Equal(-15, wheel.Double("dy"));
        Assert.Equal(0.75, wheel.Double("y"));

        // The Windows key and a digit switch the workspace while the pointer is over the video.
        Assert.True(await h.OnUi(() => c.SuperIsSuper));
        await h.OnUi(() => c.KeyDown(0x33, new RemoteMods(Super: true), "3"));
        var workspace = await computer.WaitAsync(p => p.Type == PacketType.Shortcuts && p.String("action") == "workspace", "the workspace");
        Assert.Equal(3, workspace.Int("workspace"));
        await h.OnUi(() => c.KeyDown(0x43, new RemoteMods(Ctrl: true), "c"));
        await computer.WaitAsync(p => p.String("key") == "c" && p.Bool("ctrl") == true, "the shortcut");

        // The Omarchy panel asks for the shortcuts when it shows.
        await h.OnUi(() => c.Panel = DesktopPanel.Omarchy);
        await computer.WaitAsync(p => p.Type == PacketType.Shortcuts && p.Bool("request") == true, "the request of the panel");
        computer.Send(PacketType.Shortcuts, """{"shortcuts": [{"ref": "315", "keys": "SUPER RETURN", "description": "Terminal"}], "workspaces": [{"id": 2, "windows": 1}], "active": 2}""");
        await Wait.UntilAsync(() => rig.Desktop.Model.ShortcutsOf(rig.Id) is { Loaded: true }, "the shortcuts");
        Assert.Equal("Terminal", (await h.OnUi(() => c.Shortcuts))!.Shortcuts.Single().Description);
        await h.OnUi(() => c.Shortcut(DesktopShortcuts.Run(c.Shortcuts!.Shortcuts[0])));
        await computer.WaitAsync(p => p.String("run") == "315", "the run");

        // The stream pauses while the window is minimized.
        await h.OnUi(() => c.Minimized = true);
        await computer.WaitAsync(IsStop, "the stop");
        await Wait.UntilAsync(() => rig.Desktop.Model.Status is { Phase: DesktopPhase.Idle, Message: DesktopController.MinimizedText }, "the pause");
        Assert.True(await h.OnUi(() => c.Paused && c.Hidden));
        // The stream of the computer closed.
        Assert.True(await ClosedAsync(payload));

        // While the window is minimized, a start only marks the pause, and an
        // unlock does not start the stream.
        await h.OnUi(c.Start);
        await h.OnUi(() => c.Locked = true);
        await h.OnUi(() => c.Locked = false);
        await Task.Delay(200);
        Assert.Null(computer.Take(IsStart));
        Assert.True(await h.OnUi(() => c.Paused));

        // The window comes back, and the stream starts again with the same monitor.
        await h.OnUi(() => c.ShowMonitor("HDMI-A-1"));
        await h.OnUi(() => c.Minimized = false);
        var again = await computer.WaitAsync(IsStart, "the start after the pause");
        Assert.Equal("HDMI-A-1", again.String("monitor"));
        Assert.False(await h.OnUi(() => c.Paused));

        // The lock of this computer pauses the stream too.
        await h.OnUi(() => c.Locked = true);
        await computer.WaitAsync(IsStop, "the stop for the lock");
        await Wait.UntilAsync(() => rig.Desktop.Model.Status.Message == DesktopController.LockedText, "the pause for the lock");
        await h.OnUi(() => c.Locked = false);
        await computer.WaitAsync(IsStart, "the start after the unlock");

        // The sound starts the stream again with audio.
        await h.OnUi(c.ToggleAudio);
        await computer.WaitAsync(IsStop, "the stop before the start with audio");
        var withAudio = await computer.WaitAsync(p => IsStart(p) && p.Bool("audio") == true, "the start with audio");
        var (tcp2, sound) = await computer.ConnectAsync(withAudio.Int("port")!.Value);
        using var __ = tcp2;
        await h.OnUi(() => c.AudioVolume = 0.5);
        await sound.WriteAsync(DesktopTests.Frames((DesktopFrame.Audio, new byte[3840])));
        await Wait.UntilAsync(() => rig.Sound.Count == 1, "the sound");
        Assert.Equal(0.5f, rig.Sound.LastVolume);
        await h.OnUi(c.ToggleMute);
        Assert.Equal(0, await h.OnUi(() => c.AudioVolume));
        await h.OnUi(c.ToggleMute);
        Assert.Equal(0.5, await h.OnUi(() => c.AudioVolume));

        // The user stops the stream on the computer. This side sends no stop.
        computer.Send(PacketType.Desktop, """{"state": "stop"}""");
        await Wait.UntilAsync(() => rig.Desktop.Model.Status is { Phase: DesktopPhase.Idle, Message: "Stopped on Fake Omarchy" }, "the stop of the computer");
        await h.OnUi(c.Close);
        await Task.Delay(200);
        Assert.Null(computer.Take(IsStop));
        await payload.DisposeAsync();
        await sound.DisposeAsync();
    }

    [Fact]
    public async Task StreamStopsWithTheLinkAndStartsWhenItComesBack()
    {
        using var rig = await Rig.StartAsync(34700);
        var (h, computer) = (rig.H, rig.Computer);
        var c = await h.OnUi(() => new DesktopController(h.Core, rig.Desktop, rig.Input, h.Computer!));
        Assert.False(await h.OnUi(() => c.Ready));

        // The computer turns its screen on, and the open window starts the stream.
        computer.Send(PacketType.Input, InputOn);
        var start = await computer.WaitAsync(IsStart, "the start when the screen turns on");
        Assert.Equal(DesktopPackets.DefaultSize, start.Int("maxSize"));

        // The computer refuses with its message.
        computer.Send(PacketType.Desktop, """{"state": "error", "message": "gpu-screen-recorder finds no monitor to capture"}""");
        await Wait.UntilAsync(() => rig.Desktop.Model.Status is { Phase: DesktopPhase.Error, Message: "gpu-screen-recorder finds no monitor to capture" }, "the error");
        Assert.Equal(DesktopPhase.Error, (await h.OnUi(() => c.Status))!.Phase);

        // The link drops while a start waits for the computer.
        await h.OnUi(c.Start);
        await computer.WaitAsync(IsStart, "the start again");
        computer.Link!.Close();
        await Wait.UntilAsync(() => rig.Desktop.Model.Status is { Phase: DesktopPhase.Error, Message: "The connection to Fake Omarchy closed" }, "the closed link");
        await Wait.UntilAsync(() => !h.OnUi(() => c.Ready).Result, "the window without the computer");

        // The link comes back, and the window starts the stream again.
        await rig.LinkAsync();
        await computer.WaitAsync(IsStart, "the start after the link came back");

        // While the window is minimized, a link that comes back starts nothing.
        await h.OnUi(() => c.Minimized = true);
        await computer.WaitAsync(IsStop, "the stop for the minimized window");
        computer.Link!.Close();
        await Wait.UntilAsync(() => h.Computer is { Online: false }, "the closed link");
        await rig.LinkAsync();
        await Wait.UntilAsync(() => h.OnUi(() => c.Ready).Result, "the ready window");
        await Task.Delay(200);
        Assert.Null(computer.Take(IsStart));
        await h.OnUi(() => c.Minimized = false);
        await computer.WaitAsync(IsStart, "the start when the window comes back");

        // The window closes and stops the stream that waits.
        await h.OnUi(c.Close);
        await computer.WaitAsync(IsStop, "the stop when the window closes");
        Assert.Equal(DesktopPhase.Idle, (await h.OnUi(() => rig.Desktop.Model.Status)).Phase);
    }

    [Fact]
    public async Task ViewOnlyScreenExplainsAClick()
    {
        using var rig = await Rig.StartAsync(34800);
        var (h, computer) = (rig.H, rig.Computer);
        computer.Send(PacketType.Input, """{"enabled": false, "desktop": true, "keyRepeat": true}""");
        await Wait.UntilAsync(() => rig.Input.Model.IsDesktopOn(rig.Id), "flux.input of the computer");
        var c = await h.OnUi(() => new DesktopController(h.Core, rig.Desktop, rig.Input, h.Computer!));
        Assert.True(await h.OnUi(() => c.Ready && !c.Control));
        await h.OnUi(c.Start);
        var start = await computer.WaitAsync(IsStart, "the start");
        var (tcp, payload) = await computer.ConnectAsync(start.Int("port")!.Value);
        using var _ = tcp;
        await payload.WriteAsync(DesktopTests.Frames((DesktopFrame.Format, [0x05, 0x00, 0x02, 0xD0])));
        computer.Send(PacketType.Desktop, """{"state": "live", "monitor": "eDP-1", "monitors": ["eDP-1"], "width": 1280, "height": 720}""");
        await Wait.UntilAsync(() => h.OnUi(() => c.Live).Result, "the live stream");

        // A click on a view-only screen sends nothing and explains it.
        await h.OnUi(() => c.Click(RemoteClick.Left, new DesktopPoint(0.5, 0.5)));
        Assert.True(await h.OnUi(() => c.ViewOnlyNotice));
        // The Omarchy panel closes without control.
        await h.OnUi(() => c.Panel = DesktopPanel.Omarchy);
        await Task.Delay(200);
        Assert.Null(computer.Take(p => p.Type == PacketType.MousepadRequest || p.Type == PacketType.Shortcuts));

        // Remote input turns on: the panel asks for the shortcuts.
        computer.Send(PacketType.Input, InputOn);
        await computer.WaitAsync(p => p.Type == PacketType.Shortcuts && p.Bool("request") == true, "the request of the panel");
        // Remote input turns off again: the panel closes.
        computer.Send(PacketType.Input, """{"enabled": false, "desktop": true, "keyRepeat": true}""");
        await Wait.UntilAsync(() => h.OnUi(() => c.Panel == DesktopPanel.None).Result, "the closed panel");
        await h.OnUi(c.Close);
        await payload.DisposeAsync();
    }
}
