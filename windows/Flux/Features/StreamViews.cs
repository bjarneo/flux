using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The streams of this computer to a computer: the platform parts, the hooks
// of the app, the Stream tools of Control, and the tray actions.
// ControlView.swift and MenuBarView.swift of the Mac app have the same
// tools and actions.
public static class StreamFeature
{
    // The platform parts of the streams. The webcam and the screen mirror
    // share the encoder factory.
    public static readonly WasapiMicSource Microphone = new();
    public static readonly WindowsCameras Cameras = new();
    public static readonly CpuFrameRenderer Renderer = new();
    public static readonly MediaFoundationEncoders Encoders = new();
    public static readonly WindowsScreens Screens = new();

    // The app gives both streams, so the stream requests always get the
    // starter, and this computer lists flux.stream.request.
    public static readonly StreamStarter Starter = new();

    // The Mac shows 2 rectangles for the mirror. Windows has the cast icon.
    public const string MirrorGlyph = "";

    public static void DidLaunch(AppModel model) => Starter.Attach(model);

    // Stops the streams and closes their windows, so that the computer ends
    // its virtual camera and microphone before Flux quits.
    public static void WillQuit(AppModel model)
    {
        StreamWindows.CloseAll();
        StreamRequestWindow.CloseShown();
        model.Core.Plugin<WebcamPlugin>()?.Stop();
        model.Core.Plugin<ScreenPlugin>()?.Stop();
        model.Core.Plugin<MicPlugin>()?.Stop();
    }

    // Control

    // The online computers in scope for which can is true.
    static bool Ready(AppModel m, Func<DeviceSnapshot, bool> can) =>
        m.ConnectedPaired.Any(d => (m.Scope is null || d.Id == m.Scope) && can(d));

    static UIElement Tool(AppModel m, string glyph, string title, string line, Func<DeviceSnapshot, bool> can, string ask, Card card) =>
        Parts.GridTool(glyph, title, line, () => ControlViews.Run(m, can, ask, d => m.Push(new Route.Feature(card, d.Id))), Ready(m, can), small: true);

    // The microphone works with each computer that runs Flux. A start tells
    // when the Flux of the computer is too old.
    public static UIElement? MicTool(AppModel m) => m.Core.Plugin<MicPlugin>() is null ? null
        : Tool(m, Icons.Mic, "Mic", "Use this computer as a microphone", d => d.IsFlux, "Use the microphone of this computer on", Card.Mic);

    // The webcam and the mirror share 1 page.
    public static UIElement? WebcamTool(AppModel m) => m.Core.Plugin<WebcamPlugin>() is null ? null
        : Tool(m, Icons.Webcam, "Webcam", "Use the camera of this computer", _ => true, "Stream to", Card.Stream);

    public static UIElement? MirrorTool(AppModel m) => m.Core.Plugin<ScreenPlugin>() is null ? null
        : Tool(m, MirrorGlyph, "Mirror", "Show a display of this computer", _ => true, "Stream to", Card.Stream);

    // Tray

    public static (string Title, Action Run)? StopWebcamAction(AppModel m, DeviceSnapshot d) =>
        m.Core.Plugin<WebcamPlugin>() is { } webcam && webcam.Model.Status.ActiveFor(d.Id) ? ("Stop Webcam", webcam.Stop) : null;

    public static (string Title, Action Run)? StopMirrorAction(AppModel m, DeviceSnapshot d) =>
        m.Core.Plugin<ScreenPlugin>() is { } screen && screen.Model.Status.ActiveFor(d.Id) ? ("Stop Screen Mirror", screen.Stop) : null;

    public static (string Title, Action Run)? MicAction(AppModel m, DeviceSnapshot d)
    {
        if (!d.Accepts(PacketType.Mic) || m.Core.Plugin<MicPlugin>() is not { } mic)
        {
            return null;
        }
        return mic.Model.Status.ActiveFor(d.Id) ? ("Stop Microphone", mic.Stop) : ("Start Microphone", () => mic.Start(d.Id));
    }
}

// The parts of the stream pages: DashboardCard, CardRow, SwitchRow,
// SliderRow, and StatusPill of Dashboard.swift of the Mac app.
public static class StreamParts
{
    // A card: the icon in a square of the tint, the title, the action at the
    // right, the content, and the details that open under a line.
    public static Border Card(string glyph, string title, Brush tint, UIElement? action, IEnumerable<UIElement?> content,
                              CardDetails? details = null)
    {
        var tn = Tn.Current;
        var color = tint is SolidColorBrush s ? s.Color : tn.Accent.Color;
        var square = new Border
        {
            Child = Ui.Icon(glyph, 14, tint),
            Width = 28,
            Height = 28,
            CornerRadius = new CornerRadius(7),
            Background = Frozen(Color.FromArgb(38, color.R, color.G, color.B)),
        };
        var heading = Ui.Text(title, 15, FontWeights.SemiBold);
        AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
        var rows = new List<UIElement?> { Ui.H(10, square, heading, Ui.Spacer(8), action).MinHeight(Metrics.ButtonHeight) };
        rows.AddRange(content);
        if (details is { } d)
        {
            rows.Add(Ui.Divider());
            var chevron = Ui.Icon(Icons.ChevronRight, 11, tn.Sub);
            chevron.RenderTransformOrigin = new Point(0.5, 0.5);
            chevron.RenderTransform = new RotateTransform(d.Expanded ? 90 : 0);
            var row = Ui.H(8, Ui.Text(d.Title, 13, color: tn.Sub).Fill(), chevron);
            row.Background = Brushes.Transparent;
            rows.Add(new PlainButton(row, d.Toggle).Named($"{(d.Expanded ? "Hide" : "Show")} {d.Title} of {title}"));
            if (d.Expanded)
            {
                rows.Add(Ui.V(12, d.Rows()));
            }
        }
        return Ui.Tile(Ui.V(12, rows), padding: 16);
    }

    // A row with the title in sub at the left and a control at the right.
    public static UIElement Row(string title, UIElement control) =>
        Ui.H(12, Ui.Text(title, 13, color: Tn.Current.Sub), Ui.Spacer(8), control).MinHeight(Metrics.ButtonHeight);

    // A switch with a title and an optional line under it. The box is a
    // field of the page, so that it keeps the focus.
    public static UIElement Switch(CheckBox box, string title, string subtitle, bool on)
    {
        box.IsChecked = on;
        box.VerticalAlignment = VerticalAlignment.Center;
        box.Named(title);
        Ui.Detach(box);
        return Ui.H(12,
            Ui.V(2, Ui.Text(title, 13), subtitle.Length > 0 ? Ui.Text(subtitle, 11.5, color: Tn.Current.Sub, wrap: true) : null).Fill(),
            box);
    }

    // Start or Stop at the right of a stream card.
    public static FluxButton StartStop(bool active, string start, bool enabled, Action run, string help) =>
        new FluxButton(active ? "Stop" : start, active ? ButtonKind.Destructive : ButtonKind.Filled, run, enabled: active || enabled).Help(help);

    // The state of a stream: a spinner while it starts, Live, or an error
    // mark, and the message or the idle text.
    public static UIElement Status(StreamStatus status, string idle, Brush live)
    {
        var tn = Tn.Current;
        UIElement? mark = status.Phase switch
        {
            StreamPhase.Connecting or StreamPhase.Starting => Parts.Spinner(14),
            StreamPhase.Live => StatusPill.Make("Live", live),
            StreamPhase.Error => Ui.Icon(Icons.Warning, 13, tn.Red),
            _ => null,
        };
        var text = Ui.Text(status.Message.Length == 0 ? idle : status.Message, 12.5,
            color: status.Phase == StreamPhase.Error ? tn.Red : tn.Sub, wrap: true);
        return Ui.H(8, mark, text.Fill());
    }

    // Chips of a choice, such as the shape of the webcam. The chosen chip has
    // the accent.
    public static UIElement Choices(string label, IReadOnlyList<(string Value, string Text)> items, string chosen, Action<string> pick)
    {
        var tn = Tn.Current;
        return Ui.H(4, items.Select(item =>
        {
            var selected = item.Value == chosen;
            var chip = new Border
            {
                Child = Ui.Text(item.Text, 12, FontWeights.SemiBold, selected ? tn.Text : tn.Sub),
                Background = selected ? tn.AccentTile : tn.Tile,
                BorderBrush = selected ? tn.Accent : tn.Line,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(Metrics.SmallCorner),
                Padding = new Thickness(10, 4, 10, 4),
            };
            var b = new PlainButton(chip, () =>
            {
                if (!selected)
                {
                    pick(item.Value);
                }
            }).Named($"{label} {item.Text}");
            AutomationProperties.SetItemStatus(b, selected ? "Selected" : "");
            return (UIElement)b;
        }));
    }

    // Fills a picker with the items, and selects the chosen value. updating
    // stops the change of the selection from running the action.
    public static void Fill(ComboBox box, IReadOnlyList<(string Value, string Text)> items, string chosen, ref bool updating)
    {
        updating = true;
        try
        {
            var current = box.Items.Cast<ComboBoxItem>().Select(i => ((string)i.Tag, (string)i.Content)).ToArray();
            if (!current.SequenceEqual(items))
            {
                box.Items.Clear();
                foreach (var (value, text) in items)
                {
                    box.Items.Add(new ComboBoxItem { Content = text, Tag = value });
                }
            }
            box.SelectedItem = box.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == chosen);
        }
        finally
        {
            updating = false;
        }
        Ui.Detach(box);
    }

    // The value of the item that the user picked.
    public static string? Picked(ComboBox box) => (box.SelectedItem as ComboBoxItem)?.Tag as string;

    // The control in the page with the keyboard focus. A drawing moves the
    // kept controls of a page into a new layout, and Refocus gives the focus
    // back after the drawing.
    public static UIElement? Focused(UIElement page) =>
        Keyboard.FocusedElement is UIElement e && page.IsAncestorOf(e) ? e : null;

    public static void Refocus(UIElement? element)
    {
        if (element is null)
        {
            return;
        }
        element.Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            if (element.IsVisible && !element.IsKeyboardFocusWithin)
            {
                element.Focus();
            }
        });
    }

    static SolidColorBrush Frozen(Color c)
    {
        var b = new SolidColorBrush(c);
        b.Freeze();
        return b;
    }
}

// The details of a card: the title of the line that opens them, whether they
// are open, and their rows.
public sealed record CardDetails(string Title, bool Expanded, Action Toggle, Func<IEnumerable<UIElement?>> Rows);

// A slider with its title and its value, as SliderRow of the Mac app. The
// page keeps it, so that a drag keeps going while the page draws again.
public sealed class SliderRow
{
    readonly Slider slider = new() { IsMoveToPointEnabled = true, IsSnapToTickEnabled = true, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock value = Ui.Text("", 12, mono: true);
    readonly string title;
    readonly Func<double, string> format;
    bool updating;

    // change gets each value that the user sets. dragging tells the page to
    // hold its drawing during a drag.
    public SliderRow(string title, Func<double, string> format, Action<double> change, Action<bool> dragging)
    {
        this.title = title;
        this.format = format;
        slider.Named(title);
        value.MinWidth = 64;
        value.TextAlignment = TextAlignment.Right;
        slider.GotMouseCapture += (_, _) => dragging(true);
        slider.LostMouseCapture += (_, _) => dragging(false);
        slider.ValueChanged += (_, e) =>
        {
            value.Text = format(e.NewValue);
            if (!updating)
            {
                change(e.NewValue);
            }
        };
    }

    public UIElement Build(double current, double min, double max, double step)
    {
        var tn = Tn.Current;
        updating = true;
        try
        {
            slider.Minimum = min;
            slider.Maximum = Math.Max(min + step, max);
            slider.TickFrequency = step;
            slider.SmallChange = step;
            slider.LargeChange = step * 5;
            if (!slider.IsMouseCaptureWithin)
            {
                slider.Value = current;
            }
            value.Text = format(slider.Value);
        }
        finally
        {
            updating = false;
        }
        value.Foreground = tn.Sub;
        Ui.Detach(slider);
        Ui.Detach(value);
        return Ui.H(10, Ui.Text(title, 13, color: tn.Sub).Width(90), slider.Fill(), value).MinHeight(Metrics.ButtonHeight);
    }
}

// The microphone page of 1 computer: Start or Stop, the state, the level,
// and the input. MicSection.swift of the Mac app has the same parts. The
// level moves about 15 times each second without a new drawing, so that the
// buttons stay easy to click.
public sealed class MicPage : Page
{
    readonly string deviceId;
    readonly ComboBox inputs = new() { MinWidth = 220, MaxWidth = 260, VerticalAlignment = VerticalAlignment.Center };
    readonly Border meter = new() { Height = 6, CornerRadius = new CornerRadius(3) };
    readonly Border level = new() { HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(3) };
    readonly ScrollViewer scroll = Ui.Scroll(new Border());
    MicPlugin? watched;
    UIElement? focused;
    bool updating;

    public MicPage(AppModel model, string deviceId) : base(model)
    {
        this.deviceId = deviceId;
        meter.Child = level;
        meter.SizeChanged += (_, _) => DrawLevel();
        inputs.Named("Input");
        inputs.SelectionChanged += (_, _) =>
        {
            if (!updating && StreamParts.Picked(inputs) is { } id && Plugin is { } p && id != p.Model.Input)
            {
                p.SelectInput(id);
            }
        };
        inputs.DropDownOpened += (_, _) => Hold = true;
        inputs.DropDownClosed += (_, _) => Hold = false;
        Loaded += (_, _) =>
        {
            if (Plugin is { } p && watched is null)
            {
                watched = p;
                p.Model.PropertyChanged += MicChanged;
                p.RefreshPermission();
            }
            if (Application.Current is { } app)
            {
                app.Activated += AppActivated;
            }
        };
        Unloaded += (_, _) =>
        {
            if (watched is { } p)
            {
                p.Model.PropertyChanged -= MicChanged;
                watched = null;
            }
            if (Application.Current is { } app)
            {
                app.Activated -= AppActivated;
            }
        };
    }

    MicPlugin? Plugin => Model.Core.Plugin<MicPlugin>();

    public override string Title => Card.Mic.Title();
    public override string Subtitle => Model.PairedDevice(deviceId)?.Name ?? "";

    // The user can turn the microphone on in the Settings app and come back.
    void AppActivated(object? sender, EventArgs e) => Plugin?.RefreshPermission();

    void MicChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(MicModel.Level))
        {
            DrawLevel();
        }
        else
        {
            Invalidate();
        }
    }

    void DrawLevel()
    {
        var peak = Plugin?.Model.Level ?? 0;
        level.Width = Math.Clamp(peak, 0, 1) * meter.ActualWidth;
    }

    protected override void Redrawn()
    {
        base.Redrawn();
        StreamParts.Refocus(focused);
    }

    protected override UIElement Build()
    {
        var tn = Tn.Current;
        focused = StreamParts.Focused(this);
        if (Model.PairedDevice(deviceId) is not { } d || Plugin is not { } plugin)
        {
            return Parts.Unavailable(Icons.Desktop, "The computer is gone", "The computer is no longer paired.");
        }
        if (!d.IsFlux)
        {
            return Parts.Unavailable(Icons.Mic, $"{d.Name} does not run Flux", "The microphone streams to computers that run fluxd.");
        }
        var mic = plugin.Model;
        // The state belongs to this computer, or to no computer.
        var mine = mic.Status.DeviceId is null || mic.Status.DeviceId == d.Id;
        var active = mic.Status.ActiveFor(d.Id);
        var denied = mic.Permission == MicPermission.Denied;
        var action = denied ? null : StreamParts.StartStop(active, "Start", d.Online, () =>
        {
            if (active)
            {
                plugin.Stop();
            }
            else
            {
                plugin.Start(d.Id);
            }
        }, active ? $"Stop the microphone on {d.Name}" : $"Use this computer as a microphone on {d.Name}");
        var content = new List<UIElement?>();
        if (denied)
        {
            content.Add(Ui.H(8, Ui.Icon(Icons.Mic, 14, tn.Sub), Ui.Text("Flux cannot use the microphone", 13, FontWeights.SemiBold)));
            content.Add(Ui.Text("Allow Flux in Settings > Privacy & security > Microphone, then start the microphone again.", 12.5, color: tn.Sub, wrap: true));
            content.Add(new FluxButton("Open Privacy Settings", ButtonKind.Outlined, () => Privacy.OpenSettings(Privacy.Microphone)));
        }
        else
        {
            var status = active || (mine && mic.Status.Message.Length > 0) ? mic.Status.Message : $"Ready to use this computer as a microphone on {d.Name}.";
            content.Add(Ui.H(8, active ? StatusPill.Make("Live", tn.Red) : null,
                Ui.Text(status, 12.5, color: mine && mic.Status.Phase == StreamPhase.Error ? tn.Red : tn.Sub, wrap: true).Fill()));
            if (active)
            {
                meter.Background = tn.Line;
                level.Background = tn.Red;
                Ui.Detach(meter);
                content.Add(meter);
                DrawLevel();
            }
            var items = new List<(string, string)> { ("", "System Default") };
            items.AddRange(mic.Inputs.Select(i => (i.Id, i.Name)));
            if (mic.Input.Length > 0 && !mic.Inputs.Any(i => i.Id == mic.Input))
            {
                items.Add((mic.Input, "Disconnected Input"));
            }
            StreamParts.Fill(inputs, items, mic.Input, ref updating);
            content.Add(StreamParts.Row("Input", inputs));
            content.Add(Ui.Text($"Apps on {d.Name} see this computer as Flux Microphone.", 11.5, color: tn.Sub, wrap: true));
        }
        scroll.Content = Ui.Column(StreamParts.Card(Icons.Mic, "Microphone", tn.Red, action, content), 16, 24);
        return scroll;
    }
}

// The webcam and the screen mirror of 1 computer. StreamSection.swift of
// the Mac app has the same cards. The preview of the webcam changes 6 times
// each second without a new drawing, so that the controls stay easy to use.
// The webcam makes preview images only while the page is on screen.
public sealed class StreamPage : Page
{
    const string ExpandedKey = "dashboard.Webcam.expanded";

    readonly string deviceId;
    readonly ScrollViewer scroll = Ui.Scroll(new Border());
    readonly ComboBox cameras = new() { MinWidth = 220, MaxWidth = 260, VerticalAlignment = VerticalAlignment.Center };
    readonly ComboBox displays = new() { MinWidth = 220, MaxWidth = 280, VerticalAlignment = VerticalAlignment.Center };
    readonly CheckBox sendMic = new();
    readonly CheckBox mirror = new();
    readonly Image preview = new() { Stretch = Stretch.Uniform, MaxHeight = 220, HorizontalAlignment = HorizontalAlignment.Center };
    readonly Border previewHost = new() { CornerRadius = new CornerRadius(Metrics.SmallCorner), ClipToBounds = true };
    readonly SliderRow zoom;
    readonly SliderRow exposure;
    readonly SliderRow brightness;
    readonly SliderRow contrast;
    readonly SliderRow saturation;
    readonly SliderRow warmth;
    WebcamPlugin? watchedWebcam;
    ScreenPlugin? watchedScreen;
    bool previewOn;
    UIElement? focused;
    bool updating;

    public StreamPage(AppModel model, string deviceId) : base(model)
    {
        this.deviceId = deviceId;
        previewHost.Child = preview;
        previewHost.SizeChanged += (_, e) =>
            previewHost.Clip = new RectangleGeometry(new Rect(e.NewSize), Metrics.SmallCorner, Metrics.SmallCorner);
        AutomationProperties.SetName(preview, "Preview of the webcam");
        cameras.Named("Camera");
        cameras.SelectionChanged += (_, _) =>
        {
            if (!updating && StreamParts.Picked(cameras) is { } id)
            {
                Webcam?.Update(c => c with { Camera = id });
            }
        };
        displays.Named("Display");
        displays.SelectionChanged += (_, _) =>
        {
            if (!updating && StreamParts.Picked(displays) is { } id && Screen is { } s && id != s.Model.Display)
            {
                s.Select(id);
            }
        };
        foreach (var box in new[] { cameras, displays })
        {
            box.DropDownOpened += (_, _) => Hold = true;
            box.DropDownClosed += (_, _) => Hold = false;
        }
        sendMic.Click += (_, _) => Webcam?.SetSendsMicrophone(sendMic.IsChecked == true);
        mirror.Click += (_, _) => Update(c => c with { Mirror = mirror.IsChecked == true });
        var invariant = CultureInfo.InvariantCulture;
        zoom = Slider("Zoom", v => v.ToString("0.0", invariant) + "×", (c, v) => c with { Zoom = v });
        exposure = Slider("Exposure", v => v.ToString("+0.0;-0.0;+0.0", invariant) + " EV", (c, v) => c with { Exposure = v });
        brightness = Slider("Brightness", v => v.ToString("+0.00;-0.00;+0.00", invariant), (c, v) => c with { Brightness = v });
        contrast = Slider("Contrast", v => v.ToString("0.00", invariant), (c, v) => c with { Contrast = v });
        saturation = Slider("Saturation", v => v.ToString("0.00", invariant), (c, v) => c with { Saturation = v });
        warmth = Slider("Warmth", v => v.ToString("+0.00;-0.00;+0.00", invariant), (c, v) => c with { Warmth = v });
        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => Detach();
    }

    WebcamPlugin? Webcam => Model.Core.Plugin<WebcamPlugin>();
    ScreenPlugin? Screen => Model.Core.Plugin<ScreenPlugin>();

    public override string Title => Card.Stream.Title();
    public override string Subtitle => Model.PairedDevice(deviceId)?.Name ?? "";

    SliderRow Slider(string title, Func<double, string> format, Func<WebcamConfig, double, WebcamConfig> apply) =>
        new(title, format, v => Update(c => apply(c, v)), drag => Hold = drag);

    void Update(Func<WebcamConfig, WebcamConfig> change) => Webcam?.Update(change);

    void Attach()
    {
        if (Webcam is { } w && watchedWebcam is null)
        {
            watchedWebcam = w;
            w.Model.PropertyChanged += WebcamChanged;
        }
        if (!previewOn && Webcam is { } shown)
        {
            previewOn = true;
            shown.SetPreviewShown(true);
        }
        if (Screen is { } s && watchedScreen is null)
        {
            watchedScreen = s;
            s.Model.PropertyChanged += ScreenChanged;
            WindowsScreens.Changed += DisplaysChanged;
            s.Refresh();
        }
    }

    void Detach()
    {
        if (watchedWebcam is { } w)
        {
            w.Model.PropertyChanged -= WebcamChanged;
            watchedWebcam = null;
        }
        if (previewOn && Webcam is { } shown)
        {
            previewOn = false;
            shown.SetPreviewShown(false);
        }
        if (watchedScreen is { } s)
        {
            s.Model.PropertyChanged -= ScreenChanged;
            WindowsScreens.Changed -= DisplaysChanged;
            watchedScreen = null;
        }
    }

    // A new preview image only changes the image, unless the preview comes
    // or goes.
    void WebcamChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(WebcamModel.Preview) && Webcam?.Model.Preview is ImageSource image && preview.Source is not null)
        {
            preview.Source = image;
            return;
        }
        Invalidate();
    }

    // A mirror that starts or ends can follow a change of the displays, so
    // the page reads the displays again.
    void ScreenChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ScreenModel.Status))
        {
            Dispatcher.BeginInvoke(() => Screen?.Refresh());
        }
        Invalidate();
    }

    // Windows reports a new setup of the displays on another thread.
    void DisplaysChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() => Screen?.Refresh());

    protected override void Redrawn()
    {
        base.Redrawn();
        StreamParts.Refocus(focused);
    }

    protected override UIElement Build()
    {
        focused = StreamParts.Focused(this);
        if (Model.PairedDevice(deviceId) is not { } d)
        {
            return Parts.Unavailable(Icons.Desktop, "The computer is gone", "The computer is no longer paired.");
        }
        var cards = new List<UIElement?>();
        if (Webcam is { } webcam)
        {
            cards.Add(WebcamCard(d, webcam));
        }
        if (Screen is { } screen)
        {
            cards.Add(ScreenCard(d, screen));
        }
        scroll.Content = Ui.Column(Ui.V(16, cards), 16, 24);
        return scroll;
    }

    UIElement WebcamCard(DeviceSnapshot d, WebcamPlugin plugin)
    {
        var tn = Tn.Current;
        var model = plugin.Model;
        var mine = model.Status.DeviceId == d.Id;
        var active = model.Status.ActiveFor(d.Id);
        var accepts = d.Accepts(PacketType.Webcam);
        var action = StreamParts.StartStop(active, "Start", d.Online && accepts && model.Cameras.Count > 0, () =>
        {
            if (active)
            {
                plugin.Stop();
            }
            else
            {
                plugin.Start(d.Id);
            }
        }, active ? $"Stop the webcam on {d.Name}" : $"Use the camera of this computer on {d.Name}");
        var content = new List<UIElement?>
        {
            StreamParts.Status(mine ? model.Status : StreamStatus.None, $"Use the camera of this computer as Flux Camera on {d.Name}.", tn.Green),
        };
        if (d.Online && !accepts)
        {
            content.Add(Ui.Text($"Update Flux on {d.Name} to use this computer as a webcam.", 12.5, color: tn.Sub, wrap: true));
        }
        if (plugin.CameraAccessDenied)
        {
            content.Add(Ui.H(8, Ui.Text("Flux has no access to the camera.", 12.5, color: tn.Sub, wrap: true).Fill(),
                new FluxButton("Open Privacy Settings", ButtonKind.Outlined, () => Privacy.OpenSettings(Privacy.Camera))));
        }
        if (active && model.Preview is ImageSource image)
        {
            preview.Source = image;
            previewHost.Background = tn.OffTile;
            Ui.Detach(previewHost);
            content.Add(previewHost);
        }
        else
        {
            preview.Source = null;
        }
        if (model.CameraError is { } error && active)
        {
            content.Add(Ui.Text(error, 12.5, color: tn.Red, wrap: true));
        }
        content.Add(StreamParts.Row("Camera", CameraPicker(model)));
        content.Add(StreamParts.Switch(sendMic, "Also send the microphone", "Apps on the computer also get Flux Microphone", model.SendsMicrophone));
        var expanded = Model.Core.Settings.Bool(ExpandedKey, false);
        var details = new CardDetails("Image settings", expanded, () =>
        {
            Model.Core.Settings.Set(ExpandedKey, !expanded);
            Invalidate();
        }, () => ImageSettings(plugin));
        return StreamParts.Card(Icons.Webcam, "Webcam", tn.Green, action, content, details);
    }

    // A saved camera that is gone shows the camera that the stream uses
    // instead.
    UIElement CameraPicker(WebcamModel model)
    {
        if (model.Cameras.Count == 0)
        {
            return Ui.Text("No camera", 13, color: Tn.Current.Sub);
        }
        var chosen = model.Cameras.Any(c => c.Id == model.Config.Camera) ? model.Config.Camera : model.Cameras[0].Id;
        StreamParts.Fill(cameras, model.Cameras.Select(c => (c.Id, c.Name)).ToArray(), chosen, ref updating);
        return cameras;
    }

    IEnumerable<UIElement?> ImageSettings(WebcamPlugin plugin)
    {
        var config = plugin.Model.Config;
        var caps = plugin.Model.Caps;
        yield return StreamParts.Row("Shape", StreamParts.Choices("Shape", caps.Aspects.Select(a => (a, a)).ToArray(), config.Aspect,
            a => Update(c => c with { Aspect = a })));
        var invariant = CultureInfo.InvariantCulture;
        yield return StreamParts.Row("Resolution", StreamParts.Choices("Resolution",
            caps.Resolutions.Select(r => (r.ToString(invariant), $"{r}p")).ToArray(), config.Resolution.ToString(invariant),
            r => Update(c => c with { Resolution = int.Parse(r, invariant) })));
        yield return StreamParts.Switch(mirror, "Mirror the image", "", config.Mirror);
        yield return zoom.Build(config.Zoom, 1, Math.Max(1.01, caps.ZoomMax), 0.1);
        yield return exposure.Build(config.Exposure, caps.ExposureMin, Math.Max(caps.ExposureMin + 0.01, caps.ExposureMax), Math.Max(0.01, caps.ExposureStep));
        yield return brightness.Build(config.Brightness, -1, 1, 0.05);
        yield return contrast.Build(config.Contrast, 0, 2, 0.05);
        yield return saturation.Build(config.Saturation, 0, 2, 0.05);
        yield return warmth.Build(config.Warmth, -1, 1, 0.05);
        yield return Ui.H(0, Ui.Spacer(), new FluxButton("Reset Image", ButtonKind.Outlined, plugin.Reset).Help("Set the neutral image values"));
    }

    UIElement ScreenCard(DeviceSnapshot d, ScreenPlugin plugin)
    {
        var tn = Tn.Current;
        var model = plugin.Model;
        var mine = model.Status.DeviceId == d.Id;
        var active = model.Status.ActiveFor(d.Id);
        var accepts = d.Accepts(PacketType.Screen);
        var action = StreamParts.StartStop(active, "Mirror", d.Online && accepts && model.Displays.Count > 0, () =>
        {
            if (active)
            {
                plugin.Stop();
            }
            else
            {
                plugin.Start(d.Id);
            }
        }, active ? $"Stop the mirror on {d.Name}" : $"Show a display of this computer on {d.Name}");
        var content = new List<UIElement?>
        {
            StreamParts.Status(mine ? model.Status : StreamStatus.None, $"Show a display of this computer in a window on {d.Name}.", tn.Green),
        };
        if (d.Online && !accepts)
        {
            content.Add(Ui.Text($"Update Flux on {d.Name} to mirror this screen.", 12.5, color: tn.Sub, wrap: true));
        }
        if (!model.HasAccess)
        {
            content.Add(Ui.Text("This version of Windows cannot record the screen.", 12.5, color: tn.Sub, wrap: true));
        }
        UIElement picker;
        if (model.Displays.Count == 0)
        {
            picker = Ui.Text("No display", 13, color: tn.Sub);
        }
        else
        {
            var items = model.Displays.Select(x => (x.Id, $"{x.Name} ({x.Width} × {x.Height})")).ToArray();
            StreamParts.Fill(displays, items, model.Display ?? model.Displays[0].Id, ref updating);
            picker = displays;
        }
        content.Add(StreamParts.Row("Display", picker));
        return StreamParts.Card(StreamFeature.MirrorGlyph, "Screen Mirror", tn.Magenta, action, content);
    }
}
