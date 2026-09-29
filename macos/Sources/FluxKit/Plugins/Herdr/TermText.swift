import Foundation

// Terminal text with ANSI SGR styles, for the output of a herdr agent. The
// app turns the lines into styled text. This is a port of TermText.kt of the
// Android app, so both show the same output.

/// A color of terminal text.
public enum TermColor: Sendable, Hashable {
    /// An entry of the 256-color palette. 0 to 15 are the theme colors.
    case indexed(Int)
    /// A 24-bit color as 0xRRGGBB.
    case rgb(Int)
}

/// The style of a run of terminal text. A nil color is the default color.
public struct TermStyle: Sendable, Hashable {
    public var fg: TermColor?
    public var bg: TermColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strike = false

    public init(fg: TermColor? = nil, bg: TermColor? = nil, bold: Bool = false, dim: Bool = false, italic: Bool = false,
                underline: Bool = false, inverse: Bool = false, strike: Bool = false) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strike = strike
    }
}

/// A run of text with one style.
public struct TermSpan: Sendable, Hashable {
    public var text: String
    public var style: TermStyle

    public init(_ text: String, _ style: TermStyle = TermStyle()) {
        self.text = text
        self.style = style
    }
}

/// One line of terminal text. `fill` is the background of the blank cells
/// after the text, for example the background of a panel. A nil fill is the
/// default background. Only the phone layout sets it.
public struct TermLine: Sendable, Hashable {
    public var spans: [TermSpan]
    public var fill: TermColor?

    public init(_ spans: [TermSpan], fill: TermColor? = nil) {
        self.spans = spans
        self.fill = fill
    }

    public var text: String { spans.map(\.text).joined() }
}

public enum TermText {
    private static let esc: Unicode.Scalar = "\u{1B}"
    private static let bel: Unicode.Scalar = "\u{07}"
    private static let tabWidth = 8

    /// Parses text with ANSI SGR sequences into lines of styled spans. It
    /// drops other escape sequences, carriage returns, and other control
    /// characters. It expands tabs to the next multiple of 8 columns.
    public static func parse(_ text: String) -> [TermLine] {
        let s = Array(text.unicodeScalars)
        var lines: [TermLine] = []
        var spans: [TermSpan] = []
        var run = String.UnicodeScalarView()
        var style = TermStyle()
        var column = 0

        func flush() {
            guard !run.isEmpty else { return }
            if let last = spans.last, last.style == style {
                spans[spans.count - 1].text += String(run)
            } else {
                spans.append(TermSpan(String(run), style))
            }
            run = String.UnicodeScalarView()
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case "\n":
                flush()
                lines.append(TermLine(spans))
                spans = []
                column = 0
                i += 1
            case "\t":
                let n = tabWidth - column % tabWidth
                run.append(contentsOf: repeatElement(" " as Unicode.Scalar, count: n))
                column += n
                i += 1
            case esc:
                flush()
                let next = i + 1 < s.count ? s[i + 1] : nil
                if next == "[" {
                    // CSI: parameters and intermediates, then 1 final byte from 0x40 to 0x7E.
                    var j = i + 2
                    while j < s.count && !(0x40...0x7E).contains(s[j].value) { j += 1 }
                    if j < s.count && s[j] == "m" {
                        var params = String.UnicodeScalarView()
                        params.append(contentsOf: s[(i + 2)..<j])
                        style = applySgr(style, String(params))
                    }
                    i = j + 1
                } else if next == "]" {
                    // OSC: ends with BEL or with ESC and a backslash.
                    var j = i + 2
                    while j < s.count && s[j] != bel && !(s[j] == esc && j + 1 < s.count && s[j + 1] == "\\") { j += 1 }
                    i = j < s.count && s[j] == esc ? j + 2 : j + 1
                } else if let next, "()*+".unicodeScalars.contains(next) {
                    // A character set selection, for example ESC ( B.
                    i += 3
                } else if let next, (0x30...0x7E).contains(next.value) {
                    // A 2-byte sequence, for example ESC 7 to save the cursor.
                    i += 2
                } else {
                    i += 1
                }
            default:
                if c == "\r" || c.value < 0x20 || c.value == 0x7F {
                    i += 1
                    continue
                }
                // A no-break space shows as a space.
                run.append(c == "\u{A0}" ? " " : c)
                column += 1
                i += 1
            }
        }
        flush()
        if !spans.isEmpty { lines.append(TermLine(spans)) }
        return lines
    }

    /// Applies the SGR parameters, for example "1;38;5;6", to `start`.
    static func applySgr(_ start: TermStyle, _ params: String) -> TermStyle {
        // Private and other non-SGR forms, for example ESC [ > 4 m, change nothing.
        if params.contains(where: { !"0123456789;:".contains($0) }) { return start }
        var s = start
        let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            let p = parts[i]
            if p.contains(":") {
                // The colon form keeps the color in 1 parameter, for example 38:2::215:119:87.
                s = applyColonForm(s, p.split(separator: ":", omittingEmptySubsequences: false).map(String.init))
                i += 1
                continue
            }
            let code = Int(p) ?? 0
            switch code {
            case 0: s = TermStyle()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4, 21: s.underline = true
            case 7: s.inverse = true
            case 9: s.strike = true
            case 22:
                s.bold = false
                s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 29: s.strike = false
            case 30...37: s.fg = .indexed(code - 30)
            case 39: s.fg = nil
            case 40...47: s.bg = .indexed(code - 40)
            case 49: s.bg = nil
            case 90...97: s.fg = .indexed(code - 90 + 8)
            case 100...107: s.bg = .indexed(code - 100 + 8)
            case 38, 48:
                let (color, used) = extendedColor(parts, from: i + 1)
                // An unknown color form has an unknown length, so the rest of the parameters go.
                if used == 0 { return s }
                if let color {
                    if code == 38 { s.fg = color } else { s.bg = color }
                }
                i += used
            default:
                break
            }
            i += 1
        }
        return s
    }

    /// Reads a 5;N or 2;R;G;B color that starts at `from`. It returns the
    /// color and the count of parameters that it used.
    private static func extendedColor(_ parts: [String], from: Int) -> (TermColor?, Int) {
        func int(_ i: Int) -> Int? { i < parts.count ? Int(parts[i]) : nil }
        switch from < parts.count ? parts[from] : nil {
        case "5":
            guard let n = int(from + 1), (0...255).contains(n) else { return (nil, 2) }
            return (.indexed(n), 2)
        case "2":
            let rgb = (1...3).map { int(from + $0) }
            guard let r = rgb[0], let g = rgb[1], let b = rgb[2], [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return (nil, 4) }
            return (rgbOf(r, g, b), 4)
        default:
            return (nil, 0)
        }
    }

    private static func applyColonForm(_ s: TermStyle, _ sub: [String]) -> TermStyle {
        guard let code = Int(sub[0]) else { return s }
        var s = s
        if code == 4 {
            s.underline = (sub.count > 1 ? Int(sub[1]) : nil) != 0
            return s
        }
        guard code == 38 || code == 48 else { return s }
        var color: TermColor?
        switch sub.count > 1 ? sub[1] : nil {
        case "5":
            if sub.count > 2, let n = Int(sub[2]), (0...255).contains(n) { color = .indexed(n) }
        case "2":
            // 38:2:R:G:B or 38:2:ID:R:G:B. The last 3 values are the color.
            let rgb = sub.dropFirst(2).suffix(3).map { Int($0) }
            if rgb.count == 3, let r = rgb[0], let g = rgb[1], let b = rgb[2], [r, g, b].allSatisfy({ (0...255).contains($0) }) {
                color = rgbOf(r, g, b)
            }
        default:
            break
        }
        guard let color else { return s }
        if code == 38 { s.fg = color } else { s.bg = color }
        return s
    }

    private static func rgbOf(_ r: Int, _ g: Int, _ b: Int) -> TermColor { .rgb(r << 16 | g << 8 | b) }

    /// Returns the 0xRRGGBB value of a palette entry from 16 to 255: the
    /// 6 × 6 × 6 color cube, then the 24 grays. Entries 0 to 15 come from
    /// the theme, so the result is nil for them.
    public static func paletteRgb(_ index: Int) -> Int? {
        guard (16...255).contains(index) else { return nil }
        if index >= 232 {
            let v = 8 + 10 * (index - 232)
            return v << 16 | v << 8 | v
        }
        let n = index - 16
        let levels = [0, 95, 135, 175, 215, 255]
        return levels[n / 36] << 16 | levels[n / 6 % 6] << 8 | levels[n % 6]
    }

    /// The longest rule line that the output view shows. The Android app
    /// uses the same width, so both show the same output.
    static let ruleWidth = 32

    static let ruleChars: Set<Character> = ["─", "━", "═", "-", "_", "="]

    /// Makes terminal lines fit the output view of the platform. The iPhone
    /// uses the phone layout of the Android app, see `tidyForPhone`.
    public static func tidy(_ lines: [TermLine], platform: FluxPlatform = .current) -> [TermLine] {
        platform == .phone ? tidyForPhone(lines) : tidyForWindow(lines)
    }

    /// Makes terminal lines fit the output view of the Mac. It removes the
    /// blanks at the end of each line and the empty lines at the end. It also
    /// shortens lines of box rules, because they fill the width of the terminal.
    static func tidyForWindow(_ lines: [TermLine]) -> [TermLine] {
        var out = lines.map { line -> TermLine in
            let trimmed = trimEnd(line)
            let text = trimmed.text
            if text.count > ruleWidth && text.allSatisfy({ ruleChars.contains($0) }) { return take(trimmed, ruleWidth) }
            return trimmed
        }
        while let last = out.last, last.spans.isEmpty { out.removeLast() }
        return out
    }

    private static func trimEnd(_ line: TermLine) -> TermLine {
        var spans = line.spans
        while let last = spans.last {
            var t = Substring(last.text)
            while let c = t.last, c.isWhitespace { t.removeLast() }
            if !t.isEmpty {
                spans[spans.count - 1].text = String(t)
                break
            }
            spans.removeLast()
        }
        return TermLine(spans)
    }

    static func take(_ line: TermLine, _ n: Int) -> TermLine {
        var out: [TermSpan] = []
        var left = n
        for s in line.spans {
            if left <= 0 { break }
            let t = String(s.text.prefix(left))
            out.append(TermSpan(t, s.style))
            left -= t.count
        }
        return TermLine(out, fill: line.fill)
    }

    /// Parses and tidies the output text of an agent for the platform.
    public static func lines(_ text: String, platform: FluxPlatform = .current) -> [TermLine] {
        tidy(parse(text), platform: platform)
    }
}

/// A numbered choice of a question or an approval dialog. `key` is the
/// digit that selects it.
public struct AgentChoice: Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var selected: Bool

    public init(_ key: String, _ label: String, selected: Bool = false) {
        self.key = key
        self.label = label
        self.selected = selected
    }

    public var id: String { key }

    /// How far from the end of the output the dialog can start, in lines.
    private static let scanLines = 40
    /// The last choice must be this close to the end of the output, in lines.
    private static let tailLines = 15

    /// Finds the numbered choices of the dialog at the end of the output,
    /// for example the approval dialog of Claude Code. It takes the last run
    /// of numbered lines that starts at 1 and counts up by 1. Other lines can
    /// come between the choices, for example descriptions or a rule. It
    /// returns an empty list when it finds fewer than 2 choices, or when the
    /// choices are not near the end.
    public static func find(_ lines: [String]) -> [AgentChoice] {
        let from = max(0, lines.count - scanLines)
        var hits: [(index: Int, number: Int, choice: AgentChoice)] = []
        for i in from..<lines.count {
            guard let (number, choice) = parse(lines[i]) else { continue }
            hits.append((i, number, choice))
        }
        guard let start = hits.lastIndex(where: { $0.number == 1 }) else { return [] }
        var run: [(index: Int, number: Int, choice: AgentChoice)] = []
        for h in hits[start...] {
            if h.number != run.count + 1 { break }
            run.append(h)
        }
        guard run.count >= 2, let last = run.last, last.index >= lines.count - tailLines else { return [] }
        // A single key selects a choice, so only 1 to 9 work.
        return run.map(\.choice).filter { $0.key.count == 1 }
    }

    /// Reads 1 line in the form `[❯›>] N. label` or `N) label`, with blanks
    /// before and after the marker, as the Android app does.
    private static func parse(_ line: String) -> (Int, AgentChoice)? {
        func blank(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\u{0B}" || c == "\u{0C}" || c == "\r" || c == "\n" }
        var s = Substring(line).drop(while: blank)
        var selected = false
        if let c = s.first, "❯›>".contains(c) {
            selected = true
            s = s.dropFirst().drop(while: blank)
        }
        let digits = s.prefix(while: { ("0"..."9").contains($0) })
        guard (1...2).contains(digits.count), let number = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        guard let mark = s.first, mark == "." || mark == ")" else { return nil }
        s = s.dropFirst()
        // At least 1 blank, then at least 1 more character.
        guard s.count >= 2, let space = s.first, blank(space) else { return nil }
        let label = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, AgentChoice(String(number), label, selected: selected))
    }
}
