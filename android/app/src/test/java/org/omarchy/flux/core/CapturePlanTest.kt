package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CapturePlanTest {
    private val now = 1_800_000_000L

    private fun img(id: Long, path: String, pending: Boolean = false, added: Long = now) =
        MediaImage(id, path, "IMG_$id.jpg", pending, added)

    @Test
    fun folderRules() {
        assertEquals(CaptureKind.Screenshot, CaptureRules.kindOf("Pictures/Screenshots/"))
        assertEquals(CaptureKind.Screenshot, CaptureRules.kindOf("DCIM/Screenshots/"))
        assertEquals(CaptureKind.Screenshot, CaptureRules.kindOf("dcim/screenshots"))
        assertEquals(CaptureKind.Photo, CaptureRules.kindOf("DCIM/Camera/"))
        assertNull(CaptureRules.kindOf("Pictures/WhatsApp/"))
        assertNull(CaptureRules.kindOf("DCIM/CameraRoll/"))
        assertNull(CaptureRules.kindOf(""))
    }

    @Test
    fun onlyImagesAfterTheSwitchGoOut() {
        val state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        val plan = planCapture(state, listOf(img(9, "DCIM/Camera/"), img(11, "DCIM/Camera/")), now)
        assertEquals(listOf(11L), plan.send.map { it.first.id })
        assertEquals(CaptureKind.Photo, plan.send.single().second)
    }

    @Test
    fun aKindThatIsOffDoesNotGoOut() {
        val state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        val plan = planCapture(state, listOf(img(11, "Pictures/Screenshots/"), img(12, "Download/")), now)
        assertTrue(plan.send.isEmpty())
        assertEquals("both images need no more work", 12L, plan.state.baseline)
    }

    @Test
    fun aSentImageDoesNotGoOutAgain() {
        var state = CaptureState().enable(CaptureKind.Screenshot, newest = 10)
        val images = listOf(img(11, "Pictures/Screenshots/"))
        val first = planCapture(state, images, now)
        assertEquals(1, first.send.size)
        // The image did not go out yet, so the baseline stays before it.
        assertEquals(10L, first.state.baseline)
        state = first.state.markSent(11)
        val second = planCapture(state, images, now)
        assertTrue("a reconnect or a restart does not send again", second.send.isEmpty())
        assertEquals(11L, second.state.baseline)
        assertTrue("the baseline covers the sent image", second.state.sent.isEmpty())
    }

    @Test
    fun anUnsentImageIsTriedAgain() {
        val state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        val images = listOf(img(11, "DCIM/Camera/"), img(12, "DCIM/Camera/"))
        val first = planCapture(state, images, now)
        // No computer took 11. Only 12 went out.
        val second = planCapture(first.state.markSent(12), images, now)
        assertEquals(listOf(11L), second.send.map { it.first.id })
        assertEquals(10L, second.state.baseline)
    }

    @Test
    fun aPendingImageWaits() {
        val state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        val pending = planCapture(state, listOf(img(11, "DCIM/Camera/", pending = true), img(12, "Download/")), now)
        assertTrue(pending.send.isEmpty())
        assertEquals("the pending image stops the baseline", 10L, pending.state.baseline)
        val done = planCapture(pending.state, listOf(img(11, "DCIM/Camera/"), img(12, "Download/")), now)
        assertEquals(listOf(11L), done.send.map { it.first.id })
    }

    @Test
    fun anOldPendingImageDoesNotBlock() {
        val state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        val old = now - CaptureRules.PENDING_LIMIT_SEC - 1
        val plan = planCapture(state, listOf(img(11, "DCIM/Camera/", pending = true, added = old), img(12, "Download/")), now)
        assertEquals(12L, plan.state.baseline)
    }

    @Test
    fun aSecondSwitchStartsAtItsOwnTime() {
        var state = CaptureState().enable(CaptureKind.Photo, newest = 10)
        state = state.enable(CaptureKind.Screenshot, newest = 20)
        val plan = planCapture(state, listOf(img(15, "Pictures/Screenshots/"), img(21, "Pictures/Screenshots/")), now)
        assertEquals(listOf(21L), plan.send.map { it.first.id })
    }

    @Test
    fun turningAllOffAndOnSkipsTheGap() {
        var state = CaptureState().enable(CaptureKind.Photo, newest = 10).disable(CaptureKind.Photo)
        state = state.enable(CaptureKind.Photo, newest = 50)
        assertEquals(50L, state.baseline)
        val plan = planCapture(state, listOf(img(30, "DCIM/Camera/"), img(51, "DCIM/Camera/")), now)
        assertEquals(listOf(51L), plan.send.map { it.first.id })
    }
}
