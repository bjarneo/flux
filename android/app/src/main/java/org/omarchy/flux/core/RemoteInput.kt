package org.omarchy.flux.core

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The touchpad and the keyboard of this phone for a computer, with
 * flux.mousepad.request. The computer runs the input only while its
 * remote_input setting is on. It tells the phone with flux.input.
 */
object RemoteInput {
    /** Special keys, with the specialKey numbers of flux.mousepad.request. */
    enum class Key(val code: Int, val label: String) {
        Backspace(1, "⌫"), Tab(2, "tab"), Left(4, "←"), Up(5, "↑"), Right(6, "→"), Down(7, "↓"),
        Home(10, "home"), End(11, "end"), Enter(12, "⏎"), Delete(13, "del"), Escape(14, "esc"),
    }

    /** The modifiers that the next key or text holds. */
    data class Mods(val ctrl: Boolean = false, val alt: Boolean = false, val shift: Boolean = false, val meta: Boolean = false) {
        val any: Boolean get() = ctrl || alt || shift || meta

        fun fields(): List<Pair<String, Any?>> = buildList {
            if (ctrl) add("ctrl" to true)
            if (alt) add("alt" to true)
            if (shift) add("shift" to true)
            if (meta) add("super" to true)
        }
    }

    /** The mouse buttons of a click. */
    enum class Click(val field: String) { Left("singleclick"), Right("rightclick"), Middle("middleclick") }

    fun move(dx: Float, dy: Float) = Packet(Types.MOUSEPAD_REQUEST, bodyOf("dx" to round(dx), "dy" to round(dy)))

    /** A positive [dy] scrolls down, and a positive [dx] scrolls right. */
    fun scroll(dx: Float, dy: Float) = Packet(Types.MOUSEPAD_REQUEST, bodyOf("scroll" to true, "dx" to round(dx), "dy" to round(dy)))

    fun click(c: Click) = Packet(Types.MOUSEPAD_REQUEST, bodyOf(c.field to true))

    /** Presses the left button for a drag, or releases it. */
    fun hold(down: Boolean) = Packet(Types.MOUSEPAD_REQUEST, bodyOf((if (down) "singlehold" else "singlerelease") to true))

    fun text(text: String, mods: Mods = Mods()) = Packet(Types.MOUSEPAD_REQUEST, bodyOf("key" to text, *mods.fields().toTypedArray()))

    fun key(k: Key, mods: Mods = Mods()) = Packet(Types.MOUSEPAD_REQUEST, bodyOf("specialKey" to k.code, *mods.fields().toTypedArray()))

    /** The most presses of a key in 1 packet. */
    const val MAX_REPEAT = 4096

    /** The most characters of text in 1 packet. The computer cuts a longer text. */
    private const val MAX_TEXT = 4096

    /** The longest draft, in characters, see [draft]. */
    const val MAX_DRAFT = 4000

    /**
     * The most lines of a draft. Each line and each line break is 1
     * packet, and the computer drops packets after 256 waiting actions.
     */
    const val MAX_DRAFT_LINES = 100

    /** Returns [s] without the lines after [MAX_DRAFT_LINES]. */
    fun draftLines(s: String): String {
        var breaks = 0
        for (i in s.indices) {
            if (s[i] == '\n' && ++breaks == MAX_DRAFT_LINES) return s.substring(0, i)
        }
        return s
    }

    /**
     * Presses [k] [count] times. With [repeat], 1 packet holds up to
     * [MAX_REPEAT] presses. A computer tells with keyRepeat in flux.input
     * that it reads repeat. Without it, each press is 1 packet.
     */
    fun keys(k: Key, count: Int, repeat: Boolean, mods: Mods = Mods()): List<Packet> {
        if (count <= 0) return emptyList()
        if (!repeat) return List(count) { key(k, mods) }
        return buildList {
            var left = count
            while (left > 0) {
                val n = min(left, MAX_REPEAT)
                add(if (n == 1) key(k, mods) else Packet(Types.MOUSEPAD_REQUEST, bodyOf("specialKey" to k.code, "repeat" to n, *mods.fields().toTypedArray())))
                left -= n
            }
        }
    }

    /**
     * Types a draft: each line as text, and Shift+Enter between the lines,
     * so that a chat box keeps the lines in 1 message. A long line goes in
     * parts that the computer takes whole.
     */
    fun draft(s: String): List<Packet> = buildList {
        s.replace("\r\n", "\n").replace('\r', '\n').split('\n').forEachIndexed { i, line ->
            if (i > 0) add(key(Key.Enter, Mods(shift = true)))
            var start = 0
            while (start < line.length) {
                val end = if (line.codePointCount(start, line.length) <= MAX_TEXT) line.length else line.offsetByCodePoints(start, MAX_TEXT)
                add(text(line.substring(start, end)))
                start = end
            }
        }
    }

    /**
     * Puts the pointer on the position [x], [y] of the
     * remote desktop, from 0 at the top left corner to 1 at the bottom right
     * corner. The computer runs the action of the packet after the move.
     */
    fun at(x: Float, y: Float) = Packet(Types.MOUSEPAD_REQUEST, bodyOf(*at(x, y, emptyArray())))

    /** Clicks at the position [x], [y] of the remote desktop. */
    fun clickAt(c: Click, x: Float, y: Float) = Packet(Types.MOUSEPAD_REQUEST, bodyOf(*at(x, y, arrayOf(c.field to true))))

    /** Presses or releases the left button at the position [x], [y] of the remote desktop. */
    fun holdAt(down: Boolean, x: Float, y: Float) =
        Packet(Types.MOUSEPAD_REQUEST, bodyOf(*at(x, y, arrayOf((if (down) "singlehold" else "singlerelease") to true))))

    /** Scrolls at the position [x], [y] of the remote desktop. A positive [dy] scrolls down. */
    fun scrollAt(dx: Float, dy: Float, x: Float, y: Float) =
        Packet(Types.MOUSEPAD_REQUEST, bodyOf(*at(x, y, arrayOf("scroll" to true, "dx" to round(dx), "dy" to round(dy)))))

    private fun at(x: Float, y: Float, fields: Array<Pair<String, Any?>>): Array<Pair<String, Any?>> =
        arrayOf("x" to position(x), "y" to position(y), *fields)

    private fun round(v: Float): Double = (v * 100).roundToInt() / 100.0

    /** A position with 4 decimals: a step of 0.3 pixels on a 3000-pixel monitor. */
    private fun position(v: Float): Double = (v.coerceIn(0f, 1f) * 10_000).roundToInt() / 10_000.0

    /** Sends a packet to the device. It returns false when the device has no link. */
    fun send(core: FluxCore, id: String, p: Packet): Boolean = core.device(id)?.send(p) ?: false

    /**
     * The factor from a finger motion to a pointer motion, for a motion of
     * [distance] dp in 1 touch event. A slow finger moves the pointer
     * precisely, and a fast finger moves it further.
     */
    fun pointerScale(distance: Float): Float = BASE_SPEED * (1f + min(MAX_BOOST, abs(distance) / BOOST_DP))

    private const val BASE_SPEED = 1.3f
    private const val BOOST_DP = 10f
    private const val MAX_BOOST = 2f

    /**
     * The device that the volume keys control while the touchpad screen
     * shows, or null. Volume down sends Right, and volume up sends Left,
     * which moves a presentation to the next or the previous slide.
     */
    @Volatile var volumeKeysDevice: String? = null

    /** Handles a volume key. It returns true when the touchpad screen used it. */
    fun onVolumeKey(core: FluxCore, up: Boolean): Boolean {
        val id = volumeKeysDevice ?: return false
        send(core, id, key(if (up) Key.Left else Key.Right))
        return true
    }
}

/**
 * The text that the type field typed on the computer since it started. A
 * change of the field goes to the computer as backspaces and new text, see
 * [TextEdit]. A tap, a key, or a dictation moves the cursor of the
 * computer, so the field then starts again with [reset].
 */
class TypeMirror {
    /** The text that the computer has from the field. */
    var sent = ""
        private set

    /** What a change of the field does on the computer. */
    sealed interface Change {
        /** Press Backspace [backspaces] times, then type [text]. */
        data class Edit(val backspaces: Int, val text: String) : Change

        /** A modifier is held, so the new text goes as a shortcut, such as ctrl and c. The field starts again. */
        data class Shortcut(val text: String) : Change
    }

    /** Handles the new [text] of the field, without the text that the keyboard composes. */
    fun change(text: String, modsHeld: Boolean): Change {
        val edit = TextEdit.between(sent, text)
        if (modsHeld && edit.text.isNotEmpty()) {
            sent = ""
            return Change.Shortcut(edit.text)
        }
        sent = text
        return Change.Edit(edit.backspaces, edit.text)
    }

    /** Returns the backspaces that delete the text on the computer, and starts again. */
    fun clear(): Int {
        val n = sent.codePointCount(0, sent.length)
        sent = ""
        return n
    }

    /** Removes the last character, for the Backspace key. It returns false when the field typed nothing. */
    fun dropLast(): Boolean {
        if (sent.isEmpty()) return false
        sent = sent.substring(0, sent.offsetByCodePoints(sent.length, -1))
        return true
    }

    /** Forgets the text, for example after a tap on the computer. */
    fun reset() {
        sent = ""
    }
}

/**
 * The keys that change the text [old] into [new]: backspaces for the end
 * of [old] that changed, then the new end. The keyboard of the phone
 * edits a word while it composes it, and a correction replaces the word.
 */
data class TextEdit(val backspaces: Int, val text: String) {
    companion object {
        fun between(old: String, new: String): TextEdit {
            val p = old.commonPrefixWith(new).length
            return TextEdit(old.codePointCount(p, old.length), new.substring(p))
        }
    }
}
