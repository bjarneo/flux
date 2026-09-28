package org.omarchy.flux.voice

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import java.util.Locale
import kotlin.math.PI
import kotlin.math.sin
import kotlin.random.Random

private const val TAG = "FluxDictation"

/**
 * Speech to text on the phone, for the reply field of an agent. The phone
 * does all the work. Flux uses the on-device recognizer of Android when the
 * phone has one. Otherwise it uses the default recognizer and asks it to
 * stay offline. The audio does not go to the computer.
 *
 * Recognizers end a session in 2 ways. The Google on-device recognizer
 * keeps 1 session open through pauses and sends a final text at each pause.
 * Other recognizers end the session with the first final text. [Dictation]
 * collects each final text and starts a new session only when the old one
 * ended, so a long prompt with pauses stays one dictation. Some recognizers
 * start the partial text again after a pause and send no final text for the
 * words before it. [Dictation] then makes those words final. After a stop, it
 * waits until the recognizer is quiet, so the last words are not lost.
 *
 * The dictation ends when the user stops it, after [SILENCE_STOP_MS] with
 * no speech, or after [MAX_MS]. Use it on the main thread only.
 */
class Dictation(private val context: Context) {
    enum class Phase { Idle, Listening, Finishing }

    var phase by mutableStateOf(Phase.Idle)
        private set

    /** The final text so far. */
    var settled by mutableStateOf("")
        private set

    /** The partial text of the words that the recognizer still hears. It can change. */
    var pending by mutableStateOf("")
        private set

    /** The input level from 0 to 1. The wave reads it in its draw phase. */
    var level by mutableFloatStateOf(0f)
        private set

    /** The last level report, in elapsed realtime. 0 until the recognizer reports a level. */
    var levelAt = 0L
        private set

    /** The start of the dictation, in elapsed realtime. */
    var startedAt by mutableLongStateOf(0L)
        private set

    /** True when the on-device recognizer of Android transcribes. */
    var onDevice by mutableStateOf(false)
        private set

    /** The message of the last failure. A new start clears it. */
    var error by mutableStateOf<String?>(null)
        private set

    /** The language that the recognizer uses, as a tag such as `en-GB`. Empty until the recognizer is ready. */
    var language by mutableStateOf("")
        private set

    /** True when the last dictation failed because the recognizer has no model for its language. */
    var languageError by mutableStateOf(false)
        private set

    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    /** True from startListening until the recognizer ends the session. */
    private var session = false
    /** The last partial text as the recognizer sent it. A final text clears it. */
    private var partial = ""
    private var hints: List<String> = emptyList()
    private var onDone: ((String) -> Unit)? = null
    /** The last time that the user spoke, in elapsed realtime. */
    private var spokeAt = 0L
    /** The last callback of the recognizer, in elapsed realtime. */
    private var eventAt = 0L
    /** The start of the current session and its level reports, to see if the recognizer streams levels. */
    private var sessionAt = 0L
    private var levels = 0
    /** The restarts after a busy or failed recognizer, since the last good session. */
    private var retries = 0
    /** The phone languages, in the order of the Android language settings. */
    private var languages: List<String> = emptyList()
    /** The index in [languages] of the language of the current session. */
    private var lang = 0
    /** The first phone language that the recognizer supports but has not downloaded. */
    private var missing: String? = null
    /** True when the user chose the language, so the phone languages do not count. */
    private var chosen = false
    private var demo = false

    /**
     * Starts a dictation. [hints] are words that the recognizer should
     * expect, such as the project name. [onDone] gets the text at the end,
     * unless the user cancels. Returns false when the phone has no
     * recognizer. [error] then tells why.
     */
    fun start(hints: List<String>, demo: Boolean = false, onDone: (String) -> Unit): Boolean {
        if (phase != Phase.Idle) return false
        error = null
        languageError = false
        this.demo = demo
        if (!demo && recognizer == null) {
            recognizer = create() ?: run {
                error = "This phone has no speech recognizer. Install a voice input app, such as Speech Recognition and Synthesis from Google."
                return false
            }
        }
        this.hints = hints
        this.onDone = onDone
        settled = ""
        pending = ""
        level = 0f
        levelAt = 0L
        retries = 0
        demoStep = 0
        // A language that the user chose is the only language. Otherwise the
        // recognizer tries the phone languages in order. A language that
        // worked before goes first, so a new dictation starts at once.
        val choice = DictationSettings.language(context)
        chosen = choice.isNotEmpty()
        languages = if (chosen) listOf(choice) else phoneLanguages().ifEmpty { listOf(Locale.getDefault().toLanguageTag()) }
        lang = remembered?.takeIf { it.first == languages }?.let { languages.indexOf(it.second) }?.takeIf { it >= 0 } ?: 0
        missing = null
        language = if (demo) "en-US" else ""
        startedAt = SystemClock.elapsedRealtime()
        spokeAt = startedAt
        phase = Phase.Listening
        if (demo) {
            main.post(demoTick)
        } else {
            listen()
            main.postDelayed(watch, WATCH_MS)
        }
        return true
    }

    /** Stops the dictation. The recognizer finishes the last words, then [start] gets the text. */
    fun stop() {
        if (phase != Phase.Listening) return
        phase = Phase.Finishing
        level = 0f
        main.removeCallbacks(check)
        if (demo) {
            main.removeCallbacks(demoTick)
            main.postDelayed(finishNow, DEMO_FINISH_MS)
            return
        }
        if (!session) {
            finish()
            return
        }
        recognizer?.stopListening()
        // The last texts come soon after the stop. A recognizer that sends
        // none still ends the dictation with the text so far.
        main.postDelayed(finishNow, FINISH_TIMEOUT_MS)
    }

    /** Ends the dictation at once and keeps the text so far, for example when the app goes to the background. */
    fun stopNow() {
        if (phase == Phase.Idle) return
        finish()
    }

    /** Ends the dictation and drops its text. */
    fun cancel() {
        if (phase == Phase.Idle) return
        main.removeCallbacksAndMessages(null)
        if (session) recognizer?.cancel()
        session = false
        onDone = null
        reset()
    }

    /** Frees the recognizer. The screen calls it when it closes. */
    fun release() {
        cancel()
        recognizer?.destroy()
        recognizer = null
    }

    private fun create(): SpeechRecognizer? {
        val local = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        if (!local && !SpeechRecognizer.isRecognitionAvailable(context)) return null
        onDevice = local
        val r = if (local) SpeechRecognizer.createOnDeviceSpeechRecognizer(context) else SpeechRecognizer.createSpeechRecognizer(context)
        r.setRecognitionListener(listener)
        Log.i(TAG, "recognizer ready, on device: $local")
        return r
    }

    private fun intent(tag: String = languages[lang]) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        // A recognizer that reads these values keeps the session open
        // through pauses. The Google on-device recognizer reads an Int.
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_STOP_MS.toInt())
        putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, SILENCE_STOP_MS.toInt())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Punctuation and capitals, as in typed text.
            putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            putExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION, true)
            if (hints.isNotEmpty()) putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(hints))
        }
    }

    private fun listen() {
        val r = recognizer ?: return
        session = true
        sessionAt = SystemClock.elapsedRealtime()
        eventAt = sessionAt
        levels = 0
        r.startListening(intent())
    }

    private val next = Runnable { if (phase == Phase.Listening && !session) listen() }

    /** Adds a final text. Without one, the partial text counts. */
    private fun commit(text: String?) {
        settled = DictationText.merge(settled, text?.takeIf { it.isNotBlank() } ?: pending)
        pending = ""
        partial = ""
    }

    /** A final text. The session can go on after it, so the dictation waits for the next event. */
    private fun onFinal(text: String?) {
        if (phase == Phase.Idle) return
        commit(text)
        Log.d(TAG, "final text, ${DictationText.words(text.orEmpty()).size} words")
        if (phase == Phase.Finishing) {
            settle()
            return
        }
        main.removeCallbacks(check)
        main.postDelayed(check, CHECK_MS)
    }

    /**
     * Runs [CHECK_MS] after a final text while the user dictates. A
     * recognizer that streams levels and has gone quiet ended its session,
     * so a new session starts. Other recognizers keep the session open, and
     * the dictation waits.
     */
    private val check = Runnable {
        if (phase != Phase.Listening || !session) return@Runnable
        val now = SystemClock.elapsedRealtime()
        val streams = levels * 1000L / maxOf(1L, now - sessionAt) >= STREAM_RATE
        if (streams && now - eventAt >= CHECK_MS) {
            Log.d(TAG, "the session ended after its final text")
            ended()
        }
    }

    /** The recognizer ended the session. A new session starts while the user dictates. */
    private fun ended() {
        commit(null)
        session = false
        level = 0f
        when {
            phase == Phase.Finishing -> settle()
            quiet() -> finish()
            else -> main.post(next)
        }
    }

    /** Waits until the recognizer is quiet after a stop, then finishes. A new final text starts the wait again. */
    private fun settle() {
        main.removeCallbacks(finishNow)
        main.postDelayed(finishNow, SETTLE_MS)
    }

    private val finishNow = Runnable { if (phase != Phase.Idle) finish() }

    /** Stops the dictation after a long silence or at the time limit. */
    private val watch = object : Runnable {
        override fun run() {
            if (phase != Phase.Listening) return
            if (quiet()) {
                Log.i(TAG, "no speech for ${SILENCE_STOP_MS / 1000} s, stop")
                stop()
                return
            }
            main.postDelayed(this, WATCH_MS)
        }
    }

    private fun quiet(): Boolean {
        val now = SystemClock.elapsedRealtime()
        return now - spokeAt >= SILENCE_STOP_MS || now - startedAt >= MAX_MS
    }

    private fun onError(code: Int) {
        if (phase == Phase.Idle) return
        Log.d(TAG, "recognizer error $code")
        when {
            DictationText.isSilence(code) -> ended()
            // A stop can end the session with an error. The text is complete.
            phase == Phase.Finishing -> ended()
            // The recognizer has no model for this language. The next phone language gets a try.
            DictationText.isLanguage(code) -> {
                session = false
                if (code == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE && missing == null) missing = languages[lang]
                if (lang + 1 < languages.size) {
                    Log.i(TAG, "recognizer has no ${languages[lang]} (error $code), try ${languages[lang + 1]}")
                    lang++
                    main.post(next)
                } else {
                    fail(code)
                }
            }
            // A recognizer that is busy or lost its service gets a new start.
            code in RESTARTS && retries < MAX_RETRIES -> {
                session = false
                retries++
                Log.i(TAG, "recognizer error $code, restart $retries")
                commit(null)
                recognizer?.destroy()
                recognizer = create()
                if (recognizer == null) fail(code) else main.postDelayed(next, RETRY_MS)
            }
            else -> {
                session = false
                fail(code)
            }
        }
    }

    private fun fail(code: Int) {
        Log.w(TAG, "recognizer error $code")
        // With no usable language, Android downloads the first supported one.
        val download = missing?.takeIf { DictationText.isLanguage(code) }
        languageError = DictationText.isLanguage(code)
        error = when {
            download != null -> DictationText.downloading(download)
            code == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED && chosen -> DictationText.notSupported(languages.first())
            code == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> DictationText.unsupported(languages)
            else -> DictationText.message(code)
        }
        if (download != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching { recognizer?.triggerModelDownload(intent(download)) }.onFailure { Log.w(TAG, "model download: ${it.message}") }
        }
        finish()
    }

    /** Ends the dictation and gives the text to the caller. */
    private fun finish() {
        main.removeCallbacksAndMessages(null)
        if (session) recognizer?.cancel()
        session = false
        commit(null)
        val text = settled
        val done = onDone
        onDone = null
        reset()
        if (text.isNotEmpty()) done?.invoke(text)
    }

    private fun reset() {
        phase = Phase.Idle
        level = 0f
        settled = ""
        pending = ""
        partial = ""
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            eventAt = SystemClock.elapsedRealtime()
            retries = 0
            val tag = languages.getOrNull(lang) ?: return
            if (language != tag) Log.i(TAG, "recognizer language $tag")
            language = tag
            remembered = languages to tag
        }

        override fun onBeginningOfSpeech() {
            eventAt = SystemClock.elapsedRealtime()
            spokeAt = eventAt
        }

        override fun onRmsChanged(rmsdB: Float) {
            eventAt = SystemClock.elapsedRealtime()
            levels++
            if (phase != Phase.Listening) return
            level = DictationText.level(rmsdB)
            levelAt = eventAt
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (phase == Phase.Idle) return
            eventAt = SystemClock.elapsedRealtime()
            val t = first(partialResults)
            if (t.isNullOrBlank()) return
            spokeAt = eventAt
            // After a final text, a partial text holds only the new words,
            // or, with some recognizers, the whole text again.
            val words = DictationText.unsettled(settled, t)
            // Some recognizers start the partial text again after a pause and
            // send no final text for the words before it. Those words become
            // final, so a long dictation keeps its start.
            if (DictationText.restarts(partial, t)) {
                Log.d(TAG, "partial text started again, keep ${DictationText.words(pending).size} words")
                commit(null)
            }
            partial = t
            pending = words
        }

        override fun onResults(results: Bundle?) {
            eventAt = SystemClock.elapsedRealtime()
            onFinal(first(results))
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            eventAt = SystemClock.elapsedRealtime()
            onFinal(first(segmentResults))
        }

        override fun onEndOfSegmentedSession() {
            if (phase != Phase.Idle) ended()
        }

        override fun onError(error: Int) = this@Dictation.onError(error)

        override fun onEndOfSpeech() {
            eventAt = SystemClock.elapsedRealtime()
            level = 0f
        }

        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun first(b: Bundle?): String? = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    // Debug builds only: a sample dictation for the demo computers, so that
    // the screen and its animation render on an emulator with no voice.
    private var demoStep = 0
    private val demoTick = object : Runnable {
        override fun run() {
            if (phase != Phase.Listening) return
            val t = SystemClock.elapsedRealtime() - startedAt
            val words = DEMO_TEXT.split(' ')
            val said = (t / DEMO_WORD_MS).toInt().coerceAtMost(words.size)
            val speaking = said < words.size
            // Each word rises and falls, as a syllable does.
            val syllable = sin(PI * (t % DEMO_WORD_MS) / DEMO_WORD_MS).toFloat()
            level = if (speaking) (0.08f + 0.9f * syllable * (0.45f + 0.55f * Random.nextFloat())) else 0.03f * Random.nextFloat()
            levelAt = SystemClock.elapsedRealtime()
            if (said != demoStep) {
                demoStep = said
                // The first sentence is final. The words after it are still partial.
                val cut = if (said > DEMO_SETTLED_WORDS) DEMO_SETTLED_WORDS else 0
                settled = words.take(cut).joinToString(" ")
                pending = words.subList(cut, said).joinToString(" ")
            }
            main.postDelayed(this, DEMO_TICK_MS)
        }
    }

    companion object {
        /** The phone languages and the one that worked last, for the next dictation on any screen. */
        @Volatile private var remembered: Pair<List<String>, String>? = null

        /** A dictation with no speech for this long ends by itself. */
        const val SILENCE_STOP_MS = 20_000L
        /** The longest dictation. */
        const val MAX_MS = 5 * 60_000L
        /** The longest wait for the last text after a stop. */
        private const val FINISH_TIMEOUT_MS = 3_000L
        /** After a stop, the dictation ends when the recognizer sends no final text for this long. */
        private const val SETTLE_MS = 450L
        /** The wait after a final text before the dictation checks if the session ended. */
        private const val CHECK_MS = 1_200L
        /** Level reports per second of a recognizer that streams levels while the session runs. */
        private const val STREAM_RATE = 4
        private const val WATCH_MS = 1_000L
        private const val RETRY_MS = 250L
        private const val MAX_RETRIES = 3
        // A phone before API 31 never reports ERROR_SERVER_DISCONNECTED, so the value is safe to inline.
        @SuppressLint("InlinedApi")
        private val RESTARTS = setOf(
            SpeechRecognizer.ERROR_CLIENT,
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
            SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
        )

        private const val DEMO_TEXT = "Run the migration on a copy of the database first. Then show me the row counts before you apply it."
        private const val DEMO_SETTLED_WORDS = 10
        private const val DEMO_WORD_MS = 320L
        private const val DEMO_TICK_MS = 70L
        private const val DEMO_FINISH_MS = 600L

        /** True when the phone has a speech recognizer. */
        fun available(context: Context): Boolean =
            SpeechRecognizer.isRecognitionAvailable(context) ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context))
    }
}

/** A [Dictation] for the current screen. It frees its recognizer when the screen closes. */
@Composable
fun rememberDictation(): Dictation {
    val context = LocalContext.current.applicationContext
    val dictation = remember { Dictation(context) }
    DisposableEffect(dictation) { onDispose { dictation.release() } }
    return dictation
}
