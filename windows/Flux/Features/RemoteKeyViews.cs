using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FluxKit;

namespace Flux;

// The glyphs of Segoe Fluent Icons that the Control features use beside Icons.
static class ControlGlyphs
{
    public const string Left = "";
    public const string Right = "";
    public const string Up = "";
    public const string Down = "";
    public const string Backspace = "";
    public const string Return = "";
    public const string Star = "";
    public const string StarFilled = "";
    public const string Globe = "";
    public const string Video = "";
    public const string Window = "";
    public const string Home = "";
}

// Turns the key events of WPF into the keys of the computer, for the
// touchpad and the remote desktop. RemoteKeyView of RemoteKeys.swift has
// the same rules: special keys go as special keys, shortcuts as text with
// modifiers, and other keys through the text input of Windows, so that dead
// keys, input methods, and the AltGr characters of the layout work.
public static class RemoteKeyInput
{
    // Maps 1 key with the modifiers that this computer holds, and sends it
    // when it goes to the computer. altGr is true while the right Alt key is
    // down. It returns the press. Tests call it with sample keys.
    public static RemotePress Press(RemoteKeyTarget target, Key key, ModifierKeys modifiers, bool altGr = false)
    {
        var virtualKey = KeyInterop.VirtualKeyFromKey(key);
        var held = RemoteMods.FromModifierKeys((int)modifiers);
        return target.KeyDown(virtualKey, held, KeyText.Plain(virtualKey, held.Shift), altGr);
    }

    // The key of a key event. Alt makes WPF report Key.System.
    public static Key KeyOf(KeyEventArgs e) => e.Key == Key.System ? e.SystemKey : e.Key;

    public static bool IsModifier(Key key) => key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or
        Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin;

    // Handles a key down of a view that types on the computer. A key that
    // went to the computer is handled, so that WPF and Windows do not use
    // it. A Compose press goes on to the text input of Windows, and
    // TextInput sends its text. A modifier alone sends nothing: it goes with
    // the next key.
    public static void KeyDown(RemoteKeyTarget target, KeyEventArgs e)
    {
        var key = KeyOf(e);
        if (key is Key.ImeProcessed or Key.DeadCharProcessed or Key.None)
        {
            return;
        }
        if (IsModifier(key))
        {
            // Alt alone would open the menu of the window.
            e.Handled = target.KeysReady && key is Key.LeftAlt or Key.RightAlt;
            return;
        }
        var press = Press(target, key, Keyboard.Modifiers, Keyboard.IsKeyDown(Key.RightAlt));
        e.Handled = press is RemotePress.SpecialKey or RemotePress.Text;
    }

    // Sends the text that the text input of Windows made.
    public static void TextInput(RemoteKeyTarget target, TextCompositionEventArgs e)
    {
        if (!target.KeysReady || e.Text.Length == 0 || e.Text.All(char.IsControl))
        {
            return;
        }
        target.TextInput(e.Text);
        e.Handled = true;
    }
}

// A pill with a dot and a short state, such as "Live".
public static class StatusPill
{
    public static Border Make(string text, Brush color)
    {
        var tn = Tn.Current;
        return new Border
        {
            Child = Ui.H(6, Ui.Dot(color, 7), Ui.Text(text, 11.5, FontWeights.Medium, color)),
            Background = tn.Tile,
            BorderBrush = tn.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Metrics.ChipCorner),
            Padding = new Thickness(9, 3, 10, 3),
            VerticalAlignment = VerticalAlignment.Center,
        }.Named(text);
    }
}

// A key of the key rows that stays on for the next key or text: ctrl,
// alt, shift, or super. It has the accent while it is on.
sealed class ModifierChip : PlainButton
{
    readonly string name;
    readonly Border chip;
    readonly TextBlock label;

    public ModifierChip(string text, string name, Action toggle)
    {
        this.name = name;
        label = Ui.Text(text, 12, FontWeights.SemiBold, mono: true, align: TextAlignment.Center);
        chip = new Border
        {
            Child = label,
            CornerRadius = new CornerRadius(Metrics.SmallCorner),
            BorderThickness = new Thickness(1),
            MinHeight = Metrics.ButtonHeight,
            MinWidth = 52,
            Padding = new Thickness(10, 0, 10, 0),
        };
        Content = chip;
        HorizontalAlignment = HorizontalAlignment.Left;
        Click += (_, _) => toggle();
        Update(false);
    }

    public void Update(bool on)
    {
        var tn = Tn.Current;
        chip.Background = on ? tn.AccentTile : tn.Tile;
        chip.BorderBrush = on ? tn.Accent : tn.Line;
        label.Foreground = on ? tn.Text : tn.Sub;
        var help = on ? $"Release {name}" : $"Hold {name} for the next key or text";
        ToolTip = help;
        AutomationProperties.SetName(this, name);
        AutomationProperties.SetItemStatus(this, on ? "On" : "Off");
        AutomationProperties.SetHelpText(this, help);
    }
}

// The key rows and the type field of the touchpad and the remote desktop:
// Escape, Tab, the arrows, Backspace, and Enter, then ctrl, alt, shift, and
// super, which hold for the next key or text, and the setting "Alt is Alt".
// Under them, the type field, the mic key, and Enter. The words of a
// dictation go to spoken, and the computer types them at its cursor.
// RemoteKeyRows and RemoteTypeField of RemoteKeys.swift and the keys of
// TouchpadView.swift have the same parts. The layout stays, so that the type
// field keeps its text and its focus.
public sealed class RemoteKeysPanel : View
{
    static readonly (RemoteKey Key, string Label, string Glyph, string Name)[] Keys =
    [
        (RemoteKey.Escape, "esc", "", "Escape"),
        (RemoteKey.Tab, "tab", "", "Tab"),
        (RemoteKey.Left, "", ControlGlyphs.Left, "Left"),
        (RemoteKey.Up, "", ControlGlyphs.Up, "Up"),
        (RemoteKey.Down, "", ControlGlyphs.Down, "Down"),
        (RemoteKey.Right, "", ControlGlyphs.Right, "Right"),
        (RemoteKey.Backspace, "", ControlGlyphs.Backspace, "Backspace"),
        (RemoteKey.Enter, "", ControlGlyphs.Return, "Enter"),
    ];

    readonly RemoteKeyTarget target;
    readonly List<(FluxButton Button, string Name)> keys = [];
    readonly ModifierChip ctrl;
    readonly ModifierChip alt;
    readonly ModifierChip shift;
    readonly ModifierChip super;
    readonly CheckBox altIsAlt = new() { Content = "Alt is Alt", VerticalAlignment = VerticalAlignment.Center };
    readonly RemoteTypeField typeField;
    readonly FluxButton enter;
    readonly VoiceBar voice;
    readonly Stack root;

    public RemoteKeysPanel(RemoteKeyTarget target, FluxCore core, Action<string> spoken)
    {
        this.target = target;
        Watch(target);
        foreach (var k in Keys)
        {
            var b = new FluxButton(k.Label, ButtonKind.Tonal, () => target.Key(k.Key), k.Glyph.Length > 0 ? k.Glyph : null).Stretched();
            b.Named(k.Name);
            keys.Add((b, k.Name));
        }
        ctrl = new ModifierChip("ctrl", "Control", () => target.Mods = target.Mods with { Ctrl = !target.Mods.Ctrl });
        alt = new ModifierChip("alt", "Alt", () => target.Mods = target.Mods with { Alt = !target.Mods.Alt });
        shift = new ModifierChip("shift", "Shift", () => target.Mods = target.Mods with { Shift = !target.Mods.Shift });
        super = new ModifierChip("super", "Super", () => target.Mods = target.Mods with { Super = !target.Mods.Super });
        altIsAlt.Click += (_, _) => target.AltIsAlt = altIsAlt.IsChecked == true;
        altIsAlt.ToolTip = "On: Alt is Alt for letters too. Off: AltGr types the characters of the layout of this computer, such as @ on a Nordic keyboard.";
        AutomationProperties.SetName(altIsAlt, "Alt is Alt");
        typeField = new RemoteTypeField(target);
        enter = new FluxButton("", ButtonKind.Tonal, () => target.Key(RemoteKey.Enter), ControlGlyphs.Return).Named("Enter");
        enter.MinWidth = 44;
        enter.Height = 34;
        voice = new VoiceBar(core, typeField, spoken, enter);
        root = Ui.V(10,
            Ui.H(6, keys.Select(k => (UIElement)k.Button.Fill())),
            Ui.H(6, ctrl, alt, shift, super, Ui.Spacer(12), altIsAlt),
            voice);
    }

    // The type field, for the tests.
    internal TextBox Field => typeField.Box;

    // The type field with its keys and the draft editor, for the tests.
    internal RemoteTypeField TypeField => typeField;

    // The type field with the mic key and Enter. The remote desktop starts a
    // dictation from its bar too.
    public VoiceBar Voice => voice;

    protected override UIElement Build()
    {
        var name = target.Name;
        foreach (var (button, keyName) in keys)
        {
            button.ToolTip = $"Press {keyName} on {name}";
        }
        var mods = target.Mods;
        ctrl.Update(mods.Ctrl);
        alt.Update(mods.Alt);
        shift.Update(mods.Shift);
        super.Update(mods.Super);
        altIsAlt.IsChecked = target.AltIsAlt;
        altIsAlt.Foreground = Tn.Current.Text;
        enter.ToolTip = $"Press Enter on {name}";
        typeField.Update();
        voice.Enabled = target.KeysReady;
        return root;
    }
}

// The text field that types on the computer. Each word goes out after its
// space, Enter sends the rest and presses Enter, and Backspace in the empty
// field presses Backspace on the computer. Text that an input method still
// composes waits. The clear key empties the field. Only the text after the
// last word is in the field, so the clear key sends no keys. The expand key
// opens the draft editor: the text goes to the computer only at Type, so
// that the spelling of this computer can correct it first. TypeField.swift
// and RemoteTypeField of RemoteKeys.swift of the Mac app have the same rules.
sealed class RemoteTypeField : Border
{
    readonly RemoteKeyTarget target;
    readonly TextBlock placeholder = Ui.Text("", 13);
    readonly PlainButton expand;
    bool composing;
    bool updating;

    public TextBox Box { get; } = new()
    {
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalContentAlignment = VerticalAlignment.Center,
        FontSize = 13,
        MinHeight = 34,
        Padding = new Thickness(4, 0, 4, 0),
    };

    public RemoteTypeField(RemoteKeyTarget target)
    {
        this.target = target;
        placeholder.IsHitTestVisible = false;
        placeholder.Margin = new Thickness(7, 0, 0, 0);
        expand = FieldKeys.Expand(() => Editor().ShowDialog());
        Box.TextChanged += (_, _) => Changed();
        Box.PreviewKeyDown += Pressed;
        TextCompositionManager.AddPreviewTextInputStartHandler(Box, (_, e) => composing = e.TextComposition.CompositionText.Length > 0);
        TextCompositionManager.AddPreviewTextInputUpdateHandler(Box, (_, e) => composing = true);
        TextCompositionManager.AddPreviewTextInputHandler(Box, (_, _) => composing = false);
        var grid = new Grid();
        grid.Children.Add(placeholder);
        grid.Children.Add(Box);
        Child = Ui.H(4, grid.Fill(), FieldKeys.Clear(Box, Update), expand);
        CornerRadius = new CornerRadius(Metrics.SmallCorner);
        BorderThickness = new Thickness(1);
        Padding = new Thickness(4, 0, 6, 0);
        Box.GotKeyboardFocus += (_, _) => Update();
        Box.LostKeyboardFocus += (_, _) => Update();
    }

    public void Update()
    {
        var tn = Tn.Current;
        var name = target.Name;
        Background = tn.Bg;
        BorderBrush = Box.IsKeyboardFocused ? tn.Accent : tn.LineHi;
        Box.Foreground = tn.Text;
        Box.CaretBrush = tn.Accent;
        Box.FontFamily = Faces.Body;
        Box.IsEnabled = target.KeysReady;
        placeholder.Text = $"Type on {name}";
        placeholder.Foreground = tn.Dim;
        placeholder.Visibility = Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(Box, $"Type on {name}");
        if (!composing && Box.Text != target.FieldText && !Box.IsKeyboardFocused)
        {
            SetText(target.FieldText);
        }
        expand.Named("Write a longer text").Help($"Write a longer text, then type it on {name}");
    }

    // The draft editor with Type. Each line break goes as Shift+Enter. The
    // draft stays after the editor closes, and Type empties it.
    internal FieldEditor Editor() => new(Window.GetWindow(this), $"Type on {target.Name}", target.Draft, text => target.Draft = text,
        new FieldEditorAction("Type", () => target.CanTypeDraft, target.TypeDraft, $"Type the text on {target.Name}"),
        $"Each line break goes as Shift+Enter. A draft holds at most {RemoteInput.MaxDraftLines} lines.",
        RemoteInput.MaxDraft, RemoteInput.LimitDraft, "Close");

    void SetText(string text)
    {
        updating = true;
        Box.Text = text;
        Box.CaretIndex = text.Length;
        updating = false;
        target.FieldText = text;
        Update();
    }

    void Changed()
    {
        if (updating)
        {
            return;
        }
        // An input method or a dead key composes: wait for the text.
        if (!composing)
        {
            var keep = target.FieldChanged(Box.Text);
            if (keep != Box.Text)
            {
                SetText(keep);
                return;
            }
            target.FieldText = keep;
        }
        placeholder.Visibility = Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    void Pressed(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter when Keyboard.Modifiers == ModifierKeys.None:
                target.FieldReturn(Box.Text);
                SetText("");
                e.Handled = true;
                break;
            case Key.Back when Box.Text.Length == 0:
                target.Key(RemoteKey.Backspace);
                e.Handled = true;
                break;
            case Key.Escape:
                // Escape goes to the computer, for example to leave the
                // insert mode of an editor.
                target.Key(RemoteKey.Escape);
                e.Handled = true;
                break;
        }
    }
}
