using FluxKit;

namespace FluxKit.Tests;

// RemoteInputTests.swift and RemoteInputKeysTests.swift of the Mac app,
// with the keys of Windows in place of the keys of the Mac.
public class InputTests
{
    static Packet RoundTrip(Packet p) => Packet.Parse(p.Serialize())!;

    static DeviceSnapshot Computer(params string[] incoming) =>
        new("a", "roger", "desktop", "", true, true, true, PairState.Paired, "", ValueList.From(incoming), ValueList<string>.Empty);

    [Fact]
    public void CapabilitiesMatchTheComputer()
    {
        var plugin = new RemoteInputPlugin();
        Assert.Equal(["flux.mousepad.request"], plugin.Outgoing);
        Assert.Equal(["flux.input"], plugin.Incoming);
    }

    [Fact]
    public void SupportNeedsTheMousepadCapability()
    {
        Assert.False(RemoteInputPlugin.Supported(Computer(PacketType.Tunnel)));
        Assert.True(RemoteInputPlugin.Supported(Computer(PacketType.Tunnel, PacketType.MousepadRequest)));
    }

    [Fact]
    public void MotionAndScrollBodies()
    {
        var move = RoundTrip(RemoteInput.Move(3.14159, -2));
        Assert.Equal(PacketType.MousepadRequest, move.Type);
        Assert.Equal(3.14, move.Double("dx"));
        Assert.Equal(-2, move.Double("dy"));
        Assert.False(move.Has("scroll"));
        Assert.Equal(2, move.Body.Count);

        var scroll = RoundTrip(RemoteInput.Scroll(0, 12.5));
        Assert.True(scroll.Bool("scroll"));
        Assert.Equal(12.5, scroll.Double("dy"));
        Assert.Equal(0, RemoteInput.Move(double.NaN, double.PositiveInfinity).Double("dx"));
    }

    [Fact]
    public void ClicksAndHold()
    {
        Assert.True(RemoteInput.Click(RemoteClick.Left).Bool("singleclick"));
        Assert.True(RemoteInput.Click(RemoteClick.Right).Bool("rightclick"));
        Assert.True(RemoteInput.Click(RemoteClick.Middle).Bool("middleclick"));
        Assert.True(RemoteInput.Hold(true).Bool("singlehold"));
        Assert.True(RemoteInput.Hold(false).Bool("singlerelease"));
        Assert.Single(RemoteInput.Click(RemoteClick.Left).Body);
    }

    [Fact]
    public void KeysUseTheProtocolNumbers()
    {
        var enter = RoundTrip(RemoteInput.Key(RemoteKey.Enter));
        Assert.Equal(12, enter.Int("specialKey"));
        Assert.Single(enter.Body);
        var codes = new Dictionary<RemoteKey, int>
        {
            [RemoteKey.Backspace] = 1, [RemoteKey.Tab] = 2, [RemoteKey.Left] = 4, [RemoteKey.Up] = 5, [RemoteKey.Right] = 6,
            [RemoteKey.Down] = 7, [RemoteKey.PageUp] = 8, [RemoteKey.PageDown] = 9, [RemoteKey.Home] = 10, [RemoteKey.End] = 11,
            [RemoteKey.Delete] = 13, [RemoteKey.Escape] = 14, [RemoteKey.F1] = 21, [RemoteKey.F12] = 32,
        };
        foreach (var (k, code) in codes)
        {
            Assert.Equal(code, (int)k);
        }

        var tab = RemoteInput.Key(RemoteKey.Tab, new RemoteMods(Ctrl: true, Shift: true));
        Assert.True(tab.Bool("ctrl"));
        Assert.True(tab.Bool("shift"));
        Assert.False(tab.Has("alt"));
        Assert.False(tab.Has("super"));
    }

    [Fact]
    public void KeysRepeatOnlyWhenTheComputerCan()
    {
        Assert.Empty(RemoteInput.Keys(RemoteKey.Backspace, 0, default, repeat: true));
        Assert.Empty(RemoteInput.Keys(RemoteKey.Backspace, -3, default, repeat: false));
        var plain = RemoteInput.Keys(RemoteKey.Backspace, 3, default, repeat: false);
        // An older fluxd gets 1 packet for each press.
        Assert.Equal(3, plain.Count);
        Assert.All(plain, p => Assert.True(p.Int("specialKey") == 1 && !p.Has("repeat")));

        var one = RemoteInput.Keys(RemoteKey.Backspace, 1, default, repeat: true);
        Assert.Single(one);
        Assert.False(one[0].Has("repeat"));

        var many = RoundTrip(RemoteInput.Keys(RemoteKey.Backspace, 40, new RemoteMods(Ctrl: true), repeat: true)[0]);
        Assert.Equal(1, many.Int("specialKey"));
        Assert.Equal(40, many.Int("repeat"));
        Assert.True(many.Bool("ctrl"));
        Assert.Single(RemoteInput.Keys(RemoteKey.Backspace, 40, default, repeat: true));

        var huge = RemoteInput.Keys(RemoteKey.Delete, RemoteInput.MaxRepeat * 2 + 1, default, repeat: true);
        Assert.Equal([RemoteInput.MaxRepeat, RemoteInput.MaxRepeat, null], huge.Select(p => p.Int("repeat")));
        Assert.Equal(13, huge[^1].Int("specialKey"));
    }

    [Fact]
    public void DraftTypesLinesWithShiftEnter()
    {
        Assert.Empty(RemoteInput.Draft(""));
        var one = RemoteInput.Draft("Hello team");
        Assert.Single(one);
        Assert.Equal("Hello team", one[0].String("key"));

        var lines = RemoteInput.Draft("Hi,\r\nthe build is ready.\n\nBye");
        Assert.Equal(["Hi,", null, "the build is ready.", null, null, "Bye"], lines.Select(p => p.String("key")));
        foreach (var p in lines.Where(p => !p.Has("key")))
        {
            Assert.Equal(12, p.Int("specialKey"));
            // A line break goes as Shift+Enter.
            Assert.True(p.Bool("shift"));
        }
        Assert.Equal(3, RemoteInput.Draft("a\rb").Count);
        // A line break at the end stays.
        Assert.Equal(["a", null], RemoteInput.Draft("a\n").Select(p => p.String("key")));
    }

    [Fact]
    public void DraftLimits()
    {
        Assert.Equal(100, RemoteInput.MaxDraftLines);
        Assert.Equal("a\nb", RemoteInput.LimitDraft("a\nb"));
        var lines = string.Join("\n", Enumerable.Range(1, 150));
        var cut = RemoteInput.LimitDraft(lines);
        Assert.Equal(RemoteInput.MaxDraftLines, cut.Split('\n').Length);
        // The text after line 100 goes away.
        Assert.EndsWith("\n100", cut);
        // 100 lines and 99 line breaks.
        Assert.Equal(199, RemoteInput.Draft(cut).Count);
        Assert.Equal(RemoteInput.MaxDraft, RemoteInput.LimitDraft(new string('x', 5000)).Length);
        // CR LF counts as 1 line break, as on the Mac.
        Assert.Equal(RemoteInput.MaxDraftLines, RemoteInput.LimitDraft(string.Join("\r\n", Enumerable.Range(1, 150))).Split("\r\n").Length);
    }

    [Fact]
    public void DraftSplitsLongLinesBetweenCharacters()
    {
        var thumb = "👍🏽";
        var longLine = new string('a', RemoteInput.MaxText) + thumb + "b";
        var parts = RemoteInput.Draft(longLine).Select(p => p.String("key")).OfType<string>().ToList();
        Assert.Equal(2, parts.Count);
        Assert.Equal(RemoteInput.MaxText, parts[0].EnumerateRunes().Count());
        // A character stays in 1 packet.
        Assert.Equal(thumb + "b", parts[1]);
        Assert.Equal(longLine, string.Concat(parts));
        Assert.Equal([new string('x', 10)], RemoteInput.Chunks(new string('x', 10)));
    }

    [Fact]
    public void TextWithSuper()
    {
        var p = RoundTrip(RemoteInput.Text(" ", new RemoteMods(Super: true)));
        Assert.Equal(" ", p.String("key"));
        Assert.True(p.Bool("super"));
        Assert.Equal(2, p.Body.Count);
    }

    [Fact]
    public void ModifierKeysMapToTheComputer()
    {
        // The ModifierKeys of WPF: Alt 1, Control 2, Shift 4, Windows 8.
        Assert.Equal(new RemoteMods(true, true, true, true), RemoteMods.FromModifierKeys(15));
        Assert.Equal(new RemoteMods(Ctrl: true), RemoteMods.FromModifierKeys(2));
        Assert.Equal(new RemoteMods(Alt: true), RemoteMods.FromModifierKeys(1));
        Assert.Equal(new RemoteMods(Shift: true), RemoteMods.FromModifierKeys(4));
        Assert.Equal(new RemoteMods(Super: true), RemoteMods.FromModifierKeys(8));
        Assert.False(RemoteMods.FromModifierKeys(0).Any);
        Assert.Equal(new RemoteMods(Ctrl: true, Super: true), new RemoteMods(Ctrl: true).Union(new RemoteMods(Super: true)));
    }

    [Fact]
    public void WindowsKeyCodes()
    {
        var codes = new Dictionary<int, RemoteKey>
        {
            [0x08] = RemoteKey.Backspace, [0x09] = RemoteKey.Tab, [0x25] = RemoteKey.Left, [0x26] = RemoteKey.Up,
            [0x27] = RemoteKey.Right, [0x28] = RemoteKey.Down, [0x21] = RemoteKey.PageUp, [0x22] = RemoteKey.PageDown,
            [0x24] = RemoteKey.Home, [0x23] = RemoteKey.End, [0x0D] = RemoteKey.Enter, [0x2E] = RemoteKey.Delete,
            [0x1B] = RemoteKey.Escape, [0x70] = RemoteKey.F1, [0x71] = RemoteKey.F2, [0x72] = RemoteKey.F3, [0x73] = RemoteKey.F4,
            [0x74] = RemoteKey.F5, [0x75] = RemoteKey.F6, [0x76] = RemoteKey.F7, [0x77] = RemoteKey.F8, [0x78] = RemoteKey.F9,
            [0x79] = RemoteKey.F10, [0x7A] = RemoteKey.F11, [0x7B] = RemoteKey.F12,
        };
        foreach (var (code, k) in codes)
        {
            Assert.Equal(k, RemoteInput.Special(code));
        }
        Assert.Equal(Enum.GetValues<RemoteKey>().ToHashSet(), codes.Values.ToHashSet());
        // A, Space, Insert, and F13 are not special keys.
        Assert.Null(RemoteInput.Special(0x41));
        Assert.Null(RemoteInput.Special(0x20));
        Assert.Null(RemoteInput.Special(0x2D));
        Assert.Null(RemoteInput.Special(0x7C));
    }

    [Fact]
    public void NumberRowKeysGiveDigits()
    {
        Assert.Equal(1, RemoteInput.Digit(0x31));
        Assert.Equal(5, RemoteInput.Digit(0x35));
        Assert.Equal(0, RemoteInput.Digit(0x30));
        Assert.Null(RemoteInput.Digit(0x41));
        // The number pad does not switch workspaces.
        Assert.Null(RemoteInput.Digit(0x61));
    }

    [Fact]
    public void PressRules()
    {
        static RemotePress Press(RemoteKey? key, RemoteMods mods, string? plain, bool altIsAlt = false, bool superIsSuper = true, bool altGr = false) =>
            RemoteInput.Press(key, mods, plain, altIsAlt, superIsSuper, altGr);

        // Letters go through the text input of Windows.
        Assert.Equal(new RemotePress.Compose(), Press(null, default, "a"));
        Assert.Equal(new RemotePress.Compose(), Press(null, new RemoteMods(Shift: true), "A"));
        // Alt types a letter as Alt only when it is Alt.
        Assert.Equal(new RemotePress.Compose(), Press(null, new RemoteMods(Alt: true), "2"));
        Assert.Equal(new RemotePress.Text("f", new RemoteMods(Alt: true)), Press(null, new RemoteMods(Alt: true), "f", altIsAlt: true));
        // AltGr types the character of the layout, unless Alt is Alt.
        var altGr = new RemoteMods(Ctrl: true, Alt: true);
        Assert.Equal(new RemotePress.Compose(), Press(null, altGr, "2", altGr: true));
        Assert.Equal(new RemotePress.Text("2", altGr), Press(null, altGr, "2", altIsAlt: true, altGr: true));
        // Special keys keep all modifiers.
        Assert.Equal(new RemotePress.SpecialKey(RemoteKey.Left, new RemoteMods(Alt: true)), Press(RemoteKey.Left, new RemoteMods(Alt: true), null));
        Assert.Equal(new RemotePress.SpecialKey(RemoteKey.Tab, new RemoteMods(Shift: true)), Press(RemoteKey.Tab, new RemoteMods(Shift: true), "\t"));
        Assert.Equal(new RemotePress.SpecialKey(RemoteKey.Escape, default), Press(RemoteKey.Escape, default, "\u001B"));
        // Shortcuts send the plain text with the modifiers.
        Assert.Equal(new RemotePress.Text("c", new RemoteMods(Ctrl: true)), Press(null, new RemoteMods(Ctrl: true), "c"));
        Assert.Equal(new RemotePress.Text("C", new RemoteMods(Ctrl: true, Shift: true)), Press(null, new RemoteMods(Ctrl: true, Shift: true), "C"));
        Assert.Equal(new RemotePress.Text(" ", new RemoteMods(Super: true)), Press(null, new RemoteMods(Super: true), " "));
        Assert.Equal(new RemotePress.Text("t", new RemoteMods(Ctrl: true, Alt: true)), Press(null, new RemoteMods(Ctrl: true, Alt: true), "t"));
        // This computer keeps the Windows key while the pad does not hold the pointer.
        Assert.Equal(new RemotePress.Ignore(), Press(null, new RemoteMods(Super: true), "w", superIsSuper: false));
        Assert.Equal(new RemotePress.Ignore(), Press(RemoteKey.Escape, new RemoteMods(Super: true), null, superIsSuper: false));
        // A key without text stays.
        Assert.Equal(new RemotePress.Ignore(), Press(null, new RemoteMods(Ctrl: true), ""));
        Assert.Equal(new RemotePress.Ignore(), Press(null, new RemoteMods(Ctrl: true), null));
    }

    [Fact]
    public void WheelScrollsLikeThisComputer()
    {
        // A notch away from the user scrolls up.
        var up = RemoteInput.Wheel(0, 120)!;
        Assert.True(up.Bool("scroll"));
        Assert.Equal(-15, up.Double("dy"));
        Assert.Equal(0, up.Double("dx"));
        var down = RemoteInput.Wheel(0, -240)!;
        Assert.Equal(30, down.Double("dy"));
        // A positive horizontal delta scrolls right.
        Assert.Equal(15, RemoteInput.Wheel(120, 0)!.Double("dx"));
        // A precision touchpad sends small deltas.
        Assert.Equal(-1.25, RemoteInput.Wheel(0, 10)!.Double("dy"));
        Assert.Null(RemoteInput.Wheel(0, 0.001));
    }

    [Fact]
    public void TypeFieldSendsWholeWords()
    {
        Assert.Equal(("", "hel"), RemoteInput.Words("hel"));
        Assert.Equal(("hello ", ""), RemoteInput.Words("hello "));
        Assert.Equal(("hello ", "wor"), RemoteInput.Words("hello wor"));
        Assert.Equal(("æøå 😀 ", "x"), RemoteInput.Words("æøå 😀 x"));
        Assert.Equal(("", ""), RemoteInput.Words(""));
    }

    [Fact]
    public void ClickIsAPressThatDoesNotMove()
    {
        var t = new PointerTracker();
        t.LeftDown();
        Assert.Empty(t.Move(1, 1));
        var up = t.LeftUp();
        Assert.Single(up);
        Assert.True(up[0].Bool("singleclick"));
        Assert.False(t.Dragging);
        Assert.Empty(t.LeftUp());
    }

    [Fact]
    public void PressThatMovesIsADrag()
    {
        var t = new PointerTracker();
        t.LeftDown();
        Assert.Empty(t.Move(1, 0));
        var start = t.Move(2, 1);
        Assert.True(t.Dragging);
        Assert.Equal(2, start.Count);
        Assert.True(start[0].Bool("singlehold"));
        // The motion before the drag starts moves after the press.
        Assert.Equal(3, start[1].Double("dx"));
        Assert.Equal(1, start[1].Double("dy"));
        var next = t.Move(-4, 0);
        Assert.Single(next);
        Assert.Equal(-4, next[0].Double("dx"));
        var end = t.LeftUp();
        Assert.Single(end);
        Assert.True(end[0].Bool("singlerelease"));
        Assert.False(t.Dragging);
    }

    [Fact]
    public void MotionWithoutAPressMoves()
    {
        var t = new PointerTracker();
        var p = t.Move(0.5, -7);
        Assert.Single(p);
        Assert.Equal(0.5, p[0].Double("dx"));
        Assert.Equal(-7, p[0].Double("dy"));
        Assert.False(p[0].Has("singlehold"));
    }

    [Fact]
    public void CancelReleasesADrag()
    {
        var t = new PointerTracker();
        t.LeftDown();
        Assert.Empty(t.Cancel());
        t.LeftDown();
        t.Move(10, 0);
        var end = t.Cancel();
        Assert.Single(end);
        Assert.True(end[0].Bool("singlerelease"));
        // The up after a cancel sends nothing.
        Assert.Empty(t.LeftUp());
    }

    [Fact]
    public void ReleaseChord()
    {
        var c = new ReleaseChord();
        var ctrl = new RemoteMods(Ctrl: true);
        var both = new RemoteMods(Ctrl: true, Alt: true);
        Assert.False(c.Flags(ctrl));
        Assert.False(c.Flags(both));
        Assert.False(c.Flags(new RemoteMods(Alt: true)));
        Assert.True(c.Flags(default));
        // Ctrl alone does nothing.
        Assert.False(c.Flags(ctrl));
        Assert.False(c.Flags(default));
        // A key between makes it a shortcut.
        Assert.False(c.Flags(both));
        c.Interrupt();
        Assert.False(c.Flags(default));
        // Shift or the Windows key with the chord makes it a shortcut too.
        Assert.False(c.Flags(both));
        Assert.False(c.Flags(both with { Shift = true }));
        Assert.False(c.Flags(default));
    }

    [Fact]
    public void StateFollowsTheComputer()
    {
        var model = new RemoteInputModel();
        Assert.Null(model.Enabled("a"));
        Assert.False(model.IsOn("a"));
        model.Set("a", true);
        Assert.True(model.IsOn("a"));
        model.Set("a", false);
        Assert.Equal(false, model.Enabled("a"));
        Assert.False(model.IsOn("a"));
        // An older fluxd does not tell keyRepeat.
        Assert.False(model.CanRepeat("a"));
        model.Set("a", true, desktop: true, keyRepeat: true);
        Assert.True(model.CanRepeat("a"));
        // Each flux.input tells the state again.
        model.Set("a", true);
        Assert.False(model.CanRepeat("a"));
    }

    [Fact]
    public void ModelReportsItsChanges()
    {
        var model = new RemoteInputModel();
        var changes = new List<string?>();
        model.PropertyChanged += (_, e) => changes.Add(e.PropertyName);
        model.Set("a", true, true, true);
        model.Set("a", true, true, true);
        Assert.Equal([nameof(RemoteInputModel.States)], changes);
    }

    sealed class Target(bool workspaceKeys) : RemoteKeyTarget(null)
    {
        public List<Packet> Sent { get; } = [];
        public bool Ready { get; set; } = true;
        public bool SuperOn { get; set; } = true;
        public override bool KeysReady => Ready;
        public override bool SuperIsSuper => SuperOn;
        public override bool WorkspaceKeys => workspaceKeys;
        public override string Name => "roger";
        public override void Send(IReadOnlyList<Packet> packets) => Sent.AddRange(packets);
    }

    [Fact]
    public void StickyModifiersHoldForTheNextKey()
    {
        var t = new Target(workspaceKeys: false) { Mods = new RemoteMods(Ctrl: true) };
        t.Text("c");
        Assert.Equal("c", t.Sent[0].String("key"));
        Assert.True(t.Sent[0].Bool("ctrl"));
        Assert.False(t.Mods.Any);
        t.Key(RemoteKey.Left, new RemoteMods(Shift: true));
        Assert.True(t.Sent[1].Bool("shift"));
        Assert.False(t.Sent[1].Has("ctrl"));
    }

    [Fact]
    public void SuperAndADigitSwitchesTheWorkspace()
    {
        var t = new Target(workspaceKeys: true);
        Assert.Equal(new RemotePress.Text("3", new RemoteMods(Super: true)), t.KeyDown(0x33, new RemoteMods(Super: true), "3"));
        Assert.Equal(PacketType.Shortcuts, t.Sent[0].Type);
        Assert.Equal("workspace", t.Sent[0].String("action"));
        Assert.Equal(3, t.Sent[0].Int("workspace"));
        // Shift turns the digit into another character. The number row key still counts.
        t.KeyDown(0x32, new RemoteMods(Shift: true, Super: true), "@");
        Assert.Equal("moveToWorkspace", t.Sent[1].String("action"));
        Assert.Equal(2, t.Sent[1].Int("workspace"));
        // Without the flux.shortcuts capability, the digit goes as text.
        var old = new Target(workspaceKeys: false);
        old.KeyDown(0x33, new RemoteMods(Super: true), "3");
        Assert.Equal("3", old.Sent[0].String("key"));
        Assert.True(old.Sent[0].Bool("super"));
    }

    [Fact]
    public void KeyDownSendsOnlyWhenReady()
    {
        var t = new Target(workspaceKeys: false);
        Assert.Equal(new RemotePress.SpecialKey(RemoteKey.Enter, default), t.KeyDown(0x0D, default, "\r"));
        Assert.Equal(12, t.Sent[0].Int("specialKey"));
        Assert.Equal(new RemotePress.Compose(), t.KeyDown(0x41, default, "a"));
        Assert.Single(t.Sent);
        t.TextInput("é");
        Assert.Equal("é", t.Sent[1].String("key"));
        t.Ready = false;
        Assert.Equal(new RemotePress.Ignore(), t.KeyDown(0x0D, default, "\r"));
        t.TextInput("x");
        Assert.Equal(2, t.Sent.Count);
    }

    [Fact]
    public void TypeFieldAndDraft()
    {
        var t = new Target(workspaceKeys: false);
        Assert.Equal("wor", t.FieldChanged("hello wor"));
        Assert.Equal("hello ", t.Sent[0].String("key"));
        t.FieldReturn("world");
        Assert.Equal("world", t.Sent[1].String("key"));
        Assert.Equal(12, t.Sent[2].Int("specialKey"));
        // A sticky modifier sends the field at once as a shortcut.
        t.Mods = new RemoteMods(Ctrl: true);
        Assert.Equal("", t.FieldChanged("c"));
        Assert.True(t.Sent[3].Bool("ctrl"));

        Assert.False(t.CanTypeDraft);
        t.Draft = "a\nb";
        Assert.True(t.CanTypeDraft);
        t.Mods = new RemoteMods(Alt: true);
        t.TypeDraft();
        Assert.Equal("", t.Draft);
        Assert.False(t.Mods.Any);
        Assert.Equal(["a", null, "b"], t.Sent.Skip(4).Select(p => p.String("key")));
    }
}
