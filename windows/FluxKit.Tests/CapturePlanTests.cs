using FluxKit;

namespace FluxKit.Tests;

// CapturePlanTests.swift of the Mac app, with the screenshot rules of Windows.
public class CapturePlanTests
{
    const long Now = 1_800_000_000;

    static CaptureItem Shot(long id, bool pending = false, long? added = null) =>
        new(id, CaptureKind.Screenshot, $"Screenshot ({id}).png", pending, added ?? Now);

    static CaptureItem Photo(long id, bool pending = false, long? added = null) =>
        new(id, CaptureKind.Photo, $"IMG_{id}.jpg", pending, added ?? Now);

    static CaptureItem Other(long id) => new(id, null, $"notes-{id}.txt", false, Now);

    static long[] Ids(CapturePlan plan) => plan.Send.Select(s => s.Item.Id).ToArray();

    [Fact]
    public void ScreenshotRules()
    {
        Assert.True(CaptureRules.IsScreenshot("Screenshot (12).png"));
        Assert.True(CaptureRules.IsScreenshot("Screenshot 2026-10-15 101500.png"));
        Assert.True(CaptureRules.IsScreenshot("Capture d’écran (3).PNG"));
        Assert.True(CaptureRules.IsScreenshot("snip.jpg"));
        Assert.False(CaptureRules.IsScreenshot("Screen Recording 2026-10-15 101500.mp4"), "a recording is not an image");
        Assert.False(CaptureRules.IsScreenshot("desktop.ini"));
        Assert.False(CaptureRules.IsScreenshot("png"));
    }

    [Fact]
    public void OnlyImagesAfterTheSwitchGoOut()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        var plan = CapturePlanner.Plan(state, [Photo(9), Photo(11)], Now);
        Assert.Equal([11], Ids(plan));
        Assert.Equal(CaptureKind.Photo, plan.Send[0].Kind);
    }

    [Fact]
    public void AKindThatIsOffDoesNotGoOut()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        var plan = CapturePlanner.Plan(state, [Shot(11), Other(12)], Now);
        Assert.Empty(plan.Send);
        Assert.Equal(12, plan.State.Baseline);
    }

    [Fact]
    public void ASentImageDoesNotGoOutAgain()
    {
        var state = new CaptureState().Enable(CaptureKind.Screenshot, 10);
        CaptureItem[] items = [Shot(11)];
        var first = CapturePlanner.Plan(state, items, Now);
        Assert.Single(first.Send);
        // The image did not go out yet, so the baseline stays before it.
        Assert.Equal(10, first.State.Baseline);
        state = first.State.MarkSent(11);
        var second = CapturePlanner.Plan(state, items, Now);
        Assert.Empty(second.Send);
        Assert.Equal(11, second.State.Baseline);
        Assert.Empty(second.State.Sent);
    }

    [Fact]
    public void AnUnsentImageIsTriedAgain()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        CaptureItem[] items = [Photo(11), Photo(12)];
        var first = CapturePlanner.Plan(state, items, Now);
        // No computer took 11. Only 12 went out.
        var second = CapturePlanner.Plan(first.State.MarkSent(12), items, Now);
        Assert.Equal([11], Ids(second));
        Assert.Equal(10, second.State.Baseline);
    }

    [Fact]
    public void APendingImageWaits()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        var pending = CapturePlanner.Plan(state, [Photo(11, pending: true), Other(12)], Now);
        Assert.Empty(pending.Send);
        Assert.Equal(10, pending.State.Baseline);
        var done = CapturePlanner.Plan(pending.State, [Photo(11), Other(12)], Now);
        Assert.Equal([11], Ids(done));
    }

    [Fact]
    public void AnOldPendingImageDoesNotBlock()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        var old = Now - CaptureRules.PendingLimit - 1;
        var plan = CapturePlanner.Plan(state, [Photo(11, pending: true, added: old), Other(12)], Now);
        Assert.Equal(12, plan.State.Baseline);
    }

    [Fact]
    public void ASecondSwitchStartsAtItsOwnTime()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10).Enable(CaptureKind.Screenshot, 20);
        var plan = CapturePlanner.Plan(state, [Shot(15), Shot(21)], Now);
        Assert.Equal([21], Ids(plan));
    }

    [Fact]
    public void TurningAllOffAndOnSkipsTheGap()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10).Disable(CaptureKind.Photo).Enable(CaptureKind.Photo, 50);
        Assert.Equal(50, state.Baseline);
        var plan = CapturePlanner.Plan(state, [Photo(30), Photo(51)], Now);
        Assert.Equal([51], Ids(plan));
    }

    [Fact]
    public void TheSentSetKeepsTheNewestIds()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        // Item 11 waits, so every sent ID stays after the baseline.
        for (var id = 12L; id <= 12 + CapturePlanner.MaxSent; id++)
        {
            state = state.MarkSent(id);
        }
        var plan = CapturePlanner.Plan(state, [Photo(11, pending: true)], Now);
        Assert.Equal(CapturePlanner.MaxSent, plan.State.Sent.Count);
        Assert.DoesNotContain(12L, plan.State.Sent);
        Assert.Contains(12L + CapturePlanner.MaxSent, plan.State.Sent);
    }

    // 1 scan sends at most 50 images, the oldest first. The rest wait for the
    // next scan.
    [Fact]
    public void AScanSendsAtMost50Images()
    {
        var state = new CaptureState().Enable(CaptureKind.Photo, 10);
        var items = Enumerable.Range(11, 60).Select(i => Photo(i)).ToArray();
        var first = CapturePlanner.Plan(state, items, Now);
        Assert.Equal(Enumerable.Range(11, 50).Select(i => (long)i), Ids(first));
        Assert.Equal(10, first.Waiting);
        Assert.Equal(10, first.State.Baseline);
        state = first.Send.Aggregate(first.State, (s, x) => s.MarkSent(x.Item.Id));
        var second = CapturePlanner.Plan(state, items, Now);
        Assert.Equal(Enumerable.Range(61, 10).Select(i => (long)i), Ids(second));
        Assert.Equal(0, second.Waiting);
        Assert.Equal(60, second.State.Baseline);
    }

    [Fact]
    public void StateSurvivesARestart()
    {
        var state = new CaptureState().Enable(CaptureKind.Screenshot, 10).Enable(CaptureKind.Photo, 20).MarkSent(11);
        var json = System.Text.Json.Nodes.JsonNode.Parse(state.ToJson().ToJsonString());
        Assert.Equal(state, CaptureState.FromJson(json));
        Assert.Equal(new CaptureState(), CaptureState.FromJson(null));
        Assert.Equal(new CaptureState(), CaptureState.FromJson(System.Text.Json.Nodes.JsonNode.Parse("[1]")));
    }
}
