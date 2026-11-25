namespace FluxKit;

// A point in a view, in device-independent pixels, with a top left origin.
public readonly record struct RemotePoint(double X, double Y)
{
    public static readonly RemotePoint Zero = new(0, 0);
}

// The size of a view or a video.
public readonly record struct RemoteSize(double Width, double Height)
{
    public static readonly RemoteSize Zero = new(0, 0);
}

// A rectangle in a view, with a top left origin.
public readonly record struct RemoteRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;
    public double MinY => Y;
    public double MaxX => X + Width;
    public double MaxY => Y + Height;
}

public static partial class RemoteInput
{
    const double BaseSpeed = 1.3;
    const double BoostDistance = 10.0;
    const double MaxBoost = 2.0;

    // The factor from a finger motion to a pointer motion, for a motion of
    // distance points in 1 touch event, as in Flux for Android. A slow
    // finger moves the pointer precisely, and a fast finger moves it
    // further.
    public static double PointerScale(double distance) =>
        BaseSpeed * (1 + Math.Min(MaxBoost, Math.Abs(distance) / BoostDistance));
}

// The keys that change the text old into new: backspaces for the end of
// old that changed, then the new end. A touch keyboard edits a word while
// it composes it, and a correction replaces the word. A backspace removes 1
// code point, as in Flux for Android.
public readonly record struct TypeEdit(int Backspaces, string Text)
{
    public static TypeEdit Between(string old, string @new)
    {
        var a = RemoteText.Characters(old);
        var b = RemoteText.Characters(@new);
        var prefix = 0;
        while (prefix < a.Count && prefix < b.Count && a[prefix] == b[prefix])
        {
            prefix++;
        }
        return new TypeEdit(RemoteText.Scalars(string.Concat(a.Skip(prefix))), string.Concat(b.Skip(prefix)));
    }
}

// What a change of the type field does.
public abstract record TypeChange
{
    // Press Backspace Backspaces times, then type Text. With Clear, the
    // field empties.
    public sealed record Edit(int Backspaces, string Text, bool Clear) : TypeChange;

    // A modifier is held, so the new text goes as a shortcut, such as ctrl
    // and c. The field empties.
    public sealed record Shortcut(string Text) : TypeChange;
}

// The type field of a touch keyboard: what the computer has, and what each
// change of the field sends. The keyboard can change the text before the
// cursor, so each change goes out as backspaces and new text. The app
// leaves out the text that the keyboard still composes at the end. The
// field keeps all text since the last reset, so that its clear key can
// delete that text on the computer.
public sealed class RemoteTypeBuffer
{
    // With restart, a field with more characters than this empties after a
    // word. A clear or an edit then needs at most about this many Backspace
    // packets, for a fluxd that presses 1 key for each packet.
    public const int RestartLength = 48;

    // The text of the field that the computer has.
    public string Sent { get; private set; } = "";

    // Handles the new text of the field, without the text that the keyboard
    // composes. composing is true while the keyboard composes. With restart,
    // a long field empties after a word, see RestartLength. Use it for a
    // computer without keyRepeat.
    public TypeChange Change(string text, bool composing, bool modsHeld, bool restart = false)
    {
        var edit = TypeEdit.Between(Sent, text);
        if (modsHeld && edit.Text.Length > 0)
        {
            Sent = "";
            return new TypeChange.Shortcut(edit.Text);
        }
        if (restart && !composing && RemoteText.Characters(text).Count > RestartLength && text.EndsWith(' '))
        {
            Sent = "";
            return new TypeChange.Edit(edit.Backspaces, edit.Text, true);
        }
        Sent = text;
        return new TypeChange.Edit(edit.Backspaces, edit.Text, false);
    }

    // Forgets the text and returns the Backspace presses that delete it on
    // the computer: 1 for each code point, as TypeEdit counts them.
    public int Clear()
    {
        var n = RemoteText.Scalars(Sent);
        Sent = "";
        return n;
    }

    // Removes the last character, for the Backspace key of the key rows. It
    // returns the Backspace presses that delete it on the computer: 1 for
    // each code point, as TypeEdit counts them. It returns 0 when the
    // computer has no text from the field.
    public int DropLast()
    {
        var characters = RemoteText.Characters(Sent);
        if (characters.Count == 0)
        {
            return 0;
        }
        var last = characters[^1];
        Sent = string.Concat(characters.Take(characters.Count - 1));
        return RemoteText.Scalars(last);
    }

    // Forgets the text, for example after Enter or a click.
    public void Reset() => Sent = "";
}

// What a touchpad gesture sends.
public abstract record TouchpadAction
{
    public sealed record Move(double Dx, double Dy) : TouchpadAction;

    // A positive Dy scrolls down.
    public sealed record Scroll(double Dx, double Dy) : TouchpadAction;

    public sealed record Click(RemoteClick Button) : TouchpadAction;

    // Presses the left button for a drag, or releases it.
    public sealed record Hold(bool Down) : TouchpadAction;

    // The packet of the action.
    public Packet ToPacket() => this switch
    {
        Move m => RemoteInput.Move(m.Dx, m.Dy),
        Scroll s => RemoteInput.Scroll(s.Dx, s.Dy),
        Click c => RemoteInput.Click(c.Button),
        Hold h => RemoteInput.Hold(h.Down),
        _ => throw new InvalidOperationException("an unknown touchpad action"),
    };
}

// The gestures of a touchpad on a touch screen, as in Flux for Android. 1
// finger moves the pointer, and a tap clicks. 2 fingers scroll, and a tap
// with 2 fingers clicks the right button. A tap with 3 fingers clicks the
// middle button. A finger that holds still starts a drag, which ends when
// the finger lifts. Positions and distances are in points, and times in
// seconds.
public sealed class TouchpadGesture
{
    // A finger that stays still this long starts a drag.
    public const double HoldDelay = 0.45;

    // The motion after which a touch is no tap.
    public const double Slop = 8.0;

    // The scroll units for 1 point of finger motion.
    public const double ScrollSpeed = 1.2;

    bool active;
    Dictionary<int, RemotePoint> points = [];
    double holdAt;
    // The most fingers during the gesture.
    int fingers;
    double travel;
    bool holding;
    // The motion of 1 finger that did not go out yet.
    double pendingX;
    double pendingY;

    // The time at which a still finger starts a drag, or null when no drag
    // can start.
    public double? HoldDeadline => WaitsForHold ? holdAt : null;

    bool WaitsForHold => active && !holding && fingers == 1 && travel < Slop;

    // Handles the fingers on the pad after a touch event, by ID. No fingers
    // ends the gesture.
    public IReadOnlyList<TouchpadAction> Touches(IReadOnlyDictionary<int, RemotePoint> now, double time)
    {
        if (!active)
        {
            if (now.Count == 0)
            {
                return [];
            }
            Reset();
            active = true;
            holdAt = time + HoldDelay;
            fingers = Math.Max(1, now.Count);
            points = new Dictionary<int, RemotePoint>(now);
            return [];
        }
        var output = new List<TouchpadAction>(HoldIfDue(time));
        if (now.Count == 0)
        {
            output.AddRange(End());
            return output;
        }
        fingers = Math.Max(fingers, now.Count);
        var deltas = now.Select(e => points.TryGetValue(e.Key, out var p) ? (Dx: e.Value.X - p.X, Dy: e.Value.Y - p.Y) : (Dx: 0.0, Dy: 0.0)).ToList();
        points = new Dictionary<int, RemotePoint>(now);
        if (fingers == 1 && deltas.Count > 0)
        {
            var d = deltas[0];
            travel += double.Hypot(d.Dx, d.Dy);
            pendingX += d.Dx;
            pendingY += d.Dy;
            if ((travel >= Slop || holding) && (pendingX != 0 || pendingY != 0))
            {
                var scale = RemoteInput.PointerScale(double.Hypot(pendingX, pendingY));
                output.Add(new TouchpadAction.Move(pendingX * scale, pendingY * scale));
                pendingX = 0;
                pendingY = 0;
            }
        }
        else if (now.Count >= 2)
        {
            double n = now.Count;
            var dx = deltas.Sum(d => d.Dx) / n;
            var dy = deltas.Sum(d => d.Dy) / n;
            travel += double.Hypot(dx, dy);
            // Natural scrolling: the content follows the fingers.
            if (travel >= Slop && (dx != 0 || dy != 0))
            {
                output.Add(new TouchpadAction.Scroll(-dx * ScrollSpeed, -dy * ScrollSpeed));
            }
        }
        return output;
    }

    // Starts the drag when the finger stayed still until its time.
    public IReadOnlyList<TouchpadAction> HoldIfDue(double time)
    {
        if (!WaitsForHold || time < holdAt)
        {
            return [];
        }
        holding = true;
        return [new TouchpadAction.Hold(true)];
    }

    // Ends the gesture without a click, for example when the system takes
    // the touches. A drag releases the button.
    public IReadOnlyList<TouchpadAction> Cancel()
    {
        var release = active && holding;
        Reset();
        return release ? [new TouchpadAction.Hold(false)] : [];
    }

    IReadOnlyList<TouchpadAction> End()
    {
        var wasHolding = holding;
        var moved = travel >= Slop;
        var count = fingers;
        Reset();
        if (wasHolding)
        {
            return [new TouchpadAction.Hold(false)];
        }
        if (moved)
        {
            return [];
        }
        return count switch
        {
            1 => [new TouchpadAction.Click(RemoteClick.Left)],
            2 => [new TouchpadAction.Click(RemoteClick.Right)],
            _ => [new TouchpadAction.Click(RemoteClick.Middle)],
        };
    }

    void Reset()
    {
        active = false;
        points = [];
        holdAt = 0;
        fingers = 0;
        travel = 0;
        holding = false;
        pendingX = 0;
        pendingY = 0;
    }
}
