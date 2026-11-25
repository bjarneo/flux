using FluxKit;

namespace FluxKit.Tests;

// Ported from HerdrViewReadTests.swift: the agent screen takes only the
// answer to its newest read.
public class HerdrViewReadTests
{
    [Fact]
    public void ResponseMustMatchRequestModeAndPath()
    {
        var read = new HerdrViewRead(3, "diff", "new.swift");
        Assert.True(read.Accepts(3, "diff", "new.swift", true));
        Assert.False(read.Accepts(2, "diff", "new.swift", true));
        Assert.False(read.Accepts(3, "ansi", "new.swift", true));
        Assert.False(read.Accepts(3, "diff", "old.swift", true));
        Assert.False(read.Accepts(null, "diff", "new.swift", true));
    }

    [Fact]
    public void AnAnswerWithoutANumberCountsOnlyWithoutReview()
    {
        var read = new HerdrViewRead(3, "ansi", "");
        // An older fluxd sends no number and knows no review.
        Assert.True(read.Accepts(null, "ansi", "", false));
        Assert.False(read.Accepts(null, "ansi", "", true));
    }
}
