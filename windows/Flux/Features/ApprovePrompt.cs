using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using FluxKit;

namespace Flux;

// The windows of the approval prompt. The plugin asks for the prompt for
// each new request, and a click on the notification, the chat card, the
// banner, or the tray asks for it again. ApprovePromptWindow of the Mac app
// has the same job.
public static class ApprovePrompts
{
    static ApprovePromptWindow? window;

    // The handle of the prompt window while it shows, for the prompt of
    // Windows Hello. Each thread can read it.
    static long handle;

    // The open prompt window. Tests read it.
    internal static ApprovePromptWindow? Open => window;

    // Lets the plugin bring the prompt to the front for each new request.
    public static void Install(AppModel model)
    {
        if (model.Core.Plugin<ApprovePlugin>() is { } plugin)
        {
            plugin.Model.PresentRequested += () => Show(plugin);
        }
    }

    // Shows the prompt of the request that the model shows, in front of the
    // other windows.
    public static void Show(ApprovePlugin plugin)
    {
        if (plugin.Model.Shown is null)
        {
            return;
        }
        if (window is null)
        {
            var w = new ApprovePromptWindow(plugin);
            w.SourceInitialized += (_, _) => Interlocked.Exchange(ref handle, new WindowInteropHelper(w).Handle.ToInt64());
            w.Closed += (_, _) =>
            {
                Interlocked.Exchange(ref handle, 0);
                if (window == w)
                {
                    window = null;
                }
            };
            window = w;
        }
        window.Show();
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
    }

    // The window that the prompt of Windows Hello belongs to: the prompt
    // window, or 0 while it does not show.
    public static IntPtr Owner() => new(Interlocked.Read(ref handle));

    public static void Close() => window?.Close();
}

// 1 request from a computer, with Approve and Deny. Approve asks for Windows
// Hello, and this computer signs only after it. The window floats over the
// other windows, like an incoming call. Escape denies, and Enter does not
// approve, so that a key that the user typed for another window cannot
// approve. The window closes when the request ends: approved, denied,
// cancelled by the computer, or timed out. The result of an enrollment or a
// failure stays until the user closes it. The close button closes only the
// window, and the request stays open in the chat and in the tray until it
// ends. ApprovePrompt.swift of the Mac app has the same rules.
// docs/approve.md is the design.
public sealed class ApprovePromptWindow : Window
{
    readonly ApprovePlugin plugin;

    public ApprovePromptWindow(ApprovePlugin plugin)
    {
        this.plugin = plugin;
        Title = ApproveTexts.PromptTitle;
        Width = 460;
        MinHeight = 360;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        FontFamily = Faces.Body;
        Background = Tn.Current.TileHi;
        Content = new ApprovePromptView(plugin);
        Tn.Changed += Retheme;
        plugin.Model.PropertyChanged += ModelChanged;
        PreviewKeyDown += Key;
        Closed += (_, _) =>
        {
            Tn.Changed -= Retheme;
            plugin.Model.PropertyChanged -= ModelChanged;
            // A result that shows goes with the window.
            if (plugin.Model.Current is null)
            {
                plugin.CloseResult();
            }
        };
    }

    void Retheme() => Background = Tn.Current.TileHi;

    // The request ended, and no result shows. While Windows Hello asks, the
    // prompt does not float, so that the prompt of Windows Hello can come in
    // front of it.
    void ModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ApproveModel.Shown) && plugin.Model.Shown is null)
        {
            Close();
        }
        else if (e.PropertyName == nameof(ApproveModel.Phase))
        {
            Topmost = plugin.Model.Phase.Kind != ApprovePhaseKind.Working;
        }
    }

    void Key(object sender, KeyEventArgs e)
    {
        var asking = plugin.Model.Phase.Kind is ApprovePhaseKind.Ask or ApprovePhaseKind.Working;
        if (e.Key == System.Windows.Input.Key.Escape)
        {
            e.Handled = true;
            if (asking)
            {
                plugin.Deny();
            }
            else
            {
                plugin.CloseResult();
            }
        }
        else if (asking && e.Key is System.Windows.Input.Key.Enter or System.Windows.Input.Key.Return)
        {
            // Enter never approves.
            e.Handled = true;
        }
    }
}

// The content of the prompt: the request, the key code of an enrollment, or
// a failure. The layout draws again only when the request or the step
// changes, so that a button keeps the focus while the countdown goes down.
sealed class ApprovePromptView : View
{
    readonly ApprovePlugin plugin;
    readonly TextBlock expires = Ui.Text("", 12, color: Tn.Current.Sub, mono: true, align: TextAlignment.Center);
    string drawn = "";
    ThemeColors? drawnTheme;
    UIElement? root;

    public ApprovePromptView(ApprovePlugin plugin)
    {
        this.plugin = plugin;
        Watch(plugin.Model);
    }

    ApproveModel Model => plugin.Model;

    protected override UIElement Build()
    {
        var m = Model;
        expires.Text = m.ExpiresText ?? "";
        expires.Foreground = Tn.Current.Sub;
        expires.Shown(m.ExpiresText is not null);
        var key = $"{m.Shown?.ComputerId}|{m.Shown?.Id}|{m.Phase.Kind}|{m.Phase.Text}";
        if (root is not null && key == drawn && ReferenceEquals(drawnTheme, Tn.Current))
        {
            return root;
        }
        drawn = key;
        drawnTheme = Tn.Current;
        UIElement body = m.Phase.Kind switch
        {
            ApprovePhaseKind.Enrolled => Enrolled(m.Phase.Text),
            ApprovePhaseKind.Failed => Failed(m.Phase.Text),
            _ => m.Shown is { } r ? Ask(r, m.Phase.Kind == ApprovePhaseKind.Working) : new Border(),
        };
        root = Ui.Box(body, 28, 28, 28, 28);
        return root;
    }

    UIElement Ask(ApproveRequest r, bool working)
    {
        var tn = Tn.Current;
        var question = ApproveMessage.Question(r);
        var items = new List<UIElement?>
        {
            Ui.Icon(Icons.Fingerprint, 56, tn.Accent).Align(HorizontalAlignment.Center),
            Ui.Text(question, 20, wrap: true, align: TextAlignment.Center).Named(question),
        };
        foreach (var line in ApprovePlugin.Details(r, plugin.ReplacesKey(r)))
        {
            items.Add(Ui.Text(line, 13, color: tn.Sub, wrap: true, align: TextAlignment.Center));
        }
        if (r.Kind == ApproveKind.Approve)
        {
            items.Add(Ui.Text(ApproveTexts.ApproveHint, 13, color: tn.Red, wrap: true, align: TextAlignment.Center));
        }
        Ui.Detach(expires);
        items.Add(expires);
        var label = r.Kind == ApproveKind.Approve ? ApproveTexts.ApproveButton : ApproveTexts.EnrollButton;
        var deny = new FluxButton(ApproveTexts.DenyButton, ButtonKind.Outlined, plugin.Deny).Named(ApproveTexts.DenyButton).Help(ApproveTexts.DenyHelp);
        var approve = new FluxButton(label, ButtonKind.Filled, plugin.Approve, Icons.Fingerprint, enabled: !working).Named(label)
            .Help($"Ask {ApproveTexts.UserCheck}, then sign the request");
        // Enter on the focused button does not approve either.
        KeyboardNavigation.SetAcceptsReturn(approve, false);
        items.Add(Ui.H(12, deny, approve).Align(HorizontalAlignment.Center).Margin(0, 6, 0, 0));
        if (working)
        {
            items.Add(Ui.H(8, Parts.Spinner(14), Ui.Text(r.Kind == ApproveKind.Enroll ? ApproveTexts.EnrollWorking : ApproveTexts.Working, 13,
                color: tn.Sub, wrap: true)).Align(HorizontalAlignment.Center));
        }
        return Ui.V(14, items);
    }

    UIElement Enrolled(string code)
    {
        var tn = Tn.Current;
        var text = Ui.SelectableText(code, 26, color: tn.Text);
        text.FontWeight = FontWeights.SemiBold;
        text.TextWrapping = TextWrapping.NoWrap;
        var chip = new Border
        {
            Child = text,
            Background = tn.Line,
            CornerRadius = new CornerRadius(Metrics.ChipCorner),
            Padding = new Thickness(18, 10, 18, 10),
            HorizontalAlignment = HorizontalAlignment.Center,
        }.Named($"{ApproveTexts.KeyCode} {code}");
        var done = new FluxButton("Done", ButtonKind.Filled, plugin.CloseResult) { IsDefault = true }.Named("Done");
        return Ui.V(14,
            Ui.Icon(Icons.Fingerprint, 56, tn.Accent).Align(HorizontalAlignment.Center),
            Ui.Text(ApproveTexts.EnrolledTitle, 20, align: TextAlignment.Center),
            Ui.Text(ApproveTexts.EnrolledHint, 13, color: tn.Sub, wrap: true, align: TextAlignment.Center),
            chip,
            done.Align(HorizontalAlignment.Center));
    }

    UIElement Failed(string message)
    {
        var tn = Tn.Current;
        var close = new FluxButton("Close", ButtonKind.Filled, plugin.CloseResult) { IsDefault = true }.Named("Close");
        return Ui.V(14,
            Ui.Icon(Icons.Warning, 48, tn.Red).Align(HorizontalAlignment.Center),
            Ui.Text(message, 17, wrap: true, align: TextAlignment.Center),
            Ui.Text(ApproveTexts.FailedHint, 13, color: tn.Sub, wrap: true, align: TextAlignment.Center),
            close.Align(HorizontalAlignment.Center));
    }
}
