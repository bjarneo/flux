using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The requests of a computer to start the webcam or the microphone of this
// computer. While a window of Flux is active, the prompt window shows the
// request. Otherwise a notification shows it. Only a click on start starts
// a stream: the page of the stream opens in its own window, and StreamStarts
// starts the stream when the computer is connected. StreamRequestFeature of
// StreamRequestWindow.swift of the Mac app has the same rules.
public sealed class StreamStarter : IStreamStarter
{
    AppModel? model;
    StreamStarts? starts;

    // Connects the starter to the app after the start of the app.
    public void Attach(AppModel model)
    {
        this.model = model;
        starts = new StreamStarts(model.Core);
        if (Application.Current is not { } app)
        {
            return;
        }
        // A request that waits shows when Flux becomes the active app. A
        // click on the notification also makes Flux active, and its start
        // ends the request, so the check waits for that click first.
        app.Activated += (_, _) =>
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.5) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                if (model.Core.Plugin<StreamRequestPlugin>() is { } plugin)
                {
                    plugin.Expire();
                    if (IsAppActive && plugin.Model.Current is not null)
                    {
                        StreamRequestWindow.Present(plugin);
                    }
                }
            };
            timer.Start();
        };
    }

    public bool IsAppActive => Application.Current?.Windows.OfType<Window>().Any(w => w.IsActive) == true;

    public void Present()
    {
        if (model?.Core.Plugin<StreamRequestPlugin>() is { } plugin)
        {
            StreamRequestWindow.Present(plugin);
        }
    }

    public bool Streams(StreamRequestKind kind, string computerId) => starts?.Streams(kind, computerId) == true;

    // Opens the page of the stream, and starts the stream with the saved
    // settings when the computer is connected.
    public void Start(StreamRequest request)
    {
        OpenPage(request.ComputerId, request.Kind);
        starts?.Begin(request);
    }

    public void OpenPage(string computerId, StreamRequestKind kind)
    {
        if (model is { } m)
        {
            StreamWindows.Show(m, kind == StreamRequestKind.Webcam ? Card.Stream : Card.Mic, computerId);
        }
    }
}

// The prompt of the newest stream request: the question, what the start
// does, Not now, and the start button. It stays over other windows, and it
// closes when no request is open. Its close button is Not now for each open
// request. Start is not the default button, so that a key press for another
// window cannot start a stream. Esc is Not now.
public sealed class StreamRequestWindow : Window
{
    static StreamRequestWindow? shown;

    readonly StreamRequestPlugin plugin;
    // True when the window closes because no request is open.
    bool ending;

    StreamRequestWindow(StreamRequestPlugin plugin)
    {
        this.plugin = plugin;
        Title = "Flux";
        Width = 440;
        Height = 320;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        FontFamily = Faces.Body;
        Prompt = new PromptView(plugin);
        Content = Prompt;
        Theme();
        Tn.Changed += Theme;
        plugin.Model.PropertyChanged += Changed;
        InputBindings.Add(new KeyBinding(new Relay(() =>
        {
            if (plugin.Model.Current is { } r)
            {
                plugin.Dismiss(r.Id);
            }
        }), Key.Escape, ModifierKeys.None));
        Closing += (_, _) =>
        {
            if (ending)
            {
                return;
            }
            foreach (var r in plugin.Model.Requests)
            {
                plugin.Dismiss(r.Id);
            }
        };
        Closed += (_, _) =>
        {
            Tn.Changed -= Theme;
            plugin.Model.PropertyChanged -= Changed;
            if (shown == this)
            {
                shown = null;
            }
        };
    }

    internal PromptView Prompt { get; }

    // The open prompt, or null. Tests read it.
    internal static StreamRequestWindow? Shown => shown;

    // Shows the newest open request.
    public static void Present(StreamRequestPlugin plugin)
    {
        if (plugin.Model.Current is null)
        {
            return;
        }
        shown ??= new StreamRequestWindow(plugin);
        shown.Show();
        if (shown.WindowState == WindowState.Minimized)
        {
            shown.WindowState = WindowState.Normal;
        }
        shown.Activate();
        shown.Prompt.FocusNotNow();
    }

    // Closes the prompt. The requests stay open.
    public static void CloseShown()
    {
        if (shown is { } w)
        {
            w.ending = true;
            w.Close();
        }
    }

    void Theme()
    {
        Background = Tn.Current.Bg;
        Foreground = Tn.Current.Text;
    }

    // The last request ended: started, Not now, timed out, or unpaired.
    void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (plugin.Model.Current is null)
        {
            Dispatcher.BeginInvoke(CloseShown);
        }
    }

    internal sealed class PromptView : View
    {
        readonly StreamRequestPlugin plugin;
        FluxButton? notNow;

        public PromptView(StreamRequestPlugin plugin)
        {
            this.plugin = plugin;
            Watch(plugin.Model);
        }

        public void FocusNotNow()
        {
            Redraw();
            notNow?.Focus();
        }

        protected override UIElement Build()
        {
            var tn = Tn.Current;
            if (plugin.Model.Current is not { } r)
            {
                return new System.Windows.Controls.Border();
            }
            var icon = Ui.Icon(r.Kind == StreamRequestKind.Webcam ? Icons.Webcam : Icons.Mic, 40, tn.Accent);
            var title = Ui.Text(r.Title, 17, FontWeights.SemiBold, wrap: true, align: TextAlignment.Center);
            AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
            notNow = new FluxButton(StreamRequest.NotNowLabel, ButtonKind.Outlined, () => plugin.Dismiss(r.Id))
                .Help($"Close the request of {r.ComputerName}");
            var start = new FluxButton(r.Kind.StartLabel(), ButtonKind.Filled, () => plugin.Start(r.Id));
            var buttons = Ui.H(Metrics.Gap, notNow, start).Margin(0, 6, 0, 0);
            buttons.HorizontalAlignment = HorizontalAlignment.Center;
            var body = Ui.V(14,
                icon,
                title,
                Ui.Text(r.Kind.Detail(r.ComputerName), 13, color: tn.Sub, wrap: true, align: TextAlignment.Center),
                buttons);
            body.VerticalAlignment = VerticalAlignment.Center;
            return Ui.Box(body, 28, 28, 28, 28);
        }
    }
}

// The windows of the webcam page and the microphone page of a computer,
// which a click on start opens. Each computer has 1 window for each page.
// The page is the same as under Control. The window shows the messages of
// the app at the bottom, for example when a start does not reach the
// computer. StreamWindows of the Mac app has the same job.
public static class StreamWindows
{
    static readonly Dictionary<string, StreamWindow> Open = [];

    // The open windows.
    public static IReadOnlyList<Window> All => Open.Values.ToArray();

    // Shows the page of the computer, and opens its window when it is not
    // open. A computer that is not paired opens nothing.
    public static void Show(AppModel model, Card card, string deviceId)
    {
        if (model.PairedDevice(deviceId) is not { } d)
        {
            return;
        }
        var key = $"{card} {deviceId}";
        if (!Open.TryGetValue(key, out var w))
        {
            var page = Features.Route(model, new Route.Feature(card, deviceId));
            w = new StreamWindow(model, page, $"{card.Title()} for {d.Name}", card == Card.Stream ? new Size(640, 680) : new Size(560, 440));
            Open[key] = w;
            w.Closed += (_, _) => Open.Remove(key);
        }
        w.Show();
        if (w.WindowState == WindowState.Minimized)
        {
            w.WindowState = WindowState.Normal;
        }
        w.Activate();
    }

    public static void CloseAll()
    {
        foreach (var w in All)
        {
            w.Close();
        }
    }

    sealed class StreamWindow : Window
    {
        readonly AppModel model;
        readonly System.Windows.Controls.Border toast = new() { IsHitTestVisible = false };

        public StreamWindow(AppModel model, Page page, string title, Size size)
        {
            this.model = model;
            Title = title;
            Width = size.Width;
            Height = size.Height;
            MinWidth = 420;
            MinHeight = 320;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            FontFamily = Faces.Body;
            var grid = new System.Windows.Controls.Grid();
            grid.Children.Add(page);
            grid.Children.Add(toast);
            Content = grid;
            Theme();
            Tn.Changed += Theme;
            model.PropertyChanged += Changed;
            Closed += (_, _) =>
            {
                Tn.Changed -= Theme;
                model.PropertyChanged -= Changed;
            };
            InputBindings.Add(new KeyBinding(new Relay(Close), Key.Escape, ModifierKeys.None));
        }

        void Theme()
        {
            Background = Tn.Current.Bg;
            Foreground = Tn.Current.Text;
            DrawToast();
        }

        void Changed(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(AppModel.Toast))
            {
                DrawToast();
            }
        }

        void DrawToast()
        {
            var tn = Tn.Current;
            toast.Child = model.Toast is { } text
                ? new System.Windows.Controls.Border
                {
                    Child = Ui.Text(text, 13, wrap: true),
                    Background = tn.TileHi,
                    BorderBrush = tn.LineHi,
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(18),
                    Padding = new Thickness(14, 8, 14, 8),
                    MaxWidth = 480,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Bottom,
                    Margin = new Thickness(0, 0, 0, 16),
                }.Named(text)
                : null;
        }
    }
}
