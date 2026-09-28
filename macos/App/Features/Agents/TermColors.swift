import AppKit
import FluxKit
import SwiftUI

/// The colors of the agent output: Tokyo Night in dark mode and Tokyo
/// Night Day in light mode, the colors of Omarchy and of the Android app.
/// Each color follows the appearance of the window.
enum TermColors {
    static let background = dynamic(light: 0xD8DBE5, dark: 0x1A1B26)
    static let border = dynamic(light: 0xC4C8DA, dark: 0x292E42)
    static let text = dynamic(light: 0x3760BF, dark: 0xC0CAF5)
    static let dim = dynamic(light: 0x848CB5, dark: 0x565F89)
    static let red = dynamic(light: 0xF52A65, dark: 0xF7768E)
    static let green = dynamic(light: 0x587539, dark: 0x9ECE6A)
    static let blue = dynamic(light: 0x2E7DE9, dark: 0x7AA2F7)
    static let magenta = dynamic(light: 0x9854F1, dark: 0xBB9AF7)
    static let cyan = dynamic(light: 0x007197, dark: 0x7DCFFF)

    /// The 16 theme colors of the terminal. The bright colors use the same
    /// hues. Black is the background and white is the secondary text, so
    /// both work in light mode too.
    private static let palette: [Color] = {
        let black = dynamic(light: 0xD0D5E3, dark: 0x16161E)
        let yellow = dynamic(light: 0x8C6C3E, dark: 0xE0AF68)
        let white = dynamic(light: 0x6172B0, dark: 0xA9B1D6)
        return [black, red, green, yellow, blue, magenta, cyan, white, dim, red, green, yellow, blue, magenta, cyan, text]
    }()

    /// The alpha of dim text.
    private static let dimAlpha = 0.6

    static func color(_ c: TermColor) -> Color {
        switch c {
        case .indexed(let i):
            if palette.indices.contains(i) { return palette[i] }
            return rgb(TermText.paletteRgb(i) ?? 0xC0CAF5)
        case .rgb(let v):
            return rgb(v)
        }
    }

    /// The lines as styled text in the terminal colors.
    static func attributed(_ lines: [TermLine]) -> AttributedString {
        var out = AttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            for span in line.spans { out += styled(span) }
        }
        return out
    }

    private static func styled(_ span: TermSpan) -> AttributedString {
        var a = AttributedString(span.text)
        let s = span.style
        guard s != TermStyle() else { return a }
        var fg = s.fg.map(color) ?? text
        var bg = s.bg.map(color)
        if s.inverse {
            let f = fg
            fg = bg ?? background
            bg = f
        }
        a.foregroundColor = s.dim ? fg.opacity(dimAlpha) : fg
        if let bg { a.backgroundColor = bg }
        if s.bold || s.italic {
            var font = Font.system(size: fontSize, weight: s.bold ? .bold : .regular, design: .monospaced)
            if s.italic { font = font.italic() }
            a.font = font
        }
        if s.underline { a.underlineStyle = Text.LineStyle(pattern: .solid) }
        if s.strike { a.strikethroughStyle = Text.LineStyle(pattern: .solid) }
        return a
    }

    static let fontSize: CGFloat = 12
    static let font = Font.system(size: fontSize, design: .monospaced)

    private static func rgb(_ v: Int) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

extension AgentStatus {
    var label: String {
        switch self {
        case .blocked: "Needs input"
        case .done: "Done"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .blocked: .red
        case .done: .green
        case .working: .blue
        case .idle, .unknown: .secondary
        }
    }
}

/// The status dot and the status label of an agent.
struct AgentStatusLabel: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.color)
        }
    }
}
