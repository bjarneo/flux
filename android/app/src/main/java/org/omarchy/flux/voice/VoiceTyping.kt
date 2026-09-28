package org.omarchy.flux.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.mic.MicSession

/**
 * Dictation that types its words somewhere, for example on the computer.
 * [start] asks for the microphone when needed. The words go to the
 * callback of [rememberVoiceTyping] when the dictation ends. Show
 * [LanguagePicker] next to the dictation for the language choice.
 */
class VoiceTyping internal constructor(val dictation: Dictation, private val context: Context) {
    /** True when the phone has a speech recognizer. */
    val available: Boolean = Dictation.available(context)

    /** The last problem to show, or null. */
    var error by mutableStateOf<String?>(null)
        internal set

    /** True while the language picker shows. */
    var picking by mutableStateOf(false)

    internal var askMic: () -> Unit = {}
    internal var onText: (String) -> Unit = {}
    internal var startAfterGrant by mutableStateOf(false)

    /** Starts a dictation. It returns false when the dictation did not start. [error] then tells why, if it is known. */
    fun start(): Boolean {
        error = null
        if (MicSession.status.value.active) {
            error = "Stop Flux Microphone to dictate"
            return false
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            askMic()
            return false
        }
        val ok = dictation.start(emptyList()) { spoken -> if (spoken.isNotBlank()) onText(spoken) }
        if (!ok) error = dictation.error
        return ok
    }

    /** Keeps the words so far and opens the language picker. */
    fun pickLanguage() {
        dictation.stopNow()
        picking = true
    }
}

/**
 * Returns a [VoiceTyping] for this screen. [onText] gets the words of each
 * dictation. The dictation ends with its words when the app goes to the
 * background, because Android gives the microphone only to a visible app.
 */
@Composable
fun rememberVoiceTyping(onText: (String) -> Unit): VoiceTyping {
    val context = LocalContext.current
    val dictation = rememberDictation()
    val v = remember(dictation) { VoiceTyping(dictation, context) }
    val text by rememberUpdatedState(onText)
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) v.startAfterGrant = true else v.error = "Allow the microphone for Flux to dictate"
    }
    v.askMic = { askMic.launch(Manifest.permission.RECORD_AUDIO) }
    v.onText = { text(it) }
    LaunchedEffect(v.startAfterGrant) {
        if (!v.startAfterGrant) return@LaunchedEffect
        v.startAfterGrant = false
        v.start()
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, dictation) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) dictation.stopNow() }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    return v
}

/** The language picker of [v]. A chosen language starts the next dictation. */
@Composable
fun LanguagePicker(v: VoiceTyping) {
    if (!v.picking) return
    val context = LocalContext.current
    val models = rememberSpeechModels()
    var language by remember { mutableStateOf(DictationSettings.language(context)) }
    fun choose(tag: String) {
        DictationSettings.setLanguage(context, tag)
        language = tag
    }
    LanguageSheet(
        models,
        selected = language,
        onSelect = { tag ->
            choose(tag)
            v.picking = false
            v.start()
        },
        onDownloaded = ::choose,
        onDismiss = { v.picking = false },
    )
}
