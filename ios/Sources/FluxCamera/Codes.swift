import Foundation

/// Barcode recognition model. Port of Android `camera/Codes.kt` (`CodeFormat`,
/// `CodeKind`, `WifiInfo`, `ContactInfo`, `ScannedCode`, `ShareBody`,
/// `Codes`, `CaptureNames`).
///
/// iOS detection rides `VNDetectBarcodesRequest` + live
/// `AVCaptureMetadataOutput` (`CapturePipelines` maps their symbologies to
/// `CodeFormat`); the sheet, the desktop text, and the file names below are
/// recognizer-independent.

/// The symbology of a scanned code, independent of the recognizer.
public enum CodeFormat: String, Sendable, CaseIterable {
    case qrCode = "QR code"
    case dataMatrix = "Data Matrix"
    case pdf417 = "PDF417"
    case aztec = "Aztec"
    case ean13 = "EAN-13"
    case ean8 = "EAN-8"
    case upcA = "UPC-A"
    case upcE = "UPC-E"
    case code128 = "Code 128"
    case code39 = "Code 39"
    case code93 = "Code 93"
    case codabar = "Codabar"
    case itf = "ITF"
    case unknown = "Barcode"

    public var label: String { rawValue }
}

/// What the content of a code is.
public enum CodeKind: String, Sendable {
    case url = "Link"
    case wifi = "Wi-Fi network"
    case contact = "Contact"
    case product = "Product code"
    case text = "Text"

    public var label: String { rawValue }
}

/// A Wi-Fi network from a code.
public struct WifiInfo: Sendable, Equatable {
    public var ssid, password, security: String

    public init(ssid: String, password: String, security: String) {
        self.ssid = ssid
        self.password = password
        self.security = security
    }
}

/// A contact from a code.
public struct ContactInfo: Sendable, Equatable {
    public var name: String
    public var phones, emails: [String]
    public var organization: String

    public init(name: String, phones: [String], emails: [String], organization: String) {
        self.name = name
        self.phones = phones
        self.emails = emails
        self.organization = organization
    }
}

/// A code as the scanner reads it. `url`/`wifi`/`contact` are set when the
/// scanner knows the content type.
public struct ScannedCode: Sendable, Equatable {
    public var format: CodeFormat
    public var raw: String
    public var url: String?
    public var wifi: WifiInfo?
    public var contact: ContactInfo?
    public var product: Bool

    public init(
        format: CodeFormat, raw: String, url: String? = nil,
        wifi: WifiInfo? = nil, contact: ContactInfo? = nil, product: Bool = false
    ) {
        self.format = format
        self.raw = raw
        self.url = url
        self.wifi = wifi
        self.contact = contact
        self.product = product
    }
}

/// The packet an action sends. It becomes the body of
/// `kdeconnect.share.request`.
public enum ShareBody: Sendable, Equatable {
    case openURL(String)
    case copy(String)
    case save(String)

    /// Returns the fields of the `kdeconnect.share.request` body.
    public func fields() -> [(String, Any?)] {
        switch self {
        case .openURL(let url): return [("url", url)]
        case .copy(let text): return [("text", text)]
        case .save(let text): return [("text", text), ("scan", true)]
        }
    }
}

/// A button of the result sheet.
public struct CodeAction: Sendable, Equatable {
    public var verb: String
    public var body: ShareBody

    public init(verb: String, body: ShareBody) {
        self.verb = verb
        self.body = body
    }
}

/// The result sheet for one code: type line, value to show, and 2 actions.
public struct CodeSheet: Sendable, Equatable {
    public var title: String
    public var value: String
    public var kind: CodeKind
    public var actions: [CodeAction]

    public init(title: String, value: String, kind: CodeKind, actions: [CodeAction]) {
        self.title = title
        self.value = value
        self.kind = kind
        self.actions = actions
    }
}

public enum Codes {
    private static let productFormats: Set<CodeFormat> = [.ean13, .ean8, .upcA, .upcE]

    /// Returns the kind of content in the code.
    public static func kind(_ code: ScannedCode) -> CodeKind {
        if code.url != nil || isURL(code.raw) { return .url }
        if code.wifi != nil || code.raw.lowercased().hasPrefix("wifi:") { return .wifi }
        let lower = code.raw.lowercased()
        if code.contact != nil || lower.hasPrefix("begin:vcard") || lower.hasPrefix("mecard:") { return .contact }
        if code.product || productFormats.contains(code.format) { return .product }
        return .text
    }

    /// Builds the result sheet. A link opens or copies on the computer;
    /// anything else saves or copies. `pc` is the computer name.
    public static func sheet(_ code: ScannedCode, pc: String) -> CodeSheet {
        let k = kind(code)
        let value = text(code, kind: k)
        let actions: [CodeAction] =
            switch k {
            case .url: [
                    CodeAction(verb: "Open on \(pc)", body: .openURL(value)),
                    CodeAction(verb: "Copy on \(pc)", body: .copy(value)),
                ]
            default: [
                    CodeAction(verb: "Save on \(pc)", body: .save(value)),
                    CodeAction(verb: "Copy on \(pc)", body: .copy(value)),
                ]
            }
        return CodeSheet(title: "\(code.format.label) · \(k.label)", value: value, kind: k, actions: actions)
    }

    /// Returns the text the computer gets. Wi-Fi and contact codes become
    /// readable lines; other codes keep their raw value.
    public static func text(_ code: ScannedCode, kind: CodeKind? = nil) -> String {
        switch kind ?? self.kind(code) {
        case .url:
            return (code.url ?? code.raw).trimmingCharacters(in: .whitespacesAndNewlines)
        case .wifi:
            guard let w = code.wifi else { return code.raw }
            var lines = ["Wi-Fi network: \(w.ssid)"]
            if !w.password.isEmpty { lines.append("Password: \(w.password)") }
            if !w.security.isEmpty { lines.append("Security: \(w.security)") }
            return lines.joined(separator: "\n")
        case .contact:
            guard let c = code.contact else { return code.raw }
            let joined = ([c.name, c.organization].filter { !$0.isEmpty } + c.phones + c.emails)
                .joined(separator: "\n")
            return joined.isEmpty ? code.raw : joined
        default:
            return code.raw
        }
    }

    private static func isURL(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://\\S+$", options: .regularExpression) != nil
    }
}

/// The names of the files the camera sends.
public enum CaptureNames {
    /// Returns a photo name such as IMG_20260925_101500.jpg.
    public static func photo(_ c: DateComponents) -> String {
        String(format: "IMG_%04d%02d%02d_%02d%02d%02d.jpg",
               c.year ?? 0, c.month ?? 0, c.day ?? 0,
               c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Returns a document name such as scan-20260925-101500.pdf.
    public static func document(_ c: DateComponents) -> String {
        String(format: "scan-%04d%02d%02d-%02d%02d%02d.pdf",
               c.year ?? 0, c.month ?? 0, c.day ?? 0,
               c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
