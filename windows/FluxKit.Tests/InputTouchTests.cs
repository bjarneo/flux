using FluxKit;

namespace FluxKit.Tests;

// TouchInputTests.swift of the Mac app.
public class InputTouchTests
{
    static RemotePoint P(double x, double y) => new(x, y);

    static Dictionary<int, RemotePoint> Fingers(params (int Id, RemotePoint At)[] points) => points.ToDictionary(p => p.Id, p => p.At);

    // Pointer speed

    [Fact]
    public void PointerScaleGrowsWithSpeed()
    {
        // A slow finger moves the pointer precisely.
        Assert.Equal(1.3, RemoteInput.PointerScale(0), 9);
        Assert.Equal(1.3 * 1.5, RemoteInput.PointerScale(5), 9);
        Assert.Equal(1.3 * 1.5, RemoteInput.PointerScale(-5), 9);
        Assert.Equal(1.3 * 3, RemoteInput.PointerScale(20), 9);
        // The boost stops at 2.
        Assert.Equal(1.3 * 3, RemoteInput.PointerScale(200), 9);
    }

    // Text edits

    [Fact]
    public void TypeEditBetween()
    {
        Assert.Equal(new TypeEdit(0, "hello"), TypeEdit.Between("", "hello"));
        Assert.Equal(new TypeEdit(0, " "), TypeEdit.Between("hello", "hello "));
        // A correction replaces the end that changed.
        Assert.Equal(new TypeEdit(2, "he"), TypeEdit.Between("teh", "the"));
        Assert.Equal(new TypeEdit(1, ""), TypeEdit.Between("abc", "ab"));
        Assert.Equal(new TypeEdit(3, ""), TypeEdit.Between("abc", ""));
        // A backspace per code point, as on Android.
        Assert.Equal(new TypeEdit(2, ""), TypeEdit.Between("a👍🏽", "a"));
        Assert.Equal(new TypeEdit(1, "e"), TypeEdit.Between("café", "cafe"));
    }

    [Fact]
    public void TypeBufferSendsEachChange()
    {
        var b = new RemoteTypeBuffer();
        Assert.Equal(new TypeChange.Edit(0, "h", false), b.Change("h", false, false));
        Assert.Equal(new TypeChange.Edit(0, "i", false), b.Change("hi", false, false));
        // No change sends nothing.
        Assert.Equal(new TypeChange.Edit(0, "", false), b.Change("hi", false, false));
        Assert.Equal(new TypeChange.Edit(1, "", false), b.Change("h", false, false));
        Assert.Equal("h", b.Sent);
    }

    [Fact]
    public void TypeBufferHeldModifierMakesAShortcut()
    {
        var b = new RemoteTypeBuffer();
        b.Change("ab", false, false);
        Assert.Equal(new TypeChange.Shortcut("c"), b.Change("abc", false, true));
        // The letter of a shortcut does not stay in the field.
        Assert.Equal("", b.Sent);
        Assert.Equal(new TypeChange.Edit(0, "x", false), b.Change("x", false, false));
        var c = new RemoteTypeBuffer();
        c.Change("ab", false, false);
        // A backspace with a held modifier is no shortcut.
        Assert.Equal(new TypeChange.Edit(1, "", false), c.Change("a", false, true));
    }

    [Fact]
    public void TypeBufferStartsAgainAfterALongLineOnlyWithRestart()
    {
        var b = new RemoteTypeBuffer();
        var line = string.Concat(Enumerable.Repeat("word ", 9));
        Assert.Equal(45, line.Length);
        b.Change(line, false, false, restart: true);
        Assert.Equal(new TypeChange.Edit(0, "abcd", false), b.Change(line + "abcd", false, false, restart: true));
        // The field keeps its text while the keyboard composes.
        Assert.Equal(new TypeChange.Edit(0, " ", false), b.Change(line + "abcd ", true, false, restart: true));
        // A fluxd without keyRepeat gets at most about 50 Backspace packets.
        Assert.Equal(new TypeChange.Edit(0, "", true), b.Change(line + "abcd ", false, false, restart: true));
        Assert.Equal("", b.Sent);
        Assert.Equal(0, b.Clear());
    }

    [Fact]
    public void TypeBufferKeepsALongLine()
    {
        var b = new RemoteTypeBuffer();
        var line = string.Concat(Enumerable.Repeat("word ", 30));
        Assert.Equal(new TypeChange.Edit(0, line, false), b.Change(line, false, false));
        Assert.Equal(new TypeChange.Edit(0, "abcd ", false), b.Change(line + "abcd ", false, false));
        // The field keeps its text, so that the clear key can delete it.
        Assert.Equal(line + "abcd ", b.Sent);
    }

    [Fact]
    public void TypeBufferClearDeletesTheSentText()
    {
        var b = new RemoteTypeBuffer();
        Assert.Equal(0, b.Clear());
        b.Change("hi 👍🏽", false, false);
        // 1 Backspace for each code point, as TypeEdit counts them.
        Assert.Equal(5, b.Clear());
        Assert.Equal("", b.Sent);
        Assert.Equal(new TypeChange.Edit(0, "a", false), b.Change("a", false, false));
    }

    [Fact]
    public void TypeBufferDropsTheLastCharacter()
    {
        var b = new RemoteTypeBuffer();
        // No text: the Backspace key goes to the computer as it is.
        Assert.Equal(0, b.DropLast());
        b.Change("a👍🏽bc", false, false);
        Assert.Equal(1, b.DropLast());
        Assert.Equal(1, b.DropLast());
        // 1 Backspace for each code point, as TypeEdit counts them.
        Assert.Equal(2, b.DropLast());
        Assert.Equal("a", b.Sent);
        b.Change("abc", false, false);
        Assert.Equal(1, b.DropLast());
        Assert.Equal("ab", b.Sent);
        // The field follows with no new key.
        Assert.Equal(new TypeChange.Edit(0, "", false), b.Change("ab", false, false));
        b.Reset();
        Assert.Equal("", b.Sent);
    }

    // Touchpad

    static List<TouchpadAction> Pad(params (Dictionary<int, RemotePoint> Points, double At)[] steps)
    {
        var g = new TouchpadGesture();
        return steps.SelectMany(s => g.Touches(s.Points, s.At)).ToList();
    }

    [Fact]
    public void TapsClickByFingerCount()
    {
        Assert.Equal([new TouchpadAction.Click(RemoteClick.Left)], Pad((Fingers((1, P(10, 10))), 0), (Fingers(), 0.1)));
        Assert.Equal([new TouchpadAction.Click(RemoteClick.Right)], Pad(
            (Fingers((1, P(10, 10))), 0), (Fingers((1, P(10, 10)), (2, P(50, 10))), 0.02),
            (Fingers((2, P(50, 10))), 0.1), (Fingers(), 0.11)));
        Assert.Equal([new TouchpadAction.Click(RemoteClick.Middle)], Pad(
            (Fingers((1, RemotePoint.Zero), (2, P(40, 0)), (3, P(80, 0))), 0), (Fingers(), 0.1)));
    }

    [Fact]
    public void MoveWaitsForTheSlopThenAccelerates()
    {
        var g = new TouchpadGesture();
        Assert.Empty(g.Touches(Fingers((1, RemotePoint.Zero)), 0));
        // 5 points is under the slop.
        Assert.Empty(g.Touches(Fingers((1, P(3, 4))), 0.01));
        var first = g.Touches(Fingers((1, P(6, 8))), 0.02);
        var scale = RemoteInput.PointerScale(10);
        // The motion before the slop goes out with the first move.
        Assert.Equal([new TouchpadAction.Move(6 * scale, 8 * scale)], first);
        Assert.Equal([new TouchpadAction.Move(RemoteInput.PointerScale(1), 0)], g.Touches(Fingers((1, P(7, 8))), 0.03));
        // A finger that moved does not hold.
        Assert.Null(g.HoldDeadline);
        // A move does not click.
        Assert.Empty(g.Touches(Fingers(), 0.04));
    }

    [Fact]
    public void TwoFingersScrollNaturally()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, P(0, 100)), (2, P(40, 100))), 0);
        // Under the slop.
        Assert.Empty(g.Touches(Fingers((1, P(0, 95)), (2, P(40, 95))), 0.01));
        // Fingers that move up scroll down.
        Assert.Equal([new TouchpadAction.Scroll(0, 5 * 1.2)], g.Touches(Fingers((1, P(0, 90)), (2, P(40, 90))), 0.02));
        // The motion is the mean of the fingers.
        Assert.Equal([new TouchpadAction.Scroll(-5 * 1.2, 0)], g.Touches(Fingers((1, P(10, 90)), (2, P(40, 90))), 0.03));
        Assert.Empty(g.Touches(Fingers(), 0.04));
    }

    [Fact]
    public void HoldStillStartsADrag()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, P(10, 10))), 1);
        Assert.Equal(1.45, g.HoldDeadline);
        Assert.Empty(g.HoldIfDue(1.2));
        Assert.Equal([new TouchpadAction.Hold(true)], g.HoldIfDue(1.45));
        Assert.Null(g.HoldDeadline);
        // A drag moves at once, without the slop.
        Assert.Equal([new TouchpadAction.Move(2 * RemoteInput.PointerScale(2), 0)], g.Touches(Fingers((1, P(12, 10))), 1.5));
        // The drag ends when the finger lifts, without a click.
        Assert.Equal([new TouchpadAction.Hold(false)], g.Touches(Fingers(), 1.6));
    }

    [Fact]
    public void LateEventHoldsFirst()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, RemotePoint.Zero)), 0);
        Assert.Equal([new TouchpadAction.Hold(true), new TouchpadAction.Move(RemoteInput.PointerScale(1), 0)],
            g.Touches(Fingers((1, P(1, 0))), 0.5));
    }

    [Fact]
    public void HoldWithoutMotionReleases()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, RemotePoint.Zero)), 0);
        g.HoldIfDue(0.5);
        Assert.Equal([new TouchpadAction.Hold(false)], g.Touches(Fingers(), 0.6));
    }

    [Fact]
    public void CancelReleasesADragWithoutAClick()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, RemotePoint.Zero)), 0);
        // A canceled tap does not click.
        Assert.Empty(g.Cancel());
        g.Touches(Fingers((1, RemotePoint.Zero)), 1);
        g.HoldIfDue(1.5);
        Assert.Equal([new TouchpadAction.Hold(false)], g.Cancel());
        // The gesture ended.
        Assert.Empty(g.Touches(Fingers(), 2));
    }

    [Fact]
    public void TwoFingersDoNotHold()
    {
        var g = new TouchpadGesture();
        g.Touches(Fingers((1, RemotePoint.Zero), (2, P(30, 0))), 0);
        Assert.Null(g.HoldDeadline);
        Assert.Empty(g.HoldIfDue(1));
    }

    [Fact]
    public void ActionsBecomePackets()
    {
        Assert.Equal(1.23, new TouchpadAction.Move(1.234, 2).ToPacket().Double("dx"));
        Assert.True(new TouchpadAction.Scroll(0, 1).ToPacket().Bool("scroll"));
        Assert.True(new TouchpadAction.Click(RemoteClick.Right).ToPacket().Bool("rightclick"));
        Assert.True(new TouchpadAction.Hold(false).ToPacket().Bool("singlerelease"));
    }
}
