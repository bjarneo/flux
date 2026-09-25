package org.omarchy.flux.camera

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDateTime

class CodesTest {
    @Test
    fun urlOpensOrCopies() {
        val sheet = Codes.sheet(ScannedCode(CodeFormat.QrCode, "https://omarchy.org/flux", url = "https://omarchy.org/flux"), "laptop")
        assertEquals(CodeKind.Url, sheet.kind)
        assertEquals("QR code · Link", sheet.title)
        assertEquals(listOf("Open on laptop", "Copy on laptop"), sheet.actions.map { it.verb })
        assertEquals(ShareBody.OpenUrl("https://omarchy.org/flux"), sheet.actions[0].body)
        assertEquals(ShareBody.Copy("https://omarchy.org/flux"), sheet.actions[1].body)
    }

    @Test
    fun rawUrlWithoutTypeIsALink() {
        assertEquals(CodeKind.Url, Codes.kind(ScannedCode(CodeFormat.DataMatrix, " http://192.168.1.5:8080/x ")))
        assertEquals("http://192.168.1.5:8080/x", Codes.text(ScannedCode(CodeFormat.DataMatrix, " http://192.168.1.5:8080/x ")))
    }

    @Test
    fun textSavesOrCopies() {
        val sheet = Codes.sheet(ScannedCode(CodeFormat.Aztec, "Gate B14"), "pc")
        assertEquals(CodeKind.Text, sheet.kind)
        assertEquals(listOf(ShareBody.Save("Gate B14"), ShareBody.Copy("Gate B14")), sheet.actions.map { it.body })
    }

    @Test
    fun productCodes() {
        assertEquals(CodeKind.Product, Codes.kind(ScannedCode(CodeFormat.Ean13, "7038010009457")))
        assertEquals(CodeKind.Product, Codes.kind(ScannedCode(CodeFormat.Code128, "978020137962", product = true)))
        assertEquals(CodeKind.Text, Codes.kind(ScannedCode(CodeFormat.Code128, "PKG-0925")))
        assertEquals("UPC-A · Product code", Codes.sheet(ScannedCode(CodeFormat.UpcA, "036000291452"), "pc").title)
    }

    @Test
    fun wifiBecomesReadable() {
        val code = ScannedCode(CodeFormat.QrCode, "WIFI:S:home;T:WPA;P:secret;;", wifi = WifiInfo("home", "secret", "WPA"))
        assertEquals(CodeKind.Wifi, Codes.kind(code))
        assertEquals("Wi-Fi network: home\nPassword: secret\nSecurity: WPA", Codes.text(code))
        assertEquals(CodeKind.Wifi, Codes.kind(ScannedCode(CodeFormat.QrCode, "wifi:S:open;;")))
        assertEquals("Wi-Fi network: open", Codes.text(ScannedCode(CodeFormat.QrCode, "x", wifi = WifiInfo("open", "", ""))))
    }

    @Test
    fun contactBecomesReadable() {
        val code = ScannedCode(
            CodeFormat.QrCode, "BEGIN:VCARD\nFN:Dan Kim\nEND:VCARD",
            contact = ContactInfo("Dan Kim", listOf("+47 400 00 000"), listOf("dan@example.com"), "Basecamp"),
        )
        assertEquals(CodeKind.Contact, Codes.kind(code))
        assertEquals("Dan Kim\nBasecamp\n+47 400 00 000\ndan@example.com", Codes.text(code))
        assertEquals("MECARD:N:Kim;;", Codes.text(ScannedCode(CodeFormat.QrCode, "MECARD:N:Kim;;")))
    }

    @Test
    fun bodies() {
        assertEquals(listOf("url" to "https://x.org"), ShareBody.OpenUrl("https://x.org").fields())
        assertEquals(listOf("text" to "a"), ShareBody.Copy("a").fields())
        assertEquals(listOf("text" to "a", "scan" to true), ShareBody.Save("a").fields())
    }

    @Test
    fun fileNames() {
        val t = LocalDateTime.of(2026, 9, 25, 10, 15, 0)
        assertEquals("IMG_20260925_101500.jpg", CaptureNames.photo(t))
        assertEquals("scan-20260925-101500.pdf", CaptureNames.document(t))
    }
}
