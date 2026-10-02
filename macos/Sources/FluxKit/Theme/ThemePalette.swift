import Foundation

/// The colors of 1 Flux palette, as 0xRRGGBB. `of(_:)` makes a palette from
/// the theme of a computer, and `tokyoNight` and `tokyoNightDay` are the
/// palettes without one. It is a port of ThemePalette.kt of the Android app.
///
/// The contrast contract:
/// - `text` and `sub` reach 4.5:1 on each of the `containers`: the
///   `surfaces`, `line`, and `accentTile`.
/// - The `fills`, from `accent` to `yellow`, reach 4.5:1 as text on the
///   `surfaces` and `accentTile`. On `line`, they reach 3:1, so use them
///   there for icons and borders only.
/// - `onAccent` reaches 4.5:1 on each fill.
/// - `dim` reaches 3:1 on `bg`, `tile`, and `tileHi`. It is not for text.
/// - `termBlue` reaches 4.5:1 on the `surfaces`.
/// - Each `border` color reaches 3:1 on `bg` and `tile`.
public struct ThemePalette: Sendable, Equatable {
    /// The name of the theme, for example "tokyo-night".
    public var name: String
    public var dark: Bool
    /// The page.
    public var bg: Int
    /// A tile that is off, and the background of the agent output.
    public var offTile: Int
    public var tile: Int
    /// A tile that stands out, a menu, or a dialog.
    public var tileHi: Int
    /// The border of a tile, and a tonal container for `text` and `sub`.
    public var line: Int
    public var lineHi: Int
    /// The body ink. It is at least `textStep` away from `sub`.
    public var text: Int
    /// The second ink, for hints, labels, and placeholders.
    public var sub: Int
    /// For borders and disabled states only.
    public var dim: Int
    /// The ink on a fill of `accent` or a semantic color.
    public var onAccent: Int
    /// The primary color, for actions and selection.
    public var accent: Int
    /// A tile with the hue of `accent` and the luminance of `tileHi`, for a selected item.
    public var accentTile: Int
    public var cyan: Int
    public var green: Int
    public var magenta: Int
    public var orange: Int
    /// Red means "needs you" or an error, nothing else.
    public var red: Int
    public var yellow: Int
    /// The blue of the terminal, for ANSI blue in the agent output. The `accent` can be another color.
    public var termBlue: Int
    /// The colors of the active border gradient.
    public var border: [Int]
    /// The angle of the border gradient in degrees, as in Hyprland, or nil for corner to corner.
    public var borderAngle: Double?

    public init(name: String, dark: Bool, bg: Int, offTile: Int, tile: Int, tileHi: Int, line: Int, lineHi: Int,
                text: Int, sub: Int, dim: Int, onAccent: Int, accent: Int, accentTile: Int, cyan: Int, green: Int,
                magenta: Int, orange: Int, red: Int, yellow: Int, termBlue: Int, border: [Int], borderAngle: Double?) {
        self.name = name
        self.dark = dark
        self.bg = bg
        self.offTile = offTile
        self.tile = tile
        self.tileHi = tileHi
        self.line = line
        self.lineHi = lineHi
        self.text = text
        self.sub = sub
        self.dim = dim
        self.onAccent = onAccent
        self.accent = accent
        self.accentTile = accentTile
        self.cyan = cyan
        self.green = green
        self.magenta = magenta
        self.orange = orange
        self.red = red
        self.yellow = yellow
        self.termBlue = termBlue
        self.border = border
        self.borderAngle = borderAngle
    }

    /// The surfaces that the tiles and the page use.
    public var surfaces: [Int] { [bg, offTile, tile, tileHi] }

    /// Each color that holds `text` and `sub`: the `surfaces`, `line`, and `accentTile`.
    public var containers: [Int] { surfaces + [line, accentTile] }

    /// The fills that take `onAccent` text, in this order.
    public var fills: [Int] { [accent, cyan, green, magenta, orange, red, yellow] }

    /// The contrast that text needs, WCAG 2.2 AA.
    public static let textContrast = 4.5
    /// The contrast that icons, borders, and large text need, WCAG 2.2 AA.
    public static let nonTextContrast = 3.0
    /// The least contrast of `text` against `sub`, so that the 2 inks look different.
    public static let textStep = 1.4
    /// The least OKLAB distance of the accent from red. Below it, the accent looks like red.
    public static let minAccentDistance = 0.08

    /// The contrast of a surface step against the page: the least, the most, and the value to make.
    private struct Step {
        let least: Double
        let most: Double
        let make: Double
    }

    /// 1 choice of the accent: the `source` color of the theme, the
    /// `accentTile` that it tints, the `needs` of a fill as text with that
    /// tile, and the guarded `accent` and `red`.
    private struct AccentTrial {
        let source: Int
        let accentTile: Int
        let needs: [ContrastNeed]
        let accent: Int
        let red: Int
        var apart: Double { ColorMath.distance(accent, red) }
    }

    /// How much of the accent the accent tile takes.
    private static let accentTileMix = 0.18
    /// The least chroma of a color that replaces the accent, so that it is not a gray.
    private static let minAccentChroma = 0.05
    /// Below this background luminance, a theme is dark.
    private static let darkLuminance = 0.179
    /// The contrast of white on a dark page, or of black on a light page, at least.
    private static let bgHeadroom = 10.0
    /// The same for a tile, so that the text and the colors can reach their contrast.
    private static let tileHeadroom = 7.0
    /// The same for `line`, which holds text.
    private static let lineHeadroom = 6.0
    private static let tileDark = Step(least: 1.06, most: 1.25, make: 1.12)
    private static let hiDark = Step(least: 1.10, most: 1.40, make: 1.22)
    private static let tileLight = Step(least: 1.04, most: 1.12, make: 1.07)
    private static let hiLight = Step(least: 1.08, most: 1.20, make: 1.13)
    private static let lineMix = 0.08
    private static let lineHiMix = 0.22
    private static let subMix = 0.3
    private static let dimMix = 0.55
    /// The most chroma of the body ink in a light theme, so that it reads as a neutral.
    private static let neutralChroma = 0.045
    /// The theme colors that can replace an accent that looks like red, in order.
    private static let accentStandins = ["blue", "bright_blue", "cyan", "bright_cyan", "magenta", "bright_magenta"]

    /// A fixed palette. Only `accentTile` is computed.
    private static func spec(name: String, dark: Bool, bg: Int, offTile: Int, tile: Int, tileHi: Int, line: Int,
                             lineHi: Int, text: Int, sub: Int, dim: Int, onAccent: Int, accent: Int, cyan: Int,
                             green: Int, magenta: Int, orange: Int, red: Int, yellow: Int) -> ThemePalette {
        ThemePalette(name: name, dark: dark, bg: bg, offTile: offTile, tile: tile, tileHi: tileHi, line: line,
                     lineHi: lineHi, text: text, sub: sub, dim: dim, onAccent: onAccent, accent: accent,
                     accentTile: ColorMath.tint(tileHi, toward: accent, accentTileMix), cyan: cyan, green: green,
                     magenta: magenta, orange: orange, red: red, yellow: yellow, termBlue: accent,
                     border: [accent, cyan], borderAngle: nil)
    }

    /// Tokyo Night, the default Omarchy theme. The tiles are lighter than the page.
    public static let tokyoNight: ThemePalette = spec(
        name: "tokyo-night", dark: true,
        bg: 0x16161E, offTile: 0x1A1B26, tile: 0x1F2335, tileHi: 0x24283B, line: 0x292E42, lineHi: 0x3B4261,
        text: 0xC0CAF5, sub: 0x8B94BE, dim: 0x66709B, onAccent: 0x16161E,
        accent: 0x7AA2F7, cyan: 0x7DCFFF, green: 0x9ECE6A, magenta: 0xBB9AF7, orange: 0xFF9E64, red: 0xF7768E,
        yellow: 0xE0AF68
    )

    /// Tokyo Night Day. The tiles are darker steps of the page, and the body ink is a neutral slate.
    public static let tokyoNightDay: ThemePalette = spec(
        name: "tokyo-night-day", dark: false,
        bg: 0xE1E2E7, offTile: 0xDDDEE4, tile: 0xD9DBE1, tileHi: 0xD4D5DC, line: 0xC4C8DA, lineHi: 0xA8AECB,
        text: 0x343B58, sub: 0x44518A, dim: 0x70769E, onAccent: 0xFFFFFF,
        accent: 0x2457B8, cyan: 0x006486, green: 0x496529, magenta: 0x7B31CF, orange: 0x914A00, red: 0xBA0046,
        yellow: 0x765729
    )

    /// Makes the palette of a computer theme through the contrast guard.
    /// The background decides whether the theme is dark. The mode of the
    /// theme counts only when the background is missing. The guard moves
    /// only the lightness of a color, so the hue stays. It runs the guard
    /// about 30 times, so do not call it while the UI draws.
    public static func of(_ theme: OmarchyTheme) -> ThemePalette {
        let rawBg = theme["background"]
        let dark: Bool = rawBg.map { ColorMath.luminance($0) < darkLuminance } ?? theme.dark ?? true
        let base = dark ? tokyoNight : tokyoNightDay
        let extreme = dark ? 0xFFFFFF : 0x000000
        func surface(_ c: Int, _ headroom: Double) -> Int {
            ColorMath.guarded(c, [ContrastNeed(extreme, headroom)], lighter: !dark)
        }
        let bg = surface(rawBg ?? base.bg, bgHeadroom)
        let bgLum = ColorMath.luminance(bg)
        func inkSide(_ c: Int) -> Bool { dark ? ColorMath.luminance(c) > bgLum : ColorMath.luminance(c) < bgLum }
        let fg = theme["foreground"] ?? base.text
        // The surfaces step toward the ink. A foreground on the wrong side gives no direction.
        let ink = inkSide(fg) ? fg : extreme
        func step(_ candidate: Int?, _ s: Step) -> Int {
            if let c = candidate, inkSide(c) {
                let r = ColorMath.contrast(bg, c)
                if r >= s.least && r <= s.most { return c }
                if r > s.most { return ColorMath.stepTo(from: bg, to: c, target: s.most) }
            }
            return ColorMath.stepTo(from: bg, to: ink, target: s.make)
        }
        let rawTile: Int
        let rawHi: Int
        if dark {
            rawHi = step(theme["lighter_background"], hiDark)
            rawTile = step(ColorMath.mix(bg, rawHi, 0.6), tileDark)
        } else {
            rawTile = step(theme["dark_background"], tileLight)
            let hi = step(theme["darker_background"], hiLight)
            rawHi = ColorMath.luminance(hi) < ColorMath.luminance(rawTile) ? hi : step(nil, hiLight)
        }
        let tile = surface(rawTile, tileHeadroom)
        let tileHi = surface(rawHi, tileHeadroom)
        let offTile = surface(ColorMath.mix(bg, tile, 0.5), tileHeadroom)
        let line = surface(ColorMath.mix(tileHi, ink, lineMix), lineHeadroom)
        let lineHi = ColorMath.mix(tileHi, ink, lineHiMix)
        let surfaces = [bg, offTile, tile, tileHi]

        func semantic(_ key: String, _ fallback: Int) -> Int { theme[key] ?? theme["bright_" + key] ?? fallback }
        func needs(_ ratio: Double, _ colors: [Int]) -> [ContrastNeed] { colors.map { ContrastNeed($0, ratio) } }
        let themeAccent = theme["accent"] ?? theme["blue"] ?? base.accent
        let rawRed = semantic("red", base.red)

        // The accent tile takes the hue of the accent, so the needs of each ink depend on the accent.
        func trial(_ source: Int) -> AccentTrial {
            let accentTile = ColorMath.tint(tileHi, toward: source, accentTileMix)
            let n = needs(textContrast, surfaces + [accentTile]) + [ContrastNeed(line, nonTextContrast)]
            return AccentTrial(source: source, accentTile: accentTile, needs: n,
                               accent: ColorMath.guarded(source, n, lighter: dark),
                               red: ColorMath.guarded(rawRed, n, lighter: dark))
        }
        let others = accentStandins.compactMap { theme[$0] } + [base.accent]
        let chosen = pickAccent(trial(themeAccent), others, trial)
        let accentTile = chosen.accentTile
        let fillNeeds = chosen.needs
        let inkNeeds = needs(textContrast, surfaces + [line, accentTile])

        let body = dark ? fg : ColorMath.limitChroma(fg, max: neutralChroma)
        let firstText = ColorMath.guarded(body, inkNeeds, lighter: dark)
        let sub = ColorMath.guarded(ColorMath.mix(firstText, bg, subMix), inkNeeds, lighter: dark)
        let text = ColorMath.guarded(firstText, inkNeeds + [ContrastNeed(sub, textStep)], lighter: dark)
        let dim = ColorMath.guarded(theme["muted"] ?? ColorMath.mix(text, bg, dimMix),
                                    needs(nonTextContrast, [bg, tile, tileHi]), lighter: dark)

        let sources: [Int] = [chosen.source, semantic("cyan", base.cyan), semantic("green", base.green),
                              semantic("magenta", base.magenta), semantic("orange", base.orange), rawRed,
                              semantic("yellow", base.yellow)]
        var colors: [Int] = sources.map { ColorMath.guarded($0, fillNeeds, lighter: dark) }

        // The ink on a fill: the light or the dark ink, whichever reads better on the accent.
        let lightInk = ColorMath.luminance(text) > ColorMath.luminance(bg) ? text : bg
        let darkInk = lightInk == text ? bg : text
        let light = ColorMath.contrast(colors[0], lightInk) >= ColorMath.contrast(colors[0], darkInk)
        let onAccent = ColorMath.guarded(light ? lightInk : darkInk, needs(textContrast, colors), lighter: light)
        let onAccentNeeds = fillNeeds + [ContrastNeed(onAccent, textContrast)]
        colors = colors.map { (c: Int) -> Int in
            if ColorMath.contrast(c, onAccent) >= textContrast { return c }
            return ColorMath.guarded(c, onAccentNeeds, lighter: !light)
        }

        let termBlue = ColorMath.guarded(theme["blue"] ?? theme["bright_blue"] ?? base.termBlue,
                                         needs(textContrast, surfaces), lighter: dark)
        let borderNeeds = needs(nonTextContrast, [bg, tile])
        // The theme accent stays in the gradient, so that the theme stays recognizable.
        let ownAccent = chosen.source == themeAccent ? colors[0] : ColorMath.guarded(themeAccent, fillNeeds, lighter: dark)
        let borderSource = theme.border.isEmpty ? [ownAccent, colors[1]] : theme.border
        let border = borderSource.map { ColorMath.guarded($0, borderNeeds, lighter: dark) }
        return ThemePalette(name: theme.name, dark: dark, bg: bg, offTile: offTile, tile: tile, tileHi: tileHi,
                            line: line, lineHi: lineHi, text: text, sub: sub, dim: dim, onAccent: onAccent,
                            accent: colors[0], accentTile: accentTile, cyan: colors[1], green: colors[2],
                            magenta: colors[3], orange: colors[4], red: colors[5], yellow: colors[6],
                            termBlue: termBlue, border: border,
                            borderAngle: theme.border.isEmpty ? nil : theme.borderAngle)
    }

    /// Keeps the accent apart from red. When `first` is too close to red,
    /// it takes the first of `others` that has a visible chroma, reaches its
    /// contrast, and is far enough from red. When no color is far enough, it
    /// takes the color that is farthest from red.
    private static func pickAccent(_ first: AccentTrial, _ others: [Int], _ trial: (Int) -> AccentTrial) -> AccentTrial {
        if first.apart >= minAccentDistance { return first }
        var best = first
        for c in others {
            let t = trial(c)
            if ColorMath.oklch(t.accent).c < minAccentChroma || !ColorMath.meets(t.accent, t.needs) { continue }
            if t.apart >= minAccentDistance { return t }
            if t.apart > best.apart { best = t }
        }
        return best
    }
}
