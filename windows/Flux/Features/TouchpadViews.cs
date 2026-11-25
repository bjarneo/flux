using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The touchpad windows, 1 for each computer. A window gives the pointer
// back to this computer when it closes or stops being the active window.
// TouchpadWindows.swift of the Mac app has the same rules.
public static class TouchpadWindows
{
    static readonly Dictionary<string, TouchpadWindow> Open = [];

    // The open windows.
    public static IReadOnlyList<TouchpadWindow> All => Open.Values.ToArray();

    // Shows the touchpad of a computer. Remote input can type in any window
    // of the computer, so a new window asks for Windows Hello first, as the
    // phone asks for its screen lock.
    public static void Show(AppModel model, DeviceSnapshot device)
    {
        if (Front(device.Id))
        {
            return;
        }
        ReplyLock.Run($"control the pointer and the keys of {device.Name}", Application.Current?.MainWindow, () => Create(model, device), model.Show);
    }

    static bool Front(string deviceId)
    {
        if (!Open.TryGetValue(deviceId, out var w))
        {
            return false;
        }
        w.ShowFront();
        return true;
    }

    static void Create(AppModel model, DeviceSnapshot device)
    {
        if (Front(device.Id) || model.Core.Plugin<RemoteInputPlugin>() is not { } plugin)
        {
            return;
        }
        var w = new TouchpadWindow(new TouchpadController(model.Core, plugin, device), model.Core);
        Open[device.Id] = w;
        w.Closed += (_, _) => Open.Remove(device.Id);
        w.ShowFront();
    }
}

// The window of the touchpad and the keyboard for a computer.
public sealed class TouchpadWindow : Window
{
    readonly TouchpadView view;

    public TouchpadController Controller { get; }

    public TouchpadWindow(TouchpadController controller, FluxCore core)
    {
        Controller = controller;
        Title = $"Touchpad and Keyboard for {controller.Name}";
        Width = 600;
        Height = 520;
        MinWidth = 480;
        MinHeight = 440;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Faces.Body;
        view = new TouchpadView(controller, core);
        Content = view;
        Theme();
        Tn.Changed += Theme;
        Deactivated += (_, _) => view.Release();
        Closed += (_, _) =>
        {
            Tn.Changed -= Theme;
            view.Release();
            controller.Close();
        };
        InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
        HorizontalWheel.Watch(this, view.HorizontalWheel);
    }

    // The view, for the tests.
    internal TouchpadView View => view;

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
}

// The touchpad and the keyboard for a computer: the pad, the key rows, the
// type field, and the mic key. The computer types the words of a dictation
// at its cursor. The computer runs the input only while its remote_input
// setting is on. TouchpadView.swift of the Mac app has the same layout.
public sealed class TouchpadView : View
{
    readonly TouchpadController controller;
    readonly Grid root = new() { Margin = new Thickness(16) };

    public TouchpadView(TouchpadController controller, FluxCore core)
    {
        this.controller = controller;
        Watch(controller);
        Pad = new TouchpadPad(controller);
        Keys = new RemoteKeysPanel(controller, core, controller.TypeSpoken);
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 200 });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(Keys, 1);
        Keys.Margin = new Thickness(0, 10, 0, 0);
        root.Children.Add(Pad);
        root.Children.Add(Keys);
    }

    internal TouchpadPad Pad { get; }
    internal RemoteKeysPanel Keys { get; }

    public void Release() => Pad.Release();

    public bool HorizontalWheel(int delta) => Pad.HorizontalWheel(delta);

    protected override UIElement Build()
    {
        var name = controller.Name;
        if (!controller.Ready)
        {
            Pad.Release();
        }
        if (controller.Device is not { Paired: true } d)
        {
            return Parts.Unavailable(Icons.Link, $"{name} is not paired", $"Pair this computer with {name} again to use the touchpad.");
        }
        if (!d.Online)
        {
            return Parts.Unavailable(Icons.Wifi, $"{d.Name} is offline", $"The touchpad works when {d.Name} is connected.");
        }
        if (!RemoteInputPlugin.Supported(d))
        {
            return Parts.Unavailable(Icons.Mouse, $"Update Flux on {d.Name}", $"This version of Flux on {d.Name} does not take input from this computer.");
        }
        if (!controller.Ready)
        {
            return Parts.Unavailable(Icons.Mouse, "Remote input is off",
                $"On {d.Name}, set remote_input = true in ~/.config/flux/config.toml, then run systemctl --user reload fluxd.");
        }
        Pad.Update();
        return root;
    }
}

// The pad. A click gives it the pointer of this computer: the cursor hides
// and stays in the pad, and each motion, click, scroll, and key goes to the
// computer. Ctrl and Alt together give the pointer back. While the pad has
// the keyboard focus, keys go to the computer too, but this computer keeps
// its Windows key shortcuts. TouchpadSurface.swift of the Mac app has the
// same rules.
public sealed class TouchpadPad : Border
{
    readonly TouchpadController controller;
    readonly ReleaseChord chord = new();
    SuperKeys? superKeys;
    // True while the pad holds the pointer of this computer.
    bool holding;
    // True when the next left button up belongs to the press that took the
    // pointer.
    bool skipUp;
    // The center of the pad on the screen, in pixels.
    Point center;

    public TouchpadPad(TouchpadController controller)
    {
        this.controller = controller;
        Focusable = true;
        FocusVisualStyle = null;
        CornerRadius = new CornerRadius(14);
        AutomationProperties.SetName(this, "Touchpad");
        Loaded += (_, _) => Dispatcher.BeginInvoke(() => Focus());
        Unloaded += (_, _) => Release();
        GotKeyboardFocus += (_, _) => controller.PadFocused = true;
        LostKeyboardFocus += (_, _) =>
        {
            controller.PadFocused = false;
            Release();
        };
        LostMouseCapture += (_, _) => Release();
        MouseDown += Down;
        MouseUp += Up;
        MouseMove += (_, _) => Moved();
        MouseWheel += Wheel;
        PreviewKeyDown += KeyPressed;
        PreviewKeyUp += KeyReleased;
        PreviewTextInput += (_, e) => RemoteKeyInput.TextInput(controller, e);
    }

    // Draws the state: a green border while the pad holds the pointer.
    public void Update()
    {
        var tn = Tn.Current;
        var captured = controller.Captured;
        Background = tn.Tile;
        BorderBrush = captured ? tn.Green : tn.Line;
        BorderThickness = new Thickness(captured ? 2 : 1);
        Child = Hint();
    }

    // The text in the middle of the pad.
    UIElement Hint()
    {
        var tn = Tn.Current;
        var name = controller.Name;
        var lines = new List<UIElement?>
        {
            Ui.Icon(Icons.Mouse, 28, controller.Captured ? tn.Green : tn.Sub),
        };
        if (controller.Captured)
        {
            lines.Add(Ui.Text($"Controlling {name}", 15, FontWeights.SemiBold, align: TextAlignment.Center));
            lines.Add(Line("Press Ctrl and Alt together to give the pointer back to this computer."));
        }
        else
        {
            lines.Add(Ui.Text($"Click to control {name}", 15, FontWeights.SemiBold, align: TextAlignment.Center));
            lines.Add(Line($"The pointer, the clicks, the scrolls, and all keys then go to {name}."));
            lines.Add(Line("The right button is a right-click, and the middle button is a middle-click. Press and move to drag."));
            if (controller.PadFocused)
            {
                lines.Add(Line($"Keys that you type now go to {name}. This computer keeps its Windows key shortcuts."));
            }
        }
        var stack = Ui.V(8, lines).Align(HorizontalAlignment.Center, VerticalAlignment.Center).Margin(20);
        stack.IsHitTestVisible = false;
        return stack;
    }

    static TextBlock Line(string text) => Ui.Text(text, 12.5, color: Tn.Current.Sub, wrap: true, align: TextAlignment.Center);

    // Takes the pointer: the cursor hides, stays in the pad, and goes back
    // to the center after each motion. The Windows key goes to the
    // computer while the pad holds the pointer.
    internal void Take()
    {
        if (!controller.Capture())
        {
            return;
        }
        holding = true;
        CaptureMouse();
        Cursor = Cursors.None;
        var topLeft = PointToScreen(new Point(0, 0));
        var bottomRight = PointToScreen(new Point(ActualWidth, ActualHeight));
        center = new Point((topLeft.X + bottomRight.X) / 2, (topLeft.Y + bottomRight.Y) / 2);
        if (!PointerClip.Clip(new Rect(topLeft, bottomRight)))
        {
            FluxLog.Info("input", "Windows did not keep the pointer in the touchpad");
        }
        PointerClip.MoveTo(center);
        superKeys = new SuperKeys((key, held, altGr) =>
        {
            chord.Interrupt();
            controller.KeyDown(key, held, KeyText.Plain(key, held.Shift), altGr);
        });
        Update();
    }

    // Gives the pointer back to this computer. A drag on the computer ends.
    public void Release()
    {
        controller.Release();
        if (!holding)
        {
            return;
        }
        holding = false;
        superKeys?.Dispose();
        superKeys = null;
        PointerClip.Free();
        Cursor = null;
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }
        Update();
    }

    void Down(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!holding)
        {
            // A press on the free pad takes the pointer and does not click.
            Focus();
            Take();
            skipUp = e.ChangedButton == MouseButton.Left;
            return;
        }
        chord.Interrupt();
        switch (e.ChangedButton)
        {
            case MouseButton.Left:
                controller.LeftDown();
                break;
            case MouseButton.Right:
                controller.Click(RemoteClick.Right);
                break;
            case MouseButton.Middle:
                controller.Click(RemoteClick.Middle);
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
        if (skipUp)
        {
            skipUp = false;
            return;
        }
        if (holding)
        {
            controller.LeftUp();
        }
    }

    // The motion of the mouse or the touchpad of this computer, with the
    // pointer speed of Windows. A positive dy moves down.
    void Moved()
    {
        if (!holding || PointerClip.Position() is not { } p)
        {
            return;
        }
        var dx = p.X - center.X;
        var dy = p.Y - center.Y;
        if (dx == 0 && dy == 0)
        {
            return;
        }
        PointerClip.MoveTo(center);
        var dpi = VisualTreeHelper.GetDpi(this);
        controller.Moved(dx / dpi.DpiScaleX, dy / dpi.DpiScaleY);
    }

    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if (!holding)
        {
            return;
        }
        chord.Interrupt();
        controller.Wheel(0, e.Delta);
        e.Handled = true;
    }

    public bool HorizontalWheel(int delta)
    {
        if (!holding)
        {
            return false;
        }
        chord.Interrupt();
        controller.Wheel(delta, 0);
        return true;
    }

    void KeyPressed(object sender, KeyEventArgs e)
    {
        var key = RemoteKeyInput.KeyOf(e);
        if (RemoteKeyInput.IsModifier(key))
        {
            ModifiersChanged(Keyboard.Modifiers);
        }
        else
        {
            chord.Interrupt();
        }
        RemoteKeyInput.KeyDown(controller, e);
    }

    void KeyReleased(object sender, KeyEventArgs e)
    {
        if (RemoteKeyInput.IsModifier(RemoteKeyInput.KeyOf(e)))
        {
            ModifiersChanged(Keyboard.Modifiers);
        }
    }

    // Ctrl and Alt that go down together and come up with no key or click
    // between give the pointer back.
    internal void ModifiersChanged(ModifierKeys held)
    {
        if (chord.Flags(RemoteMods.FromModifierKeys((int)held)) && holding)
        {
            Release();
        }
    }
}
