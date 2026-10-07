package org.omarchy.flux.ui

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.Editable
import android.text.InputType
import android.text.Selection
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.CorrectionInfo
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputContentInfo
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.TextAttribute
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.HerdrTerminalEvent
import org.omarchy.flux.core.HerdrTerminalSession
import org.omarchy.flux.theme.OmarchyTheme

/**
 * Keeps the page of a live terminal: the WebView with xterm.js and the
 * feeder of the stream events. The caller keeps it above the layout of
 * the screen, so that a move of [HerdrTerminalView], for example at a
 * rotation, keeps the page, its zoom, and its stream. The page goes away
 * when the caller leaves the composition.
 */
@Composable
internal fun rememberTerminalFeeder(deviceId: String): TerminalFeeder {
    val context = LocalContext.current
    val feeder = remember {
        TerminalFeeder(reader = context.getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled == true)
    }
    feeder.deviceId = deviceId
    DisposableEffect(feeder) {
        HerdrSync.terminalSink = feeder
        onDispose {
            if (HerdrSync.terminalSink === feeder) HerdrSync.terminalSink = null
            feeder.detach()
        }
    }
    return feeder
}
/**
 * The image types that the phone keyboard may paste into the terminal. The
 * keyboard offers its image and clipboard options only while the editor
 * names them. The phone turns each image into a PNG before it sends it.
 */
internal val TERMINAL_IMAGE_TYPES = arrayOf("image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "image/heif")

/**
 * True when the terminal view can take focus on the phone. The phone is in
 * touch mode, so a view that is not focusable in touch mode cannot take
 * focus. requestFocus() then returns false, the input manager never serves
 * the view, and Android ignores showSoftInput(). A tap still does not open
 * the keyboard, because the touch listener takes each touch before
 * View.onTouchEvent can focus the view.
 */
internal const val TERMINAL_FOCUSABLE_IN_TOUCH_MODE = true

/**
 * True when the keyboard key may open the keyboard: the input gate is open
 * and the view can take focus in touch mode. The gate keeps a reconnect or
 * a terminal without an unlock from opening the keyboard.
 */
internal fun keyboardMayOpen(ready: Boolean, focusableInTouchMode: Boolean): Boolean =
    ready && focusableInTouchMode

/** The length from which a block of keyboard text goes as a paste, in characters. */
internal const val TERMINAL_PASTE_FROM = 256

/**
 * True when text from the phone keyboard goes as a paste and not as typed
 * text. A block with a line break or a tab goes as a paste, so it does not
 * submit the prompt or complete a word. A long block goes as a paste, so
 * the agent applies its own paste handling, for example a placeholder for
 * a large paste. A word that the keyboard composed or swiped goes as typed
 * text, so the menus of the agent for @ and / still follow it.
 */
internal fun committedAsPaste(text: String): Boolean =
    text.any { it == '\n' || it == '\r' || it == '\t' } || text.codePointCount(0, text.length) >= TERMINAL_PASTE_FROM

/** True when a replacement of the keyboard is inside the buffer. A stale offset must not turn a replacement into an append. */
internal fun imeReplacementInBounds(start: Int, end: Int, length: Int): Boolean =
    start in 0..length && end in 0..length

/** One edit of the typed line: delete [backspaces] code points at the end, then type [text]. */
internal data class LineEdit(val backspaces: Int, val text: String)

/**
 * The edit that changes the typed line [old] into [new]. A program deletes
 * one code point for each backspace, so the count is in code points. The
 * common part never ends inside a surrogate pair, so the new text never
 * starts with half of an emoji.
 */
internal fun lineEdit(old: String, new: String): LineEdit {
    var common = 0
    val max = minOf(old.length, new.length)
    while (common < max && old[common] == new[common]) common++
    if (common > 0 && Character.isHighSurrogate(old[common - 1])) common--
    return LineEdit(old.codePointCount(common, old.length), new.substring(common))
}

/**
 * The text that the phone typed on the current line of the program, as the
 * program got it. A correction of the keyboard becomes backspaces and the
 * new text. Each send returns false when the event did not go out. The
 * line is then empty, because the state of the program is not known.
 */
internal class SentLine {
    var text = ""
        private set

    /** Sends the edit from [text] to [cur]. Returns false when an event did not go out. */
    fun sync(cur: String, key: (String) -> Boolean, type: (String) -> Boolean, paste: (String) -> Boolean): Boolean {
        val edit = lineEdit(text, cur)
        var ok = true
        repeat(edit.backspaces) { if (ok) ok = key("backspace") }
        if (ok && edit.text.isNotEmpty()) ok = if (committedAsPaste(edit.text)) paste(edit.text) else type(edit.text)
        text = if (ok) cur else ""
        return ok
    }

    fun reset() {
        text = ""
    }
}

/**
 * The named key of a key code, or null. Shift with Tab is Shift+Tab. Only
 * these keys go to the program as keys. Other keys type their character.
 */
internal fun terminalKeyName(keyCode: Int, shift: Boolean): String? = when (keyCode) {
    KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "enter"
    KeyEvent.KEYCODE_TAB -> if (shift) "shift+tab" else "tab"
    KeyEvent.KEYCODE_DEL -> "backspace"
    KeyEvent.KEYCODE_ESCAPE -> "esc"
    KeyEvent.KEYCODE_DPAD_UP -> "up"
    KeyEvent.KEYCODE_DPAD_DOWN -> "down"
    KeyEvent.KEYCODE_DPAD_LEFT -> "left"
    KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
    else -> null
}

/**
 * The live terminal of a herdr pane. It draws the ANSI frames of the
 * pane in xterm.js inside a WebView. The view measures the grid that fits
 * the phone and gives it to [onGrid]. In control mode, the computer
 * resizes the pane to that grid, so the program draws its screen for the
 * phone. The page is part of the app and loads nothing from the network,
 * so the terminal content never reaches a browser and no terminal query
 * goes back to the program.
 *
 * The touches of the page come back here: one finger scrolls the
 * terminal of the computer while [control] is on and pans the view
 * otherwise, two fingers zoom and pan locally, and a wheel step goes out
 * through [onWheel]. While the keyboard shows, a change of the view
 * height keeps the grid on the computer, and the view shows the bottom
 * rows of the grid. With [sample], the view draws that screen and opens
 * no stream, for screenshots. When the renderer of the page stops, the
 * view goes away and [onGone] runs, so that the app keeps its process.
 * While [inputReady] is true, the phone keyboard types into [input].
 */
@Composable
internal fun HerdrTerminalView(
    feeder: TerminalFeeder,
    session: HerdrTerminalSession?,
    onReady: () -> Unit,
    modifier: Modifier = Modifier,
    sample: TerminalSample? = null,
    control: Boolean = false,
    theme: OmarchyTheme? = null,
    onWheel: (column: Int, row: Int, direction: String) -> Unit = { _, _, _ -> },
    onGrid: (cols: Int, rows: Int) -> Unit = { _, _ -> },
    onDrawn: (session: String) -> Unit = {},
    inputEnabled: Boolean = true,
    onTap: (column: Int, row: Int) -> Unit = { _, _ -> },
    onGone: () -> Unit = {},
    inputReady: Boolean = false,
    imageReady: Boolean = false,
    input: TerminalInput? = null,
) {
    feeder.onReady = {
        if (sample != null) feeder.draw(sample) else onReady()
    }
    feeder.onGone = onGone
    feeder.onWheel = onWheel
    feeder.onTap = onTap
    feeder.onGrid = onGrid
    feeder.onDrawn = onDrawn
    feeder.control = control
    feeder.inputEnabled = inputEnabled
    // The keyboard takes height from the view while it shows or moves.
    val ime = WindowInsets.ime
    val density = LocalDensity.current
    val keyboard by remember(ime, density) { derivedStateOf { ime.getBottom(density) > 0 } }
    feeder.keepRows = keyboard
    // After the keyboard closed, the grid fits the full height again.
    LaunchedEffect(keyboard) { if (!keyboard) feeder.prepare() }
    // The theme of the computer colors the default and indexed colors of
    // the frames. The page takes it before the first frame and on each change.
    DisposableEffect(theme) {
        feeder.setTheme(theme)
        onDispose { }
    }
    AndroidView(
        modifier = modifier.semantics {
            // With TalkBack on, the page shows the rows of the terminal to
            // TalkBack, and a description would hide them.
            if (!feeder.reader) {
                contentDescription = "The terminal of ${session?.pane ?: "the pane"}. " +
                    if (control) "This phone controls it." else "This phone only shows it."
            }
        },
        factory = { context -> feeder.view(context) },
        update = { view ->
            // The gate and the input come from the current composition, not
            // from the factory. A stale capture then cannot type into a
            // terminal that lost control or changed session.
            val editor = view as TerminalWebView
            editor.input = input
            editor.inputReady = inputReady
            editor.imageReady = imageReady
            input?.editor = editor
        },
        onRelease = { view ->
            val editor = view as TerminalWebView
            // A moved view can already serve a new node. Only this view lets go of its own input.
            if (input?.editor === editor) input.editor = null
            editor.input = null
            editor.closeKeyboard()
        },
    )
}

/**
 * The typed input of the terminal on screen. The Live view fills its
 * senders, and the key row and the terminal view call it. [ready] gates
 * each action, and each sender checks the session again when it sends, so
 * a late callback cannot type into a session that lost control or changed.
 */
internal class TerminalInput {
    var ready by mutableStateOf(false)

    /** True while the computer also accepts a bracketed paste. */
    var pasteReady by mutableStateOf(false)

    /** True while the computer also accepts an image to paste. */
    var imageReady by mutableStateOf(false)

    /**
     * True after text went to the input of the agent with no Enter after
     * it. Live can end while that text still waits there.
     */
    var unsent by mutableStateOf(false)

    var onText: ((String) -> Boolean)? = null
    var onKey: ((String) -> Boolean)? = null
    var onPaste: ((String) -> Boolean)? = null
    var onImage: ((Uri, () -> Unit) -> Boolean)? = null

    /** The terminal view on screen, or null. */
    var editor: TerminalWebView? = null

    /** Types [text] on the computer. Returns false when it did not go out. */
    fun type(text: String): Boolean {
        if (!ready || text.isEmpty()) return false
        val sent = onText?.invoke(text) == true
        if (sent) unsent = true
        return sent
    }

    /** Sends the named key [name]. Returns false when it did not go out. */
    fun send(name: String): Boolean {
        if (!ready) return false
        val sent = onKey?.invoke(name) == true
        if (sent && name == "enter") unsent = false
        return sent
    }

    /** Pastes [text] as one bracketed paste. Returns false when it did not go out. */
    fun paste(text: String): Boolean {
        if (!ready || text.isEmpty()) return false
        // A computer without the paste capability keeps the typing path.
        // That path refuses a block with a line break.
        if (!pasteReady) return type(text)
        val sent = onPaste?.invoke(text) == true
        if (sent) unsent = true
        return sent
    }

    /**
     * Pastes the image at [uri] in the active session. The phone turns it
     * into a PNG, and the computer puts it on its clipboard and pastes it.
     * [release] ends the read grant of the keyboard. It runs once, also
     * when the image does not go out. Returns false when the image did not
     * go out.
     */
    fun pasteImage(uri: Uri, release: () -> Unit): Boolean {
        val sent = ready && imageReady && onImage?.invoke(uri, release) == true
        if (!sent) release()
        return sent
    }

    /** Presses a key of the key row. Text that waits in the keyboard goes first. */
    fun key(name: String): Boolean = press { send(name) }

    /**
     * Types the digit of a choice tile. Text that waits in the keyboard goes
     * first. The dialog takes the digit, so no text waits in the input.
     */
    fun choose(digit: String): Boolean = press { onText?.invoke(digit) == true }

    /**
     * Runs [action], which can change the line of the program, for example
     * a tap on the terminal. While typing is on, the text that waits in the
     * keyboard goes first, and the typed line starts again after it.
     */
    fun lineAction(action: () -> Boolean): Boolean {
        val e = editor
        return if (ready && e != null) e.press(action) else action()
    }

    /** Forgets the typed line, for example after the computer refused an event. */
    fun forget() {
        editor?.resetLine()
    }

    /** Shows the phone keyboard. Android hides it again. */
    fun showKeyboard() {
        if (ready) editor?.showKeyboard()
    }

    private fun press(action: () -> Boolean): Boolean {
        if (!ready) return false
        return lineAction(action)
    }
}

/**
 * The terminal WebView that also takes the phone keyboard. The page only
 * draws. The keyboard text comes here and goes to the computer through
 * [input]. The view keeps the typed line of the program, so a correction
 * of the keyboard can replace text that the phone already sent.
 *
 * The typed line starts again after each key or tap that changes the line
 * on the computer: Enter, Esc, Tab, an arrow, a tap, a choice, an image,
 * and a paste with a line break. A correction then reaches only the text
 * typed since then, and it cannot delete text that the program changed.
 */
internal class TerminalWebView(context: Context) : WebView(context) {
    /** The typed input that the keyboard text goes to, or null. */
    var input: TerminalInput? = null

    /** True while the terminal may take typed input. */
    var inputReady: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            // Android refuses the input connection while the terminal is
            // not ready, and it does not build one later on its own. The
            // keyboard then shows with no way to type. So the input starts
            // again when the terminal becomes ready. When the terminal stops
            // taking input, the keyboard hides and the typed line starts
            // again, because the program can change while the phone waits.
            if (value) {
                refreshInput()
            } else {
                resetLine()
                hideKeyboard()
            }
        }

    /**
     * True while the computer also accepts an image paste. The keyboard
     * reads the accepted content types when the input connection is built,
     * so a change starts the input again while the keyboard shows.
     */
    var imageReady: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            if (value) refreshInput()
        }

    private var connection: TerminalInputConnection? = null

    /** The typed line that the connections of this view share. A new connection starts from it. */
    private val line = SentLine()

    /** The input manager of this view. */
    private fun imm(): InputMethodManager? =
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager

    /** Builds the input connection again while the keyboard shows on this view. */
    fun refreshInput() {
        val manager = imm() ?: return
        if (manager.isActive(this)) manager.restartInput(this)
    }

    /** Shows the phone keyboard. The view takes focus first, because Android ignores showSoftInput() for a view that it does not serve. */
    fun showKeyboard() {
        if (!keyboardMayOpen(inputReady, isFocusableInTouchMode) || !requestFocus()) return
        // The post lets the focus change reach the input manager first.
        // restartInput builds the connection of a view that was served
        // without one.
        post {
            if (inputReady && hasFocus()) {
                val manager = imm() ?: return@post
                manager.restartInput(this)
                manager.showSoftInput(this, 0)
            }
        }
    }

    /** Hides the keyboard and drops the focus. */
    fun hideKeyboard() {
        clearFocus()
        windowToken?.let { imm()?.hideSoftInputFromWindow(it, 0) }
    }

    /** Hides the keyboard and forgets the typed line. Only for a view that goes away. */
    fun closeKeyboard() {
        connection?.clearContent()
        line.reset()
        hideKeyboard()
    }

    /**
     * Forgets the typed line. The keyboard learns that the line is empty,
     * so it drops its own copy of the text too. The input connection stays,
     * so a key that the user types next is not lost.
     */
    fun resetLine() {
        connection?.clearContent()
        line.reset()
    }

    /**
     * Runs [action] as one press of the user. The text that waits in the
     * keyboard composition goes first, so a key cannot pass a word that the
     * user typed before it. The typed line then starts again.
     */
    fun press(action: () -> Boolean): Boolean {
        connection?.flush()
        val sent = action()
        resetLine()
        return sent
    }

    /** Presses the named key [name]. Backspace edits the typed line instead. */
    private fun pressKey(name: String): Boolean {
        val i = input ?: return false
        if (name == "backspace") {
            return connection?.deleteBack() ?: i.send(name)
        }
        return press { i.send(name) }
    }

    /**
     * Handles one key event of a keyboard. A named key goes to the program,
     * Backspace edits the typed line, and a key with a character types it.
     * A key with Ctrl or Meta goes on to the WebView. With Alt, only a
     * character goes out, because AltGr is the right Alt key and types the
     * characters such as @ and { on many layouts. Returns true when the key
     * was used.
     */
    @Suppress("DEPRECATION")
    fun handleKey(event: KeyEvent): Boolean {
        if (event.isCtrlPressed || event.isMetaPressed) return false
        val name = terminalKeyName(event.keyCode, event.isShiftPressed).takeUnless { event.isAltPressed }
        return when (event.action) {
            KeyEvent.ACTION_DOWN -> if (name != null) {
                pressKey(name)
                true
            } else {
                typeKey(event)
            }
            KeyEvent.ACTION_UP -> name != null || keyChar(event) != null
            KeyEvent.ACTION_MULTIPLE -> {
                val chars = event.characters
                if (event.keyCode == KeyEvent.KEYCODE_UNKNOWN && !chars.isNullOrEmpty()) {
                    typeKeyText(chars)
                    true
                } else {
                    false
                }
            }
            else -> false
        }
    }

    /** The character of a key event, or null. A dead key for an accent has none here. */
    private fun keyChar(event: KeyEvent): String? {
        val c = event.unicodeChar
        if (c == 0 || c and KeyCharacterMap.COMBINING_ACCENT != 0) return null
        return String(Character.toChars(c))
    }

    /**
     * Types the character of a key event. Some keyboards send digits as
     * key events, for example AOSP LatinIME when it does not compose. A
     * hardware keyboard sends each key so.
     */
    private fun typeKey(event: KeyEvent): Boolean {
        val text = keyChar(event) ?: return false
        typeKeyText(text)
        return true
    }

    private fun typeKeyText(text: String) {
        val c = connection
        if (c != null) c.typeKey(text) else input?.type(text)
    }

    /**
     * A hardware keyboard sends its keys to the focused view. WebView would
     * give them to the page, which takes no input, so the terminal takes
     * them first.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (inputReady && hasFocus() && handleKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onCheckIsTextEditor(): Boolean = inputReady

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        // The text that waits in the old connection goes out first, so the
        // new connection starts from the full typed line.
        connection?.flush()
        if (!inputReady) {
            connection = null
            return null
        }
        // The terminal asks for plain input. Some keyboards still offer
        // suggestions, and the connection turns their replacements into
        // edits of the typed line. The keyboard does not learn what the
        // user types into an agent, which can be a secret.
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        // The keyboard offers its image options only for these types.
        if (imageReady) outAttrs.contentMimeTypes = TERMINAL_IMAGE_TYPES
        val c = TerminalInputConnection(this)
        connection = c
        // The keyboard starts with the typed line and its cursor at the end.
        val seed = line.text
        outAttrs.initialSelStart = seed.length
        outAttrs.initialSelEnd = seed.length
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) outAttrs.setInitialSurroundingText(seed)
        return c
    }

    /**
     * The bridge of the phone keyboard. A committed character goes out at
     * once. Composing edits wait for a short time, so a word goes out once.
     * A committed replacement goes out at once. The editable keeps the typed
     * line, so a correction becomes backspaces and the new text.
     */
    private inner class TerminalInputConnection(target: View) : BaseInputConnection(target, true) {
        // BaseInputConnection makes its own editable for a view that is not
        // a text editor. The property is nullable in the platform types.
        private val content: Editable = editable ?: Editable.Factory.getInstance().newEditable("")

        private val imeHandler = android.os.Handler(android.os.Looper.getMainLooper())
        private var pendingSync: Runnable? = null
        private val composeDebounceMs = 180L

        // When the last composing word went out recently, rewrites are a
        // typing burst, so they keep waiting. A single rewrite is a tapped
        // correction, and it goes out at once.
        private var lastComposingSend = 0L
        private val composeBurstMs = 500L

        init {
            // The keyboard asks for the text before the cursor to correct a
            // word. So the editable starts with the typed line.
            val seed = line.text
            if (seed.isNotEmpty()) {
                content.append(seed)
                Selection.setSelection(content, content.length)
            }
        }

        /** True while the keyboard talks to this connection. An old connection sends nothing. */
        private val current: Boolean get() = this === connection

        /** Empties the editable and tells the keyboard. The caller resets the typed line. */
        fun clearContent() {
            cancelPending()
            content.clear()
            reportSelection()
        }

        /** Sends the composing text that waits now. */
        fun flush() {
            cancelPending()
            sync()
        }

        // Sends the edit between the typed line and the editable. A
        // correction becomes backspaces and the corrected word.
        private fun sync() {
            if (!current) return
            val cur = content.toString()
            val i = input
            val ok = i != null && line.sync(cur, key = { i.send(it) }, type = { i.type(it) }, paste = { i.paste(it) })
            if (!ok) {
                // An event did not go out, so the state of the program is
                // not known. The keyboard starts again with an empty line.
                clearContent()
            } else if (cur.any { it == '\n' || it == '\r' }) {
                // The program can show a paste with a line break as one
                // placeholder, so a later correction cannot count on it.
                resetLine()
            }
        }

        /** Types [text] from a key event, and tells the keyboard where the cursor moved. */
        fun typeKey(text: String) {
            cancelPending()
            // commitText would replace a composing word, so the word stays first.
            super.finishComposingText()
            pinToEnd()
            super.commitText(text, 1)
            sync()
            reportSelection()
        }

        /**
         * Deletes the code point before the cursor, or the selection, for a
         * Backspace key. On an empty line, Backspace goes to the program,
         * which can hold text that the line forgot. Returns false when the
         * key did not go out.
         */
        fun deleteBack(): Boolean {
            cancelPending()
            val i = input ?: return false
            if (content.isEmpty()) return i.send("backspace")
            val start = Selection.getSelectionStart(content).coerceIn(0, content.length)
            val end = Selection.getSelectionEnd(content).coerceIn(0, content.length)
            when {
                start != end -> content.delete(minOf(start, end), maxOf(start, end))
                end > 0 -> content.delete(Character.offsetByCodePoints(content, end, -1), end)
            }
            sync()
            reportSelection()
            return true
        }

        // Tells the keyboard about a change that it did not ask for, so its
        // own copy of the cursor stays right.
        private fun reportSelection() {
            if (!current) return
            imm()?.updateSelection(
                this@TerminalWebView,
                Selection.getSelectionStart(content),
                Selection.getSelectionEnd(content),
                getComposingSpanStart(content),
                getComposingSpanEnd(content),
            )
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
            if (!current) return false
            cancelPending()
            // A lone line break is the Return key, and a lone tab is the Tab key.
            val key = when (text.toString()) {
                "\n", "\r" -> "enter"
                "\t" -> "tab"
                else -> null
            }
            if (key != null) {
                pressKey(key)
                return true
            }
            pinToEnd()
            super.commitText(text, newCursorPosition)
            sync()
            return true
        }

        /**
         * The Return key of the keyboard. The editor names no action, so
         * the keyboard calls this for Return. The pending text goes first,
         * then Enter, and then the line starts again.
         */
        override fun performEditorAction(actionCode: Int): Boolean {
            if (!current) return false
            pressKey("enter")
            return true
        }

        /**
         * Some keyboards report a correction here before they replace the
         * word. The call changes no text, so it only sends a pending
         * composing edit at once.
         */
        override fun commitCorrection(info: CorrectionInfo): Boolean {
            cancelPending()
            val ok = super.commitCorrection(info)
            sync()
            return ok
        }

        /**
         * A tapped correction on newer Android. The keyboard replaces the
         * word here, not through commitText or the composing calls, so the
         * fix goes out at once. The range uses the real selection, so it is
         * not moved to the end, and the diff of the whole line sends the
         * result exactly.
         */
        override fun replaceText(
            start: Int,
            end: Int,
            text: CharSequence,
            newCursorPosition: Int,
            attrs: TextAttribute?,
        ): Boolean {
            cancelPending()
            if (!imeReplacementInBounds(start, end, content.length)) {
                return false
            }
            val ok = super.replaceText(start, end, text, newCursorPosition, attrs)
            sync()
            return ok
        }

        override fun commitContent(
            inputContentInfo: InputContentInfo,
            flags: Int,
            opts: Bundle?,
        ): Boolean {
            if (!current) return false
            val mime = inputContentInfo.description.getMimeType(0) ?: return false
            if (mime !in TERMINAL_IMAGE_TYPES) return false
            // The keyboard grants a read of the content for this paste only.
            // HerdrSync ends the grant after the read.
            if (flags and InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION != 0) {
                try {
                    inputContentInfo.requestPermission()
                } catch (_: Exception) {
                    return false
                }
            }
            val i = input
            if (i == null) {
                inputContentInfo.releasePermission()
                return false
            }
            // The text typed before the image goes first. The image then
            // puts an attachment in the line, so the line starts again.
            return press { i.pasteImage(inputContentInfo.contentUri) { inputContentInfo.releasePermission() } }
        }

        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
            cancelPending()
            pinToEnd()
            super.setComposingText(text, newCursorPosition)
            // A rewrite of sent text after a pause is a tapped correction,
            // so it shows at once like a completion. Inside a burst it is
            // still typing, so it waits. The settled word then goes out once,
            // and a smart prompt does not get a storm of rewrites.
            if (lineEdit(line.text, content.toString()).backspaces > 0) {
                val now = android.os.SystemClock.uptimeMillis()
                if (now - lastComposingSend < composeBurstMs) {
                    scheduleSync()
                } else {
                    lastComposingSend = now
                    sync()
                }
            } else {
                scheduleSync()
            }
            return true
        }

        override fun finishComposingText(): Boolean {
            cancelPending()
            super.finishComposingText()
            sync()
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            if (!current) return false
            cancelPending()
            val left = deleteLocal(beforeLength, afterLength, codePoints = false)
            // Deletions past the start of the line refer to text on the
            // computer that the line forgot, so they go out as backspaces.
            repeat(left) { input?.send("backspace") }
            sync()
            return true
        }

        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean {
            if (!current) return false
            cancelPending()
            val left = deleteLocal(beforeLength, afterLength, codePoints = true)
            repeat(left) { input?.send("backspace") }
            sync()
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (!current) return false
            if (inputReady && handleKey(event)) return true
            return super.sendKeyEvent(event)
        }

        // Deletes from the editable only. Returns how many requested
        // deletions before the cursor fell outside the editable. The bridge
        // has no forward-delete key, so deletions after the cursor that fall
        // outside go nowhere.
        private fun deleteLocal(beforeLength: Int, afterLength: Int, codePoints: Boolean): Int {
            val e = content
            val sel = Selection.getSelectionStart(e)
            val end = Selection.getSelectionEnd(e)
            if (sel < 0 || end < 0) return beforeLength
            var start = minOf(sel, end)
            var stop = maxOf(sel, end)
            var left = beforeLength
            while (left > 0 && start > 0) {
                start = if (codePoints) Character.offsetByCodePoints(e, start, -1) else start - 1
                left--
            }
            var right = afterLength
            while (right > 0 && stop < e.length) {
                stop = if (codePoints) Character.offsetByCodePoints(e, stop, 1) else stop + 1
                right--
            }
            e.delete(start, stop)
            Selection.setSelection(e, start)
            return left
        }

        private fun cancelPending() {
            pendingSync?.let { imeHandler.removeCallbacks(it) }
            pendingSync = null
        }

        // The prompt of a terminal is edited at its end. An insert in the
        // middle of the buffer would arrive at the end of the remote line,
        // so a collapsed cursor in the middle moves to the end first. A
        // range stays where it is, because a range replacement replays
        // exactly.
        private fun pinToEnd() {
            val start = Selection.getSelectionStart(content)
            val end = Selection.getSelectionEnd(content)
            if (start == end && start >= 0 && start != content.length) {
                Selection.setSelection(content, content.length)
            }
        }

        private fun scheduleSync() {
            cancelPending()
            val task = Runnable {
                pendingSync = null
                lastComposingSend = android.os.SystemClock.uptimeMillis()
                sync()
            }
            pendingSync = task
            imeHandler.postDelayed(task, composeDebounceMs)
        }
    }
}

/**
 * Hands terminal events to the WebView on its main thread. The stream
 * delivers the events in order, and so does the handler, so the terminal
 * always sees the grid of a frame before the frame itself. The touches
 * of the page arrive here too and become wheel steps, zoom, and pan.
 */
internal class TerminalFeeder(
    /** True when TalkBack explored by touch as the terminal opened. The page then keeps its rows for TalkBack. */
    val reader: Boolean = false,
) : (String, HerdrTerminalEvent) -> Unit {
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * The computer whose terminal this feeder draws. Events of another
     * computer are dropped, so a late frame or close of one never reaches
     * the terminal of another, whose session can share the same name.
     */
    @Volatile
    var deviceId: String = ""

    /** The view that draws the terminal, or null while it is gone. */
    @Volatile
    var webView: WebView? = null

    /** Called on the main thread once the xterm page is ready for frames. */
    @Volatile
    var onReady: (() -> Unit)? = null

    /** Called on the main thread for each wheel step of a gesture. */
    @Volatile
    var onWheel: ((column: Int, row: Int, direction: String) -> Unit)? = null

    /** Called on the main thread for a tap on a cell. */
    var onTap: ((column: Int, row: Int) -> Unit)? = null

    /** Called on the main thread with the phone grid of the view. */
    @Volatile
    var onGrid: ((cols: Int, rows: Int) -> Unit)? = null

    /** Called on the main thread when the first full frame of a session shows. */
    var onDrawn: ((String) -> Unit)? = null

    /** Called on the main thread after the renderer of the page stopped and the view went away. */
    var onGone: (() -> Unit)? = null
    private var sessionId = ""

    /** True while the touches go to the gestures. Main thread. */
    var inputEnabled = true

    /** True while the keyboard shows. A change of the view height then keeps the grid. Main thread. */
    var keepRows = false

    /** The xterm theme JSON of the computer, or null while it sent none. */
    @Volatile
    private var themeJson: String? = null

    private var ready = false
    private var cols = 0
    private var rows = 0

    /** True after a full frame drew the screen. Only then can input go out. */
    private var baseline = false

    /** The touches of the page, in CSS pixels. Main thread only. */
    val gestures = TerminalGestures(
        onWheel = { column, row, direction ->
            // The gesture is already control-only. A screen that has no
            // first full frame yet takes no input either.
            if (baseline) onWheel?.invoke(column, row, direction)
        },
        onFont = { size, x, y -> eval("FluxTerminal.zoom($size, $x, $y)") },
        onPan = { dx, dy -> eval("FluxTerminal.pan($dx, $dy)") },
        onTap = { column, row ->
            if (baseline && inputEnabled) onTap?.invoke(column, row)
        },
        // The fling ticks run on the same main thread as the touches.
        post = { delay, action -> handler.postDelayed(action, delay) },
    )

    /** True while the phone controls the terminal. Main thread. */
    var control: Boolean
        get() = gestures.control
        set(value) {
            gestures.control = value
        }

    /**
     * The WebView of the page. The first call makes it. A later call
     * moves the same view to its new place, so the page keeps its state.
     * Main thread.
     */
    fun view(context: Context): WebView {
        webView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            return view
        }
        return makeView(context).also { webView = it }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun makeView(context: Context): WebView = TerminalWebView(context).apply {
        // The page paints the theme background itself.
        setBackgroundColor(android.graphics.Color.TRANSPARENT)
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = false
        // The page is part of the APK and must always be the one
        // of this build, never a cached copy.
        settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
        clearCache(true)
        // The page needs no network and no files. The assets of the app
        // still load.
        settings.blockNetworkLoads = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        // The page never goes to another address, and no link opens an app.
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

            // The renderer crashed, or the system stopped it to get memory.
            // Without this handler, Android stops the app and its links.
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                rendererGone(view)
                return true
            }
        }
        // The gestures of the terminal are its own, so the
        // browser scrolls and zooms nothing here.
        settings.setSupportZoom(false)
        settings.builtInZoomControls = false
        // Only the keyboard key focuses the view. The touch listener takes
        // each touch, so a tap does not open the keyboard.
        isFocusable = true
        isFocusableInTouchMode = TERMINAL_FOCUSABLE_IN_TOUCH_MODE
        setOnTouchListener { view, event ->
            // Claim the entire drag before the enclosing Compose
            // scroll column can intercept it and cancel the WebView.
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                view.parent?.requestDisallowInterceptTouchEvent(true)
            }
            touch(event, resources.displayMetrics.density.toDouble())
            if (event.actionMasked == MotionEvent.ACTION_UP ||
                event.actionMasked == MotionEvent.ACTION_CANCEL
            ) {
                view.parent?.requestDisallowInterceptTouchEvent(false)
                if (event.actionMasked == MotionEvent.ACTION_UP) view.performClick()
            }
            true
        }
        addJavascriptInterface(TerminalBridge(this@TerminalFeeder, reader), "FluxBridge")
        addOnLayoutChangeListener { _, left, top, right, bottom,
            oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft ||
                bottom - top != oldBottom - oldTop
            ) prepare()
        }
        loadUrl("file:///android_asset/terminal/index.html")
    }

    /** The JS page finished loading. Any thread. */
    fun pageReady() {
        handler.post {
            if (!ready) {
                ready = true
                applyTheme()
                prepare()
                onReady?.invoke()
            }
        }
    }

    /** Measures the phone grid of the view. The page gives it to [onGrid]. Main thread. */
    fun prepare() {
        val view = webView ?: return
        if (!ready || view.width == 0 || view.height == 0) return
        val density = view.resources.displayMetrics.density
        eval("FluxTerminal.prepare(${view.width / density}, ${view.height / density}, $keepRows)")
    }

    /** Sets the theme of the computer to draw default and indexed colors. Any thread. */
    fun setTheme(theme: OmarchyTheme?) {
        val json = theme?.let { terminalTheme(it).toString() }
        handler.post {
            themeJson = json
            if (ready) applyTheme()
        }
    }

    /** Sends the last theme to the page. Main thread. */
    private fun applyTheme() {
        val json = themeJson ?: return
        // The page takes the theme as a JSON string literal.
        val quoted = kotlinx.serialization.json.JsonPrimitive(json).toString()
        eval("FluxTerminal.theme($quoted)")
    }

    /** Feeds one event of the stream. Any thread. */
    override fun invoke(deviceId: String, event: HerdrTerminalEvent) {
        if (deviceId != this.deviceId) return
        handler.post {
            val view = webView ?: return@post
            if (!ready) return@post
            when (event) {
                is HerdrTerminalEvent.Opened -> {
                    sessionId = event.session
                    baseline = false
                    gestures.reset()
                    resize(view, event.width, event.height)
                }
                is HerdrTerminalEvent.Frame -> {
                    // A frame draws into its own grid, so a new size of
                    // the terminal resets it first.
                    if (event.width != cols || event.height != rows) {
                        baseline = false
                        gestures.reset()
                        resize(view, event.width, event.height)
                    }
                    val id = kotlinx.serialization.json.JsonPrimitive(sessionId).toString()
                    // The parser accepts only base64 bytes, so they cannot
                    // end the string literal.
                    view.evaluateJavascript(
                        "FluxTerminal.write('${event.bytes}', ${event.full}, $id)", null,
                    )
                }
                // The screen shows the reason. The terminal keeps its
                // last screen until a new stream opens.
                is HerdrTerminalEvent.Closed -> {
                    sessionId = ""
                    baseline = false
                    gestures.reset()
                }
            }
        }
    }

    /** Native touches on the main thread, mapped to the page's CSS pixels. */
    fun touch(event: MotionEvent, density: Double) {
        if (!inputEnabled) {
            gestures.reset()
            return
        }
        fun send(action: String, index: Int, history: Int? = null) {
            val x = history?.let { event.getHistoricalX(index, it) } ?: event.getX(index)
            val y = history?.let { event.getHistoricalY(index, it) } ?: event.getY(index)
            val time = history?.let { event.getHistoricalEventTime(it) } ?: event.eventTime
            gestures.touch(action, event.getPointerId(index), x / density, y / density, time)
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
                send("down", event.actionIndex)
            MotionEvent.ACTION_MOVE -> {
                // Android can batch several positions into one delivery.
                // Keep their original order and times, not just the last.
                for (history in 0 until event.historySize) {
                    for (index in 0 until event.pointerCount) send("move", index, history)
                }
                for (index in 0 until event.pointerCount) send("move", index)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> send("up", event.actionIndex)
            MotionEvent.ACTION_CANCEL -> {
                for (index in 0 until event.pointerCount) send("cancel", index)
                gestures.reset()
            }
        }
    }

    /** The grid of the page as it draws it. Any thread. */
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        handler.post {
            gestures.geometry = TerminalGeometry(cellW, cellH, originX, originY, cols, rows, font)
        }
    }

    /** The phone grid that the page measured. Any thread. */
    fun grid(cols: Int, rows: Int) {
        handler.post { onGrid?.invoke(cols, rows) }
    }

    /** The page drew the first full frame of [id]. Any thread. */
    fun drawn(id: String) {
        handler.post {
            webView?.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    if (id == sessionId && ready) {
                        baseline = true
                        onDrawn?.invoke(id)
                    }
                }
            })
        }
    }

    private fun resize(view: WebView, width: Int, height: Int) {
        if (width < 1 || height < 1) return
        cols = width
        rows = height
        // The page fits the grid into the view, and the layout viewport
        // of a WebView is not its visible size. Pass the real CSS size.
        val density = view.resources.displayMetrics.density
        val cssW = view.width / density
        val cssH = view.height / density
        view.evaluateJavascript("FluxTerminal.reset($width, $height, $cssW, $cssH)", null)
    }

    /** Runs one call in the page. Main thread. */
    private fun eval(js: String) {
        webView?.evaluateJavascript(js, null)
    }

    /** Draws a sample screen instead of a stream. Any thread. */
    fun draw(sample: TerminalSample) {
        handler.post {
            val view = webView ?: return@post
            if (!ready) return@post
            resize(view, sample.cols, sample.rows)
            val bytes = android.util.Base64.encodeToString(
                sample.ansi.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP,
            )
            view.evaluateJavascript("FluxTerminal.write('$bytes')", null)
        }
    }

    /**
     * Drops [view] after its renderer stopped. The view cannot draw again,
     * so it leaves the layout, and [onGone] tells the screen. Main thread.
     */
    private fun rendererGone(view: WebView) {
        val current = view === webView
        if (current) {
            webView = null
            ready = false
            baseline = false
            sessionId = ""
            gestures.reset()
        }
        (view.parent as? ViewGroup)?.removeView(view)
        view.destroy()
        if (current) onGone?.invoke()
    }

    /** Drops the view and the callbacks after the terminal is gone. */
    fun detach() {
        handler.post {
            val view = webView
            webView = null
            onReady = null
            onWheel = null
            onTap = null
            onGrid = null
            onDrawn = null
            onGone = null
            ready = false
            baseline = false
            gestures.reset()
            // The page and its renderer go away with the terminal.
            view?.let {
                (it.parent as? ViewGroup)?.removeView(it)
                it.destroy()
            }
        }
    }
}

/** The calls of the xterm page into the app. */
private class TerminalBridge(private val feeder: TerminalFeeder, private val reader: Boolean) {
    @JavascriptInterface
    fun ready(cols: Int, rows: Int) {
        feeder.pageReady()
    }

    /** True when the page must keep its rows for TalkBack. */
    @JavascriptInterface
    fun screenReader(): Boolean = reader

    @JavascriptInterface
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        feeder.geometry(cellW, cellH, originX, originY, cols, rows, font)
    }

    @JavascriptInterface
    fun grid(cols: Int, rows: Int) {
        feeder.grid(cols, rows)
    }

    @JavascriptInterface
    fun drawn(session: String) {
        feeder.drawn(session)
    }
}

/** A screen that the terminal view draws instead of a stream, for screenshots. */
data class TerminalSample(val ansi: String, val cols: Int, val rows: Int)

/**
 * Debug builds only: the sample screen of [org.omarchy.flux.core.DebugDemo]
 * for reproducible terminal screenshots, or null when none was given.
 */
internal fun terminalDebugSample(): TerminalSample? {
    val ansi = org.omarchy.flux.core.DebugDemo.terminalSample ?: return null
    val grid = org.omarchy.flux.core.DebugDemo.terminalGrid?.split('x').orEmpty()
    val cols = grid.getOrNull(0)?.toIntOrNull() ?: 100
    val rows = grid.getOrNull(1)?.toIntOrNull() ?: 30
    return TerminalSample(ansi, cols, rows)
}
