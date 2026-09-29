package org.omarchy.flux.voice

import android.os.Build
import android.speech.SpeechRecognizer
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.omarchy.flux.ui.Ic
import org.omarchy.flux.ui.Mono
import org.omarchy.flux.ui.SectionLabel
import org.omarchy.flux.ui.Sym
import org.omarchy.flux.ui.T
import org.omarchy.flux.ui.Tile
import org.omarchy.flux.ui.TileLabel
import org.omarchy.flux.ui.TileShape
import org.omarchy.flux.ui.TiledGutter
import org.omarchy.flux.ui.Tn

/** The part of the screen height that the picker takes. */
private const val SHEET_HEIGHT = 0.88f

/** While a model downloads, the picker reads the lists again at this interval. */
private const val REFRESH_MS = 3_000L

/**
 * The language picker of dictation. It lists the languages on the phone,
 * the languages that download, and the languages that the recognizer can
 * download. A tap on a language on the phone selects it. A tap on another
 * language downloads its model. [selected] is the chosen language, or
 * empty for automatic mode. [onDownloaded] runs when a download that this
 * picker started is done.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LanguageSheet(
    models: SpeechModels,
    selected: String,
    onSelect: (String) -> Unit,
    onDownloaded: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(models) { models.refresh() }
    // A download changes the lists, so the picker reads them again until it ends.
    val downloading = models.downloading
    LaunchedEffect(downloading) {
        while (isActive && downloading) {
            delay(REFRESH_MS)
            models.refresh()
        }
    }
    var query by rememberSaveable { mutableStateOf("") }
    // A dictation replaces the search. It uses the phone languages, because the chosen language can be the
    // one that fails, and its panel does not open this picker again.
    val voice = rememberVoiceTyping(automatic = true) { query = DictationText.query(it) }
    val phone = remember { phoneLanguages() }
    val unsupported = models.load == SpeechModels.Load.Unsupported
    // Dictation uses the recognizer on the phone when it has one, see Dictation. The other recognizer can use a network service.
    val context = LocalContext.current
    val local = remember {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
    }
    val rows = if (unsupported) {
        // Without a list from the recognizer, the phone languages are the choices.
        LanguageCatalog.rows(phone, emptyList(), emptyList(), phone, query)
    } else {
        LanguageCatalog.rows(models.installed, models.pending + models.progress.keys, models.supported, phone, query)
    }
    val automatic = if (unsupported) phone.firstOrNull() else LanguageCatalog.automatic(phone, models.installed)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheet,
        containerColor = Tn.bg,
        contentColor = Tn.text,
        dragHandle = {
            Box(Modifier.padding(top = 10.dp, bottom = 6.dp).size(36.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(Tn.lineHi))
        },
    ) {
        // A fixed height keeps the sheet below the status bar, and the
        // sheet does not jump while the search changes the list.
        LazyColumn(
            Modifier.fillMaxWidth().fillMaxHeight(SHEET_HEIGHT).padding(horizontal = TiledGutter),
            contentPadding = PaddingValues(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            item {
                Column(Modifier.padding(start = 4.dp, top = 4.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TileLabel("dictation language")
                    T(
                        if (local) {
                            "Choose the language that you speak. The phone transcribes it on the device."
                        } else {
                            "Choose the language that you speak. The speech recognizer app of the phone can send the audio to its service."
                        },
                        size = 13, color = Tn.sub,
                    )
                }
            }
            item {
                VoiceField(voice, languages = false) { m ->
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        modifier = m,
                        placeholder = { T("Find a language", color = Tn.dim) },
                        leadingIcon = { Sym(Ic.search, tint = Tn.dim, size = 20.dp) },
                        trailingIcon = if (query.isEmpty()) null else {
                            { Box(Modifier.size(40.dp).clip(CircleShape).clickable(onClickLabel = "Clear") { query = "" }, contentAlignment = Alignment.Center) { Sym(Ic.close, "Clear", tint = Tn.dim, size = 18.dp) } }
                        },
                        singleLine = true,
                        textStyle = TextStyle(color = Tn.text, fontSize = 14.sp),
                        shape = TileShape,
                    )
                }
            }
            if (query.isBlank()) {
                item {
                    Spacer(Modifier.height(2.dp))
                    AutomaticTile(automatic, selected.isEmpty()) { onSelect("") }
                }
            }
            when (models.load) {
                SpeechModels.Load.Loading -> item {
                    Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Tn.magenta)
                        T("Reading the languages of the speech recognizer", color = Tn.sub, size = 13)
                    }
                }
                SpeechModels.Load.Unsupported -> item {
                    T(
                        "This Android version cannot list or download speech models. You can choose one of the phone languages.",
                        Modifier.padding(4.dp), size = 12, color = Tn.dim,
                    )
                }
                else -> {}
            }
            models.error?.let { e -> item { T(e, Modifier.padding(4.dp), size = 12, color = Tn.red) } }
            for (state in LanguageRow.State.entries) {
                val group = rows.filter { it.state == state }
                if (group.isEmpty()) continue
                item(key = "label-$state") {
                    SectionLabel(
                        when (state) {
                            LanguageRow.State.Installed -> "on this phone"
                            LanguageRow.State.Downloading -> "downloading"
                            LanguageRow.State.Available -> "download"
                        },
                    )
                }
                items(group, key = { "${it.state}-${it.tag}" }) { row ->
                    LanguageTile(row, row.tag == selected, models.progress[row.tag]) {
                        when (row.state) {
                            LanguageRow.State.Installed -> onSelect(row.tag)
                            LanguageRow.State.Available -> models.download(row.tag, onDownloaded)
                            LanguageRow.State.Downloading -> {}
                        }
                    }
                }
            }
            if (models.load == SpeechModels.Load.Ready && rows.isEmpty() && query.isNotBlank()) {
                item { T("No language matches \"${query.trim()}\".", Modifier.padding(4.dp), size = 13, color = Tn.dim) }
            }
            if (!unsupported && local) {
                item {
                    T(
                        "Android downloads each model from Google once. Dictation then runs on this phone, and the audio stays on the phone.",
                        Modifier.padding(start = 4.dp, end = 4.dp, top = 12.dp), size = 11, color = Tn.dim,
                    )
                }
            }
        }
    }
}

/** The automatic mode: the first phone language that has a model. */
@Composable
private fun AutomaticTile(language: String?, selected: Boolean, onClick: () -> Unit) {
    Tile(
        Modifier.fillMaxWidth(), onClick,
        container = if (selected) Tn.tileHi else Tn.tile,
        border = BorderStroke(1.dp, if (selected) Tn.blue else Tn.line),
        padding = PaddingValues(horizontal = 14.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("Automatic", size = 14, weight = FontWeight.SemiBold)
                T(
                    if (language != null) "The phone languages in order. Now ${DictationText.languageName(language)}."
                    else "The phone languages in order. None of them has a model yet.",
                    size = 12, color = Tn.sub,
                )
            }
            if (selected) Sym(Ic.check, "Selected", tint = Tn.blue, size = 20.dp)
        }
    }
}

/**
 * A language: its name, its own name, and its tag. A language on the
 * phone shows a check when it is selected. A language to download shows a
 * download key. A download shows its progress.
 */
@Composable
private fun LanguageTile(row: LanguageRow, selected: Boolean, progress: Int?, onClick: () -> Unit) {
    val loading = row.state == LanguageRow.State.Downloading
    Tile(
        Modifier.fillMaxWidth(),
        if (loading) null else onClick,
        accent = if (row.state == LanguageRow.State.Available) Tn.cyan else Tn.blue,
        container = if (selected) Tn.tileHi else Tn.tile,
        border = BorderStroke(1.dp, if (selected) Tn.blue else Tn.line),
        padding = PaddingValues(start = 14.dp, end = 10.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    T(row.name, Modifier.weight(1f, fill = false), size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                    T(row.tag, size = 10, color = Tn.dim, family = Mono, maxLines = 1)
                }
                if (row.native != row.name) T(row.native, size = 12, color = Tn.sub, maxLines = 1)
                if (loading) {
                    Spacer(Modifier.height(4.dp))
                    val p = progress ?: -1
                    if (p >= 0) {
                        LinearProgressIndicator(
                            progress = { p / 100f },
                            modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                            color = Tn.cyan, trackColor = Tn.line, strokeCap = StrokeCap.Round, gapSize = 0.dp, drawStopIndicator = {},
                        )
                    } else {
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                            color = Tn.cyan, trackColor = Tn.line, strokeCap = StrokeCap.Round, gapSize = 0.dp,
                        )
                    }
                    T(
                        if (p >= 0) "Downloading, $p %" else "Waiting for Android to download it",
                        size = 11, color = Tn.dim,
                    )
                }
            }
            when {
                selected -> Sym(Ic.check, "Selected", tint = Tn.blue, size = 20.dp)
                row.state == LanguageRow.State.Available -> Box(
                    Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)).background(Tn.tileHi),
                    contentAlignment = Alignment.Center,
                ) { Sym(Ic.download, "Download", tint = Tn.cyan, size = 20.dp) }
                loading && (progress ?: -1) >= 0 -> T("${progress}%", Modifier.width(40.dp), size = 12, color = Tn.cyan, family = Mono)
                else -> {}
            }
        }
    }
}
