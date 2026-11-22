using FluxKit;

namespace FluxKit.Tests;

// The texts about the link to a computer. Ported from LinkNoteTest.kt of the
// Android app, with the same vectors.
public class LinkNoteTests
{
    static string Time(DateTimeOffset _) => "14:02";
    static DateTimeOffset At(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms);
    const long Minute = 60_000;

    [Fact]
    public void AClosedLinkSaysThatTheComputerIsNotReachableAndWhenTheOutputIsFrom()
    {
        var n = LinkNote.ThreadNote(false, false, "omarchy-xps", At(5_000), At(9_000_000), Time)!;
        Assert.Equal(ThreadLink.Unreachable, n.State);
        Assert.Equal("omarchy-xps is not reachable.", n.Title);
        Assert.Equal("This output is from 14:02.", n.Detail);
    }

    [Fact]
    public void AClosedLinkWithNoKnownTimeHasNoSecondLine()
    {
        var n = LinkNote.ThreadNote(false, false, "omarchy-xps", null, At(9_000), Time)!;
        Assert.Equal("omarchy-xps is not reachable.", n.Title);
        Assert.Equal("", n.Detail);
    }

    [Fact]
    public void AComputerThatConnectsShowsTheConnectingLine()
    {
        var n = LinkNote.ThreadNote(false, true, "omarchy-xps", At(5_000), At(9_000), Time)!;
        Assert.Equal(ThreadLink.Connecting, n.State);
        Assert.Equal("Connecting to omarchy-xps", n.Title);
        Assert.Equal("", n.Detail);
    }

    [Fact]
    public void AnOpenLinkShowsTheTimeAndTheAgeOfTheOutput()
    {
        var n = LinkNote.ThreadNote(true, false, "omarchy-xps", At(1_000), At(1_000 + 30_000), Time)!;
        Assert.Equal(ThreadLink.Connected, n.State);
        Assert.Equal("Output from 14:02", n.Title);
        Assert.Equal("now", n.Detail);
        Assert.Equal("3m", LinkNote.ThreadNote(true, false, "omarchy-xps", At(1_000), At(1_000 + 3 * Minute), Time)!.Detail);
    }

    [Fact]
    public void AnOpenLinkWithNoOutputHasNoNote() =>
        Assert.Null(LinkNote.ThreadNote(true, false, "omarchy-xps", null, At(9_000), Time));

    [Fact]
    public void AnOpenLinkWinsOverTheConnectingFlag() =>
        Assert.Equal(ThreadLink.Connected, LinkNote.ThreadNote(true, true, "omarchy-xps", At(1_000), At(2_000), Time)!.State);

    [Fact]
    public void TheAgeGrowsInSteps()
    {
        static TimeSpan Ms(long ms) => TimeSpan.FromMilliseconds(ms);
        Assert.Equal("now", LinkNote.Age(Ms(59_999)));
        Assert.Equal("1m", LinkNote.Age(Ms(Minute)));
        Assert.Equal("59m", LinkNote.Age(Ms(59 * Minute)));
        Assert.Equal("1h", LinkNote.Age(Ms(60 * Minute)));
        Assert.Equal("23h", LinkNote.Age(Ms(23 * 60 * Minute)));
        Assert.Equal("2d", LinkNote.Age(Ms(48 * 60 * Minute)));
        // A clock that moves back gives now.
        Assert.Equal("now", LinkNote.Age(Ms(-5)));
    }

    [Fact]
    public void ARowOfAComputerThatIsNotReachableShowsSince()
    {
        Assert.Equal("Not reachable since 14:02", LinkNote.RowLine(false, At(5_000), Time));
        Assert.Equal("Not reachable", LinkNote.RowLine(false, null, Time));
        Assert.Null(LinkNote.RowLine(true, At(5_000), Time));
    }

    // AC90: the UI text names the Access card. Only the texts about
    // herdr_terminals may name a config key. The test reads the source of the app.
    [Fact]
    public void TheUiTextNamesTheAccessCardAndNotHerdrControl()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Flux", "Flux.csproj")))
        {
            dir = dir.Parent;
        }
        Assert.NotNull(dir);
        var files = Directory.EnumerateFiles(Path.Combine(dir.FullName, "Flux"), "*.cs", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") &&
                        !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")).ToArray();
        Assert.NotEmpty(files);
        var hits = files.SelectMany(f => File.ReadLines(f).Where(l => l.Contains("\"") && l.Contains("herdr_control"))).ToArray();
        Assert.All(hits, l => Assert.Contains("herdr_terminals", l));
        Assert.Contains(files, f => File.ReadAllText(f).Contains("Agent control in Flux on"));
    }
}
