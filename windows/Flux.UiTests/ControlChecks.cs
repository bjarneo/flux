using System.Collections.Immutable;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Flux;
using FluxKit;
using static Harness;

// The Control features: the tools of Control, the touchpad with its key
// mapping, the remote desktop with the Omarchy panel, Get files with its
// downloads, and the H.264 decoder of Media Foundation.
public static class ControlChecks
{
    public static void Run(Harness h)
    {
        h.ApplyDevices();
        Pump();
        Tools(h);
        Touchpad(h);
        Desktop(h);
        Browse(h);
        Decoder(h);
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        input.Model.Set(h.Paired.Id, false, false, false);
        h.Model.SetScope(null);
    }

    // The 3 tools of Control with their lines.
    static void Tools(Harness h)
    {
        var window = h.Window;
        var model = h.Model;
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var desktop = h.Core.Plugin<DesktopPlugin>()!;
        var id = h.Paired.Id;
        model.Go(Destination.Control);
        Pump();
        h.Check(Shows(window, "Omarchy panel") && Shows(window, "Remote desktop") && Shows(window, "Touchpad"), "Control shows the 3 tools");
        h.Check(Shows(window, "Off on omarchy-xps"), "the tools are off before the computer turns them on");

        input.Model.Set(id, true, true, true);
        Pump();
        h.Check(Shows(window, "Pointer, keys, and slides"), "the touchpad shows its line");
        h.Check(Shows(window, "See and use the screen"), "the remote desktop shows its line");
        h.Check(Shows(window, "Workspaces, windows, and key bindings"), "the Omarchy panel shows its line");

        input.Model.Set(id, false, true, true);
        Pump();
        h.Check(Shows(window, "View only"), "the remote desktop is view only without remote input");

        input.Model.Set(id, true, true, true);
        model.SetScope(id);
        desktop.Model.Shortcuts = desktop.Model.Shortcuts.SetItem(id, SampleShortcuts());
        Pump();
        h.Check(Shows(window, "Workspace 2 · 2 windows"), "the Omarchy panel shows the workspace of the computer in scope");
        model.SetScope(null);
        model.Go(Destination.Chat);
        Pump();
    }

    // The touchpad window, the key mapping, the release chord, and the type field.
    static void Touchpad(Harness h)
    {
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var paired = h.Paired;
        var controller = new TouchpadController(h.Core, input, paired);
        Computer(controller, paired);
        input.Model.Set(paired.Id, true, true, false);
        input.Model.Set(paired.Id, true, true, true);
        var w = new TouchpadWindow(controller, h.Core);
        w.Show();
        Pump();
        h.Check(controller.Ready, "the touchpad is ready");
        h.Check(w.Title == "Touchpad and Keyboard for omarchy-xps", "the touchpad window names the computer");
        h.Check(Shows(w, "Click to control omarchy-xps"), "the pad tells how to start");
        h.Check(Shows(w, "esc") && Shows(w, "ctrl") && Shows(w, "super"), "the key rows show the keys and the modifiers");
        h.Check(Shows(w, "Type on omarchy-xps"), "the type field shows its placeholder");

        // The keys of WPF in the layout of the runner, which is US English.
        h.Check(RemoteKeyInput.Press(controller, Key.F5, ModifierKeys.None) is RemotePress.SpecialKey { Key: RemoteKey.F5 }, "F5 is a special key");
        h.Check(RemoteKeyInput.Press(controller, Key.Left, ModifierKeys.Shift) is RemotePress.SpecialKey { Key: RemoteKey.Left, Mods.Shift: true },
            "Shift+Left keeps Shift");
        h.Check(RemoteKeyInput.Press(controller, Key.C, ModifierKeys.Control) is RemotePress.Text { Value: "c", Mods.Ctrl: true }, "Ctrl+C is a shortcut");
        h.Check(RemoteKeyInput.Press(controller, Key.A, ModifierKeys.None) is RemotePress.Compose, "A types through the text input of Windows");
        h.Check(RemoteKeyInput.Press(controller, Key.F4, ModifierKeys.Alt) is RemotePress.SpecialKey { Key: RemoteKey.F4, Mods.Alt: true },
            "Alt+F4 goes to the computer");
        h.Check(RemoteKeyInput.Press(controller, Key.Q, ModifierKeys.Control | ModifierKeys.Alt, altGr: true) is RemotePress.Compose,
            "AltGr types the character of the layout");
        h.Check(RemoteKeyInput.Press(controller, Key.D1, ModifierKeys.Windows) is RemotePress.Ignore,
            "Windows+1 stays with Windows while the pad does not hold the pointer");
        var altIsAlt = controller.AltIsAlt;
        controller.AltIsAlt = true;
        h.Check(RemoteKeyInput.Press(controller, Key.X, ModifierKeys.Alt) is RemotePress.Text { Value: "x", Mods.Alt: true }, "Alt+X is a shortcut with Alt is Alt");
        controller.AltIsAlt = altIsAlt;

        w.View.Pad.Take();
        Pump();
        h.Check(controller.Captured, "a click on the pad takes the pointer");
        h.Check(Shows(w, "Controlling omarchy-xps"), "the pad tells that it holds the pointer");
        h.Check(RemoteKeyInput.Press(controller, Key.D1, ModifierKeys.Windows) is RemotePress.Text { Value: "1", Mods.Super: true },
            "Windows+1 goes to the computer while the pad holds the pointer");
        w.View.Pad.ModifiersChanged(ModifierKeys.Control);
        w.View.Pad.ModifiersChanged(ModifierKeys.Control | ModifierKeys.Alt);
        w.View.Pad.ModifiersChanged(ModifierKeys.Control);
        w.View.Pad.ModifiersChanged(ModifierKeys.None);
        Pump();
        h.Check(!controller.Captured, "Ctrl and Alt give the pointer back");

        w.View.Keys.Field.Text = "hello wor";
        Pump();
        h.Check(w.View.Keys.Field.Text == "wor", "the type field sends each word after its space");
        w.Close();
        Pump();
    }

    // The remote desktop window with the bar, the Omarchy panel, and the keys.
    static void Desktop(Harness h)
    {
        var input = h.Core.Plugin<RemoteInputPlugin>()!;
        var desktop = h.Core.Plugin<DesktopPlugin>()!;
        var paired = h.Paired;
        var decodes = DecoderMissing() is null;
        var controller = new DesktopController(h.Core, desktop, input, paired);
        Computer(controller, paired);
        // A minimized window does not start the stream, so the check needs no network.
        controller.Minimized = true;
        input.Model.Set(paired.Id, true, true, false);
        input.Model.Set(paired.Id, true, true, true);
        desktop.Model.Shortcuts = desktop.Model.Shortcuts.SetItem(paired.Id, SampleShortcuts());
        desktop.Model.Status = new DesktopStatus(DesktopPhase.Live, "Shows omarchy-xps", paired.Id, "DP-1")
        {
            Monitors = ValueList.From(new[] { "DP-1", "HDMI-A-1" }),
            Width = 1920,
            Height = 1080,
        };
        controller.Panel = DesktopPanel.Omarchy;
        var w = new RemoteDesktopWindow(h.Model, controller);
        w.Show();
        Pump();
        h.Check(w.Title == "Desktop of omarchy-xps", "the desktop window names the computer");
        if (decodes)
        {
            h.Check(Shows(w, "Live"), "the bar shows that the stream is live");
        }
        else
        {
            // Without Media Foundation, the window tells why the screen does not show.
            Wait(() => desktop.Model.Status.Phase == DesktopPhase.Error);
            h.Check(Shows(w, "The screen does not show") && Shows(w, "This computer cannot show the stream"), "the window tells that the stream cannot show");
        }
        h.Check(Shows(w, "Audio on"), "the bar shows the sound key");
        h.Check(w.View.Omarchy.IsVisible, "the Omarchy panel shows");
        h.Check(Shows(w, "Windows") && Shows(w, "2 windows"), "the panel counts the windows of the workspace");
        h.Check(Shows(w, "Alacritty") && Shows(w, "~/Code/flux") && Shows(w, "Focused"), "the panel shows the focused window");
        h.Check(Shows(w, "Firefox"), "the panel shows the other window");
        h.Check(Shows(w, "Launch") && Shows(w, "Terminal") && Shows(w, "super return"), "the panel shows the pinned shortcuts");
        h.Check(Shows(w, "10") && Shows(w, "close") && Shows(w, "split"), "the panel shows the workspaces and the window keys");

        controller.Panel = DesktopPanel.Keys;
        Pump();
        h.Check(w.View.Keys.IsVisible && !w.View.Omarchy.IsVisible, "the keys replace the Omarchy panel");
        h.Check(Shows(w, "Alt is Alt"), "the keys show the setting Alt is Alt");

        input.Model.Set(paired.Id, false, true, true);
        Pump();
        h.Check(Shows(w, "View only") && !w.View.Keys.IsVisible, "the window is view only without remote input");
        input.Model.Set(paired.Id, true, false, true);
        Pump();
        h.Check(Shows(w, "Remote desktop is off"), "the window tells that the remote desktop is off");
        w.Close();
        Pump();
        desktop.Model.Status = new DesktopStatus();
        desktop.Model.Shortcuts = ImmutableDictionary<string, DesktopShortcutsState>.Empty;
        input.Model.Set(paired.Id, true, true, true);
    }

    // The Get files window with a folder, the downloads, and the search.
    static void Browse(Harness h)
    {
        var browse = h.Core.Plugin<BrowsePlugin>()!;
        var paired = h.Paired;
        BrowseWindows.Show(h.Model, paired.Id);
        Pump();
        var w = BrowseWindows.All.Single();
        var browser = browse.Browser(paired.Id)!;
        Set(browser, nameof(BrowseModel.DeviceName), "omarchy-xps");
        Set(browser, nameof(BrowseModel.Error), null);
        Set(browser, nameof(BrowseModel.Loading), false);
        Set(browser, nameof(BrowseModel.CanSearch), true);
        Set(browser, nameof(BrowseModel.Roots), ValueList.From(new[] { new BrowseRoot("Home", "/home/u"), new BrowseRoot("Downloads", "/home/u/Downloads") }));
        Set(browser, nameof(BrowseModel.Path), "/home/u/Documents");
        Set(browser, nameof(BrowseModel.Entries), (IReadOnlyList<BrowseEntry>)
        [
            new BrowseEntry("Notes", "/home/u/Documents/Notes", true, 0),
            new BrowseEntry("report.pdf", "/home/u/Documents/report.pdf", false, 12_000),
            new BrowseEntry("photo.png", "/home/u/Documents/photo.png", false, 4_200_000),
        ]);
        Pump();
        h.Check(Shows(w, "Home") && Shows(w, "Documents"), "the bar shows the folders from the root");
        h.Check(Shows(w, "Notes") && Shows(w, "report.pdf") && Shows(w, "photo.png"), "the list shows the entries");
        h.Check(Shows(w, "12 KB") && Shows(w, "Folder"), "the list shows the size and the kind");

        var saved = Path.Combine(Path.GetTempPath(), "flux-ui-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(saved, "sample");
        Set(browser, nameof(BrowseModel.Downloads), ImmutableList.Create(
            new BrowseDownload(Guid.NewGuid(), "big.iso", 1_000_000_000) { Received = 250_000_000 },
            new BrowseDownload(Guid.NewGuid(), Path.GetFileName(saved), 6) { Received = 6, State = new BrowseDownloadState.Done(saved) }));
        Pump();
        h.Check(Shows(w, "Downloads") && Shows(w, "big.iso") && Shows(w, "250 MB of 1 GB"), "the downloads show the progress");
        h.Check(Shows(w, "Saved in"), "the downloads show where a file went");
        h.Check(ZoneOf(saved).Contains("ZoneId=3", StringComparison.Ordinal), "a downloaded file gets the Mark of the Web");

        Set(browser, nameof(BrowseModel.SearchText), "rep");
        Set(browser, nameof(BrowseModel.Found), new BrowseFound(1, ValueList.From(new[]
        {
            new BrowseEntry("report.pdf", "/home/u/Documents/report.pdf", false, 12_000),
        }), More: true));
        Pump();
        h.Check(Shows(w, "Home/Documents"), "the search shows the place of a result");
        h.Check(Shows(w, "Showing the first 100 matches. Type more of the name."), "the search tells that more names match");
        browser.EndSearch();
        Pump();
        h.Check(Shows(w, "photo.png"), "the end of the search shows the folder again");

        w.Quitting = true;
        w.Close();
        Pump();
        h.Check(BrowseWindows.All.Count == 0, "the Get files window closes");
        try
        {
            File.Delete(saved);
        }
        catch (IOException)
        {
        }
    }

    // Decodes the H.264 sample with the decoder of Media Foundation, and
    // shows it through the video output of the remote desktop.
    static void Decoder(Harness h)
    {
        if (SampleFile() is not { } path)
        {
            h.Check(false, "the H.264 sample desktop-sample.h264 is in Flux.UiTests");
            return;
        }
        if (DecoderMissing() is { } reason)
        {
            Console.WriteLine($"SKIP: the H.264 decoder of Media Foundation: {reason}");
            return;
        }
        var frames = Frames(File.ReadAllBytes(path));
        h.Check(frames.Count == 8 && frames.Count(f => f.Key) == 2, "the sample has 8 frames and 2 key frames");
        h.Check(MediaFoundationVideo.HasSps(frames[0].Data) && !MediaFoundationVideo.HasSps(frames[1].Data), "the first key frame carries the SPS");

        var pictures = 0;
        var size = "";
        var colors = new HashSet<int>();
        void Show(Nv12Picture p)
        {
            pictures++;
            size = $"{p.Width}x{p.Height}";
            var pixels = new byte[p.Width * p.Height * 4];
            Nv12.ToBgr(p, pixels);
            for (var i = 0; i < pixels.Length; i += 4 * 97)
            {
                colors.Add(pixels[i] >> 5 | pixels[i + 1] >> 5 << 3 | pixels[i + 2] >> 5 << 6);
            }
        }
        using (var decoder = H264Decoder.Open())
        {
            foreach (var f in frames)
            {
                decoder.Decode(f.Data, f.Key, Show);
            }
            decoder.Drain(Show);
        }
        h.Check(pictures == 8, $"the decoder gives 8 pictures, not {pictures}");
        h.Check(size == "320x180", $"the pictures are 320x180, not {size}");
        h.Check(colors.Count > 8, "the pictures have the colors of the test pattern");

        // The output of the remote desktop: the SPS and the PPS come in a
        // config frame, and the key frames come without them.
        var sets = DesktopH264.ParameterSets(frames[0].Data)!.Value;
        BitmapSource? shown = null;
        string? failure = null;
        var video = new MediaFoundationVideo(Dispatcher.CurrentDispatcher, b => shown = b ?? shown, f => failure = f);
        h.Check(video.Configure(sets.Sps, sets.Pps), "the video output takes the SPS and the PPS");
        foreach (var f in frames)
        {
            Wait(() => video.IsReady);
            video.Decode(f.Key ? WithoutSets(f.Data) : f.Data, f.Key);
        }
        Wait(() => shown is not null || failure is not null);
        h.Check(failure is null && shown is { PixelWidth: 320, PixelHeight: 180 }, $"the video output shows the pictures: {failure}");
        video.Dispose();
    }

    // The reason why Windows cannot decode H.264, or null.
    static string? DecoderMissing()
    {
        try
        {
            H264Decoder.Open().Dispose();
            return null;
        }
        catch (NotSupportedException e)
        {
            return $"{e.Message}: {e.InnerException?.Message}";
        }
    }

    // The frames of Annex-B data: each slice with the parameter sets before
    // it, with 4-byte start codes.
    static List<(byte[] Data, bool Key)> Frames(byte[] data)
    {
        var frames = new List<(byte[], bool)>();
        var pending = new List<byte>();
        foreach (var unit in DesktopH264.Units(data))
        {
            pending.AddRange([0, 0, 0, 1]);
            pending.AddRange(unit);
            var type = unit[0] & 0x1F;
            if (type is 1 or 5)
            {
                frames.Add((pending.ToArray(), type == 5));
                pending.Clear();
            }
        }
        return frames;
    }

    // The frame without its SPS and PPS.
    static byte[] WithoutSets(byte[] frame)
    {
        var output = new List<byte>();
        foreach (var unit in DesktopH264.Units(frame))
        {
            if ((unit[0] & 0x1F) is not (7 or 8))
            {
                output.AddRange([0, 0, 0, 1]);
                output.AddRange(unit);
            }
        }
        return output.ToArray();
    }

    // The sample next to this file, or in the folder of the project above
    // the build output.
    static string? SampleFile([CallerFilePath] string source = "")
    {
        const string name = "desktop-sample.h264";
        var here = Path.Combine(Path.GetDirectoryName(source) ?? "", name);
        if (File.Exists(here))
        {
            return here;
        }
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, name);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    // The Omarchy panel of a computer: workspace 2 with 2 windows, and the
    // shortcuts that the panel pins first.
    static DesktopShortcutsState SampleShortcuts() => new()
    {
        Loaded = true,
        Active = 2,
        Workspaces = ValueList.From(new[] { new DesktopWorkspace(1, 1), new DesktopWorkspace(2, 2) }),
        Windows = ValueList.From(new[]
        {
            new FluxKit.DesktopWindow("0x1", 2, "Alacritty", "Alacritty", "~/Code/flux", true),
            new FluxKit.DesktopWindow("0x2", 2, "Firefox", "firefox", "Omarchy", false),
            new FluxKit.DesktopWindow("0x3", 1, "Spotify", "spotify", "Song", false),
        }),
        Shortcuts = ValueList.From(new[]
        {
            new DesktopShortcut("t", "SUPER RETURN", "Terminal"),
            new DesktopShortcut("b", "SUPER SHIFT B", "Browser"),
            new DesktopShortcut("m", "SUPER ALT SPACE", "Omarchy menu"),
        }),
    };

    // A controller reads the computer from the core, which has no computers
    // in the checks, so the check gives it the sample computer.
    static void Computer(object controller, DeviceSnapshot device) =>
        controller.GetType().GetField("device", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(controller, device);

    // Sets a property of a model that has a private setter.
    static void Set(object target, string property, object? value) => target.GetType().GetProperty(property)!.SetValue(target, value);

    static string ZoneOf(string path)
    {
        try
        {
            return File.ReadAllText(path + ":Zone.Identifier");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return "";
        }
    }

    // Runs the UI thread until the condition is true, for at most 10 seconds.
    static void Wait(Func<bool> done)
    {
        var end = DateTime.UtcNow.AddSeconds(10);
        while (!done() && DateTime.UtcNow < end)
        {
            Pump();
            Thread.Sleep(20);
        }
    }
}
