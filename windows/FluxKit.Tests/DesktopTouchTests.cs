using FluxKit;

namespace FluxKit.Tests;

// DesktopTouchTests.swift of the Mac app.
public class DesktopTouchTests
{
    // A 400 × 300 view with a 1280 × 720 video: 400 × 225 at the top 37.5.
    static readonly DesktopViewport Fit = new(new RemoteSize(400, 300), new RemoteSize(1280, 720));

    static DesktopPoint Point(double x, double y) => new(x, y);

    static RemotePoint P(double x, double y) => new(x, y);

    static Dictionary<int, RemotePoint> Fingers(params (int Id, RemotePoint At)[] points) => points.ToDictionary(p => p.Id, p => p.At);

    static void AssertPoint(DesktopPoint? p, double x, double y)
    {
        Assert.NotNull(p);
        Assert.Equal(x, p.Value.X, 9);
        Assert.Equal(y, p.Value.Y, 9);
    }

    // Viewport

    [Fact]
    public void ViewportFitsTheVideo()
    {
        Assert.Equal(new RemoteRect(0, 37.5, 400, 225), Fit.FitRect);
        Assert.Equal(0.3125, Fit.Pixel);
        Assert.Equal(Fit.FitRect, Fit.VideoFrame);
        AssertPoint(Fit.ToVideo(P(200, 150)), 0.5, 0.5);
        AssertPoint(Fit.ToVideo(P(0, 37.5)), 0, 0);
        // The bar over the video.
        Assert.Null(Fit.ToVideo(P(200, 10)));
        AssertPoint(Fit.ToVideo(P(200, 10), clamp: true), 0.5, 0);
    }

    [Fact]
    public void ZoomKeepsTheFocusAndStaysOnTheView()
    {
        var z = Fit.Zoom(2, P(200, 150));
        Assert.Equal(2, z.Scale);
        Assert.Equal(P(-200, -150), z.Offset);
        AssertPoint(z.ToVideo(P(200, 150)), 0.5, 0.5);
        Assert.Equal(0.625, z.Pixel);
        Assert.Equal(new RemoteRect(-200, -75, 800, 450), z.VideoFrame);
        // The left edge of the video stays at the left edge of the view.
        Assert.Equal(0, z.Pan(1000, 0).Offset.X);
        Assert.Equal(-400, z.Pan(-1000, 0).Offset.X);
        Assert.Equal(-75, z.Pan(0, 1000).Offset.Y);
        Assert.Equal(-225, z.Pan(0, -1000).Offset.Y);
        Assert.Equal(DesktopViewport.MaxScale, Fit.Zoom(100, RemotePoint.Zero).Scale);
        var back = z.Zoom(0.1, P(10, 10));
        Assert.Equal(1, back.Scale);
        // At scale 1 the video is in the center.
        Assert.Equal(RemotePoint.Zero, back.Offset);
        // A fitted video does not move.
        Assert.Equal(RemotePoint.Zero, Fit.Pan(50, 50).Offset);
    }

    [Fact]
    public void ResizeOfOneSideKeepsTheZoom()
    {
        var z = Fit.Zoom(3, RemotePoint.Zero);
        // The same sizes keep the zoom.
        Assert.Equal(z, z.Resized(Fit.View, Fit.Video));
        // A panel at the side takes 100 points of the width.
        var r = z.Resized(new RemoteSize(300, 300), Fit.Video);
        // The video keeps its size on the screen.
        Assert.Equal(z.Pixel, r.Pixel, 9);
        Assert.Equal(4, r.Scale, 9);
        // The point at the center keeps its place where the video allows it.
        Assert.Equal(1.0 / 6, r.ToVideo(P(150, 150))?.X ?? -1, 9);
        // No view yet.
        Assert.Null(new DesktopViewport(RemoteSize.Zero, Fit.Video).ToVideo(RemotePoint.Zero));
    }

    [Fact]
    public void RotationStartsAtScaleOne()
    {
        var z = Fit.Zoom(3, P(200, 150));
        var r = z.Resized(new RemoteSize(300, 400), Fit.Video, Point(0.5, 0.5));
        // Both sides change, so the video fits the view again.
        Assert.Equal(new DesktopViewport(new RemoteSize(300, 400), Fit.Video), r);
        Assert.Equal(1, r.Scale);
    }

    [Fact]
    public void NewVideoOrFirstViewStartsAtScaleOne()
    {
        var z = Fit.Zoom(3, RemotePoint.Zero);
        var video = z.Resized(Fit.View, new RemoteSize(1920, 1080));
        Assert.Equal(1, video.Scale);
        Assert.Equal(RemotePoint.Zero, video.Offset);
        var first = new DesktopViewport(RemoteSize.Zero, Fit.Video).Resized(Fit.View, Fit.Video);
        Assert.Equal(Fit, first);
        var gone = z.Resized(RemoteSize.Zero, Fit.Video);
        Assert.Equal(1, gone.Scale);
    }

    [Fact]
    public void KeyboardKeepsTheTappedPointInView()
    {
        // The keyboard takes the bottom half of the view.
        var shortView = new RemoteSize(400, 150);
        var center = Fit.Resized(shortView, Fit.Video);
        // The video keeps its width, so the text keeps its size.
        Assert.Equal(1.5, center.Scale, 9);
        Assert.Equal(Fit.Pixel, center.Pixel, 9);
        AssertPoint(center.ToVideo(P(200, 75)), 0.5, 0.5);

        var field = Point(0.5, 0.9);
        var r = Fit.Resized(shortView, Fit.Video, field);
        var y = r.VideoFrame.MinY + field.Y * r.VideoFrame.Height;
        // A field near the bottom stays in view, in the lower part of the view.
        Assert.InRange(y, 0, shortView.Height);
        Assert.True(y > 75);

        // The keyboard hides: the view comes back to the first fit.
        var back = r.Resized(Fit.View, Fit.Video, field);
        Assert.Equal(1, back.Scale, 9);
        Assert.Equal(Fit.FitRect.MinX, back.VideoFrame.MinX, 9);
        Assert.Equal(Fit.FitRect.MinY, back.VideoFrame.MinY, 9);
    }

    [Fact]
    public void ResizeKeepsTheScaleInItsLimits()
    {
        var z = Fit.Zoom(6, P(200, 150));
        // A smaller view cannot zoom past the limit.
        Assert.Equal(DesktopViewport.MaxScale, z.Resized(new RemoteSize(100, 300), Fit.Video).Scale);
        // A wider view fits the video.
        Assert.Equal(1, Fit.Resized(new RemoteSize(800, 300), Fit.Video).Scale);
    }

    // Taps

    static IReadOnlyList<DesktopTouchAction> Run(DesktopTouches t, Dictionary<int, RemotePoint> points, double at, DesktopViewport? v = null) =>
        t.Touches(points, at, v ?? Fit);

    static DesktopTouchAction Click(RemoteClick c, DesktopPoint at) => new DesktopTouchAction.Click(c, at);

    [Fact]
    public void TapClicksAtTheFinger()
    {
        var t = new DesktopTouches();
        Assert.Empty(Run(t, Fingers((1, P(100, 150))), 0));
        // A small motion is still a tap.
        Assert.Empty(Run(t, Fingers((1, P(103, 150))), 0.05));
        Assert.Equal([Click(RemoteClick.Left, Point(0.25, 0.5))], Run(t, Fingers(), 0.1));
    }

    [Fact]
    public void SecondTapNearTheFirstReusesItsPosition()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        Run(t, Fingers(), 0.05);
        Run(t, Fingers((2, P(110, 160))), 0.2);
        // The computer sees a double click.
        Assert.Equal([Click(RemoteClick.Left, Point(0.25, 0.5))], Run(t, Fingers(), 0.3));
        Run(t, Fingers((3, P(200, 150))), 0.4);
        // A tap far away clicks at its own finger.
        Assert.Equal([Click(RemoteClick.Left, Point(0.5, 0.5))], Run(t, Fingers(), 0.45));
        Run(t, Fingers((4, P(200, 150))), 1.0);
        Assert.Equal([Click(RemoteClick.Left, Point(0.5, 0.5))], Run(t, Fingers(), 1.0));
        Run(t, Fingers((5, P(210, 150))), 1.5);
        // A late tap clicks at its own finger.
        Assert.Equal([Click(RemoteClick.Left, Point(0.525, 0.5))], Run(t, Fingers(), 1.5));
    }

    [Fact]
    public void TapOnTheBarsDoesNothing()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 10))), 0);
        Assert.Empty(Run(t, Fingers(), 0.1));
    }

    // Hold

    [Fact]
    public void HoldClicksTheRightButton()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        Assert.Equal(0.45, t.HoldDeadline);
        Assert.Empty(t.HoldIfDue(0.3, Fit));
        // The pointer goes under the finger.
        Assert.Equal([new DesktopTouchAction.Held(), new DesktopTouchAction.Move(Point(0.25, 0.5))], t.HoldIfDue(0.45, Fit));
        Assert.Null(t.HoldDeadline);
        Assert.Empty(Run(t, Fingers((1, P(102, 150))), 0.5));
        Assert.Equal([Click(RemoteClick.Right, Point(0.25, 0.5))], Run(t, Fingers(), 0.6));
    }

    [Fact]
    public void HoldAndMoveDrags()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        t.HoldIfDue(0.5, Fit);
        Assert.Equal([new DesktopTouchAction.Hold(true, Point(0.25, 0.5)), new DesktopTouchAction.Move(Point(0.3, 0.5))],
            Run(t, Fingers((1, P(120, 150))), 0.6));
        // No motion sends nothing.
        Assert.Empty(Run(t, Fingers((1, P(120, 150))), 0.65));
        // A drag past the edge stays on the edge.
        Assert.Equal([new DesktopTouchAction.Move(Point(1, 0.5))], Run(t, Fingers((1, P(500, 150))), 0.7));
        Assert.Equal([new DesktopTouchAction.Hold(false, Point(1, 0.5))], Run(t, Fingers(), 0.8));
    }

    [Fact]
    public void LateEventHoldsFirst()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        Assert.Equal([new DesktopTouchAction.Held(), new DesktopTouchAction.Move(Point(0.25, 0.5))], Run(t, Fingers((1, P(100, 150))), 0.5));
    }

    [Fact]
    public void CancelReleasesOnlyADrag()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        // A canceled tap does not click.
        Assert.Empty(t.Cancel(Fit));
        Run(t, Fingers((1, P(100, 150))), 1);
        t.HoldIfDue(1.5, Fit);
        Run(t, Fingers((1, P(120, 150))), 1.6);
        Assert.Equal([new DesktopTouchAction.Hold(false, Point(0.3, 0.5))], t.Cancel(Fit));
    }

    // Pan and zoom

    [Fact]
    public void OneFingerMovesTheZoomedView()
    {
        var zoomed = Fit.Zoom(2, P(200, 150));
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0, zoomed);
        Assert.Empty(Run(t, Fingers((1, P(104, 150))), 0.05, zoomed));
        // The pan starts at the first position.
        Assert.Equal([new DesktopTouchAction.Viewport(zoomed.Pan(10, 0))], Run(t, Fingers((1, P(110, 150))), 0.1, zoomed));
        var moved = zoomed.Pan(10, 0);
        Assert.Equal([new DesktopTouchAction.Viewport(moved.Pan(10, -5))], Run(t, Fingers((1, P(120, 145))), 0.15, moved));
        // A pan does not hold, and it does not click.
        Assert.Null(t.HoldDeadline);
        Assert.Empty(Run(t, Fingers(), 0.2, moved));
    }

    [Fact]
    public void TwoFingerTapClicksTheRightButtonAtTheCenter()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150))), 0);
        Assert.Empty(Run(t, Fingers((1, P(100, 150)), (2, P(300, 150))), 0.02));
        Assert.Null(t.HoldDeadline);
        Assert.Empty(Run(t, Fingers((2, P(300, 150))), 0.1));
        Assert.Equal([Click(RemoteClick.Right, Point(0.5, 0.5))], Run(t, Fingers(), 0.12));
    }

    [Fact]
    public void TwoFingersScrollAtTheirCenter()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150)), (2, P(200, 150))), 0);
        // Under the slop.
        Assert.Empty(Run(t, Fingers((1, P(100, 145)), (2, P(200, 145))), 0.02));
        // The pointer goes to the window under the fingers, and the content follows them.
        Assert.Equal([new DesktopTouchAction.Move(Point(0.375, 0.5)), new DesktopTouchAction.Scroll(0, 5 / 0.3125)],
            Run(t, Fingers((1, P(100, 140)), (2, P(200, 140))), 0.04));
        Assert.Equal([new DesktopTouchAction.Scroll(10 / 0.3125, 0)], Run(t, Fingers((1, P(90, 140)), (2, P(190, 140))), 0.06));
        // 1 finger after a scroll does nothing.
        Assert.Empty(Run(t, Fingers((1, P(90, 140))), 0.08));
        Assert.Empty(Run(t, Fingers(), 0.1));
    }

    [Fact]
    public void FingerThatLandsMovesNoScroll()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150)), (2, P(200, 150))), 0);
        Run(t, Fingers((1, P(100, 130)), (2, P(200, 130))), 0.02);
        // The center jumps, and the next motion starts from there.
        Assert.Empty(Run(t, Fingers((1, P(100, 130)), (2, P(200, 130)), (3, P(300, 10))), 0.04));
        Assert.Equal([new DesktopTouchAction.Scroll(0, 3 / 0.3125)], Run(t, Fingers((1, P(100, 127)), (2, P(200, 127)), (3, P(300, 7))), 0.06));
    }

    [Fact]
    public void PinchZoomsTheView()
    {
        var t = new DesktopTouches();
        Run(t, Fingers((1, P(100, 150)), (2, P(200, 150))), 0);
        Assert.Equal([new DesktopTouchAction.Viewport(Fit.Zoom(70.0 / 50.0, P(150, 150)))], Run(t, Fingers((1, P(80, 150)), (2, P(220, 150))), 0.02));
        var z = Fit.Zoom(70.0 / 50.0, P(150, 150));
        // The pinch moves the view with the fingers.
        Assert.Equal([new DesktopTouchAction.Viewport(z.Zoom(1, P(150, 150), P(10, 10)))], Run(t, Fingers((1, P(90, 160)), (2, P(230, 160))), 0.04, z));
        // A pinch does not click.
        Assert.Empty(Run(t, Fingers(), 0.1, z));
    }

    [Fact]
    public void ActionsBecomePackets()
    {
        Assert.Equal(0.25, new DesktopTouchAction.Click(RemoteClick.Left, Point(0.25, 0.5)).ToPacket()!.Double("x"));
        Assert.True(new DesktopTouchAction.Hold(true, Point(0, 0)).ToPacket()!.Bool("singlehold"));
        Assert.True(new DesktopTouchAction.Scroll(0, 2).ToPacket()!.Bool("scroll"));
        Assert.Equal(0.5, new DesktopTouchAction.Move(Point(0.5, 0.1)).ToPacket()!.Double("x"));
        Assert.Null(new DesktopTouchAction.Held().ToPacket());
        Assert.Null(new DesktopTouchAction.Viewport(Fit).ToPacket());
    }
}
