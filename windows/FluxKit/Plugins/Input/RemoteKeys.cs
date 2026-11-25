namespace FluxKit;

// A window that types on the computer: the touchpad or the remote desktop.
// This class holds the rules that both share: the sticky modifiers, the
// type field, the draft, and super with a digit for the workspaces.
// RemoteKeys.swift of the Mac app has the same rules. The window calls it
// on the UI thread.
public abstract class RemoteKeyTarget : Model
{
    // The settings key of the Alt setting, for the touchpad and the remote
    // desktop.
    internal const string AltIsAltKey = "input.altIsAlt";

    readonly FluxSettings? settings;
    RemoteMods mods;
    string fieldText = "";
    string draft = "";
    bool altIsAlt;

    protected RemoteKeyTarget(FluxSettings? settings)
    {
        this.settings = settings;
        altIsAlt = settings?.Bool(AltIsAltKey, false) ?? false;
    }

    // True when keys go to the computer.
    public abstract bool KeysReady { get; }

    // True when the Windows key is Super. Else this computer keeps its
    // Windows shortcuts.
    public abstract bool SuperIsSuper { get; }

    // True when the computer switches the workspace for super and a digit.
    public abstract bool WorkspaceKeys { get; }

    // The name of the computer, for the labels.
    public abstract string Name { get; }

    // Sends keys and clicks to the computer.
    public abstract void Send(IReadOnlyList<Packet> packets);

    // The modifiers that the next key or text holds, from the modifier
    // buttons.
    public RemoteMods Mods
    {
        get => mods;
        set => Set(ref mods, value);
    }

    // The text that waits in the type field: the rest after the last word
    // that went out.
    public string FieldText
    {
        get => fieldText;
        set => Set(ref fieldText, value);
    }

    // The text of the draft editor. It stays after the editor closes.
    public string Draft
    {
        get => draft;
        set
        {
            if (Set(ref draft, value))
            {
                Changed(nameof(CanTypeDraft));
            }
        }
    }

    // Alt is Alt for letters too. Off, AltGr types the characters of the
    // layout of this computer, such as @ on a Nordic keyboard.
    public bool AltIsAlt
    {
        get => altIsAlt;
        set
        {
            if (Set(ref altIsAlt, value))
            {
                settings?.Set(AltIsAltKey, value);
            }
        }
    }

    // True when the draft has text to type.
    public bool CanTypeDraft => KeysReady && !string.IsNullOrWhiteSpace(Draft);

    // Presses a special key with the held and the sticky modifiers.
    public void Key(RemoteKey k, RemoteMods held = default) => Send([RemoteInput.Key(k, held.Union(TakeMods()))]);

    // Types text with the held and the sticky modifiers. digit is the
    // number row key that typed it, for super and a digit.
    public void Text(string s, RemoteMods held = default, int? digit = null)
    {
        if (s.Length == 0)
        {
            return;
        }
        var all = held.Union(TakeMods());
        if (WorkspaceKeys && DesktopShortcuts.ForDigit(digit?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? s, all) is { } workspace)
        {
            Send([workspace]);
            return;
        }
        Send([RemoteInput.Text(s, all)]);
    }

    // Handles a change of the type field and returns the text that stays in
    // it. Each word goes out after its space. With a sticky modifier, the
    // text goes out at once as a shortcut, such as ctrl and c.
    public string FieldChanged(string value)
    {
        if (Mods.Any && value.Length > 0)
        {
            Text(value);
            return "";
        }
        var (words, keep) = RemoteInput.Words(value);
        Text(words);
        return keep;
    }

    // Enter in the type field sends the rest of the text and presses Enter.
    public void FieldReturn(string value)
    {
        Text(value);
        Key(RemoteKey.Enter);
    }

    // Types the draft on the computer: each line as text, and Shift+Enter
    // between the lines. The sticky modifiers clear, and the draft empties.
    public void TypeDraft()
    {
        if (!CanTypeDraft)
        {
            return;
        }
        var packets = RemoteInput.Draft(Draft);
        Mods = default;
        Draft = "";
        Send(packets);
    }

    // Handles 1 key press of the view that has the keyboard focus.
    // virtualKey is the Windows virtual key code, held the modifiers that
    // this computer holds, plain the text of the key without modifiers
    // except Shift, and altGr true while the right Alt key is down. It
    // returns the press: the view lets the text input of Windows type a
    // Compose press, and gives an Ignore press to this computer.
    public RemotePress KeyDown(int virtualKey, RemoteMods held, string? plain, bool altGr = false)
    {
        if (!KeysReady)
        {
            return new RemotePress.Ignore();
        }
        var press = RemoteInput.Press(RemoteInput.Special(virtualKey), held, plain, AltIsAlt, SuperIsSuper, altGr);
        switch (press)
        {
            case RemotePress.SpecialKey k:
                Key(k.Key, k.Mods);
                break;
            case RemotePress.Text t:
                Text(t.Value, t.Mods, RemoteInput.Digit(virtualKey));
                break;
        }
        return press;
    }

    // Types the text that the text input of Windows made for a Compose
    // press, a dead key, or an input method.
    public void TextInput(string text)
    {
        if (KeysReady)
        {
            Text(text);
        }
    }

    // Reports a change of the state that KeysReady reads.
    protected void ReadyChanged()
    {
        Changed(nameof(KeysReady));
        Changed(nameof(CanTypeDraft));
        Changed(nameof(SuperIsSuper));
        Changed(nameof(WorkspaceKeys));
        Changed(nameof(Name));
    }

    RemoteMods TakeMods()
    {
        var m = Mods;
        Mods = default;
        return m;
    }
}

// The state of 1 touchpad window. While the pad holds the pointer, the
// cursor of this computer hides and stays still, and each motion, click,
// scroll, and key goes to the computer. TouchpadController.swift of the
// Mac app has the same rules. The window calls it on the UI thread, and
// Close ends it.
public sealed class TouchpadController : RemoteKeyTarget
{
    readonly FluxCore core;
    readonly RemoteInputPlugin plugin;
    // The name when the window opened, for a computer that is gone.
    readonly string firstName;
    readonly PointerTracker tracker = new();
    DeviceSnapshot? device;
    // True after a dictation typed its text, so that the next one starts
    // with a space.
    bool afterVoice;
    bool captured;
    bool padFocused;
    bool closed;

    public TouchpadController(FluxCore core, RemoteInputPlugin plugin, DeviceSnapshot device) : base(core.Settings)
    {
        this.core = core;
        this.plugin = plugin;
        DeviceId = device.Id;
        firstName = device.Name;
        this.device = core.State.Devices.FirstOrDefault(d => d.Id == DeviceId);
        core.Changed += CoreChanged;
        plugin.Model.PropertyChanged += InputChanged;
    }

    public string DeviceId { get; }

    // The computer now, or null when it is gone.
    public DeviceSnapshot? Device => device;

    public override string Name => device?.Name ?? firstName;

    // True when the computer is online and runs the input.
    public bool Ready => device is { Paired: true, Online: true } d && RemoteInputPlugin.Supported(d) && plugin.Model.IsOn(DeviceId);

    public override bool KeysReady => Ready;

    // The Windows key is Super while the pad holds the pointer.
    public override bool SuperIsSuper => Captured;

    public override bool WorkspaceKeys => device is { } d && DesktopPlugin.ShortcutsSupported(d);

    // True while the pad holds the pointer of this computer.
    public bool Captured
    {
        get => captured;
        private set
        {
            if (Set(ref captured, value))
            {
                Changed(nameof(SuperIsSuper));
            }
        }
    }

    // True while the pad has the keyboard focus, so that keys go to the
    // computer.
    public bool PadFocused
    {
        get => padFocused;
        set => Set(ref padFocused, value);
    }

    // Takes the pointer of this computer. It returns true when the view must
    // hide the cursor and keep it still. The motion then goes to the
    // computer.
    public bool Capture()
    {
        if (!Ready || Captured)
        {
            return false;
        }
        Captured = true;
        return true;
    }

    // Gives the pointer back to this computer, and a drag on the computer
    // ends. It returns true when the view must show the cursor again.
    public bool Release()
    {
        if (!Captured)
        {
            return false;
        }
        Post(tracker.Cancel());
        Captured = false;
        return true;
    }

    public void LeftDown() => tracker.LeftDown();
    public void LeftUp() => Send(tracker.LeftUp());
    public void Moved(double dx, double dy) => Post(tracker.Move(dx, dy));
    public void Click(RemoteClick c) => Send([RemoteInput.Click(c)]);

    // Scrolls with the wheel deltas of this computer, see RemoteInput.Wheel.
    public void Wheel(double deltaX, double deltaY)
    {
        if (RemoteInput.Wheel(deltaX, deltaY) is { } p)
        {
            Post([p]);
        }
    }

    // Ends the window: the pointer comes back, and the modifiers clear.
    public void Close()
    {
        Release();
        Mods = default;
        if (!closed)
        {
            closed = true;
            core.Changed -= CoreChanged;
            plugin.Model.PropertyChanged -= InputChanged;
        }
    }

    // Sends keys and clicks. They can move the cursor of the computer, so
    // the next dictation starts with no space.
    public override void Send(IReadOnlyList<Packet> packets)
    {
        afterVoice = false;
        Post(packets);
    }

    // Types the words of a dictation. A dictation right after another
    // starts with a space.
    public void TypeSpoken(string spoken)
    {
        var words = spoken.Trim();
        if (!Ready || words.Length == 0)
        {
            return;
        }
        Post([RemoteInput.Text(afterVoice ? " " + words : words)]);
        afterVoice = true;
    }

    // Sends packets that do not move the cursor of the computer: motion and
    // scrolls.
    void Post(IReadOnlyList<Packet> packets) => plugin.Send(packets, DeviceId);

    void CoreChanged(CoreState state)
    {
        var next = state.Devices.FirstOrDefault(d => d.Id == DeviceId);
        if (next == device)
        {
            return;
        }
        device = next;
        Changed(nameof(Device));
        Changed(nameof(Ready));
        ReadyChanged();
    }

    void InputChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        Changed(nameof(Ready));
        ReadyChanged();
    }
}
