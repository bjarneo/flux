package org.omarchy.flux.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.LocaleList
import android.speech.ModelDownloadListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.edit

private const val TAG = "FluxDictation"

/** The dictation settings that the phone keeps. */
object DictationSettings {
    private const val PREFS = "flux-dictation"
    private const val LANGUAGE = "language"

    /** The language that the user chose, as a tag such as `de-DE`. Empty for the phone languages in order. */
    fun language(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(LANGUAGE, "").orEmpty()

    fun setLanguage(context: Context, tag: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putString(LANGUAGE, tag) }
    }
}

/** The phone languages as tags, in the order of the Android language settings. */
fun phoneLanguages(): List<String> {
    val list = LocaleList.getDefault()
    return DictationText.languages((0 until list.size()).map { list[it].toLanguageTag() })
}

/**
 * The speech models of the recognizer: the languages on the phone, the
 * languages that download, and the languages that it can download. Android
 * 13 and later can list them. Android 14 and later also report the progress
 * of a download. Use it on the main thread only.
 */
class SpeechModels(private val context: Context) {
    enum class Load { Loading, Ready, Unsupported, Failed }

    var load by mutableStateOf(Load.Loading)
        private set
    var installed by mutableStateOf(emptyList<String>())
        private set
    var pending by mutableStateOf(emptyList<String>())
        private set
    var supported by mutableStateOf(emptyList<String>())
        private set

    /** The progress of each download that this phone started, in percent. -1 while Android waits to start it. */
    val progress = mutableStateMapOf<String, Int>()

    /** The message of the last failure. */
    var error by mutableStateOf<String?>(null)
        private set

    /** True when the on-device recognizer of Android gives the list. */
    var onDevice = false
        private set

    private var recognizer: SpeechRecognizer? = null

    /** True while a model downloads. */
    val downloading: Boolean get() = pending.isNotEmpty() || progress.isNotEmpty()

    /** Reads the lists from the recognizer again. */
    fun refresh() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            load = Load.Unsupported
            return
        }
        val r = recognizer ?: create()?.also { recognizer = it } ?: run {
            load = Load.Unsupported
            return
        }
        query(r)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun query(r: SpeechRecognizer) {
        r.checkRecognitionSupport(intent(null), context.mainExecutor, object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                installed = support.installedOnDeviceLanguages
                pending = support.pendingOnDeviceLanguages
                supported = support.supportedOnDeviceLanguages
                // A download that ended leaves the progress list.
                progress.keys.filter { it in installed }.forEach { progress.remove(it) }
                load = Load.Ready
            }

            override fun onError(code: Int) {
                Log.w(TAG, "speech models: error $code")
                if (load == Load.Loading) load = Load.Failed
                error = "The speech recognizer did not list its languages (error $code). Try again."
            }
        })
    }

    /**
     * Downloads the model of [tag]. [onDone] runs when Android 14 or later
     * reports that the model is on the phone.
     */
    fun download(tag: String, onDone: (String) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val r = recognizer ?: return
        error = null
        progress[tag] = -1
        Log.i(TAG, "speech models: download $tag")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            r.triggerModelDownload(intent(tag), context.mainExecutor, object : ModelDownloadListener {
                override fun onProgress(completedPercent: Int) {
                    progress[tag] = completedPercent.coerceIn(0, 100)
                }

                override fun onSuccess() {
                    Log.i(TAG, "speech models: $tag is on the phone")
                    progress.remove(tag)
                    refresh()
                    onDone(tag)
                }

                override fun onScheduled() {
                    progress[tag] = -1
                }

                override fun onError(code: Int) {
                    Log.w(TAG, "speech models: download $tag, error $code")
                    progress.remove(tag)
                    error = "The download of ${DictationText.languageName(tag)} failed (error $code). Try again."
                    refresh()
                }
            })
        } else {
            // Android 13 reports no progress. The list shows the download until it ends.
            r.triggerModelDownload(intent(tag))
            refresh()
        }
    }

    fun release() {
        recognizer?.destroy()
        recognizer = null
    }

    private fun create(): SpeechRecognizer? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            onDevice = true
            return SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        }
        onDevice = false
        return if (SpeechRecognizer.isRecognitionAvailable(context)) SpeechRecognizer.createSpeechRecognizer(context) else null
    }

    private fun intent(tag: String?) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        if (tag != null) putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
    }
}

/** The [SpeechModels] of the current screen. It frees its recognizer when the screen closes. */
@Composable
fun rememberSpeechModels(): SpeechModels {
    val context = LocalContext.current.applicationContext
    val models = remember { SpeechModels(context) }
    DisposableEffect(models) { onDispose { models.release() } }
    return models
}
