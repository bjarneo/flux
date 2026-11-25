using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FluxKit;

namespace Flux;

// The dock of the chat of a computer: the clipboard of this computer with
// Send, then the composer with the + key, the field, the mic key, and the
// send key. Enter sends, and Shift+Enter adds a line. The field has the
// clear key and the expand key, which opens a larger editor with Send. The
// + key opens the tray under the composer and turns into an accent key with
// a cross, see ChatTray. The send key sends the selected screenshots and the
// text, and it shows the number of selected screenshots. Escape closes the
// tray. The field keeps its text and its focus while the chat draws again.
// ChatScreen.kt of the Android app has the same parts.
public sealed class ChatDock
{
    readonly AppModel model;
    readonly string deviceId;
    readonly TextBox field;
    readonly TextBlock hint = Ui.Text("", 13);
    readonly Border fieldFrame;
    readonly VoiceBar voice;
    readonly PlainButton plus;
    readonly PlainButton send;
    readonly Border plusTile = new() { Width = 36, Height = 36, CornerRadius = new CornerRadius(18) };
    readonly Border sendTile = new() { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(1) };
    readonly TextBlock plusIcon = Ui.Icon(Icons.Add, 16);
    readonly TextBlock sendIcon = Ui.Icon(Icons.Send, 15);
    readonly Border sendBadge = new()
    {
        MinWidth = 18,
        Height = 18,
        CornerRadius = new CornerRadius(9),
        Padding = new Thickness(4, 0, 4, 0),
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, -5, -5, 0),
        IsHitTestVisible = false,
    };
    readonly TextBlock sendCount = Ui.Text("", 10.5, FontWeights.Bold, mono: true, align: TextAlignment.Center);
    readonly Border frame;
    // The clipboard of this computer.
    readonly Border clipRow = new() { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Padding = new Thickness(10, 0, 2, 0), Height = 40 };
    readonly TextBlock clipIcon = Ui.Icon(Icons.Paste, 15);
    readonly TextBlock clipSource = Ui.Text("", 10);
    readonly TextBlock clipText = Ui.Text("", 12, mono: true);
    readonly FluxButton clipSend;
    readonly System.Windows.Threading.DispatcherTimer clipTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    long clipStamp = -1;
    bool clipEmpty = true;
    readonly ChatTray tray;
    readonly Border trayHost = new();
    bool trayOpen;

    // The dock. It stays the same element, so that the field keeps its focus.
    public Border Root { get; }

    public ChatDock(AppModel model, string deviceId)
    {
        this.model = model;
        this.deviceId = deviceId;
        field = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 140,
            MinHeight = 34,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Padding = new Thickness(2, 7, 2, 7),
            FontSize = 13,
        };
        field.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.None)
            {
                e.Handled = true;
                Send();
            }
        };
        field.TextChanged += (_, _) => UpdateKeys();
        field.GotKeyboardFocus += (_, _) => UpdateKeys();
        field.LostKeyboardFocus += (_, _) => UpdateKeys();
        plusTile.Child = plusIcon;
        sendTile.Child = sendIcon;
        sendBadge.Child = sendCount;
        plus = new PlainButton(plusTile, () => ShowTray(!trayOpen));
        var sendKey = new Grid();
        sendKey.Children.Add(sendTile);
        sendKey.Children.Add(sendBadge);
        send = new PlainButton(sendKey, Send).Named("Send").Help("Send (Enter)");
        fieldFrame = new Border
        {
            Child = FieldKeys.Row(AgentParts.WithHint(field, hint), field, () => Editor().ShowDialog()),
            CornerRadius = new CornerRadius(18),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 0, 10, 0),
            MinHeight = 36,
        };
        // A dictation puts its words at the cursor, else at the end of the text.
        voice = VoiceBar.Insert(model.Core, field, fieldFrame, send, key: 36);
        var row = Ui.H(8, plus.Top(), voice.Fill());
        clipSend = new FluxButton("Send", ButtonKind.Text, SendClipboard);
        clipRow.Child = Ui.H(10, clipIcon, Ui.V(0, clipSource, clipText).Fill(), clipSend);
        clipTimer.Tick += (_, _) => ReadClipboard();
        tray = new ChatTray(model, () => ShowTray(false), Update);
        frame = new Border
        {
            Child = new Border { Child = Ui.V(10, clipRow, row, trayHost), MaxWidth = Metrics.MaxContentWidth },
            BorderThickness = new Thickness(1, 1, 1, 0),
            CornerRadius = new CornerRadius(20, 20, 0, 0),
            Padding = new Thickness(Metrics.Gutter, 12, Metrics.Gutter, 10),
        };
        frame.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && trayOpen)
            {
                e.Handled = true;
                ShowTray(false);
            }
        };
        Root = frame;
        frame.Loaded += (_, _) =>
        {
            ReadClipboard();
            clipTimer.Start();
        };
        frame.Unloaded += (_, _) => clipTimer.Stop();
        Update();
    }

    // The computer of the chat, while it can take text and files.
    DeviceSnapshot? Ready() => model.PairedDevice(deviceId) is { Online: true } d && d.Accepts(PacketType.Share) ? d : null;

    string Name => model.DeviceOf(deviceId)?.Name ?? "the computer";

    // Opens or closes the tray. An open tray reads the newest screenshots again.
    void ShowTray(bool open)
    {
        trayOpen = open;
        if (open)
        {
            tray.Load();
        }
        Update();
    }

    // Reads the clipboard of this computer when its change count is new. A
    // copy that the source marks as private shows "Hidden text".
    void ReadClipboard()
    {
        var clipboard = Features.Clipboard;
        var stamp = clipboard.ChangeCount;
        if (stamp == clipStamp)
        {
            return;
        }
        clipStamp = stamp;
        string shown;
        try
        {
            shown = clipboard.HoldsPrivate ? ClipEvent.HiddenText
                : clipboard.ReadText() is { } text && text.Trim().Length > 0 ? ClipEvent.MakePreview(text, 400) : "";
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            // The clipboard is busy. The next tick reads it again.
            clipStamp = -1;
            return;
        }
        clipEmpty = shown.Length == 0;
        clipText.Text = clipEmpty ? "Copy text on this computer" : shown;
        clipText.FontFamily = clipEmpty || shown == ClipEvent.HiddenText ? Faces.Body : Faces.Mono;
        UpdateKeys();
    }

    void SendClipboard()
    {
        if (model.Core.Plugin<ClipboardPlugin>() is not { } plugin)
        {
            return;
        }
        if (model.PairedDevice(deviceId) is not { Online: true } d || !d.Accepts(PacketType.Clipboard))
        {
            model.Show($"{Name} is not reachable");
            return;
        }
        _ = plugin.SendClipboardAsync(d.Id);
    }

    // The field, for the tests.
    internal TextBox Field => this.field;

    // The field with the mic key and Send, for the tests.
    internal VoiceBar Voice => voice;

    // The tray, for the tests.
    internal ChatTray Tray => tray;

    // True while the tray shows, for the tests.
    internal bool TrayOpen => trayOpen;

    // The larger editor of the field, with Send. The text changes in the
    // field at once, and Send takes the same way as Send in the dock.
    internal FieldEditor Editor() => new(Window.GetWindow(Root), "Text or link", field.Text, text => field.Text = text,
        new FieldEditorAction("Send", CanSend, Send));

    // True when the field has text for the text feature, or a screenshot is selected.
    bool CanSend() => SendText is not null && field.Text.Trim().Length > 0 || tray.Selected.Count > 0;

    // The features that send text or a link. The share feature sets it.
    public static Func<AppModel, string, string, bool>? SendText { get; set; }

    // The tools of the tray, as a title, an icon, and an action for the
    // computer of the chat. The features add them, in the order of the tray.
    public static List<Func<AppModel, DeviceSnapshot, (string Title, string Glyph, Action Run)?>> Tools { get; } = [];

    // Sends the selected screenshots, then the text. A single web address
    // opens in the browser of the computer, and other text goes on its
    // clipboard.
    void Send()
    {
        var text = field.Text.Trim();
        var files = tray.Selected.ToArray();
        if (text.Length == 0 && files.Length == 0)
        {
            return;
        }
        if (Ready() is not { } d)
        {
            model.Show($"{Name} is not reachable");
            return;
        }
        if (files.Length > 0 && model.Core.Plugin<SharePlugin>() is { } share)
        {
            share.SendFiles(files, d.Id);
            tray.Clear();
        }
        if (text.Length > 0 && SendText is not null && SendText(model, d.Id, text))
        {
            field.Clear();
        }
        Update();
    }

    // Draws the colors, the state of the keys, and the tray. The field stays.
    public void Update()
    {
        UpdateKeys();
        trayHost.Child = trayOpen && model.PairedDevice(deviceId) is { } device ? tray.Build(device) : null;
        trayHost.Shown(trayOpen);
    }

    // Draws the colors and the state of the keys, after each change of the field.
    void UpdateKeys()
    {
        var tn = Tn.Current;
        var ready = Ready();
        hint.Text = $"Message {Name}";
        hint.Foreground = tn.Dim;
        System.Windows.Automation.AutomationProperties.SetName(field, hint.Text);
        frame.Background = tn.Tile;
        frame.BorderBrush = tn.Line;
        fieldFrame.Background = tn.Bg;
        fieldFrame.BorderBrush = field.IsKeyboardFocused ? tn.Accent : tn.LineHi;
        field.Foreground = tn.Text;
        field.CaretBrush = tn.Accent;
        field.FontFamily = Faces.Body;
        // The mic key shows while the text has a place to go.
        voice.Enabled = ready is not null;
        plusTile.Background = trayOpen ? tn.Accent : tn.Line;
        plusIcon.Text = trayOpen ? Icons.Close : Icons.Add;
        plusIcon.Foreground = trayOpen ? tn.OnAccent : tn.Text;
        plus.Named(trayOpen ? "Close the tools" : "Tools").Help(trayOpen ? "Close the tools (Esc)" : "Screenshots and tools");
        var canSend = CanSend();
        sendTile.Background = canSend ? tn.Accent : tn.Tile;
        sendTile.BorderBrush = canSend ? tn.Accent : tn.Line;
        sendIcon.Foreground = canSend ? tn.OnAccent : tn.Dim;
        send.IsEnabled = canSend;
        var count = tray.Selected.Count;
        sendBadge.Shown(count > 0);
        sendBadge.Background = tn.Text;
        sendCount.Foreground = tn.Bg;
        sendCount.Text = count.ToString(System.Globalization.CultureInfo.InvariantCulture);
        send.Named(count switch
        {
            0 => "Send",
            1 => "Send, 1 screenshot",
            _ => $"Send, {count} screenshots",
        });
        var clipboard = model.Core.Plugin<ClipboardPlugin>() is not null;
        clipRow.Shown(clipboard);
        clipRow.Background = tn.Bg;
        clipRow.BorderBrush = tn.Line;
        clipIcon.Foreground = tn.Cyan;
        clipSource.Text = clipEmpty ? "Clipboard on this computer · empty" : "Clipboard on this computer";
        clipSource.Foreground = tn.Cyan;
        clipText.Foreground = clipEmpty ? tn.Sub : tn.Text;
        var canClip = clipboard && !clipEmpty && model.PairedDevice(deviceId) is { Online: true } d && d.Accepts(PacketType.Clipboard);
        clipSend.IsEnabled = canClip;
        clipSend.Named("Send the clipboard").Help($"Send the clipboard of this computer to {Name}");
    }
}

// The computer for an action: the computer in scope, or the only online
// computer that takes it. With more computers, the user picks 1.
public static class Targets
{
    public static string? Pick(AppModel model, string accepts) =>
        Among(model, model.ConnectedPaired.Where(d => d.Accepts(accepts) && (model.Scope is null || d.Id == model.Scope)).ToArray(),
            model.Scope is null ? "No computer is connected" : $"{Shared.ScopeName(model)} is not reachable");

    // The only computer of ready, or the one that the user picks. With none,
    // the window shows the message none.
    public static string? Among(AppModel model, IReadOnlyList<DeviceSnapshot> ready, string none)
    {
        switch (ready.Count)
        {
            case 0:
                model.Show(none);
                return null;
            case 1:
                return ready[0].Id;
            default:
                return Choose(ready);
        }
    }

    // Asks which computer takes the action.
    static string? Choose(IReadOnlyList<DeviceSnapshot> devices)
    {
        string? chosen = null;
        Window? w = null;
        var rows = devices.Select(d => (UIElement)new PlainButton(Ui.Tile(Ui.H(10,
                Ui.Icon(Texts.Symbol(d), 15, Tn.Current.Accent), Ui.Text(d.Name, 13, FontWeights.SemiBold).Fill()), padding: 10), () =>
            {
                chosen = d.Id;
                w!.Close();
            }).Named(d.Name)).ToList();
        var body = Ui.V(Metrics.Gap, new UIElement[] { Ui.Text("Which computer?", 17, FontWeights.SemiBold) }.Concat(rows));
        w = new Window
        {
            Title = "Which computer?",
            Owner = Application.Current?.MainWindow,
            Width = 340,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
            Background = Tn.Current.TileHi,
            Content = Ui.Box(body, 20, 18, 20, 18),
        };
        w.InputBindings.Add(new KeyBinding(new Relay(w.Close), Key.Escape, ModifierKeys.None));
        w.ShowDialog();
        return chosen;
    }
}
