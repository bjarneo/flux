package org.omarchy.flux.voice

import android.annotation.SuppressLint
import android.speech.SpeechRecognizer
import java.util.Locale

/** A text field value as plain Kotlin: the text and the cursor after an insert. */
data class Edit(val text: String, val cursor: Int)

/**
 * The text rules of dictation. The functions use no Android classes at run
 * time, so the JVM tests cover them.
 */
object DictationText {
    /** Characters that follow a word with no space before them. */
    private const val CLOSING = ",.;:!?)]}'\""

    /**
     * Puts [spoken] in [text] in place of the selection from [start] to [end].
     * A space goes between the spoken text and a word that it would touch.
     * At the start of the text or of a sentence, the first letter becomes a
     * capital. The cursor goes after the spoken text.
     */
    fun insert(text: String, start: Int, end: Int, spoken: String): Edit {
        val s = spoken.trim()
        val a = minOf(start, end).coerceIn(0, text.length)
        val b = maxOf(start, end).coerceIn(a, text.length)
        if (s.isEmpty()) return Edit(text, b)
        val before = text.substring(0, a)
        val after = text.substring(b)
        val words = if (startsSentence(before)) s.replaceFirstChar { it.uppercaseChar() } else s
        val lead = if (before.isNotEmpty() && !before.last().isWhitespace() && words.first() !in CLOSING) " " else ""
        val trail = if (after.isNotEmpty() && !after.first().isWhitespace() && after.first() !in CLOSING) " " else ""
        val inserted = lead + words + trail
        return Edit(before + inserted + after, before.length + inserted.length)
    }

    /** Joins 2 texts with 1 space. */
    fun join(first: String, second: String): String {
        val a = first.trim()
        val b = second.trim()
        return when {
            a.isEmpty() -> b
            b.isEmpty() -> a
            else -> "$a $b"
        }
    }

    /** The words of [text], split at white space. */
    fun words(text: String): List<String> = text.trim().split(SPACE).filter { it.isNotEmpty() }

    /**
     * Adds the final text [next] to the final text so far. Recognizers send
     * a final text in 1 of 3 forms: only the new words, the whole text
     * again with the new words, or the same words a second time. Only the
     * new words go into the result. Case and punctuation do not matter for
     * the compare, because a later text can add them.
     */
    fun merge(settled: String, next: String): String {
        val old = words(settled)
        val new = words(next)
        return when {
            new.isEmpty() -> settled.trim()
            old.isEmpty() -> next.trim()
            startsWith(new, old) -> next.trim()
            // A repeat of 1 word can be real speech, such as "yes".
            new.size >= 2 && endsWith(old, new) -> settled.trim()
            else -> join(settled, next)
        }
    }

    /** The words of the partial text [partial] that are not in the final text [settled] yet. */
    fun unsettled(settled: String, partial: String): String {
        val old = words(settled)
        val new = words(partial)
        return if (old.isNotEmpty() && startsWith(new, old)) new.drop(old.size).joinToString(" ") else partial.trim()
    }

    /**
     * The input level from 0 to 1 for the RMS value of `onRmsChanged`.
     * Recognizers report about -2 dB for silence and about 10 dB for a loud
     * voice. The square root lifts quiet speech, so the wave shows it.
     */
    fun level(rmsDb: Float): Float {
        if (rmsDb.isNaN()) return 0f
        val linear = ((rmsDb - SILENT_DB) / (LOUD_DB - SILENT_DB)).coerceIn(0f, 1f)
        return kotlin.math.sqrt(linear)
    }

    /** The minutes and seconds of [ms], such as `0:07` or `12:30`. */
    fun clock(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        return "%d:%02d".format(Locale.ROOT, s / 60, s % 60)
    }

    /** The phone language tags without blanks, repeats, and the undefined language. */
    fun languages(tags: List<String>): List<String> =
        tags.map { it.trim() }.filter { it.isNotEmpty() && it != "und" }.distinct()

    /** The English name of a language tag, such as `English (United Kingdom)` for `en-GB`. */
    fun languageName(tag: String): String = tidy(displayLocale(tag).getDisplayName(Locale.ENGLISH)).ifEmpty { tag }

    /**
     * The locale that names the language [tag]. Recognizers write Mandarin
     * as `cmn`, and the locale data has names for `zh`.
     */
    fun displayLocale(tag: String): Locale =
        Locale.forLanguageTag(if (tag == "cmn" || tag.startsWith("cmn-")) "zh" + tag.removePrefix("cmn") else tag)

    /** A language name with a space after each comma and the short names of the Chinese scripts. */
    fun tidy(name: String): String =
        name.replace(COMMA, ", ").replace("Simplified Han", "Simplified").replace("Traditional Han", "Traditional")

    /** The message when the recognizer supports none of the phone languages. */
    fun unsupported(tags: List<String>): String =
        "The speech recognizer on this phone supports none of the phone languages: ${tags.joinToString(", ") { languageName(it) }}. " +
            "Add a language that it supports, such as English, in the Android language settings."

    /** The message when the recognizer does not support the language [tag] that the user chose. */
    fun notSupported(tag: String): String =
        "The speech recognizer on this phone does not support ${languageName(tag)}. Choose another language."

    /** The message when Android downloads the speech model for [tag]. */
    fun downloading(tag: String): String = "Android downloads the speech model for ${languageName(tag)}. Try again when it is done."

    /**
     * True for a recognizer error about the language: no support, or no
     * downloaded model. A phone before API 31 never reports these values,
     * so they are safe to inline.
     */
    @SuppressLint("InlinedApi")
    fun isLanguage(error: Int): Boolean =
        error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED || error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE

    /** True for a recognizer error that means only that nobody spoke. */
    fun isSilence(error: Int): Boolean =
        error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT

    /** The message for a recognizer error. */
    fun message(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Allow the microphone for Flux in the app settings"
        SpeechRecognizer.ERROR_AUDIO -> "The microphone is not available. Close the other app that uses it."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The speech recognizer is busy. Try again."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "The speech recognizer on this phone does not support the phone language"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "Android downloads the speech model for the phone language. Try again when it is done."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS,
        -> "The speech recognizer needs its offline model. Download it for the phone language in the Android settings."
        else -> "Dictation stopped (error $error). Try again."
    }

    private val SPACE = Regex("\\s+")
    private val COMMA = Regex(",(?=\\S)")

    private fun key(word: String) = word.lowercase().filter { it.isLetterOrDigit() }

    private fun startsWith(words: List<String>, prefix: List<String>): Boolean =
        words.size >= prefix.size && prefix.indices.all { key(words[it]) == key(prefix[it]) }

    private fun endsWith(words: List<String>, suffix: List<String>): Boolean =
        words.size >= suffix.size && suffix.indices.all { key(words[words.size - suffix.size + it]) == key(suffix[it]) }

    private const val SILENT_DB = -2f
    private const val LOUD_DB = 10f

    private fun startsSentence(before: String): Boolean {
        val t = before.trimEnd(' ', '\t')
        return t.isEmpty() || t.last() == '\n' || t.last() in ".!?"
    }
}
