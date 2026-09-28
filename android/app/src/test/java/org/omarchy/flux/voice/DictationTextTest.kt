package org.omarchy.flux.voice

import android.speech.SpeechRecognizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationTextTest {
    @Test
    fun insertsIntoAnEmptyField() {
        assertEquals(Edit("Run the tests", 13), DictationText.insert("", 0, 0, " run the tests "))
    }

    @Test
    fun addsASpaceAfterAWord() {
        assertEquals(Edit("Fix the bug in parser.go", 24), DictationText.insert("Fix the bug", 11, 11, "in parser.go"))
        assertEquals("a space after the text stays one space", Edit("Fix it now", 10), DictationText.insert("Fix it ", 7, 7, "now"))
    }

    @Test
    fun capitalizesANewSentence() {
        assertEquals(Edit("Done. Now run it", 16), DictationText.insert("Done.", 5, 5, "now run it"))
        assertEquals(Edit("Why? Check the log", 18), DictationText.insert("Why? ", 5, 5, "check the log"))
        assertEquals(Edit("First line\nSecond line", 22), DictationText.insert("First line\n", 11, 11, "second line"))
        assertEquals("inside a sentence the case stays", Edit("Use the go test", 15), DictationText.insert("Use the", 7, 7, "go test"))
    }

    @Test
    fun insertsAtTheCursor() {
        // "Run tests" with the cursor after "Run".
        assertEquals(Edit("Run the unit tests", 12), DictationText.insert("Run tests", 3, 3, "the unit"))
    }

    @Test
    fun replacesTheSelection() {
        assertEquals(Edit("Run the lint check", 18), DictationText.insert("Run the tests", 8, 13, "lint check"))
        assertEquals("a reversed selection works", Edit("Run the lint check", 18), DictationText.insert("Run the tests", 13, 8, "lint check"))
    }

    @Test
    fun keepsPunctuationAgainstTheWord() {
        assertEquals(Edit("Stop here, then wait", 9), DictationText.insert("Stop, then wait", 4, 4, "here"))
        assertEquals(Edit("Yes, please", 11), DictationText.insert("Yes", 3, 3, ", please"))
    }

    @Test
    fun ignoresEmptySpeechAndBadPositions() {
        assertEquals(Edit("keep", 4), DictationText.insert("keep", 4, 4, "   "))
        assertEquals(Edit("keep it", 7), DictationText.insert("keep", 40, 50, "it"))
    }

    @Test
    fun joinsSessions() {
        assertEquals("one two", DictationText.join("one ", " two"))
        assertEquals("two", DictationText.join("", "two"))
        assertEquals("one", DictationText.join("one", "  "))
    }

    @Test
    fun mapsLevels() {
        assertEquals(0f, DictationText.level(-2f), 0f)
        assertEquals(0f, DictationText.level(-10f), 0f)
        assertEquals(1f, DictationText.level(10f), 0f)
        assertEquals(1f, DictationText.level(40f), 0f)
        assertEquals(0f, DictationText.level(Float.NaN), 0f)
        assertTrue("quiet speech shows", DictationText.level(1f) > 0.45f)
    }

    @Test
    fun formatsTheClock() {
        assertEquals("0:00", DictationText.clock(0))
        assertEquals("0:07", DictationText.clock(7_900))
        assertEquals("12:30", DictationText.clock(750_000))
        assertEquals("0:00", DictationText.clock(-5))
    }

    @Test
    fun mergesNewWords() {
        assertEquals("Run the tests and fix lint", DictationText.merge("Run the tests", "and fix lint"))
        assertEquals("fix lint", DictationText.merge("", " fix lint "))
        assertEquals("Run the tests", DictationText.merge("Run the tests", "  "))
    }

    @Test
    fun mergesTheWholeTextAgain() {
        // Some recognizers send the whole text with each final text, with new case and punctuation.
        assertEquals("Run the tests, then fix lint.", DictationText.merge("run the tests", "Run the tests, then fix lint."))
        assertEquals("Run the tests.", DictationText.merge("Run the tests.", "Run the tests."))
    }

    @Test
    fun dropsARepeatedText() {
        assertEquals("Please check it. Fix it now", DictationText.merge("Please check it. Fix it now", "fix it now."))
        assertEquals("a repeated single word can be real speech", "Say yes yes", DictationText.merge("Say yes", "yes"))
    }

    @Test
    fun findsTheUnsettledWords() {
        assertEquals("and fix", DictationText.unsettled("Run the tests.", "run the tests and fix"))
        assertEquals("and fix", DictationText.unsettled("Run the tests.", "and fix"))
        assertEquals("hello", DictationText.unsettled("", " hello "))
        assertEquals("", DictationText.unsettled("Run the tests.", "run the tests"))
    }

    @Test
    fun findsARestartedPartialText() {
        // After a pause, the recognizer drops the words before it and hears only the new words.
        assertTrue(DictationText.restarts("Run the tests on the phone first", "then"))
        assertTrue("the same first word", DictationText.restarts("Run the tests on the phone first", "run it"))
        assertTrue("a new first word", DictationText.restarts("Okay so", "then"))
    }

    @Test
    fun keepsAChangedPartialText() {
        assertFalse("more words", DictationText.restarts("Run the", "Run the tests"))
        assertFalse("a changed last word", DictationText.restarts("Run the test", "Run the tests"))
        assertFalse("changed words", DictationText.restarts("I scream", "ice cream"))
        assertFalse("a number in digits", DictationText.restarts("It costs twenty five", "It costs 25"))
        assertFalse("no partial text before", DictationText.restarts("", "Run"))
        assertFalse("an empty partial text", DictationText.restarts("Run the tests", "  "))
    }

    @Test
    fun splitsWords() {
        assertEquals(listOf("one", "two", "three"), DictationText.words("  one two\n three "))
        assertEquals(emptyList<String>(), DictationText.words("   "))
    }

    @Test
    fun cleansThePhoneLanguages() {
        assertEquals(listOf("nb-NO", "en-GB", "en-US"), DictationText.languages(listOf("nb-NO", " en-GB", "", "und", "en-US", "en-GB")))
        assertEquals(emptyList<String>(), DictationText.languages(listOf("und")))
    }

    @Test
    fun namesLanguages() {
        assertEquals("English (United Kingdom)", DictationText.languageName("en-GB"))
        assertEquals("English", DictationText.languageName("en"))
        assertEquals("an undefined tag keeps its text", "und", DictationText.languageName("und"))
        val none = DictationText.unsupported(listOf("en-GB", "de-DE"))
        assertTrue(none, none.contains("English (United Kingdom), German (Germany)"))
        assertTrue(DictationText.downloading("en-GB").contains("English (United Kingdom)"))
    }

    @Test
    fun namesLanguageErrors() {
        assertTrue(DictationText.isLanguage(SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED))
        assertTrue(DictationText.isLanguage(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE))
        assertFalse(DictationText.isLanguage(SpeechRecognizer.ERROR_NO_MATCH))
    }

    @Test
    fun namesErrors() {
        assertTrue(DictationText.isSilence(SpeechRecognizer.ERROR_NO_MATCH))
        assertTrue(DictationText.isSilence(SpeechRecognizer.ERROR_SPEECH_TIMEOUT))
        assertFalse(DictationText.isSilence(SpeechRecognizer.ERROR_AUDIO))
        assertTrue(DictationText.message(SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS).contains("microphone"))
        assertTrue(DictationText.message(SpeechRecognizer.ERROR_NETWORK).contains("offline model"))
        assertTrue(DictationText.message(99).contains("99"))
    }
}
