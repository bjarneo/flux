package org.omarchy.flux.webcam

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.json

class WebcamConfigTest {
    private fun obj(s: String): JsonObject = json.parseToJsonElement(s).jsonObject

    private val caps = WebcamCaps(
        zoomMax = 8f, exposureMin = -2f, exposureMax = 2f, exposureStep = 1f / 3f,
        whiteBalance = listOf("auto", "daylight", "cloudy"), cameras = listOf("back", "front"),
    )

    @Test
    fun frameSizePerAspect() {
        assertEquals(1280 to 720, frameSize("16:9", 720))
        assertEquals(1920 to 1080, frameSize("16:9", 1080))
        assertEquals(960 to 720, frameSize("4:3", 720))
        assertEquals(1440 to 1080, frameSize("4:3", 1080))
        assertEquals(720 to 720, frameSize("1:1", 720))
        assertEquals(1080 to 1080, frameSize("1:1", 1080))
        assertEquals(720 to 1280, frameSize("9:16", 720))
        assertEquals(1080 to 1920, frameSize("9:16", 1080))
        assertEquals(1280 to 720, frameSize("wide", 720))
    }

    @Test
    fun configSizeFollowsAspectAndResolution() {
        val c = WebcamConfig(aspect = "9:16", resolution = 1080)
        assertEquals(1080, c.width)
        assertEquals(1920, c.height)
    }

    @Test
    fun bitrateScalesWithPixels() {
        assertEquals(4_000_000, bitrateFor(1280, 720))
        assertEquals(8_000_000, bitrateFor(1920, 1080))
        assertEquals(2_250_000, bitrateFor(720, 720))
        assertEquals(8_000_000, bitrateFor(1080, 1920))
    }

    @Test
    fun partialChangesOnlyItsFields() {
        val c = WebcamConfig().merged(obj("""{"brightness": 0.3, "aspect": "1:1"}"""))
        assertEquals(0.3f, c.brightness, 1e-6f)
        assertEquals("1:1", c.aspect)
        assertEquals(WebcamConfig().copy(brightness = c.brightness, aspect = "1:1"), c)
    }

    @Test
    fun partialAcceptsNumbersAsTextAndIgnoresWrongTypes() {
        val c = WebcamConfig().merged(obj("""{"zoom": "2.5", "resolution": 1080.0, "mirror": "true", "camera": "FRONT", "contrast": "x", "saturation": true, "warmth": "NaN"}"""))
        assertEquals(2.5f, c.zoom, 1e-6f)
        assertEquals(1080, c.resolution)
        assertTrue(c.mirror)
        assertEquals("front", c.camera)
        assertEquals(1f, c.contrast, 0f)
        assertEquals(1f, c.saturation, 0f)
        assertEquals(0f, c.warmth, 0f)
    }

    @Test
    fun clampKeepsValuesInsideTheCaps() {
        val c = WebcamConfig(
            aspect = "21:9", resolution = 2160, camera = "side", zoom = 50f, exposure = 5f,
            whiteBalance = "shade", brightness = 3f, contrast = -1f, saturation = 9f, warmth = -4f,
        ).clamped(caps)
        assertEquals("16:9", c.aspect)
        assertEquals(1080, c.resolution)
        assertEquals("back", c.camera)
        assertEquals(8f, c.zoom, 0f)
        assertEquals(2f, c.exposure, 1e-3f)
        assertEquals("auto", c.whiteBalance)
        assertEquals(1f, c.brightness, 0f)
        assertEquals(0f, c.contrast, 0f)
        assertEquals(2f, c.saturation, 0f)
        assertEquals(-1f, c.warmth, 0f)
    }

    @Test
    fun clampRoundsExposureToTheStepAndZoomUpToOne() {
        val c = WebcamConfig(exposure = 0.4f, zoom = 0.5f).clamped(caps)
        assertEquals(0.333f, c.exposure, 1e-6f)
        assertEquals(1f, c.zoom, 0f)
        // Clamping again changes nothing.
        assertEquals(c, c.clamped(caps))
    }

    @Test
    fun clampWithoutExposureSetsZero() {
        assertEquals(0f, WebcamConfig(exposure = 1.5f).clamped(WebcamCaps()).exposure, 0f)
    }

    @Test
    fun looseCapsKeepSavedValues() {
        val saved = WebcamConfig(camera = "front", zoom = 3f, exposure = 1f, whiteBalance = "twilight")
        assertEquals(saved, saved.clamped(WebcamCaps.LOOSE))
    }

    @Test
    fun resetKeepsShapeQualityAndCamera() {
        val c = WebcamConfig(
            aspect = "4:3", resolution = 1080, camera = "front", mirror = true, zoom = 3f, exposure = 1f,
            whiteBalance = "cloudy", brightness = 0.5f, contrast = 1.5f, saturation = 0.2f, warmth = 0.7f,
        ).reset()
        assertEquals(WebcamConfig(aspect = "4:3", resolution = 1080, camera = "front"), c)
    }

    @Test
    fun onlyANewFrameSizeRestartsTheStream() {
        val c = WebcamConfig()
        assertTrue(c.restartsStream(c.copy(aspect = "4:3")))
        assertTrue(c.restartsStream(c.copy(resolution = 1080)))
        assertFalse(c.restartsStream(c.copy(camera = "front")))
        assertFalse(c.restartsStream(c.copy(brightness = 0.4f, zoom = 2f)))
    }

    @Test
    fun jsonRoundTrip() {
        val c = WebcamConfig(aspect = "9:16", resolution = 1080, camera = "front", mirror = true, zoom = 2f, whiteBalance = "daylight", warmth = -0.25f)
        assertEquals(c, WebcamConfig().merged(obj(c.toJson().toString())))
    }

    @Test
    fun configPacketCarriesConfigAndCaps() {
        val p = Packet.parse(WebcamPackets.config(WebcamConfig(brightness = 0.3f), caps).serialize())!!
        assertEquals(Types.FLUX_WEBCAM, p.type)
        assertEquals("config", p.string("state"))
        val config = assertNotNullObj(p.obj("config"))
        assertEquals(0.3, config["brightness"].toString().toDouble(), 1e-6)
        val c = assertNotNullObj(p.obj("caps"))
        assertEquals("8.0", c["zoomMax"].toString())
        assertEquals("""["auto","daylight","cloudy"]""", c["whiteBalance"].toString())
        assertEquals("""[720,1080]""", c["resolutions"].toString())
    }

    @Test
    fun parsesConfigFromTheComputer() {
        val partial = WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "config", "config" to mapOf("brightness" to 0.3))))
        assertTrue(partial is WebcamReply.Config)
        partial as WebcamReply.Config
        assertFalse(partial.reset)
        assertEquals(0.3f, WebcamConfig().merged(partial.partial).brightness, 1e-6f)

        val reset = WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "config", "reset" to true)))
        assertEquals(WebcamReply.Config(null, true), reset)

        // A config message with neither a config nor a reset means nothing.
        assertEquals(null, WebcamReply.parse(Packet(Types.FLUX_WEBCAM, bodyOf("state" to "config"))))
    }

    private fun assertNotNullObj(o: JsonObject?): JsonObject {
        assertNotNull(o)
        return o!!
    }
}
