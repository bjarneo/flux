package org.omarchy.flux.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResumableTransferTest {
    @Test
    fun validatesMetadataBeforeFileAccess() {
        val id = "aabbccddeeff"
        val hash = "0".repeat(64)
        assertTrue(ResumableTransfer.valid(id, "empty.txt", 0, hash))
        for (name in listOf("../file", "folder/file", "folder\\file", ".", "..", "")) {
            assertFalse(ResumableTransfer.valid(id, name, 1, hash))
        }
        assertFalse(ResumableTransfer.valid("../bad", "file", 1, hash))
        assertFalse(ResumableTransfer.valid(id, "file", -1, hash))
        assertFalse(ResumableTransfer.valid(id, "file", 1, "not-a-hash"))
    }
}
