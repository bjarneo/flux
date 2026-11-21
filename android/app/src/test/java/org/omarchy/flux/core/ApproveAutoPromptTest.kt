package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApproveAutoPromptTest {
    private val nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    private fun request(kind: ApproveRequest.Kind = ApproveRequest.Kind.Approve, id: String = "req1") = ApproveRequest(
        computerId = "pc1", computerName = "omarchy-xps", id = id, kind = kind,
        host = "omarchy-xps", user = "alice", service = "sudo", tty = "/dev/pts/3", rhost = "",
        time = 1790000000, nonce = nonce, timeoutSeconds = 20,
    )

    private fun open(
        request: ApproveRequest? = request(),
        enabled: Boolean = true,
        sdk: Int = 36,
        asking: Boolean = true,
        openedId: String? = null,
    ) = ApproveAutoPrompt.shouldOpen(request, enabled, sdk, asking, openedId)

    @Test
    fun opensForAnApprovalWhenTheSettingIsOn() {
        assertTrue(open())
    }

    @Test
    fun staysOffWhenTheSettingIsOff() {
        assertFalse(open(enabled = false))
    }

    @Test
    fun neverOpensForAnEnrollment() {
        assertFalse(open(request = request(ApproveRequest.Kind.Enroll)))
    }

    @Test
    fun neverOpensWithoutARequest() {
        assertFalse(open(request = null))
    }

    @Test
    fun opensOncePerRequest() {
        assertFalse(open(openedId = "req1"))
        // A new request opens its own check.
        assertTrue(open(request = request(id = "req2"), openedId = "req1"))
    }

    @Test
    fun waitsForAnAnswerOnly() {
        assertFalse(open(asking = false))
    }

    @Test
    fun needsAndroid12ToHideOtherWindows() {
        assertFalse(open(sdk = ApproveAutoPrompt.MIN_SDK - 1))
        assertTrue(open(sdk = ApproveAutoPrompt.MIN_SDK))
    }
}
