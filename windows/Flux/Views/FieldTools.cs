using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace Flux;

// The clear key and the expand key of the text fields. The agent replies,
// the field of the chat, the type field of the touchpad and the remote
// desktop, and the searches use them. FieldTools.swift of the Mac app has
// the same parts.
public static class FieldKeys
{
    // The glyphs of Segoe Fluent Icons for the keys.
    public const string ClearGlyph = "";
    public const string ExpandGlyph = "";

    // The help of an expand key that has no other help.
    public const string ExpandHelp = "Open a larger editor";

    // The clear key of a field. It shows while the field has text. A click
    // empties the field and gives it the focus, then cleared runs, for
    // example to draw the field again.
    public static PlainButton Clear(TextBox field, Action? cleared = null)
    {
        var key = new FieldKey(ClearGlyph, 10, () =>
        {
            field.Clear();
            field.Focus();
            cleared?.Invoke();
        }).Named("Clear").Help("Clear the text");
        void Show() => key.Visibility = field.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Show();
        field.TextChanged += (_, _) => Show();
        return key;
    }

    // The key that opens a larger editor for the text of a field.
    public static PlainButton Expand(Action open, string help = ExpandHelp) =>
        new FieldKey(ExpandGlyph, 11, open).Named(help).Help(help);

    // The field with the clear key at its trailing edge, and the expand key
    // after the clear key when expand is set. The keys line up with the last
    // line of the text, in the middle of a line of 34 px.
    public static Stack Row(UIElement view, TextBox field, Action? expand = null)
    {
        var clear = Clear(field);
        var open = expand is null ? null : Expand(expand);
        foreach (var k in new[] { clear, open })
        {
            if (k is not null)
            {
                k.VerticalAlignment = VerticalAlignment.Bottom;
                k.Margin = new Thickness(0, 0, 0, 7);
            }
        }
        return Ui.H(6, view.Fill(), clear, open);
    }

    // A small key with a glyph in the second ink. It takes the color of a
    // new theme while it shows.
    sealed class FieldKey : PlainButton
    {
        readonly TextBlock glyph;

        public FieldKey(string glyph, double size, Action click)
        {
            this.glyph = Ui.Icon(glyph, size, Tn.Current.Sub).Width(20).Height(20);
            Content = this.glyph;
            HorizontalAlignment = HorizontalAlignment.Left;
            VerticalAlignment = VerticalAlignment.Center;
            Click += (_, _) => click();
            Loaded += (_, _) =>
            {
                Tn.Changed += Theme;
                Theme();
            };
            Unloaded += (_, _) => Tn.Changed -= Theme;
        }

        void Theme() => glyph.Foreground = Tn.Current.Sub;
    }
}

// An action of a field editor, such as Send. It closes the editor first.
// The editor calls Enabled at each change of the text.
public sealed record FieldEditorAction(string Title, Func<bool> Enabled, Action Run, string Help = "");

// A larger editor for the text of a field, in a dialog. The text changes in
// the field at once, so Done only closes the dialog. With limit, the text
// stops at that many characters, and cut can stop it at a rule of its own,
// such as a count of lines. Ctrl+Enter runs the action, and Esc closes the
// dialog. FieldEditor of FieldTools.swift has the same rules.
public sealed class FieldEditor : Window
{
    readonly Action<string> set;
    readonly FieldEditorAction? action;
    readonly int? limit;
    readonly Func<string, string>? cut;
    readonly FluxButton clear;
    readonly FluxButton? run;
    readonly TextBlock count;
    bool cutting;

    public FieldEditor(Window? owner, string title, string text, Action<string> set, FieldEditorAction? action = null,
                       string? hint = null, int? limit = null, Func<string, string>? cut = null, string doneTitle = "Done")
    {
        var tn = Tn.Current;
        this.set = set;
        this.action = action;
        this.limit = limit;
        this.cut = cut;
        Box = new TextBox
        {
            Text = text,
            AcceptsReturn = true,
            AcceptsTab = false,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 13,
            FontFamily = Faces.Body,
            Padding = new Thickness(8),
            Background = tn.Bg,
            Foreground = tn.Text,
            CaretBrush = tn.Accent,
            BorderBrush = tn.LineHi,
        };
        AutomationProperties.SetName(Box, title);
        // The spelling of this computer can correct the text before it goes.
        SpellCheck.SetIsEnabled(Box, true);
        count = Ui.Text("", 11, color: tn.Sub, mono: true);
        clear = new FluxButton("Clear", ButtonKind.Text, () =>
        {
            Box.Clear();
            Box.Focus();
        }).Named("Clear the editor").Help("Clear the text");
        var done = new FluxButton(doneTitle, ButtonKind.Outlined, Close).Named(doneTitle).Help($"{doneTitle} (Esc)");
        if (action is not null)
        {
            run = new FluxButton(action.Title, ButtonKind.Filled, RunAction).Named(action.Title)
                .Help((action.Help.Length > 0 ? action.Help : action.Title) + " (Ctrl+Enter)");
        }
        var head = Ui.Text(title, 17, FontWeights.SemiBold, wrap: true).Margin(0, 0, 0, 12);
        var foot = Ui.V(8,
            hint is null ? null : Ui.Text(hint, 12, color: tn.Sub, wrap: true),
            count,
            Ui.H(8, clear, Ui.Spacer(), done, run).Margin(0, 4, 0, 0)).Margin(0, 12, 0, 0);
        var layout = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(foot, Dock.Bottom);
        layout.Children.Add(head);
        layout.Children.Add(foot);
        layout.Children.Add(Box);
        Title = title;
        Owner = owner;
        Width = 480;
        Height = 400;
        MinWidth = 360;
        MinHeight = 300;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Background = tn.TileHi;
        Foreground = tn.Text;
        FontFamily = Faces.Body;
        Content = Ui.Box(layout, 24, 22, 24, 20);
        Box.TextChanged += (_, _) => Changed();
        // The window takes the keys before the text box, which uses Enter for a new line.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                e.Handled = true;
                Close();
            }
            else if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
            {
                e.Handled = true;
                RunAction();
            }
        };
        Loaded += (_, _) =>
        {
            Box.Focus();
            Box.CaretIndex = Box.Text.Length;
        };
        Update();
    }

    // The text of the editor. Tests set it.
    internal TextBox Box { get; }

    // Closes the editor and runs the action, while the action is enabled.
    public void RunAction()
    {
        if (action is null || !action.Enabled())
        {
            return;
        }
        Close();
        action.Run();
    }

    void Changed()
    {
        if (cutting)
        {
            return;
        }
        var text = Box.Text;
        var next = cut?.Invoke(text) ?? text;
        if (limit is { } n && new StringInfo(next).LengthInTextElements > n)
        {
            next = new StringInfo(next).SubstringByTextElements(0, n);
        }
        if (next != text)
        {
            var caret = Box.CaretIndex;
            cutting = true;
            Box.Text = next;
            Box.CaretIndex = Math.Min(caret, next.Length);
            cutting = false;
        }
        set(next);
        Update();
    }

    void Update()
    {
        var length = new StringInfo(Box.Text).LengthInTextElements;
        // The count shows near the limit, so that the end of the text does not surprise.
        var near = limit is { } n && length > n * 9 / 10;
        count.Text = near ? $"{length} of {limit} characters" : "";
        count.Shown(near);
        clear.IsEnabled = Box.Text.Length > 0;
        if (run is not null && action is not null)
        {
            run.IsEnabled = action.Enabled();
        }
    }
}
