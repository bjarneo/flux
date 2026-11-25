using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using FluxKit;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Flux;

// The remote desktop window. 1 computer streams at a time, as on the
// phone. The stream stops when the window closes, and it pauses while the
// window is minimized or this computer sleeps or locks.
// DesktopWindows.swift of the Mac app has the same rules.
public static class DesktopWindows
{
    static RemoteDesktopWindow? open;

    // The open window, or null.
    public static RemoteDesktopWindow? Current => open;

    // Shows the screen of a computer. The computer can show any window, such
    // as a password manager, so a new window asks for Windows Hello first,
    // as the phone asks for its screen lock. panel shows that panel at the
    // side or under the video, for example the Omarchy panel from Control.
    public static void Show(AppModel model, DeviceSnapshot device, DesktopPanel? panel = null)
    {
        if (Front(device.Id, panel))
        {
            return;
        }
        ReplyLock.Run($"show and control the screen of {device.Name}", Application.Current?.MainWindow, () => Create(model, device, panel), model.Show);
    }

    static bool Front(string deviceId, DesktopPanel? panel)
    {
        if (open is not { } w || w.Controller.DeviceId != deviceId)
        {
            return false;
        }
        if (panel is { } p)
        {
            w.Controller.Panel = p;
        }
        w.ShowFront();
        return true;
    }

    static void Create(AppModel model, DeviceSnapshot device, DesktopPanel? panel)
    {
        if (Front(device.Id, panel) || model.Core.Plugin<DesktopPlugin>() is not { } plugin ||
            model.Core.Plugin<RemoteInputPlugin>() is not { } input)
        {
            return;
        }
        // The stream of another computer stops with its window.
        open?.Close();
        var controller = new DesktopController(model.Core, plugin, input, device);
        if (panel is { } p)
        {
            controller.Panel = p;
        }
        var w = new RemoteDesktopWindow(model, controller);
        open = w;
        w.Closed += (_, _) =>
        {
            if (open == w)
            {
                open = null;
            }
        };
        w.ShowFront();
        controller.ScreenPixels = w.ScreenPixels();
        controller.Start();
    }
}

// The window of the remote desktop of a computer. It tells the controller
// when the window is minimized and when this computer sleeps or locks.
public sealed class RemoteDesktopWindow : Window
{
    readonly DesktopView view;
    bool sessionLocked;
    bool asleep;

    public DesktopController Controller { get; }

    public RemoteDesktopWindow(AppModel model, DesktopController controller)
    {
        Controller = controller;
        Title = $"Desktop of {controller.Name}";
        Width = 1280;
        Height = 840;
        MinWidth = 640;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        view = new DesktopView(model, controller);
        Content = view;
        Theme();
        Tn.Changed += Theme;
        StateChanged += (_, _) => controller.Minimized = WindowState == WindowState.Minimized;
        Activated += (_, _) => view.Follow();
        Deactivated += (_, _) =>
        {
            controller.PointerInside = false;
            view.Follow();
        };
        SystemEvents.SessionSwitch += SessionSwitched;
        SystemEvents.PowerModeChanged += PowerChanged;
        Closed += (_, _) =>
        {
            SystemEvents.SessionSwitch -= SessionSwitched;
            SystemEvents.PowerModeChanged -= PowerChanged;
            Tn.Changed -= Theme;
            view.Close();
            controller.Close();
        };
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
        HorizontalWheel.Watch(this, view.HorizontalWheel);
    }

    // The view, for the tests.
    internal DesktopView View => view;

    void Theme()
    {
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
    }

    public void ShowFront()
    {
        Show();
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }
        Activate();
    }

    // The longest side of the screen of the window in pixels, for the size
    // of the stream.
    public int ScreenPixels()
    {
        var bounds = Forms.Screen.FromHandle(new WindowInteropHelper(this).EnsureHandle()).Bounds;
        return Math.Max(bounds.Width, bounds.Height);
    }

    // SystemEvents calls on a thread of its own.
    void SessionSwitched(object? sender, SessionSwitchEventArgs e)
    {
        bool? locked = e.Reason switch
        {
            SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or
                SessionSwitchReason.ConsoleDisconnect or SessionSwitchReason.RemoteDisconnect => true,
            SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon or
                SessionSwitchReason.ConsoleConnect or SessionSwitchReason.RemoteConnect => false,
            _ => null,
        };
        if (locked is { } l)
        {
            Dispatcher.BeginInvoke(() =>
            {
                sessionLocked = l;
                Controller.Locked = sessionLocked || asleep;
            });
        }
    }

    void PowerChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode is PowerModes.Suspend or PowerModes.Resume)
        {
            var sleeping = e.Mode == PowerModes.Suspend;
            Dispatcher.BeginInvoke(() =>
            {
                asleep = sleeping;
                Controller.Locked = sessionLocked || asleep;
            });
        }
    }
}

// The remote desktop: a bar with the state, the sound, the monitor, the
// panel buttons, and the mic button, the video, the Omarchy panel at the
// side, and the keys at the bottom. The computer types the words of a
// dictation at its cursor. DesktopView.swift of the Mac app has the same
// layout. The layout stays, so that the video and the type field keep the
// focus.
public sealed class DesktopView : View
{
    readonly DesktopController controller;
    readonly DockPanel root = new() { LastChildFill = true };
    readonly Border bar = new() { BorderThickness = new Thickness(0, 0, 0, 1) };
    readonly Border keysHost = new() { BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(12) };
    readonly Border omarchyHost = new() { BorderThickness = new Thickness(1, 0, 0, 0), Width = 300 };
    readonly Border state = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Slider volume = new() { Minimum = 0, Maximum = 1, Width = 90, VerticalAlignment = VerticalAlignment.Center, IsMoveToPointEnabled = true };
    readonly ComboBox monitors = new() { VerticalAlignment = VerticalAlignment.Center, MinWidth = 90 };
    bool updating;

    public DesktopView(AppModel model, DesktopController controller)
    {
        this.controller = controller;
        Watch(controller);
        Surface = new DesktopSurface(controller);
        Omarchy = new OmarchyPanel(model, controller);
        Keys = new RemoteKeysPanel(controller, model.Core, controller.TypeSpoken);
        // The mic button of the bar follows the state of the dictation, not each word.
        Keys.Voice.Dictation.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Dictation.State))
            {
                Invalidate();
            }
        };
        keysHost.Child = Keys;
        omarchyHost.Child = Omarchy;
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(keysHost, Dock.Bottom);
        DockPanel.SetDock(omarchyHost, Dock.Right);
        var center = new Grid();
        center.Children.Add(Surface);
        center.Children.Add(state);
        root.Children.Add(bar);
        root.Children.Add(keysHost);
        root.Children.Add(omarchyHost);
        root.Children.Add(center);
        AutomationProperties.SetName(volume, "Remote audio volume");
        volume.ValueChanged += (_, e) =>
        {
            if (!updating)
            {
                controller.AudioVolume = e.NewValue;
            }
        };
        volume.GotMouseCapture += (_, _) => Hold = true;
        volume.LostMouseCapture += (_, _) => Hold = false;
        AutomationProperties.SetName(monitors, "Monitor");
        monitors.SelectionChanged += (_, _) =>
        {
            if (!updating && monitors.SelectedItem is string m && m != controller.Status?.Monitor)
            {
                controller.ShowMonitor(m);
            }
        };
    }

    internal DesktopSurface Surface { get; }
    internal OmarchyPanel Omarchy { get; }
    internal RemoteKeysPanel Keys { get; }

    // Takes the Windows key while the pointer is over the video, see SuperKeys.
    public void Follow() => Surface.Follow();

    public bool HorizontalWheel(int delta) => Surface.HorizontalWheel(delta);

    // Ends the video of the window.
    public void Close() => Surface.Close();

    protected override UIElement Build()
    {
        var name = controller.Name;
        if (controller.Device is not { Paired: true } d)
        {
            return Parts.Unavailable(Icons.Link, $"{name} is not paired", $"Pair this computer with {name} again to show its screen.");
        }
        if (!d.Online)
        {
            return Parts.Unavailable(Icons.Wifi, $"{d.Name} is offline", $"The screen shows when {d.Name} is connected.");
        }
        if (!DesktopPlugin.Supported(d))
        {
            return Parts.Unavailable(Icons.Desktop, $"Update Flux on {d.Name}", $"This version of Flux on {d.Name} does not stream its screen.");
        }
        if (!controller.DesktopOn)
        {
            return Parts.Unavailable(Icons.Desktop, "Remote desktop is off",
                $"On {d.Name}, set remote_desktop = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.");
        }
        var tn = Tn.Current;
        bar.Background = tn.Bg;
        bar.BorderBrush = tn.Line;
        bar.Child = Bar();
        keysHost.Background = tn.Bg;
        keysHost.BorderBrush = tn.Line;
        keysHost.Visibility = controller.Panel == DesktopPanel.Keys && controller.Control ? Visibility.Visible : Visibility.Collapsed;
        omarchyHost.BorderBrush = tn.Line;
        omarchyHost.Visibility = controller.Panel == DesktopPanel.Omarchy && controller.Control ? Visibility.Visible : Visibility.Collapsed;
        state.Child = StreamState();
        Surface.Update();
        return root;
    }

    // The bar over the video: the state, the sound, the monitor, and the
    // panel buttons.
    UIElement Bar()
    {
        var tn = Tn.Current;
        var name = controller.Name;
        var status = controller.Status;
        var items = new List<UIElement?>();
        if (controller.Live)
        {
            items.Add(StatusPill.Make("Live", tn.Green));
        }
        if (!controller.Control)
        {
            items.Add(StatusPill.Make("View only", tn.Sub)
                .Help($"To control {name}, set remote_input = true on it, then run systemctl --user reload fluxd."));
            if (controller.ViewOnlyNotice)
            {
                items.Add(Ui.Text($"To control {name}, set remote_input = true on it.", 11.5, color: tn.Sub));
            }
        }
        items.Add(Ui.Spacer(8));
        items.Add(new FluxButton(controller.AudioOn ? "Audio off" : "Audio on", ButtonKind.Outlined, controller.ToggleAudio)
            .Help(controller.AudioOn ? $"Stop the sound of {name}" : $"Play the sound of {name} on this computer"));
        updating = true;
        if (controller.AudioOn)
        {
            items.Add(new FluxButton(controller.AudioVolume == 0 ? "Unmute" : "Mute", ButtonKind.Text, controller.ToggleMute));
            if (!volume.IsMouseCaptureWithin)
            {
                volume.Value = controller.AudioVolume;
            }
            Ui.Detach(volume);
            items.Add(volume);
        }
        if (status is { Monitors.Count: > 1 })
        {
            if (!monitors.Items.Cast<string>().SequenceEqual(status.Monitors))
            {
                monitors.Items.Clear();
                foreach (var m in status.Monitors)
                {
                    monitors.Items.Add(m);
                }
            }
            monitors.SelectedItem = status.Monitor;
            monitors.ToolTip = $"Show another monitor of {name}";
            Ui.Detach(monitors);
            items.Add(monitors);
        }
        updating = false;
        if (controller.Control)
        {
            if (controller.ShortcutsSupported)
            {
                items.Add(PanelButton(Icons.Grid, "Show the Omarchy panel", controller.Panel == DesktopPanel.Omarchy,
                    () => controller.TogglePanel(DesktopPanel.Omarchy)));
            }
            items.Add(PanelButton(Icons.Keyboard, "Show the keys", controller.Panel == DesktopPanel.Keys,
                () => controller.TogglePanel(DesktopPanel.Keys)));
            var dictating = Keys.Voice.Dictation.State != Dictation.Phase.Idle;
            items.Add(PanelButton(Icons.Mic, dictating ? "Stop the dictation" : $"Dictate on {name}", dictating, () =>
            {
                if (dictating)
                {
                    Keys.Voice.Stop();
                    return;
                }
                // The listening panel shows in the keys.
                controller.Panel = DesktopPanel.Keys;
                Keys.Voice.Start();
            }, tn.Red));
        }
        return Ui.H(10, items).Margin(12, 8, 12, 8);
    }

    // A button that shows or hides a panel. It has the tint while it is on,
    // the accent by default.
    static UIElement PanelButton(string glyph, string help, bool on, Action toggle, Brush? tint = null)
    {
        var tn = Tn.Current;
        var ink = tint ?? tn.Accent;
        var tile = new Border
        {
            Child = Ui.Icon(glyph, 14, on ? ink : tn.Sub),
            Width = 36,
            Height = Metrics.ButtonHeight,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            Background = on ? tn.AccentTile : tn.Tile,
            BorderBrush = on ? ink : tn.Line,
            BorderThickness = new Thickness(1),
        };
        var b = new PlainButton(tile, toggle).Named(help).Help(help);
        AutomationProperties.SetItemStatus(b, on ? "On" : "Off");
        return b;
    }

    // The state of the stream over the video: a wait, an error, or a stop.
    UIElement? StreamState()
    {
        var tn = Tn.Current;
        var status = controller.Status;
        if (status is null || status.Phase is DesktopPhase.Error or DesktopPhase.Idle)
        {
            var tile = Ui.Tile(Ui.V(12,
                Ui.Icon(Icons.Desktop, 32, tn.Sub),
                Ui.Text(status?.Phase == DesktopPhase.Error ? "The screen does not show" : "The stream stopped", 17, FontWeights.SemiBold,
                    align: TextAlignment.Center),
                Ui.Text(Message(status), 13, color: tn.Sub, wrap: true, align: TextAlignment.Center),
                new FluxButton("Start again", ButtonKind.Filled, controller.Start).Align(HorizontalAlignment.Center, VerticalAlignment.Center)),
                tn.TileHi, tn.LineHi, 32);
            tile.MaxWidth = 460;
            return tile;
        }
        if (!controller.Live)
        {
            var text = status.Message.Length > 0 ? status.Message : $"Connecting to {controller.Name}…";
            return Ui.Tile(Ui.V(12, Parts.Spinner(20), Ui.Text(text, 13, color: tn.Sub, align: TextAlignment.Center)), tn.TileHi, tn.LineHi, 24);
        }
        return null;
    }

    // The computer writes its errors in lower case.
    static string Message(DesktopStatus? status) =>
        status?.Message is { Length: > 0 } text ? char.ToUpper(text[0], System.Globalization.CultureInfo.CurrentCulture) + text[1..] : "Start the stream again.";
}

// The video of the computer screen. The video keeps the shape of the
// monitor, with bars at the sides or at the top and the bottom. The mouse
// over the video goes to the computer with its position on the monitor: a
// move, a click, a drag, and a scroll. While the video has the keyboard
// focus, keys go to the computer, and the Windows key is Super while the
// pointer is over the video. DesktopVideoView.swift of the Mac app has the
// same rules.
public sealed class DesktopSurface : Border
{
    readonly DesktopController controller;
    readonly Image image = new() { Stretch = Stretch.Uniform };
    readonly MediaFoundationVideo video;
    SuperKeys? superKeys;
    // True when the next left button up belongs to a press on the bars.
    bool skipUp;
    int clicks;
    bool closed;

    public DesktopSurface(DesktopController controller)
    {
        this.controller = controller;
        Focusable = true;
        FocusVisualStyle = null;
        ClipToBounds = true;
        Child = image;
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        video = new MediaFoundationVideo(Dispatcher, bitmap => image.Source = bitmap, Failed);
        Loaded += (_, _) =>
        {
            if (closed)
            {
                return;
            }
            controller.Plugin.Video.Attach(video);
            Dispatcher.BeginInvoke(() => Focus());
        };
        Unloaded += (_, _) =>
        {
            controller.Plugin.Video.Detach(video);
            controller.PointerInside = false;
            Follow();
        };
        GotKeyboardFocus += (_, _) => Follow();
        LostKeyboardFocus += (_, _) => Follow();
        MouseEnter += (_, _) =>
        {
            controller.PointerInside = true;
            Follow();
        };
        MouseLeave += (_, _) =>
        {
            controller.PointerInside = false;
            Follow();
        };
        MouseMove += Moved;
        MouseDown += Down;
        MouseUp += Up;
        MouseWheel += Wheel;
        LostMouseCapture += (_, _) =>
        {
            if (Mouse.LeftButton != MouseButtonState.Pressed)
            {
                return;
            }
            // Another window took the mouse during a drag.
            controller.EndPointer();
        };
        PreviewKeyDown += (_, e) => RemoteKeyInput.KeyDown(controller, e);
        PreviewTextInput += (_, e) => RemoteKeyInput.TextInput(controller, e);
    }

    public void Update()
    {
        Background = Tn.Current.Bg;
        AutomationProperties.SetName(this, $"Screen of {controller.Name}");
        Follow();
    }

    // The decoder cannot start, for example on Windows Server without Media Foundation.
    void Failed(string reason)
    {
        controller.Stop(new DesktopStatus(DesktopPhase.Error, $"This computer cannot show the stream. {reason}.", controller.DeviceId));
    }

    // Takes the Windows key while the pointer is over the live video, the
    // video has the keyboard focus, and the window is active.
    public void Follow()
    {
        var want = !closed && controller.SuperIsSuper && controller.KeysReady && IsKeyboardFocused && Window.GetWindow(this)?.IsActive == true;
        if (want && superKeys is null)
        {
            superKeys = new SuperKeys((key, held, altGr) => controller.KeyDown(key, held, KeyText.Plain(key, held.Shift), altGr));
        }
        else if (!want && superKeys is not null)
        {
            superKeys.Dispose();
            superKeys = null;
        }
    }

    public void Close()
    {
        closed = true;
        superKeys?.Dispose();
        superKeys = null;
        controller.Plugin.Video.Detach(video);
        video.Dispose();
    }

    DesktopGeometry Geometry()
    {
        var s = controller.Status;
        return new DesktopGeometry(new RemoteSize(ActualWidth, ActualHeight), new RemoteSize(s?.Width ?? 0, s?.Height ?? 0));
    }

    static RemotePoint At(Point p) => new(p.X, p.Y);

    void Moved(object sender, MouseEventArgs e)
    {
        var p = At(e.GetPosition(this));
        if (!controller.PointerInside)
        {
            controller.PointerInside = true;
            Follow();
        }
        if (e.LeftButton == MouseButtonState.Pressed && IsMouseCaptured)
        {
            if (!skipUp && Geometry().Position(p, clamp: true) is { } at)
            {
                controller.LeftDragged(p, at);
            }
            return;
        }
        controller.Hover(Geometry().Position(p));
    }

    void Down(object sender, MouseButtonEventArgs e)
    {
        Focus();
        e.Handled = true;
        var p = At(e.GetPosition(this));
        var at = Geometry().Position(p);
        switch (e.ChangedButton)
        {
            case MouseButton.Left when at is null:
                skipUp = true;
                break;
            case MouseButton.Left:
                skipUp = false;
                clicks = e.ClickCount;
                CaptureMouse();
                controller.LeftDown(p, at.Value);
                break;
            case MouseButton.Right when at is { } right:
                controller.Click(RemoteClick.Right, right);
                break;
            case MouseButton.Middle when at is { } middle:
                controller.Click(RemoteClick.Middle, middle);
                break;
        }
    }

    void Up(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }
        e.Handled = true;
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }
        if (skipUp)
        {
            skipUp = false;
            return;
        }
        var p = At(e.GetPosition(this));
        if (Geometry().Position(p, clamp: true) is { } at)
        {
            controller.LeftUp(p, at, clicks);
        }
    }

    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if (Geometry().Position(At(e.GetPosition(this))) is { } at)
        {
            controller.Wheel(0, e.Delta, at);
            e.Handled = true;
        }
    }

    public bool HorizontalWheel(int delta)
    {
        if (!IsMouseOver || Geometry().Position(At(Mouse.GetPosition(this))) is not { } at)
        {
            return false;
        }
        controller.Wheel(delta, 0, at);
        return true;
    }
}
