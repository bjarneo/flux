namespace FluxKit;

// The zoom and the pan of the remote desktop on a touch screen, as in Flux
// for Android. At scale 1, the video fits the view and keeps its shape. A
// point of the video at (x, y) at scale 1 shows at (x × scale + offset.x,
// y × scale + offset.y) in the view. The view uses a top left origin.
public sealed record DesktopViewport(RemoteSize View, RemoteSize Video)
{
    // The largest zoom.
    public const double MaxScale = 6.0;

    public double Scale { get; private init; } = 1.0;
    public RemotePoint Offset { get; private init; } = RemotePoint.Zero;

    // The rectangle of the video in the view at scale 1.
    public RemoteRect FitRect => new DesktopGeometry(View, Video).Fit;

    // The view points for 1 video pixel.
    public double Pixel => new DesktopGeometry(View, Video).Scale * Scale;

    // The rectangle of the video in the view at the zoom and the pan.
    public RemoteRect VideoFrame
    {
        get
        {
            var f = FitRect;
            return new RemoteRect(f.MinX * Scale + Offset.X, f.MinY * Scale + Offset.Y, f.Width * Scale, f.Height * Scale);
        }
    }

    // The position on the video for a point of the view. It returns null
    // for a point outside the video, unless clamp moves the point to the
    // nearest edge.
    public DesktopPoint? ToVideo(RemotePoint p, bool clamp = false)
    {
        var f = FitRect;
        if (!(f.Width > 0) || !(f.Height > 0))
        {
            return null;
        }
        var x = ((p.X - Offset.X) / Scale - f.MinX) / f.Width;
        var y = ((p.Y - Offset.Y) / Scale - f.MinY) / f.Height;
        if (clamp)
        {
            return new DesktopPoint(Math.Min(Math.Max(x, 0), 1), Math.Min(Math.Max(y, 0), 1));
        }
        if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1))
        {
            return null;
        }
        return new DesktopPoint(x, y);
    }

    // Zooms by factor around the point focus of the view and moves by pan.
    // The scale stays from 1 to MaxScale, and the video stays on the view.
    public DesktopViewport Zoom(double factor, RemotePoint focus, RemotePoint pan = default)
    {
        var next = Math.Min(Math.Max(Scale * factor, 1), MaxScale);
        // The point under the focus stays under the focus.
        return (this with
        {
            Scale = next,
            Offset = new RemotePoint(focus.X - (focus.X - Offset.X) / Scale * next + pan.X,
                                     focus.Y - (focus.Y - Offset.Y) / Scale * next + pan.Y),
        }).Clamped();
    }

    // Moves the view by dx, dy points.
    public DesktopViewport Pan(double dx, double dy) =>
        (this with { Offset = new RemotePoint(Offset.X + dx, Offset.Y + dy) }).Clamped();

    // The viewport for a new view or video size. The same sizes keep the
    // zoom. When 1 side of the view changes, for example when the keyboard
    // or a panel shows, the video keeps its size on the screen, so that the
    // text stays readable. The video point focus then keeps its place as a
    // part of the view, so that a tapped field stays in view. Without focus,
    // the point at the center of the view keeps its place. A new video, a
    // first view, or a view with 2 new sides, as after a rotation, starts at
    // scale 1.
    public DesktopViewport Resized(RemoteSize view, RemoteSize video, DesktopPoint? focus = null)
    {
        if (view == View && video == Video)
        {
            return this;
        }
        var next = new DesktopViewport(view, video);
        var fitScale = new DesktopGeometry(view, video).Scale;
        var oneSide = (view.Width == View.Width) != (view.Height == View.Height);
        if (video != Video || !oneSide || !(View.Width > 0) || !(View.Height > 0) || !(Pixel > 0) || !(fitScale > 0))
        {
            return next;
        }
        next = next with { Scale = Math.Min(Math.Max(Pixel / fitScale, 1), MaxScale) };
        var center = new RemotePoint(View.Width / 2, View.Height / 2);
        if ((focus ?? ToVideo(center, clamp: true)) is not { } at)
        {
            return next;
        }
        // The part of the old view where the focus shows.
        var old = VideoFrame;
        var partX = Math.Min(Math.Max((old.MinX + at.X * old.Width) / View.Width, 0), 1);
        var partY = Math.Min(Math.Max((old.MinY + at.Y * old.Height) / View.Height, 0), 1);
        var f = next.FitRect;
        return (next with
        {
            Offset = new RemotePoint(partX * view.Width - (f.MinX + at.X * f.Width) * next.Scale,
                                     partY * view.Height - (f.MinY + at.Y * f.Height) * next.Scale),
        }).Clamped();
    }

    // Keeps the video on the view. A video that is smaller than the view
    // stays in the center. A larger video covers the view.
    DesktopViewport Clamped()
    {
        double Axis(double offset, double start, double length, double view)
        {
            var shown = length * Scale;
            if (shown <= view)
            {
                return (view - shown) / 2 - start * Scale;
            }
            return Math.Min(Math.Max(offset, view - (start + length) * Scale), -start * Scale);
        }
        var f = FitRect;
        return this with { Offset = new RemotePoint(Axis(Offset.X, f.MinX, f.Width, View.Width), Axis(Offset.Y, f.MinY, f.Height, View.Height)) };
    }
}

// What the touches on the remote desktop do.
public abstract record DesktopTouchAction
{
    // Puts the pointer on the position.
    public sealed record Move(DesktopPoint At) : DesktopTouchAction;

    public sealed record Click(RemoteClick Button, DesktopPoint At) : DesktopTouchAction;

    // Presses the left button at the position for a drag, or releases it.
    public sealed record Hold(bool Down, DesktopPoint At) : DesktopTouchAction;

    // Scrolls the window under the pointer. A positive Dy scrolls down.
    public sealed record Scroll(double Dx, double Dy) : DesktopTouchAction;

    // The zoom or the pan of the view changes.
    public sealed record Viewport(DesktopViewport Value) : DesktopTouchAction;

    // A finger held still, for a haptic.
    public sealed record Held() : DesktopTouchAction;

    // The packet of the action, or null for a change of the view only.
    public Packet? ToPacket() => this switch
    {
        Move m => RemoteInput.At(m.At.X, m.At.Y),
        Click c => RemoteInput.ClickAt(c.Button, c.At.X, c.At.Y),
        Hold h => RemoteInput.HoldAt(h.Down, h.At.X, h.At.Y),
        Scroll s => RemoteInput.Scroll(s.Dx, s.Dy),
        _ => null,
    };
}

// The touches on the remote desktop of a touch screen, as in Flux for
// Android. A tap clicks, and a second tap near the first soon after clicks
// at the same position, so that the computer sees a double click. A finger
// that holds still clicks the right button, or drags when it then moves. 2
// fingers scroll, and a tap with 2 fingers clicks the right button. A pinch
// zooms, and 1 finger moves the zoomed view. Positions and distances are in
// view points, and times in seconds.
public sealed class DesktopTouches
{
    // A finger that stays still this long clicks the right button, or drags
    // when it moves.
    public const double HoldDelay = 0.45;

    // A second tap within this time and distance clicks at the first tap.
    public const double DoubleTapTime = 0.4;
    public const double DoubleTapDistance = 24.0;

    // The motion after which a touch is no tap.
    public const double Slop = 8.0;

    enum Mode
    {
        Pending,
        Pan,
        Held,
        Drag,
        Multi,
        Pinch,
        Scroll,
    }

    bool active;
    Mode mode = Mode.Pending;
    int first;
    RemotePoint start;
    double holdAt;
    RemotePoint last;
    HashSet<int> ids = [];
    RemotePoint startCentroid;
    double startSpan;
    RemotePoint lastCentroid;
    double lastSpan;
    // The last tap: its time, its point in the view, and its position on
    // the video.
    (double Time, RemotePoint Point, DesktopPoint At)? lastTap;

    // The time at which a still finger holds, or null when no hold can
    // start.
    public double? HoldDeadline => active && mode == Mode.Pending ? holdAt : null;

    // Handles the fingers on the view after a touch event, by ID. No fingers
    // ends the gesture. v is the zoom and the pan now.
    public IReadOnlyList<DesktopTouchAction> Touches(IReadOnlyDictionary<int, RemotePoint> now, double time, DesktopViewport v)
    {
        if (!active)
        {
            if (now.Count == 0)
            {
                return [];
            }
            var id = now.Keys.Min();
            var p0 = now[id];
            active = true;
            mode = Mode.Pending;
            first = id;
            start = p0;
            last = p0;
            holdAt = time + HoldDelay;
            ids = [id];
            startCentroid = p0;
            startSpan = 0;
            lastCentroid = p0;
            lastSpan = 0;
        }
        var output = new List<DesktopTouchAction>(HoldIfDue(time, v));
        if (now.Count == 0)
        {
            output.AddRange(End(time, v));
            return output;
        }
        var nowIds = new HashSet<int>(now.Keys);
        if (now.Count >= 2 && mode is Mode.Pending or Mode.Pan)
        {
            mode = Mode.Multi;
            startCentroid = Centroid(now);
            startSpan = Span(now, startCentroid);
        }
        switch (mode)
        {
            case Mode.Pending:
            case Mode.Pan:
            {
                if (Primary(now) is not { } p)
                {
                    break;
                }
                if (mode == Mode.Pending && Distance(p, start) >= Slop)
                {
                    mode = Mode.Pan;
                }
                if (mode == Mode.Pan)
                {
                    output.Add(new DesktopTouchAction.Viewport(v.Pan(p.X - last.X, p.Y - last.Y)));
                    last = p;
                }
                break;
            }
            case Mode.Held:
            case Mode.Drag:
            {
                if (Primary(now) is not { } p)
                {
                    break;
                }
                if (mode == Mode.Held && Distance(p, start) >= Slop)
                {
                    mode = Mode.Drag;
                    if (v.ToVideo(start, clamp: true) is { } at)
                    {
                        output.Add(new DesktopTouchAction.Hold(true, at));
                    }
                }
                if (mode == Mode.Drag && p != last && v.ToVideo(p, clamp: true) is { } to)
                {
                    output.Add(new DesktopTouchAction.Move(to));
                }
                last = p;
                break;
            }
            default:
            {
                if (now.Count < 2)
                {
                    break;
                }
                var c = Centroid(now);
                var s = Span(now, c);
                // A finger that lands or lifts moves the center. The next
                // motion starts from there.
                if (nowIds.SetEquals(ids))
                {
                    if (mode == Mode.Multi)
                    {
                        if (Math.Abs(s - startSpan) > Slop)
                        {
                            mode = Mode.Pinch;
                        }
                        else if (Distance(c, startCentroid) > Slop)
                        {
                            mode = Mode.Scroll;
                            // The scroll goes to the window under the fingers.
                            if (v.ToVideo(startCentroid) is { } at)
                            {
                                output.Add(new DesktopTouchAction.Move(at));
                            }
                        }
                    }
                    if (mode == Mode.Pinch)
                    {
                        output.Add(new DesktopTouchAction.Viewport(v.Zoom(lastSpan > 0 ? s / lastSpan : 1, lastCentroid,
                            new RemotePoint(c.X - lastCentroid.X, c.Y - lastCentroid.Y))));
                    }
                    else if (mode == Mode.Scroll && v.Pixel > 0)
                    {
                        // Natural scrolling: the content follows the fingers.
                        output.Add(new DesktopTouchAction.Scroll(-(c.X - lastCentroid.X) / v.Pixel, -(c.Y - lastCentroid.Y) / v.Pixel));
                    }
                }
                lastCentroid = c;
                lastSpan = s;
                break;
            }
        }
        ids = nowIds;
        return output;
    }

    // Holds when the finger stayed still until its time: the pointer goes
    // under it.
    public IReadOnlyList<DesktopTouchAction> HoldIfDue(double time, DesktopViewport v)
    {
        if (!active || mode != Mode.Pending || time < holdAt)
        {
            return [];
        }
        mode = Mode.Held;
        var output = new List<DesktopTouchAction> { new DesktopTouchAction.Held() };
        if (v.ToVideo(start) is { } at)
        {
            output.Add(new DesktopTouchAction.Move(at));
        }
        return output;
    }

    // Ends the gesture without a click, for example when the system takes
    // the touches. A drag releases the button.
    public IReadOnlyList<DesktopTouchAction> Cancel(DesktopViewport v)
    {
        var wasActive = active;
        active = false;
        if (!wasActive || mode != Mode.Drag || v.ToVideo(last, clamp: true) is not { } at)
        {
            return [];
        }
        return [new DesktopTouchAction.Hold(false, at)];
    }

    IReadOnlyList<DesktopTouchAction> End(double time, DesktopViewport v)
    {
        active = false;
        switch (mode)
        {
            case Mode.Pending:
            {
                if (v.ToVideo(start) is not { } position)
                {
                    return [];
                }
                var at = position;
                if (lastTap is { } prev && time - prev.Time < DoubleTapTime && Distance(start, prev.Point) < DoubleTapDistance)
                {
                    at = prev.At;
                }
                lastTap = (time, start, at);
                return [new DesktopTouchAction.Click(RemoteClick.Left, at)];
            }
            case Mode.Held:
                return v.ToVideo(start) is { } held ? [new DesktopTouchAction.Click(RemoteClick.Right, held)] : [];
            case Mode.Drag:
                return v.ToVideo(last, clamp: true) is { } end ? [new DesktopTouchAction.Hold(false, end)] : [];
            case Mode.Multi:
                return v.ToVideo(startCentroid) is { } center ? [new DesktopTouchAction.Click(RemoteClick.Right, center)] : [];
            default:
                return [];
        }
    }

    // The first finger, or the earliest finger that is still down.
    RemotePoint? Primary(IReadOnlyDictionary<int, RemotePoint> now)
    {
        if (now.TryGetValue(first, out var p))
        {
            return p;
        }
        return now.Count == 0 ? null : now[now.Keys.Min()];
    }

    static double Distance(RemotePoint a, RemotePoint b) => double.Hypot(a.X - b.X, a.Y - b.Y);

    static RemotePoint Centroid(IReadOnlyDictionary<int, RemotePoint> points)
    {
        double n = points.Count;
        return new RemotePoint(points.Values.Sum(p => p.X) / n, points.Values.Sum(p => p.Y) / n);
    }

    // The mean distance of the fingers from their center.
    static double Span(IReadOnlyDictionary<int, RemotePoint> points, RemotePoint center) =>
        points.Values.Sum(p => double.Hypot(p.X - center.X, p.Y - center.Y)) / points.Count;
}
