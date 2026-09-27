package org.omarchy.flux.core

import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The touchpad and the keyboard of this phone for a computer, with
 * kdeconnect.mousepad.request. The computer runs the input only while its
 * remote_input setting is on. It tells the phone with flux.input.
 */
object RemoteInput {
    /** Special keys, with the numbers that KDE Connect uses. */
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

    private fun round(v: Float): Double = (v * 100).roundToInt() / 100.0

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
