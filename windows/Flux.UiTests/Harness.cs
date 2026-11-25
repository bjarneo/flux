using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Flux;
using FluxKit;

// The app of the UI checks: a core that uses no network, the app model, the
// main window, and 4 sample computers. A feature adds a file with a static
// class whose name ends in "Checks" and that has a method
// "public static void Run(Harness h)". Program runs each such class. A check
// class leaves the scope empty and the window on Chats when it ends.
public sealed class Harness : IDisposable
{
    readonly string data = Path.Combine(Path.GetTempPath(), "flux-ui-" + Guid.NewGuid().ToString("N"));

    public FluxCore Core { get; }
    public AppModel Model { get; }
    public MainWindow Window { get; }

    // A paired, online computer.
    public DeviceSnapshot Paired { get; } = Device("a", "omarchy-xps", true, true, PairState.Paired);

    // A paired computer that is offline.
    public DeviceSnapshot Offline { get; } = Device("b", "omarchy-desk", true, false, PairState.Paired);

    // A computer that asks to pair.
    public DeviceSnapshot Asking { get; } = Device("c", "omarchy-new", false, true, PairState.Incoming, "5EE6825F974ED59A");

    // A computer that Flux found and that is not paired.
    public DeviceSnapshot Found { get; } = Device("d", "omarchy-lab", false, true, PairState.None);

    public int Failures { get; private set; }

    // The packet types of the sample computers. A feature adds its types.
    public static readonly List<string> Accepts =
    [
        PacketType.Tunnel, PacketType.Ping, PacketType.Share, PacketType.Clipboard, PacketType.RunCommandRequest, PacketType.MprisRequest,
        PacketType.MousepadRequest, PacketType.Desktop, PacketType.Shortcuts, PacketType.SftpRequest, PacketType.Herdr,
        PacketType.Approve, PacketType.Mic, PacketType.Webcam, PacketType.Screen,
    ];

    public Harness()
    {
        // The errors of the app show in the log of the runner.
        FluxLog.Sink = (level, category, message) =>
        {
            if (level == LogLevel.Error)
            {
                Console.WriteLine($"LOG {category}: {message}");
            }
        };
        var host = new FluxHost
        {
            DeviceName = () => "Test PC",
            DeviceType = "laptop",
            Post = action => Dispatcher.CurrentDispatcher.BeginInvoke(action),
        };
        Core = new FluxCore(new FluxPaths(data), host, new LanConfig { LoopbackOnly = true }, Features.Plugins(host.Notifier));
        Model = new AppModel(Core);
        Window = new MainWindow(Model, Features.Root, Features.Route);
    }

    public static DeviceSnapshot Device(string id, string name, bool paired, bool online, PairState state, string key = "") =>
        new(id.PadRight(32, '0'), name, "laptop", "192.168.1.20", true, paired, online, state, key,
            ValueList.From(Accepts), ValueList<string>.Empty, "fluxd", "0.17.0");

    // Puts the 4 sample computers into the app model.
    public void ApplyDevices() => Model.Apply(new CoreState
    {
        DeviceName = "Test PC",
        DeviceId = new string('f', 32),
        Devices = ValueList.From(new[] { Paired, Offline, Asking, Found }),
        TcpPort = 12101,
    });

    public void Check(bool ok, string what)
    {
        if (!ok)
        {
            Failures++;
            Console.WriteLine("FAIL: " + what);
        }
    }

    public void Fail(string what, Exception e)
    {
        Failures++;
        Console.WriteLine($"FAIL: {what}: {e}");
    }

    // Runs the UI thread until the queued work is done.
    public static void Pump()
    {
        for (var i = 0; i < 3; i++)
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () => frame.Continue = false);
            Dispatcher.PushFrame(frame);
        }
    }

    // The texts that the element shows.
    public static List<string> Texts(DependencyObject root)
    {
        var list = new List<string>();
        void Walk(DependencyObject e)
        {
            switch (e)
            {
                case TextBlock t:
                    list.Add(t.Text);
                    break;
                case TextBox b:
                    list.Add(b.Text);
                    break;
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(e); i++)
            {
                Walk(VisualTreeHelper.GetChild(e, i));
            }
        }
        Walk(root);
        return list;
    }

    public static List<Button> Buttons(DependencyObject root)
    {
        var list = new List<Button>();
        void Walk(DependencyObject e)
        {
            if (e is Button b)
            {
                list.Add(b);
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(e); i++)
            {
                Walk(VisualTreeHelper.GetChild(e, i));
            }
        }
        Walk(root);
        return list;
    }

    public static bool Shows(DependencyObject root, string text) => Texts(root).Any(t => t.Contains(text, StringComparison.Ordinal));

    // Clicks the buttons with the name that a screen reader reads.
    public static void Click(DependencyObject root, string name)
    {
        foreach (var b in Buttons(root).Where(b => System.Windows.Automation.AutomationProperties.GetName(b) == name))
        {
            b.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        }
        Pump();
    }

    // Clicks the buttons whose name for a screen reader starts with the text.
    public static void ClickStarting(DependencyObject root, string start)
    {
        foreach (var b in Buttons(root).Where(b => System.Windows.Automation.AutomationProperties.GetName(b).StartsWith(start, StringComparison.Ordinal)))
        {
            b.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        }
        Pump();
    }

    public void Dispose()
    {
        Window.Quitting = true;
        Window.Close();
        Core.Dispose();
        try
        {
            Directory.Delete(data, true);
        }
        catch (IOException)
        {
        }
    }
}
