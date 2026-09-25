package org.omarchy.flux.ui

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.SpecialKey
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** The hidden text field keeps this text, so that Backspace has a character to delete. */
private const val SENTINEL = "    "

@Composable
fun TouchpadScreen(d: DeviceUi, onBack: () -> Unit) {
    val accent = Palette.accent
    val density = LocalDensity.current.density
    var touch by remember { mutableStateOf<Offset?>(null) }
    var keyboardOpen by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    var field by remember { mutableStateOf(TextFieldValue(SENTINEL, TextRange(SENTINEL.length))) }

    Column(Modifier.fillMaxSize()) {
        TopBar("Touchpad", onBack) {
            Box(
                Modifier.clip(RoundedCornerShape(20.dp)).background(if (keyboardOpen) Palette.accentContainer else Palette.tile)
                    .clickable {
                        if (keyboardOpen) {
                            keyboard?.hide()
                            keyboardOpen = false
                        } else {
                            focus.requestFocus()
                            keyboard?.show()
                        }
                    }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) { T("Keyboard", size = 13, color = if (keyboardOpen) Palette.onAccentContainer else Palette.text) }
        }
        BasicTextField(
            value = field,
            onValueChange = { nv ->
                val t = nv.text
                when {
                    t.length > SENTINEL.length && t.startsWith(SENTINEL) -> {
                        for (ch in t.substring(SENTINEL.length)) {
                            if (ch == '\n') Plugins.special(FluxCore, d.id, SpecialKey.ENTER) else Plugins.key(FluxCore, d.id, ch.toString())
                        }
                    }
                    t.length < SENTINEL.length -> repeat(SENTINEL.length - t.length) { Plugins.special(FluxCore, d.id, SpecialKey.BACKSPACE) }
                }
                field = TextFieldValue(SENTINEL, TextRange(SENTINEL.length))
            },
            modifier = Modifier.size(1.dp).alpha(0f).focusRequester(focus).onFocusChanged { keyboardOpen = it.isFocused },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password, imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { Plugins.special(FluxCore, d.id, SpecialKey.ENTER) }),
        )
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(RoundedCornerShape(28.dp)).background(Palette.pad)
                .border(1.dp, Palette.padBorder, RoundedCornerShape(28.dp))
                .pointerInput(d.id) { touchpadGestures(d.id, density) { touch = it } },
            contentAlignment = Alignment.Center,
        ) {
            T("Tap to click\nTwo fingers to scroll\nThree fingers to switch workspace", color = Palette.hint, align = TextAlign.Center, lineHeight = 1.6f)
            touch?.let { p ->
                val r = 23.dp
                Box(
                    Modifier.align(Alignment.TopStart)
                        .offset { IntOffset((p.x - r.toPx()).roundToInt(), (p.y - r.toPx()).roundToInt()) }
                        .size(46.dp).clip(CircleShape).background(accent.copy(alpha = 0.4f)),
                )
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MouseButton("Left", RoundedCornerShape(topStart = 20.dp, bottomStart = 20.dp, topEnd = 8.dp, bottomEnd = 8.dp), Modifier.weight(1f)) {
                Plugins.click(FluxCore, d.id, "singleclick")
            }
            MouseButton("Right", RoundedCornerShape(topStart = 8.dp, bottomStart = 8.dp, topEnd = 20.dp, bottomEnd = 20.dp), Modifier.weight(1f)) {
                Plugins.click(FluxCore, d.id, "rightclick")
            }
        }
    }
}

@Composable
private fun MouseButton(label: String, shape: RoundedCornerShape, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.height(64.dp).clip(shape).background(Palette.tile).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { T(label) }
}

/**
 * The touchpad gestures. One finger moves the pointer, a tap clicks, 2
 * fingers scroll or right-click, and a 3-finger swipe switches the Omarchy
 * workspace with SUPER+TAB or SUPER+SHIFT+TAB.
 */
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.touchpadGestures(
    id: String,
    density: Float,
    onTouch: (Offset?) -> Unit,
) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val start = SystemClock.uptimeMillis()
        var maxPointers = 1
        var travel = 0f
        var moveX = 0f
        var moveY = 0f
        var scroll = 0f
        var swipe = 0f
        var switched = false
        onTouch(down.position)
        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            if (pressed.isEmpty()) break
            maxPointers = maxOf(maxPointers, pressed.size)
            val dx = pressed.map { it.position.x - it.previousPosition.x }.average().toFloat()
            val dy = pressed.map { it.position.y - it.previousPosition.y }.average().toFloat()
            travel += abs(dx) + abs(dy)
            when {
                pressed.size == 1 && maxPointers == 1 -> {
                    onTouch(pressed[0].position)
                    // Scale by density so that the pointer speed does not
                    // depend on the screen, then add acceleration.
                    val speed = (abs(dx) + abs(dy)) / density
                    val gain = 1.6f * (1f + min(speed / 12f, 1.5f))
                    moveX += dx / density * gain
                    moveY += dy / density * gain
                    if (abs(moveX) >= 1f || abs(moveY) >= 1f) {
                        Plugins.move(FluxCore, id, moveX, moveY)
                        moveX = 0f
                        moveY = 0f
                    }
                }
                pressed.size == 2 -> {
                    onTouch(null)
                    // KDE Connect sends a positive dy when the fingers move up.
                    scroll += -dy / density
                    if (abs(scroll) >= 6f) {
                        Plugins.scroll(FluxCore, id, scroll)
                        scroll = 0f
                    }
                }
                pressed.size >= 3 -> {
                    onTouch(null)
                    swipe += dx / density
                    if (!switched && abs(swipe) > 60f) {
                        switched = true
                        Plugins.special(FluxCore, id, SpecialKey.TAB, shift = swipe < 0, superKey = true)
                    }
                }
            }
            event.changes.forEach { it.consume() }
        }
        onTouch(null)
        val quick = SystemClock.uptimeMillis() - start < 250
        if (quick && travel / density < 12f) {
            when (maxPointers) {
                1 -> Plugins.click(FluxCore, id, "singleclick")
                2 -> Plugins.click(FluxCore, id, "rightclick")
            }
        }
    }
}

@Composable
fun PresentationScreen(d: DeviceUi, activity: MainActivity, onBack: () -> Unit) {
    val accent = Palette.accent
    val context = LocalContext.current
    var slide by remember { mutableIntStateOf(1) }
    var laser by remember { mutableStateOf(false) }
    val next: () -> Unit = {
        Plugins.special(FluxCore, d.id, SpecialKey.PAGE_DOWN)
        slide += 1
    }
    val previous: () -> Unit = {
        Plugins.special(FluxCore, d.id, SpecialKey.PAGE_UP)
        if (slide > 1) slide -= 1
    }
    DisposableEffect(d.id) {
        activity.volumeHandler = { up -> if (up) previous() else next() }
        onDispose { activity.volumeHandler = null }
    }
    DisposableEffect(laser) {
        if (!laser) return@DisposableEffect onDispose { }
        val sm = context.getSystemService(SensorManager::class.java)
        val gyro = sm?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                // The gyroscope gives rad/s. About 25 px per sample at 50 Hz
                // moves the pointer 1250 px for each rad/s of rotation.
                val dx = -e.values[2] * 25f
                val dy = -e.values[0] * 25f
                if (abs(dx) + abs(dy) > 0.2f) Plugins.pointer(FluxCore, d.id, dx, dy)
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (gyro != null) sm.registerListener(listener, gyro, SensorManager.SENSOR_DELAY_GAME)
        else FluxCore.toast("This phone has no gyroscope")
        onDispose {
            sm?.unregisterListener(listener)
            Plugins.stopPointer(FluxCore, d.id)
        }
    }
    Column(Modifier.fillMaxSize()) {
        TopBar("Presentation", onBack) {
            T("Slide $slide", Modifier.padding(end = 10.dp), color = Palette.secondary)
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(
                Modifier.weight(1f).heightIn(min = 200.dp).fillMaxWidth().clip(RoundedCornerShape(32.dp)).background(accent).clickable { next() },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
            ) {
                T("Next", size = 28, color = Palette.onAccent, weight = FontWeight.Medium)
                T("or press volume down", Modifier.alpha(0.7f), size = 14, color = Palette.onAccent)
            }
            Box(
                Modifier.fillMaxWidth().height(120.dp).clip(RoundedCornerShape(32.dp)).background(Palette.tile).clickable { previous() },
                contentAlignment = Alignment.Center,
            ) { T("Previous", size = 18) }
            Box(
                Modifier.fillMaxWidth().height(64.dp).clip(RoundedCornerShape(32.dp))
                    .border(1.dp, if (laser) accent else Palette.border, RoundedCornerShape(32.dp))
                    .pointerInput(Unit) {
                        detectTapGestures(onPress = {
                            laser = true
                            tryAwaitRelease()
                            laser = false
                        })
                    },
                contentAlignment = Alignment.Center,
            ) {
                T(
                    if (laser) "Laser pointer on · move the phone to aim" else "Hold for laser pointer",
                    color = if (laser) accent else Palette.laserOff,
                )
            }
        }
    }
}
