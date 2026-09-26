import Foundation

/// Reads the structured content of a code. Vision gives only the raw value,
/// so this does what ML Kit does for Flux for Android: it finds Wi-Fi
/// networks (`WIFI:`), contacts (vCard and `MECARD:`), and bookmarks
/// (`MEBKM:`).
public enum CodeContent {
    /// Returns the code with its content fields set.
    public static func parse(_ format: CodeFormat, _ raw: String) -> ScannedCode {
        let lower = raw.lowercased()
        if lower.hasPrefix("wifi:") { return ScannedCode(format, raw, wifi: wifi(raw)) }
        if lower.hasPrefix("begin:vcard") { return ScannedCode(format, raw, contact: vCard(raw)) }
        if lower.hasPrefix("mecard:") { return ScannedCode(format, raw, contact: meCard(raw)) }
        if lower.hasPrefix("mebkm:"), let url = fields(String(raw.dropFirst(6)))["URL"]?.first, !url.isEmpty {
            return ScannedCode(format, raw, url: url)
        }
        return ScannedCode(format, raw)
    }

    /// Reads `WIFI:S:<ssid>;T:<WPA|WEP|nopass>;P:<password>;;`.
    static func wifi(_ raw: String) -> WifiInfo {
        let f = fields(String(raw.dropFirst(5)))
        let type = (f["T"]?.first ?? "").uppercased()
        let security = switch type {
        case "WEP": "WEP"
        case "", "NOPASS": "open"
        default: "WPA"
        }
        return WifiInfo(ssid: f["S"]?.first ?? "", password: f["P"]?.first ?? "", security: security)
    }

    /// Reads `MECARD:N:Kim,Dan;TEL:…;EMAIL:…;ORG:…;;`. The name is "Last,First".
    static func meCard(_ raw: String) -> ContactInfo {
        let f = fields(String(raw.dropFirst(7)))
        let parts = (f["N"]?.first ?? "").split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.reversed().filter { !$0.isEmpty }.joined(separator: " ")
        return ContactInfo(name: name, phones: f["TEL"] ?? [], emails: f["EMAIL"] ?? [], organization: f["ORG"]?.first ?? "")
    }

    /// Reads the FN, N, TEL, EMAIL, and ORG lines of a vCard.
    static func vCard(_ raw: String) -> ContactInfo {
        // Folded lines continue with a space or a tab.
        let unfolded = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var fn = "", n = "", org = ""
        var phones: [String] = [], emails: [String] = []
        for line in unfolded.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            // The property name comes before any parameter, as in "TEL;TYPE=CELL".
            let key = line[..<colon].split(separator: ";").first.map { $0.uppercased() } ?? ""
            let name = key.split(separator: ".").last.map(String.init) ?? key
            let value = unescape(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            switch name {
            case "FN": fn = value
            case "N": n = value
            case "ORG": org = value.split(separator: ";").first.map(String.init) ?? value
            case "TEL" where !value.isEmpty: phones.append(value)
            case "EMAIL" where !value.isEmpty: emails.append(value)
            default: break
            }
        }
        if fn.isEmpty {
            // N is Last;First;Middle;Prefix;Suffix.
            let p = n.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            fn = [p.count > 3 ? p[3] : "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "", p.first ?? "", p.count > 4 ? p[4] : ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return ContactInfo(name: fn, phones: phones, emails: emails, organization: org)
    }

    /// Splits `KEY:value;KEY:value;;` into values by key. A backslash escapes
    /// the next character, so `\;` stays in the value.
    static func fields(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var part = ""
        var escaped = false
        func flush() {
            if let colon = part.firstIndex(of: ":") {
                let key = part[..<colon].uppercased()
                out[key, default: []].append(String(part[part.index(after: colon)...]))
            }
            part = ""
        }
        for c in text {
            if escaped {
                part.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == ";" {
                flush()
            } else {
                part.append(c)
            }
        }
        flush()
        return out
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
    }
}
