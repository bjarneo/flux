import FluxKit
import SwiftUI
import UIKit

/// The colors of the agent output: Tokyo Night in dark mode and Tokyo
/// Night Day in light mode, the colors of Omarchy, the Android app, and
/// the Mac app. Each color follows the appearance of the app.
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
    static let dimAlpha = 0.6

    /// The color of a terminal color. With `invert`, the colors that do not
    /// come from the theme get the opposite lightness, see `TermText.invertLightness`.
    static func color(_ c: TermColor, invert: Bool = false) -> Color {
        if case .indexed(let i) = c, palette.indices.contains(i) { return palette[i] }
        let v = TermText.fixedRgb(c) ?? 0xC0CAF5
        return rgb(invert ? TermText.invertLightness(v) : v)
    }

    static let fontSize: CGFloat = 11.5
    static let font = Font.system(size: fontSize, design: .monospaced)

    private static func rgb(_ v: Int) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
        }
        .accessibilityElement(children: .combine)
    }
}
