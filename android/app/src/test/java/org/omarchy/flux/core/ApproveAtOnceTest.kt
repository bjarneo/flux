package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApproveAtOnceTest {
    private fun open(
        enabled: Boolean = true,
        kind: ApproveRequest.Kind = ApproveRequest.Kind.Approve,
        sdk: Int = 34,
        resumed: Boolean = true,
        focused: Boolean = true,
        requestId: String = "a",
        openedFor: String? = null,
    ) = ApproveAtOnce.shouldOpen(enabled, kind, sdk, resumed, focused, requestId, openedFor)

    @Test
    fun theSwitchIsOffByDefault() {
        assertFalse(UiState().approveAtOnce)
    }

    @Test
    fun theSwitchOffNeverOpens() {
        assertFalse(open(enabled = false))
    }

    @Test
    fun anApprovalOpens() {
        assertTrue(open())
    }

    @Test
    fun anEnrollmentNeverOpens() {
        assertFalse(open(kind = ApproveRequest.Kind.Enroll))
    }

    @Test
    fun onlyAndroid12AndLaterOpens() {
        assertFalse(open(sdk = 29))
        assertFalse(open(sdk = 30))
        assertTrue(open(sdk = 31))
        assertTrue(ApproveAtOnce.supported(36))
        assertFalse(ApproveAtOnce.supported(30))
    }

    @Test
    fun theScreenMustBeResumedAndFocused() {
        assertFalse(open(resumed = false))
        assertFalse(open(focused = false))
    }

    @Test
    fun theSameRequestOpensOnce() {
        assertFalse(open(requestId = "a", openedFor = "a"))
    }

    @Test
    fun aCancelKeepsTheScreenAndOpensNoNewPromptForTheRequest() {
        // The screen sets openedFor when it opens the prompt. A cancel does not clear it.
        var openedFor: String? = null
        assertTrue(open(requestId = "a", openedFor = openedFor))
        openedFor = "a"
        assertFalse(open(requestId = "a", openedFor = openedFor))
        assertEquals("a", openedFor)
    }

    @Test
    fun aNewRequestOpensAgain() {
        assertTrue(open(requestId = "b", openedFor = "a"))
    }

    @Test
    fun theRecordOutlivesTheScreen() {
        ApproveAtOnce.resetOpened()
        assertFalse(ApproveAtOnce.wasOpened("a"))
        ApproveAtOnce.markOpened("a")
        // A new screen for the same request reads the same record.
        assertTrue(ApproveAtOnce.wasOpened("a"))
        assertFalse(ApproveAtOnce.wasOpened("b"))
        ApproveAtOnce.resetOpened()
    }

    @Test
    fun theRecordKeepsTheLast64Ids() {
        ApproveAtOnce.resetOpened()
        for (i in 0 until 65) ApproveAtOnce.markOpened("id$i")
        assertFalse(ApproveAtOnce.wasOpened("id0"))
        assertTrue(ApproveAtOnce.wasOpened("id64"))
        ApproveAtOnce.resetOpened()
    }
}
