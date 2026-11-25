using FluxKit;

namespace FluxKit.Tests;

// The text rules of dictation, ported from DictationTests.swift. The tests
// of the Apple recognizer errors and of the language catalog stay with the
// Mac app, because the WPF app uses the speech recognizer of Windows.
public class HerdrDictationTests
{
    [Fact]
    public void InsertsIntoAnEmptyField()
    {
        Assert.Equal(new DictationEdit("Run the tests", 13), DictationText.Insert("", 0, 0, " run the tests "));
    }

    [Fact]
    public void AddsASpaceAfterAWord()
    {
        Assert.Equal(new DictationEdit("Fix the bug in parser.go", 24), DictationText.Insert("Fix the bug", 11, 11, "in parser.go"));
        // A space after the text stays one space.
        Assert.Equal(new DictationEdit("Fix it now", 10), DictationText.Insert("Fix it ", 7, 7, "now"));
    }

    [Fact]
    public void CapitalizesANewSentence()
    {
        Assert.Equal(new DictationEdit("Done. Now run it", 16), DictationText.Insert("Done.", 5, 5, "now run it"));
        Assert.Equal(new DictationEdit("Why? Check the log", 18), DictationText.Insert("Why? ", 5, 5, "check the log"));
        Assert.Equal(new DictationEdit("First line\nSecond line", 22), DictationText.Insert("First line\n", 11, 11, "second line"));
        // Inside a sentence the case stays.
        Assert.Equal(new DictationEdit("Use the go test", 15), DictationText.Insert("Use the", 7, 7, "go test"));
    }

    [Fact]
    public void MakesASearchFromADictation()
    {
        Assert.Equal("Workspace", DictationText.Query(" Workspace. "));
        Assert.Equal("Open the browser", DictationText.Query("Open the browser?!"));
        // A period inside the words stays.
        Assert.Equal("node.js", DictationText.Query("node.js"));
        Assert.Equal("", DictationText.Query(" . "));
    }

    [Fact]
    public void MakesACommandFromADictation()
    {
        Assert.Equal("git status", DictationText.Command("Git status."));
        // A word in capitals stays.
        Assert.Equal("README first", DictationText.Command("README first"));
        // I stays.
        Assert.Equal("I", DictationText.Command("I"));
        Assert.Equal("ls -la", DictationText.Command("ls -la"));
    }

    [Fact]
    public void KeepsTheCaseOfACommand()
    {
        Assert.Equal(new DictationEdit("git status", 10), DictationText.Insert("", 0, 0, "git status", sentences: false));
        Assert.Equal(new DictationEdit("cd ~/Code && git status", 23), DictationText.Insert("cd ~/Code &&", 12, 12, "git status", sentences: false));
    }

    [Fact]
    public void InsertsAtTheCursor()
    {
        // "Run tests" with the cursor after "Run".
        Assert.Equal(new DictationEdit("Run the unit tests", 12), DictationText.Insert("Run tests", 3, 3, "the unit"));
    }

    [Fact]
    public void ReplacesTheSelection()
    {
        Assert.Equal(new DictationEdit("Run the lint check", 18), DictationText.Insert("Run the tests", 8, 13, "lint check"));
        // A reversed selection works.
        Assert.Equal(new DictationEdit("Run the lint check", 18), DictationText.Insert("Run the tests", 13, 8, "lint check"));
    }

    [Fact]
    public void KeepsPunctuationAgainstTheWord()
    {
        Assert.Equal(new DictationEdit("Stop here, then wait", 9), DictationText.Insert("Stop, then wait", 4, 4, "here"));
        Assert.Equal(new DictationEdit("Yes, please", 11), DictationText.Insert("Yes", 3, 3, ", please"));
    }

    [Fact]
    public void IgnoresEmptySpeechAndBadPositions()
    {
        Assert.Equal(new DictationEdit("keep", 4), DictationText.Insert("keep", 4, 4, "   "));
        Assert.Equal(new DictationEdit("keep it", 7), DictationText.Insert("keep", 40, 50, "it"));
    }

    [Fact]
    public void CountsTheCursorInUtf16()
    {
        // An emoji takes 2 UTF-16 units, as in the selection of a text box.
        Assert.Equal(new DictationEdit("Ship it 🚀 now", 14), DictationText.Insert("Ship it 🚀", 10, 10, "now"));
    }

    [Fact]
    public void JoinsSessions()
    {
        Assert.Equal("one two", DictationText.Join("one ", " two"));
        Assert.Equal("two", DictationText.Join("", "two"));
        Assert.Equal("one", DictationText.Join("one", "  "));
    }

    [Fact]
    public void MapsLevels()
    {
        Assert.Equal(0, DictationText.Level(-50));
        Assert.Equal(0, DictationText.Level(-90));
        Assert.Equal(1, DictationText.Level(-12));
        Assert.Equal(1, DictationText.Level(0));
        Assert.Equal(0, DictationText.Level(float.NaN));
        // Quiet speech shows.
        Assert.True(DictationText.Level(-40) > 0.45);
    }

    [Fact]
    public void FormatsTheClock()
    {
        Assert.Equal("0:00", DictationText.Clock(0));
        Assert.Equal("0:07", DictationText.Clock(7.9));
        Assert.Equal("12:30", DictationText.Clock(750));
        Assert.Equal("0:00", DictationText.Clock(-5));
    }

    [Fact]
    public void MergesNewWords()
    {
        Assert.Equal("Run the tests and fix lint", DictationText.Merge("Run the tests", "and fix lint"));
        Assert.Equal("fix lint", DictationText.Merge("", " fix lint "));
        Assert.Equal("Run the tests", DictationText.Merge("Run the tests", "  "));
    }

    [Fact]
    public void MergesTheWholeTextAgain()
    {
        // A recognizer can send the whole text with each final text, with new case and punctuation.
        Assert.Equal("Run the tests, then fix lint.", DictationText.Merge("run the tests", "Run the tests, then fix lint."));
        Assert.Equal("Run the tests.", DictationText.Merge("Run the tests.", "Run the tests."));
    }

    [Fact]
    public void DropsARepeatedText()
    {
        Assert.Equal("Please check it. Fix it now", DictationText.Merge("Please check it. Fix it now", "fix it now."));
        // A repeated single word can be real speech.
        Assert.Equal("Say yes yes", DictationText.Merge("Say yes", "yes"));
    }

    [Fact]
    public void FindsTheUnsettledWords()
    {
        Assert.Equal("and fix", DictationText.Unsettled("Run the tests.", "run the tests and fix"));
        Assert.Equal("and fix", DictationText.Unsettled("Run the tests.", "and fix"));
        Assert.Equal("hello", DictationText.Unsettled("", " hello "));
        Assert.Equal("", DictationText.Unsettled("Run the tests.", "run the tests"));
    }

    [Fact]
    public void FindsARestartedText()
    {
        // New words after a pause.
        Assert.True(DictationText.Restarted("Run the tests", "And"));
        Assert.False(DictationText.Restarted("Run the tests", "Run the tests and"));
        // A revision keeps the length.
        Assert.False(DictationText.Restarted("Ron the tests", "Run the tests"));
        // A revision keeps the first word.
        Assert.False(DictationText.Restarted("Run the", "Run"));
        // 1 word is too short to tell.
        Assert.False(DictationText.Restarted("Run", "And"));
        Assert.False(DictationText.Restarted("", "Run"));
    }

    [Fact]
    public void SplitsWords()
    {
        Assert.Equal(["one", "two", "three"], DictationText.Words("  one two\n three "));
        Assert.Empty(DictationText.Words("   "));
    }

    [Fact]
    public void CleansTheLanguages()
    {
        Assert.Equal(["nb-NO", "en-GB", "en-US"], DictationText.Languages(["nb-NO", " en_GB", "", "und", "en-US", "en-GB"]));
        Assert.Empty(DictationText.Languages(["und"]));
    }

    [Fact]
    public void NamesLanguages()
    {
        Assert.Equal("English (United Kingdom)", DictationText.LanguageName("en-GB"));
        Assert.Equal("English", DictationText.LanguageName("en"));
        // An undefined tag keeps its text.
        Assert.Equal("und", DictationText.LanguageName("und"));
        var none = DictationText.Unsupported(["en-GB", "de-DE"]);
        Assert.Contains("English (United Kingdom), German (Germany)", none);
        Assert.Contains("this computer", none);
        Assert.Contains("German (Germany)", DictationText.NotSupported("de-DE"));
    }
}
