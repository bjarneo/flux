import Foundation

/// The symbology of a scanned code, independent of Vision.
public enum CodeFormat: Sendable, CaseIterable {
    case qrCode, dataMatrix, pdf417, aztec, ean13, ean8, upcA, upcE, code128, code39, code93, codabar, itf, unknown

    public var label: String {
        switch self {
        case .qrCode: "QR code"
        case .dataMatrix: "Data Matrix"
        case .pdf417: "PDF417"
        case .aztec: "Aztec"
        case .ean13: "EAN-13"
        case .ean8: "EAN-8"
        case .upcA: "UPC-A"
        case .upcE: "UPC-E"
        case .code128: "Code 128"
        case .code39: "Code 39"
        case .code93: "Code 93"
        case .codabar: "Codabar"
        case .itf: "ITF"
        case .unknown: "Barcode"
        }
    }
}

/// What the content of a code is.
public enum CodeKind: Sendable {
    case url, wifi, contact, product, text

    public var label: String {
        switch self {
        case .url: "Link"
        case .wifi: "Wi-Fi network"
        case .contact: "Contact"
        case .product: "Product code"
        case .text: "Text"
        }
    }
}

/// A Wi-Fi network from a code.
public struct WifiInfo: Equatable, Sendable {
    public var ssid: String
    public var password: String
    public var security: String

    public init(ssid: String, password: String, security: String) {
        self.ssid = ssid
        self.password = password
        self.security = security
    }
}

/// A contact from a code.
public struct ContactInfo: Equatable, Sendable {
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public var organization: String

    public init(name: String, phones: [String], emails: [String], organization: String) {
        self.name = name
        self.phones = phones
        self.emails = emails
        self.organization = organization
    }
}

/// A code as the scanner reads it. `url`, `wifi`, and `contact` are set when
/// the content type is known.
public struct ScannedCode: Equatable, Sendable {
    public var format: CodeFormat
    public var raw: String
    public var url: String?
    public var wifi: WifiInfo?
    public var contact: ContactInfo?
    public var product: Bool

    public init(_ format: CodeFormat, _ raw: String, url: String? = nil, wifi: WifiInfo? = nil, contact: ContactInfo? = nil, product: Bool = false) {
        self.format = format
        self.raw = raw
        self.url = url
        self.wifi = wifi
        self.contact = contact
        self.product = product
    }
}

/// The packet that a code action sends: the body of flux.share.request.
public enum ShareBody: Equatable, Sendable {
    /// The computer opens the link.
    case openURL(String)
    /// The computer puts the text on its clipboard.
    case copy(String)
    /// The computer saves the text in a file in the scan folder.
    case save(String)

    /// The fields of the flux.share.request body.
    public var fields: [String: JSONValue] {
        switch self {
        case .openURL(let url): ["url": .string(url)]
        case .copy(let text): ["text": .string(text)]
        case .save(let text): ["text": .string(text), "scan": .bool(true)]
        }
    }

    public var packet: Packet { Packet(type: PacketType.share, json: fields) }
}

/// A button of the result sheet.
public struct CodeAction: Equatable, Sendable {
    public var verb: String
    public var body: ShareBody
}

/// The result sheet for 1 code: the type line, the value to show, and the 2 actions.
public struct CodeSheet: Equatable, Sendable {
    public var title: String
    public var value: String
    public var kind: CodeKind
    public var actions: [CodeAction]
}

/// Classifies scanned codes and builds what the computer gets, like Flux for Android.
public enum Codes {
    /// Returns the kind of content in the code. Only an http or https link
    /// is a link. A bookmark with another scheme, such as ftp or file, is text.
    public static func kind(_ code: ScannedCode) -> CodeKind {
        if webLink(code) != nil { return .url }
        if code.wifi != nil || code.raw.lowercased().hasPrefix("wifi:") { return .wifi }
        let lower = code.raw.lowercased()
        if code.contact != nil || lower.hasPrefix("begin:vcard") || lower.hasPrefix("mecard:") { return .contact }
        if code.product || productFormats.contains(code.format) { return .product }
        return .text
    }

    private static let productFormats: Set<CodeFormat> = [.ean13, .ean8, .upcA, .upcE]

    /// The http or https link of the code, from its bookmark or its raw value, or nil.
    private static func webLink(_ code: ScannedCode) -> String? {
        let candidates = [code.url, code.raw].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { ShareWire.isURL($0) }
    }

    /// Builds the result sheet. A link opens or copies on the computer.
    /// Anything else saves or copies on the computer. `pc` is the computer name.
    public static func sheet(_ code: ScannedCode, pc: String) -> CodeSheet {
        let kind = kind(code)
        let value = text(code, kind: kind)
        let actions: [CodeAction] = switch kind {
        case .url: [CodeAction(verb: "Open on \(pc)", body: .openURL(value)), CodeAction(verb: "Copy on \(pc)", body: .copy(value))]
        default: [CodeAction(verb: "Save on \(pc)", body: .save(value)), CodeAction(verb: "Copy on \(pc)", body: .copy(value))]
        }
        return CodeSheet(title: "\(code.format.label) · \(kind.label)", value: value, kind: kind, actions: actions)
    }

    /// Returns the text that the computer gets. Wi-Fi and contact codes become
    /// readable lines. Other codes keep their raw value.
    public static func text(_ code: ScannedCode, kind: CodeKind? = nil) -> String {
        switch kind ?? self.kind(code) {
        case .url:
            return webLink(code) ?? code.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        case .wifi:
            guard let w = code.wifi else { return code.raw }
            var lines = ["Wi-Fi network: \(w.ssid)"]
            if !w.password.isEmpty { lines.append("Password: \(w.password)") }
            if !w.security.isEmpty { lines.append("Security: \(w.security)") }
            return lines.joined(separator: "\n")
        case .contact:
            guard let c = code.contact else { return code.raw }
            let lines = [c.name, c.organization].filter { !$0.isEmpty } + c.phones + c.emails
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? code.raw : text
        case .product, .text:
            return code.raw
        }
    }
}

/// The names of the files that the camera sends.
public enum CaptureNames {
    /// Returns a photo name such as IMG_20260925_101500.jpg.
    public static func photo(_ time: Date = Date()) -> String { format("'IMG_'yyyyMMdd'_'HHmmss'.jpg'", time) }

    /// Returns a document name such as scan-20260925-101500.pdf.
    public static func document(_ time: Date = Date()) -> String { format("'scan-'yyyyMMdd'-'HHmmss'.pdf'", time) }

    /// Returns a signature name such as signature-20260925-101500.png.
    public static func signature(_ time: Date = Date()) -> String { format("'signature-'yyyyMMdd'-'HHmmss'.png'", time) }

    private static func format(_ pattern: String, _ time: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: time)
    }
}
