using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace FluxKit;

// Special keys, with the specialKey numbers of flux.mousepad.request.
public enum RemoteKey
{
    Backspace = 1,
    Tab = 2,
    Left = 4,
    Up = 5,
    Right = 6,
    Down = 7,
    PageUp = 8,
    PageDown = 9,
    Home = 10,
    End = 11,
    Enter = 12,
    Delete = 13,
    Escape = 14,
    F1 = 21,
    F2 = 22,
    F3 = 23,
    F4 = 24,
    F5 = 25,
    F6 = 26,
    F7 = 27,
    F8 = 28,
    F9 = 29,
    F10 = 30,
    F11 = 31,
    F12 = 32,
}

// The mouse buttons of a click.
public enum RemoteClick
{
    Left,
    Right,
    Middle,
}

// The modifiers that a key or text holds on the computer. Super is the
// Windows key of this computer.
public readonly record struct RemoteMods(bool Ctrl = false, bool Alt = false, bool Shift = false, bool Super = false)
{
    public bool Any => Ctrl || Alt || Shift || Super;

    public RemoteMods Union(RemoteMods other) =>
        new(Ctrl || other.Ctrl, Alt || other.Alt, Shift || other.Shift, Super || other.Super);

    // The modifiers of a WPF ModifierKeys value: Alt is 1, Control is 2,
    // Shift is 4, and Windows is 8.
    public static RemoteMods FromModifierKeys(int keys) =>
        new((keys & 2) != 0, (keys & 1) != 0, (keys & 4) != 0, (keys & 8) != 0);

    internal JsonObject Fields()
    {
        var body = new JsonObject();
        if (Ctrl)
        {
            body["ctrl"] = true;
        }
        if (Alt)
        {
            body["alt"] = true;
        }
        if (Shift)
        {
            body["shift"] = true;
        }
        if (Super)
        {
            body["super"] = true;
        }
        return body;
    }
}

// What 1 key press on this computer sends to the computer.
public abstract record RemotePress
{
    // A special key with the modifiers that this computer holds.
    public sealed record SpecialKey(RemoteKey Key, RemoteMods Mods) : RemotePress;

    // The text of a shortcut, such as Ctrl+C, with its modifiers.
    public sealed record Text(string Value, RemoteMods Mods) : RemotePress;

    // The text input of Windows makes the text, so that dead keys, input
    // methods, and the AltGr characters of the layout work.
    public sealed record Compose() : RemotePress;

    // The key stays on this computer.
    public sealed record Ignore() : RemotePress;
}

// The packets of flux.mousepad.request: this computer moves the pointer,
// clicks, scrolls, and types on the Omarchy computer. A packet holds 1
// action. docs/remote-input.md describes the fields. RemoteInput.swift of
// the Mac app has the same rules.
public static partial class RemoteInput
{
    // The most presses that 1 packet with repeat asks for. fluxd uses the
    // same limit.
    public const int MaxRepeat = 4096;

    // The longest draft, in characters. wtype types about 250 characters
    // each second, so a full draft takes about 16 seconds.
    public const int MaxDraft = 4000;

    // The most lines of a draft. Each line break is 1 packet, and the queue
    // of fluxd drops packets when it holds 256 actions.
    public const int MaxDraftLines = 100;

    // The most Unicode scalars in 1 text packet. fluxd uses the same limit.
    internal const int MaxText = 4096;

    // The scroll distance of 1 line of a mouse wheel, in the units of a
    // finger on a touchpad.
    internal const double LineScroll = 15;

    // The wheel delta of 1 notch of a Windows mouse wheel.
    internal const double WheelNotch = 120;

    public static Packet Move(double dx, double dy) =>
        new(PacketType.MousepadRequest, new JsonObject { ["dx"] = Round(dx), ["dy"] = Round(dy) });

    // A positive dy scrolls down, and a positive dx scrolls right.
    public static Packet Scroll(double dx, double dy) =>
        new(PacketType.MousepadRequest, new JsonObject { ["scroll"] = true, ["dx"] = Round(dx), ["dy"] = Round(dy) });

    public static Packet Click(RemoteClick c) => new(PacketType.MousepadRequest, new JsonObject { [ClickField(c)] = true });

    // Presses the left button for a drag, or releases it.
    public static Packet Hold(bool down) =>
        new(PacketType.MousepadRequest, new JsonObject { [down ? "singlehold" : "singlerelease"] = true });

    public static Packet Text(string text, RemoteMods mods = default)
    {
        var body = mods.Fields();
        body["key"] = text;
        return new Packet(PacketType.MousepadRequest, body);
    }

    public static Packet Key(RemoteKey k, RemoteMods mods = default)
    {
        var body = mods.Fields();
        body["specialKey"] = (int)k;
        return new Packet(PacketType.MousepadRequest, body);
    }

    // The packets that press k count times. With repeat, 1 packet asks fluxd
    // to press the key up to MaxRepeat times. Send repeat only to a computer
    // whose flux.input has keyRepeat, see RemoteInputModel.CanRepeat. An
    // older fluxd presses the key 1 time for each packet.
    public static IReadOnlyList<Packet> Keys(RemoteKey k, int count, RemoteMods mods, bool repeat)
    {
        if (count <= 0)
        {
            return [];
        }
        if (!repeat)
        {
            return Enumerable.Range(0, count).Select(_ => Key(k, mods)).ToArray();
        }
        var output = new List<Packet>();
        var left = count;
        while (left > 0)
        {
            var n = Math.Min(left, MaxRepeat);
            var body = mods.Fields();
            body["specialKey"] = (int)k;
            if (n > 1)
            {
                body["repeat"] = n;
            }
            output.Add(new Packet(PacketType.MousepadRequest, body));
            left -= n;
        }
        return output;
    }

    // Draft

    // Cuts a draft to MaxDraftLines lines and MaxDraft characters. The text
    // after the last line that fits goes away.
    public static string LimitDraft(string text)
    {
        var characters = RemoteText.Characters(text);
        var breaks = 0;
        var end = characters.Count;
        for (var i = 0; i < characters.Count; i++)
        {
            if (RemoteText.IsNewline(characters[i]))
            {
                breaks++;
                if (breaks == MaxDraftLines)
                {
                    end = i;
                    break;
                }
            }
        }
        return string.Concat(characters.Take(Math.Min(end, MaxDraft)));
    }

    // The packets that type a draft: each line as text, and Shift+Enter
    // between 2 lines, so that a chat or a form keeps the text in 1
    // message. Empty text gives no packets.
    public static IReadOnlyList<Packet> Draft(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        if (lines is [""])
        {
            return [];
        }
        var output = new List<Packet>();
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0)
            {
                output.Add(Key(RemoteKey.Enter, new RemoteMods(Shift: true)));
            }
            foreach (var part in Chunks(lines[i]))
            {
                output.Add(Text(part));
            }
        }
        return output;
    }

    // Splits text into parts of at most MaxText Unicode scalars. A character
    // stays in 1 part.
    internal static IReadOnlyList<string> Chunks(string text)
    {
        var output = new List<string>();
        var part = new StringBuilder();
        var scalars = 0;
        foreach (var c in RemoteText.Characters(text))
        {
            var n = RemoteText.Scalars(c);
            if (scalars + n > MaxText && part.Length > 0)
            {
                output.Add(part.ToString());
                part.Clear();
                scalars = 0;
            }
            part.Append(c);
            scalars += n;
        }
        if (part.Length > 0)
        {
            output.Add(part.ToString());
        }
        return output;
    }

    static double Round(double v) => double.IsFinite(v) ? Math.Round(v * 100, MidpointRounding.AwayFromZero) / 100 : 0;

    static string ClickField(RemoteClick c) => c switch
    {
        RemoteClick.Right => "rightclick",
        RemoteClick.Middle => "middleclick",
        _ => "singleclick",
    };

    // Remote desktop

    // Puts the pointer on the position x, y of the remote desktop, from 0 at
    // the top left corner to 1 at the bottom right corner. The computer runs
    // the action of the packet after the move.
    public static Packet At(double x, double y) => new(PacketType.MousepadRequest, Position(x, y));

    // Clicks at the position x, y of the remote desktop.
    public static Packet ClickAt(RemoteClick c, double x, double y)
    {
        var body = Position(x, y);
        body[ClickField(c)] = true;
        return new Packet(PacketType.MousepadRequest, body);
    }

    // Presses or releases the left button at the position x, y of the
    // remote desktop.
    public static Packet HoldAt(bool down, double x, double y)
    {
        var body = Position(x, y);
        body[down ? "singlehold" : "singlerelease"] = true;
        return new Packet(PacketType.MousepadRequest, body);
    }

    // Scrolls at the position x, y of the remote desktop. A positive dy
    // scrolls down.
    public static Packet ScrollAt(double dx, double dy, double x, double y)
    {
        var body = Position(x, y);
        body["scroll"] = true;
        body["dx"] = Round(dx);
        body["dy"] = Round(dy);
        return new Packet(PacketType.MousepadRequest, body);
    }

    // A position with 4 decimals: a step of 0.3 pixels on a 3000-pixel
    // monitor.
    static JsonObject Position(double x, double y)
    {
        static double Clamp(double v) =>
            double.IsFinite(v) ? Math.Round(Math.Min(Math.Max(v, 0), 1) * 10_000, MidpointRounding.AwayFromZero) / 10_000 : 0;
        return new JsonObject { ["x"] = Clamp(x), ["y"] = Clamp(y) };
    }

    // Windows keys

    // The digit of a key in the number row, from its Windows virtual key
    // code, or null. The row has the same keys in each layout, so
    // Win+Shift+2 is still 2. The number pad does not count. WPF gives the
    // code with KeyInterop.VirtualKeyFromKey.
    public static int? Digit(int virtualKey) => virtualKey is >= 0x30 and <= 0x39 ? virtualKey - 0x30 : null;

    // The special key of a Windows virtual key code, or null. The Enter key
    // of the number pad has the same code as Return.
    public static RemoteKey? Special(int virtualKey) => virtualKey switch
    {
        0x08 => RemoteKey.Backspace,
        0x09 => RemoteKey.Tab,
        0x0D => RemoteKey.Enter,
        0x1B => RemoteKey.Escape,
        0x21 => RemoteKey.PageUp,
        0x22 => RemoteKey.PageDown,
        0x23 => RemoteKey.End,
        0x24 => RemoteKey.Home,
        0x25 => RemoteKey.Left,
        0x26 => RemoteKey.Up,
        0x27 => RemoteKey.Right,
        0x28 => RemoteKey.Down,
        0x2E => RemoteKey.Delete,
        >= 0x70 and <= 0x7B => RemoteKey.F1 + (virtualKey - 0x70),
        _ => null,
    };

    // The scroll packet for the wheel of this computer, or null for no
    // motion. deltaY is the delta of the vertical wheel: a positive delta
    // turns the wheel away from the user and scrolls up. deltaX is the
    // delta of the horizontal wheel: a positive delta scrolls right. 1 notch
    // is 120 and scrolls 1 line. A precision touchpad sends smaller deltas,
    // with the scroll direction of the Windows settings.
    public static Packet? Wheel(double deltaX, double deltaY)
    {
        var dx = Round(deltaX / WheelNotch * LineScroll);
        var dy = Round(-deltaY / WheelNotch * LineScroll);
        if (dx == 0 && dy == 0)
        {
            return null;
        }
        return Scroll(dx, dy);
    }

    // Maps 1 key press from its special key, the held modifiers, and the
    // plain text. plain is the text of the key without modifiers except
    // Shift. Alt with a letter is Alt only when altIsAlt is on. With a
    // special key, Ctrl, or Super, Alt is always Alt. The Windows key is
    // Super only when superIsSuper is on, else this computer keeps it.
    // altGr is true while the right Alt key is down: Windows then reports
    // Ctrl and Alt, and the layout types a character, such as @ on a Nordic
    // keyboard, unless altIsAlt is on.
    public static RemotePress Press(RemoteKey? special, RemoteMods held, string? plain, bool altIsAlt, bool superIsSuper, bool altGr = false)
    {
        if (held.Super && !superIsSuper)
        {
            return new RemotePress.Ignore();
        }
        if (special is { } k)
        {
            return new RemotePress.SpecialKey(k, held);
        }
        if (altGr && !altIsAlt && !held.Super)
        {
            return new RemotePress.Compose();
        }
        if (!(held.Ctrl || held.Super || (held.Alt && altIsAlt)))
        {
            return new RemotePress.Compose();
        }
        var text = Printable(plain ?? "");
        return text.Length == 0 ? new RemotePress.Ignore() : new RemotePress.Text(text, held);
    }

    // Removes control characters and the private characters that some
    // keyboards give for function keys.
    internal static string Printable(string s)
    {
        var b = new StringBuilder();
        foreach (var r in s.EnumerateRunes())
        {
            if (Rune.IsControl(r) || r.Value is >= 0xF700 and <= 0xF8FF)
            {
                continue;
            }
            b.Append(r.ToString());
        }
        return b.ToString();
    }

    // Type field

    // Splits the text of the type field into the words to send now, up to
    // and including the last space, and the start of the word that stays in
    // the field.
    public static (string Send, string Keep) Words(string text)
    {
        var characters = RemoteText.Characters(text);
        for (var i = characters.Count - 1; i >= 0; i--)
        {
            if (RemoteText.IsWhitespace(characters[i]))
            {
                return (string.Concat(characters.Take(i + 1)), string.Concat(characters.Skip(i + 1)));
            }
        }
        return ("", text);
    }
}

// Text in characters as a person sees them. A character can hold more than
// 1 Unicode scalar, such as an emoji with a skin tone.
internal static class RemoteText
{
    public static List<string> Characters(string text)
    {
        var output = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            output.Add(e.GetTextElement());
        }
        return output;
    }

    public static int Scalars(string text)
    {
        var n = 0;
        foreach (var _ in text.EnumerateRunes())
        {
            n++;
        }
        return n;
    }

    // Line breaks as Swift counts them, also CR LF as 1 character.
    public static bool IsNewline(string character) =>
        character is "\n" or "\r" or "\r\n" or "\v" or "\f" or "\u0085" or "\u2028" or "\u2029";

    public static bool IsWhitespace(string character) =>
        character.Length > 0 && Rune.IsWhiteSpace(Rune.GetRuneAt(character, 0));
}

// Turns the mouse buttons and motion of the touchpad into packets. A left
// press that moves becomes a drag: singlehold, the motion, then
// singlerelease. A left press that does not move is a click.
public sealed class PointerTracker
{
    // The motion, in points, after which a press becomes a drag. A click on
    // a touchpad moves a little.
    public const double DragSlop = 3.0;

    bool pressed;
    double travel;
    // The motion of a press before it becomes a drag.
    double pendingX;
    double pendingY;

    public bool Dragging { get; private set; }

    public void LeftDown()
    {
        Reset();
        pressed = true;
    }

    public IReadOnlyList<Packet> LeftUp()
    {
        var was = pressed;
        var dragging = Dragging;
        Reset();
        if (!was)
        {
            return [];
        }
        return [dragging ? RemoteInput.Hold(false) : RemoteInput.Click(RemoteClick.Left)];
    }

    public IReadOnlyList<Packet> Move(double dx, double dy)
    {
        if (!pressed || Dragging)
        {
            return [RemoteInput.Move(dx, dy)];
        }
        travel += Math.Sqrt(dx * dx + dy * dy);
        pendingX += dx;
        pendingY += dy;
        if (travel < DragSlop)
        {
            return [];
        }
        Dragging = true;
        IReadOnlyList<Packet> output = [RemoteInput.Hold(true), RemoteInput.Move(pendingX, pendingY)];
        pendingX = 0;
        pendingY = 0;
        return output;
    }

    // Ends a press without a click, for example when the pad gives the
    // pointer back to this computer. A drag releases the button.
    public IReadOnlyList<Packet> Cancel()
    {
        var dragging = Dragging;
        Reset();
        return dragging ? [RemoteInput.Hold(false)] : [];
    }

    void Reset()
    {
        pressed = false;
        Dragging = false;
        travel = 0;
        pendingX = 0;
        pendingY = 0;
    }
}

// Detects Ctrl and Alt that go down together and come up with no other key
// or click between. The touchpad then gives the pointer back to this
// computer. Shortcuts such as Ctrl+Alt+T still reach the computer.
public sealed class ReleaseChord
{
    bool armed;

    // Handles a change of the modifier keys. It returns true when the chord
    // is complete.
    public bool Flags(RemoteMods held)
    {
        if (held.Shift || held.Super)
        {
            armed = false;
        }
        else if (held.Ctrl && held.Alt)
        {
            armed = true;
        }
        else if (!held.Ctrl && !held.Alt)
        {
            var done = armed;
            armed = false;
            return done;
        }
        return false;
    }

    // A key or a click happened, so the modifiers belong to a shortcut.
    public void Interrupt() => armed = false;
}
