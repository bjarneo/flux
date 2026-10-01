package org.omarchy.flux.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.ui.ButtonKind
import org.omarchy.flux.ui.FluxButton
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.MIC_REFUSED
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.Tn
import org.omarchy.flux.ui.needsMicSettings
import org.omarchy.flux.ui.openAppSettings

/**
 * Dictation that puts its words somewhere, for example in a text field or
 * on the computer. [start] asks for the microphone when needed. The words
 * go to the callback of [rememberVoiceTyping] when the dictation ends.
 * [VoiceField] shows the mic key, the errors, and the language picker.
 */
class VoiceTyping internal constructor(val dictation: Dictation, private val context: Context, private val automatic: Boolean) {
    /** True when the phone has a speech recognizer. */
    val available: Boolean = Dictation.available(context)

    /** The last problem to show, or null. */
    var error by mutableStateOf<String?>(null)
        internal set

    /** True while the language picker shows. */
    var picking by mutableStateOf(false)

    /** True after the user refused the microphone. The error then offers the app settings. */
    var refused by mutableStateOf(false)
        internal set

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
        val ok = dictation.start(emptyList(), automatic = automatic) { spoken -> if (spoken.isNotBlank()) onText(spoken) }
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
 * dictation. With [automatic], the dictation uses the phone languages, not
 * the chosen language. The dictation ends with its words when the app goes
 * to the background, because Android gives the microphone only to a
 * visible app.
 */
@Composable
fun rememberVoiceTyping(automatic: Boolean = false, onText: (String) -> Unit): VoiceTyping {
    val context = LocalContext.current
    val dictation = rememberDictation()
    val v = remember(dictation) { VoiceTyping(dictation, context, automatic) }
    val text by rememberUpdatedState(onText)
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        v.refused = !ok
        if (ok) v.startAfterGrant = true else v.error = MIC_REFUSED
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

/**
 * A text field with a mic key. [field] draws the field with the modifier
 * that it gets, and [send] draws a key after the mic key. The words of a
 * dictation go to the callback of [v]. Under the bar, a line tells why a
 * dictation failed. With [languages] off, the panel does not open the
 * language picker, for the search of the picker itself. While [enabled]
 * is off, the mic key hides, unless a dictation runs.
 */
@Composable
fun VoiceField(
    v: VoiceTyping,
    modifier: Modifier = Modifier,
    languages: Boolean = true,
    enabled: Boolean = true,
    send: (@Composable () -> Unit)? = null,
    field: @Composable (Modifier) -> Unit,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        DictationBar(
            v.dictation,
            canDictate = v.available && (enabled || v.dictation.phase != Dictation.Phase.Idle),
            onStart = v::start,
            field = field,
            send = send,
            onLanguage = if (languages) v::pickLanguage else null,
        )
        val problem = v.error ?: v.dictation.error
        if (problem != null) {
            val context = LocalContext.current
            Column(Modifier.padding(horizontal = 4.dp)) {
                T(problem, size = 12, color = Tn.red, lineHeight = 1.3f)
                // The buttons line up with the text. The padding of a text button holds the offset.
                FlowRow(Modifier.offset(x = (-12).dp)) {
                    if (languages && problem == v.dictation.error && v.dictation.languageError) {
                        FluxButton("Choose a language", { v.picking = true }, kind = ButtonKind.Text)
                    }
                    if (needsMicSettings(problem, v.refused && problem == v.error)) {
                        FluxButton("Open app settings", { openAppSettings(context) }, kind = ButtonKind.Text, icon = Ic.settings)
                    }
                }
            }
        }
    }
    if (languages) LanguagePicker(v)
}
