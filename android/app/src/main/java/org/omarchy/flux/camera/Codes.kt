package org.omarchy.flux.camera

import java.time.LocalDateTime
import java.time.format.DateTimeFormatter

/** The symbology of a scanned code, independent of ML Kit. */
enum class CodeFormat(val label: String) {
    QrCode("QR code"),
    DataMatrix("Data Matrix"),
    Pdf417("PDF417"),
    Aztec("Aztec"),
    Ean13("EAN-13"),
    Ean8("EAN-8"),
    UpcA("UPC-A"),
    UpcE("UPC-E"),
    Code128("Code 128"),
    Code39("Code 39"),
    Code93("Code 93"),
    Codabar("Codabar"),
    Itf("ITF"),
    Unknown("Barcode"),
}

/** What the content of a code is. */
enum class CodeKind(val label: String) { Url("Link"), Wifi("Wi-Fi network"), Contact("Contact"), Product("Product code"), Text("Text") }

/** A Wi-Fi network from a code. */
data class WifiInfo(val ssid: String, val password: String, val security: String)

/** A contact from a code. */
data class ContactInfo(val name: String, val phones: List<String>, val emails: List<String>, val organization: String)

/**
 * A code as the scanner reads it. [url], [wifi], and [contact] are set when
 * the scanner knows the content type.
 */
data class ScannedCode(
    val format: CodeFormat,
    val raw: String,
    val url: String? = null,
    val wifi: WifiInfo? = null,
    val contact: ContactInfo? = null,
    val product: Boolean = false,
)

/** The packet that an action sends. It becomes the body of kdeconnect.share.request. */
sealed interface ShareBody {
    data class OpenUrl(val url: String) : ShareBody
    data class Copy(val text: String) : ShareBody
    data class Save(val text: String) : ShareBody
}

/** Returns the fields of the kdeconnect.share.request body. */
fun ShareBody.fields(): List<Pair<String, Any?>> = when (this) {
    is ShareBody.OpenUrl -> listOf("url" to url)
    is ShareBody.Copy -> listOf("text" to text)
    is ShareBody.Save -> listOf("text" to text, "scan" to true)
}

/** A button of the result sheet. */
data class CodeAction(val verb: String, val body: ShareBody)

/** The result sheet for 1 code: the type line, the value to show, and the 2 actions. */
data class CodeSheet(val title: String, val value: String, val kind: CodeKind, val actions: List<CodeAction>)

object Codes {
    private val urlScheme = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$")

    /** Returns the kind of content in the code. */
    fun kind(code: ScannedCode): CodeKind = when {
        code.url != null || urlScheme.matches(code.raw.trim()) -> CodeKind.Url
        code.wifi != null || code.raw.startsWith("WIFI:", ignoreCase = true) -> CodeKind.Wifi
        code.contact != null || code.raw.startsWith("BEGIN:VCARD", ignoreCase = true) || code.raw.startsWith("MECARD:", ignoreCase = true) -> CodeKind.Contact
        code.product || code.format in productFormats -> CodeKind.Product
        else -> CodeKind.Text
    }

    private val productFormats = setOf(CodeFormat.Ean13, CodeFormat.Ean8, CodeFormat.UpcA, CodeFormat.UpcE)

    /**
     * Builds the result sheet. A link opens or copies on the computer.
     * Anything else saves or copies on the computer. [pc] is the computer name.
     */
    fun sheet(code: ScannedCode, pc: String): CodeSheet {
        val kind = kind(code)
        val value = text(code, kind)
        val actions = when (kind) {
            CodeKind.Url -> listOf(
                CodeAction("Open on $pc", ShareBody.OpenUrl(value)),
                CodeAction("Copy on $pc", ShareBody.Copy(value)),
            )
            else -> listOf(
                CodeAction("Save on $pc", ShareBody.Save(value)),
                CodeAction("Copy on $pc", ShareBody.Copy(value)),
            )
        }
        return CodeSheet("${code.format.label} · ${kind.label}", value, kind, actions)
    }

    /**
     * Returns the text that the computer gets. Wi-Fi and contact codes become
     * readable lines. Other codes keep their raw value.
     */
    fun text(code: ScannedCode, kind: CodeKind = kind(code)): String = when (kind) {
        CodeKind.Url -> (code.url ?: code.raw).trim()
        CodeKind.Wifi -> code.wifi?.let { w ->
            listOfNotNull(
                "Wi-Fi network: ${w.ssid}",
                w.password.takeIf { it.isNotEmpty() }?.let { "Password: $it" },
                w.security.takeIf { it.isNotEmpty() }?.let { "Security: $it" },
            ).joinToString("\n")
        } ?: code.raw
        CodeKind.Contact -> code.contact?.let { c ->
            (listOf(c.name, c.organization).filter { it.isNotEmpty() } + c.phones + c.emails).joinToString("\n").ifEmpty { code.raw }
        } ?: code.raw
        else -> code.raw
    }
}

/** The names of the files that the camera sends. */
object CaptureNames {
    private val photo = DateTimeFormatter.ofPattern("'IMG_'yyyyMMdd'_'HHmmss'.jpg'")
    private val document = DateTimeFormatter.ofPattern("'scan-'yyyyMMdd'-'HHmmss'.pdf'")

    /** Returns a photo name such as IMG_20260925_101500.jpg. */
    fun photo(time: LocalDateTime = LocalDateTime.now()): String = photo.format(time)

    /** Returns a document name such as scan-20260925-101500.pdf. */
    fun document(time: LocalDateTime = LocalDateTime.now()): String = document.format(time)
}
