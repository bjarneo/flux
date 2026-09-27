package org.omarchy.flux.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LanguageCatalogTest {
    private val phone = listOf("nb-NO", "en-GB", "en-US")

    @Test
    fun ordersTheSections() {
        val rows = LanguageCatalog.rows(
            installed = listOf("en-US", "de-DE", "en-GB"),
            downloading = listOf("fr-FR"),
            supported = listOf("it-IT", "en-US", "fr-FR", "es-ES", "de-DE"),
            phone = phone,
            query = "",
        )
        // The phone languages come first in their settings order, then the other languages by name.
        assertEquals(listOf("en-GB", "en-US", "de-DE", "fr-FR", "it-IT", "es-ES"), rows.map { it.tag })
        assertEquals(
            listOf(LanguageRow.State.Installed, LanguageRow.State.Installed, LanguageRow.State.Installed, LanguageRow.State.Downloading, LanguageRow.State.Available, LanguageRow.State.Available),
            rows.map { it.state },
        )
    }

    @Test
    fun aFinishedDownloadIsInstalled() {
        val rows = LanguageCatalog.rows(listOf("fr-FR"), listOf("fr-FR"), listOf("fr-FR"), phone, "")
        assertEquals(listOf(LanguageRow.State.Installed), rows.map { it.state })
    }

    @Test
    fun findsByNameOwnNameAndTag() {
        val rows = { q: String -> LanguageCatalog.rows(listOf("en-US"), emptyList(), listOf("de-DE", "fr-FR", "ja-JP"), phone, q).map { it.tag } }
        assertEquals(listOf("de-DE"), rows("germ"))
        assertEquals(listOf("de-DE"), rows("DEUTSCH"))
        assertEquals(listOf("fr-FR"), rows(" fr-fr "))
        assertEquals(emptyList<String>(), rows("klingon"))
        assertEquals(4, rows("").size)
    }

    @Test
    fun namesTheLanguage() {
        val row = LanguageCatalog.rows(emptyList(), emptyList(), listOf("de-DE"), phone, "").single()
        assertEquals("German (Germany)", row.name)
        assertEquals("Deutsch (Deutschland)", row.native)
    }

    @Test
    fun namesMandarin() {
        assertEquals("Chinese (Simplified, China)", DictationText.languageName("cmn-Hans-CN"))
        assertEquals("Chinese (Simplified, China)", DictationText.tidy("Chinese (Simplified Han,China)"))
        assertEquals("Chinese (Traditional, Taiwan)", DictationText.tidy("Chinese (Traditional Han,Taiwan)"))
    }

    @Test
    fun choosesTheAutomaticLanguage() {
        assertEquals("en-GB", LanguageCatalog.automatic(phone, listOf("en-US", "en-GB")))
        assertNull(LanguageCatalog.automatic(listOf("nb-NO"), listOf("en-US")))
    }
}
