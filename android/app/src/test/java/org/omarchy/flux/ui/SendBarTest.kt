package org.omarchy.flux.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SendBarTest {
    private fun source(name: String) = File("src/main/java/org/omarchy/flux/ui/$name").readText()

    @Test
    fun theBarKeysAndMoreHaveTheirOrder() {
        assertEquals(listOf("Photo", "File", "Scan", "More"), SendBarEntries.bar)
        assertEquals(listOf("Camera", "Text", "QR", "Signature"), SendBarEntries.more)
    }

    @Test
    fun theSourceBuildsTheEntriesInThatOrder() {
        val src = source("SendBar.kt")
        for (labels in listOf(SendBarEntries.bar, SendBarEntries.more)) {
            val at = labels.map { src.indexOf("\"$it\", \"") }
            assertTrue("a label is missing: $at", at.all { it >= 0 })
            assertEquals("the labels are out of order", at.sorted(), at)
        }
    }

    @Test
    fun theMenuHasGetFilesAndClearThisChatAndKeepsTheOthers() {
        val chat = source("ChatScreen.kt")
        for (label in listOf("Remote", "Get files", "Terminals", "New agent or terminal", "Clear this chat")) {
            assertTrue("The menu lost $label", chat.contains("Triple(\"$label\""))
        }
        assertFalse("The chat has no tray key", chat.contains("Photos, files, and tools"))
        assertTrue(chat.contains("Not sent. \${e.computer} is not reachable."))
        assertTrue(chat.contains("\"Retry\""))
    }

    @Test
    fun theDebugPageTrayOpensMore() {
        assertTrue(source("ChatScreen.kt").contains("if (tray) BarPanel.More"))
    }
}
