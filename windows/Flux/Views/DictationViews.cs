using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using FluxKit;

namespace Flux;

// The dictation language of this computer, for all text fields. The herdr
// feature keeps it in its settings, as on the Mac. An empty tag is
// Automatic: the speech language of Windows.
public static class VoiceLanguage
{
    public static string Get(FluxCore core) => core.Plugin<HerdrPlugin>()?.Model.DictationLanguage ?? "";

    public static void Set(FluxCore core, string tag)
    {
        if (core.Plugin<HerdrPlugin>() is { } herdr)
        {
            herdr.Model.DictationLanguage = tag;
        }
    }

    // The name of a tag for the texts, such as "English (United States)".
    public static string Name(string tag) => tag.Length == 0 ? "Automatic" : DictationText.LanguageName(tag);

    // Opens the languages of the speech recognizer at the anchor, with
    // Automatic first. A pick keeps the language for all fields, then picked
    // runs. The last item opens the speech settings of Windows, where the
    // user adds a speech language.
    public static void Menu(FrameworkElement anchor, FluxCore core, Action picked)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        var current = Get(core);
        var system = Dictation.SystemLanguage();
        foreach (var tag in new[] { "" }.Concat(Dictation.Languages()))
        {
            var header = tag.Length == 0 && system.Length > 0 ? $"Automatic · {DictationText.LanguageName(system)}" : Name(tag);
            var item = new MenuItem { Header = header, IsChecked = tag == current };
            item.Click += (_, _) =>
            {
                Set(core, tag);
                picked();
            };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        var settings = new MenuItem { Header = "Speech Settings…" };
        settings.Click += (_, _) => ThisComputer.Open("ms-settings:speech");
        menu.Items.Add(settings);
        menu.IsOpen = true;
    }

    // Where the audio goes, for the language chip.
    public static string About(string tag) =>
        $"Windows transcribes {(tag.Length == 0 ? "the speech language of Windows" : DictationText.LanguageName(tag))} online, so the audio goes to Microsoft.";
}

// A text field with a mic key, for the text fields of the app. At rest it
// shows the field, the mic key, and the trailing key, such as Send. While
// this computer listens, the listening panel takes the full width, and the
// mic key moves into its corner as the stop key. The mic key stays the same
// element, so that a press and hold keeps working while the panel opens.
// The words of a dictation go to onText. Under the bar, a line tells why a
// dictation failed. While Enabled is off, the mic key hides, unless a
// dictation runs, so that the user can still stop it. The bar drops its
// dictation when it leaves the window, because its field is gone.
// DictationBar and VoiceBar of DictationViews.swift of the Mac app have the
// same parts.
public sealed class VoiceBar : View
{
    const double Gap = 8;
    // The inner margin of the listening panel. The stop key sits this far from its corner.
    const double PanelPad = 12;
    // A press on the mic key that lasts this long is push to talk. The release then stops the dictation.
    static readonly TimeSpan PushToTalk = TimeSpan.FromSeconds(0.35);

    readonly FluxCore core;
    readonly Action<string> onText;
    readonly Border trailingHost = new() { VerticalAlignment = VerticalAlignment.Bottom };
    readonly Border slot;
    readonly Stack rest;
    readonly Border panel = new() { CornerRadius = new CornerRadius(Metrics.TileCorner), BorderThickness = new Thickness(1.5) };
    readonly Ellipse dot = Ui.Dot(Brushes.Transparent);
    readonly TextBlock state = Ui.Text("", 11, FontWeights.SemiBold, mono: true);
    readonly Border chip = new() { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), Padding = new Thickness(7, 2, 7, 2) };
    readonly TextBlock chipGlobe = Ui.Icon(ControlGlyphs.Globe, 10);
    readonly TextBlock chipText = Ui.Text("", 11, mono: true);
    readonly TextBlock chipChevron = Ui.Icon(Icons.ChevronDown, 8);
    readonly PlainButton chipView;
    readonly TextBlock clock = Ui.Text("", 12, mono: true);
    readonly TextBlock cancelGlyph = Ui.Icon(Icons.Close, 11);
    readonly PlainButton cancel;
    readonly TextBlock words = new() { FontSize = 13.5, FontFamily = Faces.Body, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Bottom };
    readonly ScrollViewer wordsScroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        MaxHeight = 96,
        Focusable = false,
    };
    readonly MicKey mic;
    readonly Grid bar = new();
    readonly Border problemHost = new();
    readonly Stack root;
    // Moves the time of a dictation.
    readonly DispatcherTimer ticker = new() { Interval = TimeSpan.FromSeconds(0.5) };
    bool enabled = true;
    // True after a pick of a language, until the dictation starts again.
    bool restart;
    // The distance of the resting mic key from the right edge: the width of the trailing key and the gap.
    double restRight;

    public VoiceBar(FluxCore core, UIElement field, Action<string> onText, UIElement? trailing = null, double key = 34)
    {
        this.core = core;
        this.onText = onText;
        Watch(Dictation);
        Ui.Detach(field);
        if (trailing is not null)
        {
            Ui.Detach(trailing);
            trailingHost.Child = trailing;
        }
        trailingHost.Shown(trailing is not null);
        // The mic key lies over this place.
        slot = new Border { Width = key, Height = key, VerticalAlignment = VerticalAlignment.Bottom };
        rest = Ui.H(Gap, field.Fill(), slot, trailingHost);
        chip.Child = Ui.H(4, chipGlobe, chipText, chipChevron);
        chipView = new PlainButton(chip, () => PickLanguage(chip)).Named("Dictation language");
        cancel = new PlainButton(cancelGlyph.Width(20).Height(20), Cancel).Named("Cancel dictation").Help("Drop the dictation");
        if (!Motion.Reduced)
        {
            dot.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.3, new Duration(TimeSpan.FromSeconds(0.7)))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
            });
        }
        wordsScroll.Content = words;
        var header = Ui.H(8, dot, state, chipView, Ui.Spacer(8), clock, cancel);
        // The stop key lies over this place: its width, its margin, and a gap.
        var wordsRow = Ui.H(0, wordsScroll.Fill(), new Border { Width = key + PanelPad, Height = key });
        panel.Child = Ui.V(6, header, wordsRow);
        panel.Padding = new Thickness(PanelPad, 8, 8, PanelPad);
        panel.Named("Dictation");
        mic = new MicKey(this, key) { HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
        bar.Children.Add(rest);
        bar.Children.Add(panel);
        bar.Children.Add(mic);
        root = Ui.V(6, bar, problemHost);
        trailingHost.SizeChanged += (_, _) => Place();
        ticker.Tick += (_, _) => clock.Text = Dictation.Clock;
        Unloaded += (_, _) =>
        {
            ticker.Stop();
            // A move to another place in the window loads the bar again before this check runs.
            Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
            {
                if (!IsLoaded)
                {
                    restart = false;
                    Dictation.Cancel();
                }
            });
        };
        // The field shows at once, before the first turn of the UI thread.
        Redraw();
    }

    // The dictation of this bar.
    public Dictation Dictation { get; } = new();

    // While false, the mic key hides, unless a dictation runs.
    public bool Enabled
    {
        get => enabled;
        set
        {
            if (enabled != value)
            {
                enabled = value;
                Invalidate();
            }
        }
    }

    // The mic key, for the tests.
    internal PlainButton Mic => mic;

    // Starts a dictation in the dictation language of this computer, for
    // example from the mic button of the remote desktop.
    public void Start()
    {
        if (Dictation.State != Dictation.Phase.Idle)
        {
            return;
        }
        Dictation.Start(VoiceLanguage.Get(core), Spoken);
    }

    // Stops the dictation. The words that the recognizer heard still go to
    // the field. A dictation that did not start yet heard nothing, so it ends.
    public void Stop()
    {
        switch (Dictation.State)
        {
            case Dictation.Phase.Listening:
                Dictation.Stop();
                break;
            case Dictation.Phase.Starting:
                Dictation.Cancel();
                break;
        }
    }

    // Puts a final text of a dictation in its place. The dictation calls it,
    // and the checks call it with a sample text.
    internal void Spoken(string text) => onText(text);

    // A bar whose words go in the field by the insert rule: at the cursor of
    // the user, else at the end of the text.
    public static VoiceBar Insert(FluxCore core, TextBox field, UIElement view, UIElement? trailing = null, double key = 34)
    {
        var cursor = new SpokenCursor(field);
        return new VoiceBar(core, view, cursor.Insert, trailing, key);
    }

    // A bar whose words replace the search, without the punctuation of a sentence.
    public static VoiceBar Search(FluxCore core, TextBox search, UIElement view) =>
        new(core, view, spoken =>
        {
            search.Text = DictationText.Query(spoken);
            search.CaretIndex = search.Text.Length;
        });

    protected override UIElement Build()
    {
        var d = Dictation;
        if (restart && d.State == Dictation.Phase.Idle)
        {
            restart = false;
            Start();
        }
        var active = d.State != Dictation.Phase.Idle;
        var showMic = active || enabled;
        rest.Shown(!active);
        panel.Shown(active);
        slot.Shown(showMic);
        mic.Shown(showMic);
        mic.Update(d.State);
        Place();
        if (active)
        {
            DrawPanel();
            ticker.Start();
        }
        else
        {
            ticker.Stop();
        }
        var problem = Problem();
        problemHost.Child = problem;
        problemHost.Shown(problem is not null);
        return root;
    }

    // Puts the mic key in its place: next to the field at rest, or in the
    // corner of the panel while this computer listens.
    void Place()
    {
        if (trailingHost.Visibility == Visibility.Visible && trailingHost.ActualWidth > 0)
        {
            restRight = trailingHost.ActualWidth + Gap;
        }
        var active = Dictation.State != Dictation.Phase.Idle;
        var right = trailingHost.Visibility == Visibility.Visible || active ? restRight : 0;
        mic.Margin = active ? new Thickness(0, 0, PanelPad, PanelPad) : new Thickness(0, 0, right, 0);
    }

    // The listening panel: the state, the language, the time, and the words
    // that the recognizer still revises. The words that it settled are in
    // the field already.
    void DrawPanel()
    {
        var tn = Tn.Current;
        var d = Dictation;
        var listening = d.State == Dictation.Phase.Listening;
        var ink = listening ? tn.Red : tn.Magenta;
        panel.Background = tn.Bg;
        // The border runs in the colors of the active window on Omarchy.
        panel.BorderBrush = tn.ActiveBorder();
        dot.Fill = ink;
        state.Foreground = ink;
        state.Text = d.State switch
        {
            Dictation.Phase.Starting => "starting",
            Dictation.Phase.Listening => "listening",
            _ => "transcribing",
        };
        var chosen = VoiceLanguage.Get(core);
        var tag = d.LanguageTag.Length > 0 ? d.LanguageTag : chosen;
        chipText.Text = tag.Length == 0 ? "auto" : tag;
        chip.Background = tn.Tile;
        chip.BorderBrush = tn.Line;
        foreach (var t in new[] { chipGlobe, chipText, chipChevron })
        {
            t.Foreground = tn.Sub;
        }
        chipView.Help(VoiceLanguage.About(tag) + " Click to choose another language.");
        clock.Text = d.State == Dictation.Phase.Starting ? "" : d.Clock;
        clock.Foreground = tn.Sub;
        cancelGlyph.Foreground = tn.Sub;
        if (d.Partial.Length > 0)
        {
            words.Text = d.Partial;
            words.Foreground = tn.Sub;
        }
        else
        {
            words.Text = d.State switch
            {
                Dictation.Phase.Starting => "Starting the speech recognition of Windows…",
                Dictation.Phase.Listening => "Speak now. Windows transcribes online, so the audio goes to Microsoft.",
                _ => "Writing the last words…",
            };
            words.Foreground = tn.Dim;
        }
        // The newest words stay in view.
        wordsScroll.ScrollToEnd();
    }

    // Why the last dictation failed, with the action that solves it, or null.
    UIElement? Problem()
    {
        var d = Dictation;
        if (d.Error is not { } problem)
        {
            return null;
        }
        var tn = Tn.Current;
        var actions = new List<UIElement?>();
        if (d.LanguageError)
        {
            FluxButton? choose = null;
            choose = new FluxButton("Choose a language", ButtonKind.Text, () => VoiceLanguage.Menu(choose!, core, Restart)).Named("Choose a language");
            actions.Add(choose);
        }
        if (problem is Dictation.SpeechDenied or Dictation.MicDenied)
        {
            var settings = problem == Dictation.SpeechDenied ? "ms-settings:privacy-speech" : "ms-settings:privacy-microphone";
            actions.Add(new FluxButton("Open Privacy Settings", ButtonKind.Text, () => ThisComputer.Open(settings)).Named("Open Privacy Settings"));
        }
        return Ui.H(10, new UIElement?[] { Ui.Text(problem, 12, color: tn.Red, wrap: true).Fill() }.Concat(actions));
    }

    // Opens the languages. The dictation goes on until the user picks one.
    void PickLanguage(FrameworkElement anchor) => VoiceLanguage.Menu(anchor, core, Restart);

    // Starts the dictation again in the language that the user picked. The
    // words so far still go to the field.
    void Restart()
    {
        Stop();
        restart = true;
        Invalidate();
    }

    void Cancel()
    {
        restart = false;
        Dictation.Cancel();
    }

    // The key that starts and stops a dictation. A click starts it, and the
    // next click stops it. A press and hold is push to talk: the dictation
    // stops at the release. While this computer listens, the key is red. A
    // press does not take the focus, so that the words go to the cursor of
    // the field.
    sealed class MicKey : PlainButton
    {
        readonly VoiceBar bar;
        readonly Border tile;
        long? pressedAt;
        bool stopOnRelease;

        public MicKey(VoiceBar bar, double size)
        {
            this.bar = bar;
            tile = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2) };
            Content = tile;
            Click += (_, _) => Toggle();
            PreviewMouseLeftButtonDown += Pressed;
            PreviewMouseLeftButtonUp += Released;
            // Another window took the mouse: the dictation goes on as after a click.
            LostMouseCapture += (_, _) => pressedAt = null;
        }

        public void Update(Dictation.Phase phase)
        {
            var tn = Tn.Current;
            var listening = phase == Dictation.Phase.Listening;
            tile.Background = listening ? tn.Red : tn.Line;
            tile.Child = phase switch
            {
                Dictation.Phase.Idle => Ui.Icon(Icons.Mic, 14, tn.Text),
                Dictation.Phase.Listening => Ui.Icon(AgentGlyphs.Stop, 13, tn.OnAccent),
                _ => Parts.Spinner(14, tn.Sub),
            };
            var (name, help) = phase switch
            {
                Dictation.Phase.Idle => ("Dictate", "Dictate. Click to start and stop, or press and hold to talk."),
                Dictation.Phase.Stopping => ("Dictation", "Flux writes the last words"),
                _ => ("Stop the dictation", "Stop the dictation"),
            };
            this.Named(name);
            ToolTip = help;
        }

        void Toggle()
        {
            if (bar.Dictation.State == Dictation.Phase.Idle)
            {
                bar.Start();
            }
            else
            {
                bar.Stop();
            }
        }

        void Pressed(object sender, MouseButtonEventArgs e)
        {
            e.Handled = true;
            if (pressedAt is not null)
            {
                return;
            }
            pressedAt = Stopwatch.GetTimestamp();
            var phase = bar.Dictation.State;
            stopOnRelease = phase != Dictation.Phase.Idle;
            if (phase == Dictation.Phase.Idle)
            {
                bar.Start();
            }
            CaptureMouse();
        }

        void Released(object sender, MouseButtonEventArgs e)
        {
            if (pressedAt is not { } at)
            {
                return;
            }
            e.Handled = true;
            pressedAt = null;
            ReleaseMouseCapture();
            if (stopOnRelease || Stopwatch.GetElapsedTime(at) >= PushToTalk)
            {
                bar.Stop();
            }
        }
    }
}

// The place of the words of a dictation in a field: the cursor of the user,
// else the end of the text. The cursor counts while the field has the focus,
// and after the user leaves the field. A change of the text by the app, such
// as a clear or the editor, drops the cursor, so that the next words go at
// the end. The Mac keeps the cursor of each field in the same way.
sealed class SpokenCursor
{
    readonly TextBox field;
    bool kept;
    bool inserting;

    public SpokenCursor(TextBox field)
    {
        this.field = field;
        field.LostKeyboardFocus += (_, _) => kept = true;
        field.TextChanged += (_, _) =>
        {
            if (!inserting && !field.IsKeyboardFocusWithin)
            {
                kept = false;
            }
        };
    }

    public void Insert(string spoken)
    {
        inserting = true;
        Place(field, spoken, field.IsKeyboardFocusWithin || kept);
        inserting = false;
        // The next words follow these words.
        kept = true;
    }

    // Puts the words in the field at its cursor, in place of the selection,
    // or at the end of the text. The cursor goes after the words.
    internal static void Place(TextBox field, string spoken, bool atCursor)
    {
        var text = field.Text;
        var start = atCursor ? field.SelectionStart : text.Length;
        var end = atCursor ? field.SelectionStart + field.SelectionLength : text.Length;
        var edit = DictationText.Insert(text, start, end, spoken);
        field.Text = edit.Text;
        field.CaretIndex = edit.Cursor;
    }
}
