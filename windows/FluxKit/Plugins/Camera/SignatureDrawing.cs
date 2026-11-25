namespace FluxKit;

// A point on the drawing canvas, in device-independent pixels. The origin
// is the top left corner.
public readonly record struct InkPoint(double X, double Y);

// A signature that the user draws with a mouse, a pen, or a touch screen.
// It becomes the same transparent ink as a signature on paper: the strokes
// are smoothed, drawn with soft edges, and cropped to the ink with the
// margin of SignatureCut. SignatureDrawing.swift of the Mac app has the same
// rules. The Mac draws with Core Graphics, and this file draws the same
// strokes itself, so that the result does not need a graphics library.
public sealed class SignatureDrawing
{
    readonly List<List<InkPoint>> strokes = [];

    // The width of a stroke in canvas units.
    public const double LineWidth = 3;

    // The strokes in canvas units.
    public IReadOnlyList<IReadOnlyList<InkPoint>> Strokes => strokes;

    public bool IsEmpty => strokes.Count == 0;

    // Starts a new stroke at a point.
    public void Begin(InkPoint p) => strokes.Add([p]);

    // Adds a point to the current stroke. A point closer than half a unit to
    // the last point adds nothing.
    public void Extend(InkPoint p)
    {
        if (strokes.Count == 0)
        {
            Begin(p);
            return;
        }
        var last = strokes[^1][^1];
        if (Math.Sqrt((p.X - last.X) * (p.X - last.X) + (p.Y - last.Y) * (p.Y - last.Y)) < 0.5)
        {
            return;
        }
        strokes[^1].Add(p);
    }

    // Adds a whole stroke, for example a stroke of a pen on an ink canvas.
    public void Add(IEnumerable<InkPoint> points)
    {
        var first = true;
        foreach (var p in points)
        {
            if (first)
            {
                Begin(p);
                first = false;
            }
            else
            {
                Extend(p);
            }
        }
    }

    public void Undo()
    {
        if (strokes.Count > 0)
        {
            strokes.RemoveAt(strokes.Count - 1);
        }
    }

    public void Clear() => strokes.Clear();

    // Returns the smoothed path of 1 stroke as a line through many points:
    // quadratic curves through the midpoints of the points, with the points
    // as controls. A single point stays 1 point, which becomes a dot.
    public static IReadOnlyList<InkPoint> Path(IReadOnlyList<InkPoint> stroke)
    {
        // Each curve becomes this many straight pieces.
        const int pieces = 8;
        if (stroke.Count <= 1)
        {
            return stroke.ToArray();
        }
        var path = new List<InkPoint> { stroke[0] };
        var from = stroke[0];
        for (var i = 1; i < stroke.Count; i++)
        {
            var control = stroke[i - 1];
            var b = stroke[i];
            var to = new InkPoint((control.X + b.X) / 2, (control.Y + b.Y) / 2);
            for (var k = 1; k <= pieces; k++)
            {
                var t = (double)k / pieces;
                var u = 1 - t;
                path.Add(new InkPoint(u * u * from.X + 2 * u * t * control.X + t * t * to.X, u * u * from.Y + 2 * u * t * control.Y + t * t * to.Y));
            }
            from = to;
        }
        path.Add(stroke[^1]);
        return path;
    }

    // Draws the strokes at scale pixels per canvas unit and cuts out the
    // ink. The ink color is the pen color, black. It returns null without
    // strokes.
    public SignatureInk? Ink(double canvasWidth, double canvasHeight, double scale = 2)
    {
        var w = Math.Max(1, (int)Math.Ceiling(canvasWidth * scale));
        var h = Math.Max(1, (int)Math.Ceiling(canvasHeight * scale));
        if (strokes.Count == 0 || (long)w * h > SignatureCut.MaxPixels)
        {
            return null;
        }
        var alpha = new byte[w * h];
        var radius = LineWidth * scale / 2;
        foreach (var stroke in strokes)
        {
            var path = Path(stroke);
            if (path.Count == 1)
            {
                Segment(alpha, w, h, Scaled(path[0], scale), Scaled(path[0], scale), radius);
            }
            for (var i = 1; i < path.Count; i++)
            {
                Segment(alpha, w, h, Scaled(path[i - 1], scale), Scaled(path[i], scale), radius);
            }
        }
        return SignatureCut.Ink(alpha, w, h, 0x000000);
    }

    static InkPoint Scaled(InkPoint p, double scale) => new(p.X * scale, p.Y * scale);

    // Draws 1 piece of a stroke with round ends: each pixel takes the part
    // of it that the line covers, from the distance of its center to the
    // piece. A pixel keeps the larger alpha where pieces overlap.
    static void Segment(byte[] alpha, int w, int h, InkPoint a, InkPoint b, double radius)
    {
        var reach = radius + 1;
        var x0 = Math.Max(0, (int)Math.Floor(Math.Min(a.X, b.X) - reach));
        var x1 = Math.Min(w - 1, (int)Math.Ceiling(Math.Max(a.X, b.X) + reach));
        var y0 = Math.Max(0, (int)Math.Floor(Math.Min(a.Y, b.Y) - reach));
        var y1 = Math.Min(h - 1, (int)Math.Ceiling(Math.Max(a.Y, b.Y) + reach));
        var dx = b.X - a.X;
        var dy = b.Y - a.Y;
        var length2 = dx * dx + dy * dy;
        for (var y = y0; y <= y1; y++)
        {
            for (var x = x0; x <= x1; x++)
            {
                var px = x + 0.5 - a.X;
                var py = y + 0.5 - a.Y;
                var t = length2 > 0 ? Math.Clamp((px * dx + py * dy) / length2, 0, 1) : 0;
                var ex = px - t * dx;
                var ey = py - t * dy;
                var cover = Math.Clamp(radius + 0.5 - Math.Sqrt(ex * ex + ey * ey), 0, 1);
                var value = (byte)Math.Round(cover * 255);
                var i = y * w + x;
                if (value > alpha[i])
                {
                    alpha[i] = value;
                }
            }
        }
    }
}
