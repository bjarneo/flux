package org.omarchy.flux.theme

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.json

class ThemeBookTest {
    private val a = SampleThemes.neon
    private val b = SampleThemes.catppuccinLatte
    private val b2 = SampleThemes.cottonCandy

    private fun ThemeBook.lastTheme() = current(null)?.theme

    @Test
    fun theFirstThemeBecomesTheLastTheme() {
        val book = ThemeBook()
        assertNull(book.current(null))
        assertTrue(book.put("A", a))
        assertEquals("A", book.lastId)
        assertEquals(a, book.lastTheme())
        assertEquals(paletteOf(a), book.current(null)?.palette)
    }

    @Test
    fun aReconnectWithTheSameThemeKeepsTheLastTheme() {
        val book = ThemeBook()
        book.put("A", a)
        // B sends its first theme. It does not take the place of the theme of A.
        assertTrue(book.put("B", b))
        assertEquals(a, book.lastTheme())
        // Both computers connect again in turns, with the same themes.
        repeat(3) {
            assertFalse(book.put("A", a))
            assertFalse(book.put("B", b))
            assertEquals(a, book.lastTheme())
            assertFalse(book.put("B", b))
            assertFalse(book.put("A", a))
            assertEquals(a, book.lastTheme())
        }
        // The theme on B changes, so B has the last theme.
        assertTrue(book.put("B", b2))
        assertEquals(b2, book.lastTheme())
        // A connects again with the same theme. The last theme stays.
        assertFalse(book.put("A", a))
        assertEquals(b2, book.lastTheme())
        assertEquals(mapOf("A" to "neon", "B" to "cotton-candy"), book.names())
    }

    @Test
    fun theComputerWithTheLastThemeCanChangeItAgain() {
        val book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        assertTrue(book.put("A", b2))
        assertEquals("A", book.lastId)
        assertEquals(b2, book.lastTheme())
    }

    @Test
    fun aColdStartRestoresTheBook() {
        val first = ThemeBook()
        first.put("A", a)
        first.put("B", b)
        first.put("B", b2)
        val saved = json.parseToJsonElement(first.toJson().toString()) as JsonObject

        val next = ThemeBook()
        next.load(saved)
        assertEquals("B", next.lastId)
        assertEquals(b2, next.lastTheme())
        assertEquals(first.current(null), next.current(null))
        assertEquals(first.names(), next.names())
        // The computers connect after the cold start and send the same themes.
        assertFalse(next.put("A", a))
        assertFalse(next.put("B", b2))
        assertEquals(b2, next.lastTheme())
    }

    @Test
    fun anUnpairOfTheLastComputerTakesTheNextTheme() {
        val book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        book.put("B", b2)
        assertFalse(book.forget("C"))
        assertTrue(book.forget("B"))
        assertEquals("A", book.lastId)
        assertEquals(a, book.lastTheme())
        assertTrue(book.forget("A"))
        assertNull(book.lastId)
        assertNull(book.current(null))
        assertTrue(book.names().isEmpty())
    }

    @Test
    fun anUnpairOfAnotherComputerKeepsTheLastTheme() {
        val book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        assertTrue(book.forget("B"))
        assertEquals(a, book.lastTheme())
    }

    @Test
    fun aScopeShowsOnlyTheThemeOfThatComputer() {
        val book = ThemeBook()
        book.put("A", a)
        book.put("B", b)
        assertEquals(a, book.current("A")?.theme)
        assertEquals(b, book.current("B")?.theme)
        // C sent no theme. The app does not draw the theme of another computer for it.
        assertNull(book.current("C"))
        assertEquals(a, book.current(null)?.theme)
    }

    @Test
    fun aLoadKeepsOnlyThePairedComputers() {
        val first = ThemeBook()
        first.put("A", a)
        first.put("B", b)
        first.put("B", b2)
        val next = ThemeBook()
        next.load(first.toJson()) { it == "A" }
        assertEquals("A", next.lastId)
        assertNull(next.current("B"))
        assertEquals(setOf("A"), next.names().keys)
    }

    @Test
    fun aLoadIgnoresWhatItCannotRead() {
        val book = ThemeBook()
        book.put("A", a)
        book.load(null)
        assertNull(book.current(null))
        val broken = json.parseToJsonElement(
            """{"last":"X","computers":[{"theme":{"colors":{"background":"#000000"}}},""" +
                """{"id":"B","theme":{"colors":{}}},{"id":"C","theme":"red"},""" +
                """{"id":"D","theme":{"name":"bare","colors":{"background":"#101010"}}}]}""",
        ) as JsonObject
        book.load(broken)
        assertEquals(setOf("D"), book.names().keys)
        // The saved last computer is not in the book, so the last entry takes its place.
        assertEquals("D", book.lastId)
    }
}
