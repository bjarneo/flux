package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ShareTest {
    private val pkg = "org.omarchy.flux"

    @Test
    fun onlyHttpAndHttpsWithAHostAreLinks() {
        assertEquals("https://omarchy.org/flux?x=1#top", WebUrl.of(" https://omarchy.org/flux?x=1#top "))
        assertEquals("HTTP://Example.com", WebUrl.of("HTTP://Example.com"))
        assertEquals("http://user@192.168.1.5:8080/a", WebUrl.of("http://user@192.168.1.5:8080/a"))
        assertEquals("http://[::1]:8080/", WebUrl.of("http://[::1]:8080/"))
        for (text in listOf(
            "file:///home/me/.ssh/id_ed25519", "file://host/etc/passwd", "ftp://example.com/a", "smb://nas/share",
            "javascript://x%0aalert(1)", "https://", "http:///etc", "http://:8080/", "http://user@/", "/etc/passwd",
            "www.example.com", "https://a b", "hello", "", null,
        )) {
            assertNull(text, WebUrl.of(text))
        }
    }

    @Test
    fun installerOnlyForANewerFluxWithTheSameKey() {
        val ours = byteArrayOf(1, 2, 3)
        val theirs = byteArrayOf(9, 9, 9)
        val signedByUs = { cert: ByteArray -> cert.contentEquals(ours) }
        assertTrue(ApkCheck.isUpdate(pkg, 12, listOf(ours), pkg, 11, signedByUs))
        assertFalse("another signing key", ApkCheck.isUpdate(pkg, 12, listOf(theirs), pkg, 11, signedByUs))
        assertFalse("one of 2 signers is another key", ApkCheck.isUpdate(pkg, 12, listOf(ours, theirs), pkg, 11, signedByUs))
        assertFalse("no signer", ApkCheck.isUpdate(pkg, 12, emptyList(), pkg, 11, signedByUs))
        assertFalse("another app", ApkCheck.isUpdate("com.example.flux", 12, listOf(ours), pkg, 11, signedByUs))
        assertFalse("the same version", ApkCheck.isUpdate(pkg, 11, listOf(ours), pkg, 11, signedByUs))
        assertFalse("an archive that did not parse", ApkCheck.isUpdate(null, 12, listOf(ours), pkg, 11, signedByUs))
    }

    @Test
    fun onlyAFluxUpdateNameGetsTheFullCheck() {
        assertEquals("1.2.0", ApkCheck.updateVersion("flux-android-1.2.0.apk", 30L shl 20))
        assertNull("another app", ApkCheck.updateVersion("app-release.apk", 30L shl 20))
        assertNull("an empty file", ApkCheck.updateVersion("flux-android-1.2.0.apk", 0))
        assertNull("a file above 200 MB", ApkCheck.updateVersion("flux-android-1.2.0.apk", (200L shl 20) + 1))
    }

    @Test
    fun apkByNameOrType() {
        assertTrue(ApkCheck.isApk("flux-android-1.2.0.apk", null))
        assertTrue(ApkCheck.isApk("Invoice.APK", "application/octet-stream"))
        assertTrue(ApkCheck.isApk("invoice.pdf", "application/vnd.android.package-archive"))
        assertFalse(ApkCheck.isApk("invoice.pdf", "application/pdf"))
    }

    @Test
    fun namesLoseControlAndBidiCharacters() {
        assertEquals("invoicefdp.apk", Share.sanitize("invoice\u202Efdp.apk"))
        assertEquals("ab.txt", Share.sanitize("a\u200Eb\u2066\u2069.txt"))
        assertEquals("line.txt", Share.sanitize("li\nne\u0000.txt"))
        assertEquals("passwd", Share.sanitize("../../etc/passwd"))
        assertEquals("x.txt", Share.sanitize("C:\\temp\\x.txt"))
        assertEquals("file", Share.sanitize("\u202E\u200F"))
    }

    @Test
    fun sharedFilesAreContentOfOtherApps() {
        assertTrue(Share.acceptShared("content", "com.android.providers.media.documents", pkg, granted = false))
        assertTrue(Share.acceptShared("content", "media", pkg, granted = false))
        assertFalse("a file path opens with the rights of Flux", Share.acceptShared("file", null, pkg, granted = true))
        assertFalse("the own clipboard provider", Share.acceptShared("content", "$pkg.clipboard", pkg, granted = true))
        assertFalse("the own provider of another user", Share.acceptShared("content", "10@$pkg.clipboard", pkg, granted = true))
        assertFalse(Share.acceptShared("http", "example.com", pkg, granted = true))
        assertFalse(Share.acceptShared("content", null, pkg, granted = true))
        // Contacts and messages need a grant from the app that shares them.
        assertFalse(Share.acceptShared("content", "com.android.contacts", pkg, granted = false))
        assertTrue(Share.acceptShared("content", "com.android.contacts", pkg, granted = true))
        assertFalse(Share.acceptShared("content", "mms", pkg, granted = false))
        assertFalse(Share.acceptShared("CONTENT", "10@SMS", pkg, granted = false))
    }

    @Test
    fun cacheCleanupDeletesOnlyOldTemporaryFiles() {
        val dir = Files.createTempDirectory("flux-cache").toFile()
        try {
            val now = System.currentTimeMillis()
            val day = 24 * 60 * 60_000L
            fun file(path: String, age: Long) = File(dir, path).apply {
                parentFile?.mkdirs()
                writeText("x")
                setLastModified(now - age)
            }
            val oldSend = file("flux-send123.tmp", 2 * day)
            val newSend = file("flux-send456.tmp", 60_000)
            val oldUpdate = file("received-update1.apk", 2 * day)
            val oldPhoto = file("photos/IMG_1.jpg", 2 * day)
            val newPhoto = file("photos/IMG_2.jpg", 60_000)
            val clip = file("clipboard/clip-1.png", 2 * day)
            Share.cleanCache(dir, now)
            assertFalse(oldSend.exists())
            assertTrue(newSend.exists())
            assertFalse(oldUpdate.exists())
            assertFalse(oldPhoto.exists())
            assertTrue(newPhoto.exists())
            assertTrue("the clipboard image stays", clip.exists())
        } finally {
            dir.deleteRecursively()
        }
    }
}
