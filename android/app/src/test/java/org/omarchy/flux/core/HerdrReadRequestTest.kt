package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.bodyOf

class HerdrReadRequestTest {
    @Test
    fun rejectsOldRequestsAndDifferentViews() {
        val expected = HerdrReadRequest(3, "diff", "new.kt")
        val current = HerdrOutput("pane", loading = false, request = 3, view = "diff", path = "new.kt")
        assertTrue(expected.accepts(current, true))
        assertFalse(expected.accepts(current.copy(request = 2), true))
        assertFalse(expected.accepts(current.copy(view = "ansi"), true))
        assertFalse(expected.accepts(current.copy(path = "old.kt"), true))
        assertFalse(expected.accepts(current.copy(request = null), true))
    }

    @Test
    fun parsesTheResponseIdentityAndSupportsLegacyOutput() {
        val out = parseHerdrOutput(bodyOf("kind" to "output", "pane" to "pane", "request" to 3, "view" to "diff", "path" to "new.kt"))!!
        assertTrue(HerdrReadRequest(3, "diff", "new.kt").accepts(out, true))
        val legacy = HerdrOutput("pane", loading = false)
        assertTrue(HerdrReadRequest(4, "ansi", "").accepts(legacy, false))
        assertFalse(HerdrReadRequest(4, "ansi", "").accepts(legacy, true))
    }
}
