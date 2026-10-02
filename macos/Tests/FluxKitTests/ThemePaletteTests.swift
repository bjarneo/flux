import XCTest
@testable import FluxKit

/// Ported from ThemePaletteTest.kt of the Android app. The reference values
/// come from the Kotlin code and from a Python port of the Swift code, which
/// give the same palettes.
final class ThemePaletteTests: XCTestCase {
    private let fillNames = ["accent", "cyan", "green", "magenta", "orange", "red", "yellow"]

    private func hex(_ c: Int) -> String { ColorMath.hex(c) }

    private func assertContrast(_ what: String, _ a: Int, _ b: Int, _ least: Double,
                                file: StaticString = #filePath, line: UInt = #line) {
        let r = ColorMath.contrast(a, b)
        XCTAssertGreaterThanOrEqual(r, least, "\(what): \(hex(a)) on \(hex(b)) is \(String(format: "%.2f", r)):1, needs \(least):1",
                                    file: file, line: line)
    }

    /// Asserts each contrast that the palette promises, see the contract of `ThemePalette`.
    private func assertReadable(_ p: ThemePalette, file: StaticString = #filePath, line: UInt = #line) {
        let text = ThemePalette.textContrast
        let nonText = ThemePalette.nonTextContrast
        XCTAssertEqual(p.surfaces + [p.line, p.accentTile], p.containers, file: file, line: line)
        for s in p.containers {
            assertContrast("\(p.name) text", p.text, s, text, file: file, line: line)
            assertContrast("\(p.name) sub", p.sub, s, text, file: file, line: line)
        }
        assertContrast("\(p.name) text against sub", p.text, p.sub, ThemePalette.textStep, file: file, line: line)
        for s in [p.bg, p.tile, p.tileHi] { assertContrast("\(p.name) dim", p.dim, s, nonText, file: file, line: line) }
        for (name, c) in zip(fillNames, p.fills) {
            for s in p.surfaces + [p.accentTile] {
                assertContrast("\(p.name) \(name) as text", c, s, text, file: file, line: line)
            }
            assertContrast("\(p.name) \(name) as an icon on line", c, p.line, nonText, file: file, line: line)
            assertContrast("\(p.name) ink on \(name)", p.onAccent, c, text, file: file, line: line)
        }
        for s in p.surfaces { assertContrast("\(p.name) terminal blue", p.termBlue, s, text, file: file, line: line) }
        XCTAssertFalse(p.border.isEmpty, "\(p.name) has a border", file: file, line: line)
        for b in p.border {
            for s in [p.bg, p.tile] { assertContrast("\(p.name) border", b, s, nonText, file: file, line: line) }
        }
        assertApart(p, file: file, line: line)
        // The selected tile has the luminance of tileHi, so it does not change a contrast.
        XCTAssertLessThan(ColorMath.contrast(p.accentTile, p.tileHi), 1.03, "\(p.name) accent tile", file: file, line: line)
    }

    /// Asserts that the accent does not look like red, because red means "needs you".
    private func assertApart(_ p: ThemePalette, file: StaticString = #filePath, line: UInt = #line) {
        let d = ColorMath.distance(p.accent, p.red)
        XCTAssertGreaterThanOrEqual(d, ThemePalette.minAccentDistance,
                                    "\(p.name): the accent \(hex(p.accent)) and red \(hex(p.red)) are \(String(format: "%.3f", d)) apart",
                                    file: file, line: line)
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 2 * Double.pi)
        return d > Double.pi ? 2 * Double.pi - d : d
    }

    /// Asserts that the guard kept the hue of a color with a visible chroma.
    private func assertSameHue(_ what: String, _ from: Int, _ to: Int, file: StaticString = #filePath, line: UInt = #line) {
        let a = ColorMath.oklch(from)
        let b = ColorMath.oklch(to)
        if a.c < 0.04 || b.c < 0.04 { return }
        XCTAssertLessThan(hueDistance(a.h, b.h), 0.08, "\(what): the hue moved from \(hex(from)) to \(hex(to))", file: file, line: line)
    }

    /// Asserts that 2 colors differ by 1 at most in each channel. Floating point can give a difference of 1.
    private func assertNear(_ a: Int, _ b: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for shift in [16, 8, 0] {
            let x = (a >> shift) & 0xFF
            let y = (b >> shift) & 0xFF
            XCTAssertLessThanOrEqual(abs(x - y), 1, "\(what): \(hex(a)) is not near \(hex(b))", file: file, line: line)
        }
    }

    func testContrastFollowsWcag() {
        XCTAssertEqual(ColorMath.contrast(0x000000, 0xFFFFFF), 21.0, accuracy: 0.01)
        XCTAssertEqual(ColorMath.contrast(0x7AA2F7, 0x7AA2F7), 1.0, accuracy: 0.0001)
        // The well-known lightest gray that passes AA on white.
        XCTAssertEqual(ColorMath.contrast(0x767676, 0xFFFFFF), 4.54, accuracy: 0.01)
        XCTAssertEqual(ColorMath.contrast(0x16161E, 0xC0CAF5), ColorMath.contrast(0xC0CAF5, 0x16161E))
    }

    func testTheGuardKeepsAPassingColor() {
        XCTAssertEqual(ColorMath.guarded(0xC0CAF5, [ContrastNeed(0x16161E, ThemePalette.textContrast)], lighter: true), 0xC0CAF5)
    }

    func testTheGuardMovesOnlyTheLightness() {
        let tiles = [0x16161E, 0x1F2335, 0x24283B]
        // The old Tokyo Night dim, 2.35 to 2.91:1 on the tiles.
        let moved = ColorMath.guarded(0x565F89, tiles.map { ContrastNeed($0, ThemePalette.textContrast) }, lighter: true)
        for t in tiles { assertContrast("moved dim", moved, t, ThemePalette.textContrast) }
        XCTAssertGreaterThan(ColorMath.oklch(moved).l, ColorMath.oklch(0x565F89).l)
        assertSameHue("dim", 0x565F89, moved)
        // A saturated red on a light tile goes darker and stays red.
        let red = ColorMath.guarded(0xF52A65, [ContrastNeed(0xE9EAEF, ThemePalette.textContrast)], lighter: false)
        assertContrast("red", red, 0xE9EAEF, ThemePalette.textContrast)
        assertSameHue("red", 0xF52A65, red)
    }

    func testTheFallbackPalettesAreReadable() {
        assertReadable(.tokyoNight)
        assertReadable(.tokyoNightDay)
        XCTAssertTrue(ThemePalette.tokyoNight.dark)
        XCTAssertFalse(ThemePalette.tokyoNightDay.dark)
    }

    func testTheFallbackPalettesKeepTheValuesOfTheReview() {
        let day = ThemePalette.tokyoNightDay
        let night = ThemePalette.tokyoNight
        // Light: the true Tokyo Night Day page, a neutral ink, and white on the primary fill.
        XCTAssertEqual(day.bg, 0xE1E2E7)
        XCTAssertEqual(day.accent, 0x2457B8)
        XCTAssertEqual(day.onAccent, 0xFFFFFF)
        XCTAssertGreaterThan(ColorMath.contrast(day.onAccent, day.accent), 6.5)
        XCTAssertLessThan(ColorMath.oklch(day.text).c, 0.06, "the light body ink is a neutral")
        // The light body ink and the accent no longer look alike.
        XCTAssertGreaterThan(ColorMath.oklch(day.accent).c, 3 * ColorMath.oklch(day.text).c)
        XCTAssertEqual(day.sub, 0x44518A)
        XCTAssertEqual(night.sub, 0x8B94BE)
        XCTAssertEqual(night.bg, 0x16161E)
        XCTAssertEqual(night.text, 0xC0CAF5)
        XCTAssertEqual(night.termBlue, night.accent)
        XCTAssertEqual(night.border, [night.accent, night.cyan])
        XCTAssertNil(night.borderAngle)
    }

    func testFallbackAccentTiles() {
        assertNear(ThemePalette.tokyoNight.accentTile, 0x1E2845, "Tokyo Night accent tile")
        assertNear(ThemePalette.tokyoNightDay.accentTile, 0xCBD6EE, "Tokyo Night Day accent tile")
    }

    func testTheThemeOfTheUserKeepsItsColors() {
        let p = ThemePalette.of(SampleThemes.neon)
        assertReadable(p)
        XCTAssertTrue(p.dark)
        // The colors that pass stay as they are.
        XCTAssertEqual(p.bg, 0x0C031F)
        XCTAssertEqual(p.text, 0xE8E6EF)
        XCTAssertEqual(p.accent, 0xD563FE)
        XCTAssertEqual(p.red, 0xFE288F)
        XCTAssertEqual(p.cyan, 0x21E4F8)
        // The accent, not the lime blue, is the primary color. The lime blue is the ANSI blue.
        XCTAssertNotEqual(p.accent, 0xBDFF6D)
        XCTAssertEqual(p.termBlue, 0xBDFF6D)
        // The selected tile moves toward the purple of the accent.
        XCTAssertLessThan(ColorMath.distance(p.accentTile, p.accent), ColorMath.distance(p.tileHi, p.accent))
        // The muted color gets lighter for its 3:1 and keeps its hue.
        XCTAssertNotEqual(p.dim, 0x665A8C)
        assertSameHue("muted", 0x665A8C, p.dim)
        // The ink on the accent is the dark page, which reads better than the light text.
        XCTAssertEqual(p.onAccent, p.bg)
        XCTAssertGreaterThan(ColorMath.contrast(p.onAccent, p.accent), ColorMath.contrast(p.text, p.accent))
        // The tiles are lighter steps of the page, with its purple hue.
        XCTAssertGreaterThan(ColorMath.luminance(p.tile), ColorMath.luminance(p.bg))
        XCTAssertGreaterThan(ColorMath.luminance(p.tileHi), ColorMath.luminance(p.tile))
        assertSameHue("tile", 0x0C031F, p.tile)
        // The border comes from the theme, at its angle.
        XCTAssertEqual(p.border, [0x21E4F8, 0xD563FE])
        XCTAssertEqual(p.borderAngle, 45)
    }

    func testTokyoNightFromAComputerStaysTokyoNight() {
        let p = ThemePalette.of(SampleThemes.tokyoNight)
        assertReadable(p)
        XCTAssertEqual(p.bg, 0x1A1B26)
        XCTAssertEqual(p.text, 0xC0CAF5)
        XCTAssertEqual(p.accent, 0x7AA2F7)
        XCTAssertEqual(p.red, 0xF7768E)
        XCTAssertEqual(p.tileHi, 0x24283B)
        XCTAssertGreaterThan(ColorMath.luminance(p.tile), ColorMath.luminance(p.bg))
    }

    func testTokyoNightDayGetsANeutralInkAndDarkerColors() throws {
        let theme = SampleThemes.tokyoNightDay
        let p = ThemePalette.of(theme)
        assertReadable(p)
        XCTAssertFalse(p.dark)
        XCTAssertEqual(p.bg, 0xE1E2E7)
        // The body ink was the accent blue. Now it is a neutral with the same hue.
        XCTAssertLessThanOrEqual(ColorMath.oklch(p.text).c, 0.05)
        let red = try XCTUnwrap(theme["red"])
        let accent = try XCTUnwrap(theme["accent"])
        assertSameHue("red", red, p.red)
        assertSameHue("accent", accent, p.accent)
        // The tiles are the darker steps of the page.
        XCTAssertLessThan(ColorMath.luminance(p.tile), ColorMath.luminance(p.bg))
        XCTAssertLessThan(ColorMath.luminance(p.tileHi), ColorMath.luminance(p.tile))
        // The light ink reads better on the dark accent.
        XCTAssertGreaterThan(ColorMath.luminance(p.onAccent), ColorMath.luminance(p.accent))
    }

    func testCatppuccinLatteIsReadable() throws {
        let theme = SampleThemes.catppuccinLatte
        let p = ThemePalette.of(theme)
        assertReadable(p)
        XCTAssertFalse(p.dark)
        XCTAssertEqual(p.bg, 0xEFF1F5)
        XCTAssertEqual(p.tile, 0xE6E9EF)
        XCTAssertEqual(p.tileHi, 0xDCE0E8)
        // The body ink is a little darker than the foreground, so that the second ink can sit between it and the page.
        XCTAssertLessThan(ColorMath.luminance(p.text), ColorMath.luminance(0x4C4F69))
        assertSameHue("text", 0x4C4F69, p.text)
        // The ANSI blue is the theme blue, not the mauve accent.
        assertSameHue("terminal blue", 0x1E66F5, p.termBlue)
        for key in ["red", "green", "yellow", "cyan", "magenta"] {
            let index = try XCTUnwrap(fillNames.firstIndex(of: key))
            let source = try XCTUnwrap(theme[key])
            assertSameHue(key, source, p.fills[index])
        }
        // 1 border color makes a solid border.
        XCTAssertEqual(p.border.count, 1)
    }

    func testAnAccentThatLooksLikeRedGivesWayToTheThemeBlue() throws {
        // cotton-candy: the accent #e1a4ed and red #f097c5 are 2 pinks.
        let theme = SampleThemes.cottonCandy
        let themeAccent = try XCTUnwrap(theme["accent"])
        let themeRed = try XCTUnwrap(theme["red"])
        XCTAssertLessThan(ColorMath.distance(themeAccent, themeRed), ThemePalette.minAccentDistance)
        let p = ThemePalette.of(theme)
        assertReadable(p)
        XCTAssertEqual(p.accent, 0x8EAFFE)
        XCTAssertEqual(p.red, 0xF097C5)
        XCTAssertEqual(p.cyan, 0x61E6FF)
        XCTAssertEqual(p.termBlue, 0x8EAFFE)
        // The border keeps the accent of the theme, so the theme stays recognizable.
        XCTAssertEqual(p.border, [0x61E6FF, 0xE1A4ED])
        // The selected tile moves toward the new accent.
        XCTAssertLessThan(ColorMath.distance(p.accentTile, p.accent), ColorMath.distance(p.tileHi, p.accent))
    }

    func testAnAccentThatIsRedGivesWayToAColorWithChroma() throws {
        // futurism: the accent is red, and blue and cyan are a near white.
        let theme = SampleThemes.futurism
        XCTAssertEqual(theme["accent"], theme["red"])
        let p = ThemePalette.of(theme)
        assertReadable(p)
        // The near white has no chroma, so bright_blue takes the place of the accent.
        XCTAssertEqual(p.accent, 0x00BFFF)
        assertSameHue("red", 0xFF40A3, p.red)
        // The terminal keeps the near white blue of the theme.
        XCTAssertEqual(p.termBlue, 0xF0F8FF)
        // Without a theme border, the gradient starts at the accent of the theme.
        let first = try XCTUnwrap(p.border.first)
        assertSameHue("border", 0xFF40A3, first)
        XCTAssertNil(p.borderAngle)
    }

    func testAThemeWithoutChromaTakesTheTokyoNightAccent() {
        // snow: each color is the same near black, so no theme color can be the accent.
        let ink = 0x0A0A0A
        let keys = ["foreground", "accent", "red", "green", "yellow", "orange", "cyan", "blue", "magenta",
                    "bright_blue", "bright_cyan", "bright_magenta"]
        var colors: [String: Int] = ["background": 0xFFFFFF, "muted": 0x919191]
        for key in keys { colors[key] = ink }
        let p = ThemePalette.of(OmarchyTheme(name: "snow", dark: false, colors: colors))
        assertReadable(p)
        XCTAssertFalse(p.dark)
        assertSameHue("accent", ThemePalette.tokyoNightDay.accent, p.accent)
        XCTAssertEqual(p.red, ink)
    }

    func testAnAccentFarFromRedStays() throws {
        for theme in [SampleThemes.neon, SampleThemes.tokyoNight, SampleThemes.catppuccinLatte] {
            let p = ThemePalette.of(theme)
            let accent = try XCTUnwrap(theme["accent"])
            assertSameHue("\(theme.name) accent", accent, p.accent)
        }
    }

    func testTheTintKeepsTheLuminance() {
        let t = ColorMath.tint(0x24283B, toward: 0x7AA2F7, 0.18)
        XCTAssertNotEqual(t, 0x24283B)
        XCTAssertEqual(ColorMath.luminance(t), ColorMath.luminance(0x24283B), accuracy: 0.002)
        XCTAssertLessThan(ColorMath.distance(t, 0x7AA2F7), ColorMath.distance(0x24283B, 0x7AA2F7))
        XCTAssertEqual(ColorMath.distance(0x7AA2F7, 0x7AA2F7), 0)
        XCTAssertLessThan(ColorMath.distance(0xE1A4ED, 0xF097C5), ThemePalette.minAccentDistance)
        XCTAssertGreaterThan(ColorMath.distance(0x8EAFFE, 0xF097C5), ThemePalette.minAccentDistance)
    }

    func testALowContrastThemeBecomesReadable() throws {
        let theme = SampleThemes.lowContrast
        let p = ThemePalette.of(theme)
        assertReadable(p)
        XCTAssertTrue(p.dark)
        // The page goes darker so that the ink can reach its contrast.
        let background = try XCTUnwrap(theme["background"])
        let red = try XCTUnwrap(theme["red"])
        XCTAssertLessThan(ColorMath.luminance(p.bg), ColorMath.luminance(background))
        XCTAssertGreaterThanOrEqual(ColorMath.contrast(p.text, p.bg), ThemePalette.textContrast)
        assertSameHue("red", red, p.red)
        // The gray blue accent is too close to the gray red, and the theme has no
        // other color with chroma. The Tokyo Night blue takes the place of the accent.
        assertSameHue("accent", ThemePalette.tokyoNight.accent, p.accent)
    }

    func testAThemeWithFewColorsTakesTheRestFromTokyoNight() {
        let dark = ThemePalette.of(OmarchyTheme(name: "bare", dark: nil, colors: ["background": 0x101010, "foreground": 0xEEEEEE]))
        assertReadable(dark)
        XCTAssertTrue(dark.dark)
        XCTAssertEqual(dark.red, ThemePalette.tokyoNight.red)
        let light = ThemePalette.of(OmarchyTheme(name: "bare", dark: false, colors: ["accent": 0x8839EF]))
        assertReadable(light)
        XCTAssertFalse(light.dark)
        XCTAssertEqual(light.bg, ThemePalette.tokyoNightDay.bg)
        // Without a border, the gradient goes from the accent to cyan, corner to corner.
        XCTAssertEqual(light.border, [light.accent, light.cyan])
        XCTAssertNil(light.borderAngle)
    }

    func testTheBackgroundDecidesTheMode() {
        let p = ThemePalette.of(OmarchyTheme(name: "wrong mode", dark: true, colors: ["background": 0xF7F7F7, "foreground": 0x2B2426]))
        XCTAssertFalse(p.dark)
        XCTAssertEqual(p.bg, 0xF7F7F7)
        assertReadable(p)
    }

    func testADarkBorderGetsLighter() {
        let p = ThemePalette.of(OmarchyTheme(name: "dark border", dark: true, colors: ["background": 0x0C031F],
                                             border: [0x1A0A30, 0x0C031F], borderAngle: 90))
        assertReadable(p)
        XCTAssertEqual(p.border.count, 2)
        XCTAssertEqual(p.borderAngle, 90)
    }

    func testEverySampleIsReadable() {
        for theme in SampleThemes.all { assertReadable(ThemePalette.of(theme)) }
    }

    // MARK: Reference values

    /// A palette from the 19 colors in the order of `roles`.
    private func reference(_ name: String, _ dark: Bool, _ v: [Int], border: [Int], angle: Double?) -> ThemePalette {
        ThemePalette(name: name, dark: dark, bg: v[0], offTile: v[1], tile: v[2], tileHi: v[3], line: v[4], lineHi: v[5],
                     text: v[6], sub: v[7], dim: v[8], onAccent: v[9], accent: v[10], accentTile: v[11], cyan: v[12],
                     green: v[13], magenta: v[14], orange: v[15], red: v[16], yellow: v[17], termBlue: v[18],
                     border: border, borderAngle: angle)
    }

    private let roles: [(String, KeyPath<ThemePalette, Int>)] = [
        ("bg", \ThemePalette.bg), ("offTile", \ThemePalette.offTile), ("tile", \ThemePalette.tile),
        ("tileHi", \ThemePalette.tileHi), ("line", \ThemePalette.line), ("lineHi", \ThemePalette.lineHi),
        ("text", \ThemePalette.text), ("sub", \ThemePalette.sub), ("dim", \ThemePalette.dim),
        ("onAccent", \ThemePalette.onAccent), ("accent", \ThemePalette.accent), ("accentTile", \ThemePalette.accentTile),
        ("cyan", \ThemePalette.cyan), ("green", \ThemePalette.green), ("magenta", \ThemePalette.magenta),
        ("orange", \ThemePalette.orange), ("red", \ThemePalette.red), ("yellow", \ThemePalette.yellow),
        ("termBlue", \ThemePalette.termBlue),
    ]

    private func assertNearPalette(_ got: ThemePalette, _ want: ThemePalette, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.name, want.name, file: file, line: line)
        XCTAssertEqual(got.dark, want.dark, "\(want.name) dark", file: file, line: line)
        for (role, path) in roles {
            assertNear(got[keyPath: path], want[keyPath: path], "\(want.name) \(role)", file: file, line: line)
        }
        XCTAssertEqual(got.border.count, want.border.count, "\(want.name) border", file: file, line: line)
        for (g, w) in zip(got.border, want.border) { assertNear(g, w, "\(want.name) border", file: file, line: line) }
        XCTAssertEqual(got.borderAngle, want.borderAngle, "\(want.name) border angle", file: file, line: line)
    }

    /// The full palettes of the samples. The Kotlin code of Flux for Android gives the same values.
    func testSamplePalettesMatchTheReferenceValues() {
        let want: [(OmarchyTheme, ThemePalette)] = [
            (SampleThemes.neon, reference("neon", true, [
                0x0C031F, 0x130A26, 0x1A112C, 0x231B35, 0x332B44, 0x4E485E, 0xE8E6EF, 0xA6A2B1, 0x6E6295, 0x0C031F,
                0xD563FE, 0x2E1242, 0x21E4F8, 0x9ECE6A, 0xBB9AF7, 0xFF9E64, 0xFE288F, 0xE0AF68, 0xBDFF6D,
            ], border: [0x21E4F8, 0xD563FE], angle: 45)),
            (SampleThemes.tokyoNight, reference("tokyo-night", true, [
                0x1A1B26, 0x1D1F2D, 0x202333, 0x24283B, 0x30354A, 0x464C64, 0xC0CAF5, 0x959DBE, 0x66709B, 0x1A1B26,
                0x7AA2F7, 0x1E2845, 0x7DCFFF, 0x9ECE6A, 0xBB9AF7, 0xFF9E64, 0xF7768E, 0xE0AF68, 0x7AA2F7,
            ], border: [0x33CCFF, 0x00FF99], angle: 45)),
            (SampleThemes.tokyoNightDay, reference("tokyo-night-day", false, [
                0xE1E2E7, 0xDBDCE1, 0xD5D6DB, 0xCECFD4, 0xC2C6D2, 0xADB7CF, 0x323D55, 0x4B5365, 0x6B729A, 0xE1E2E7,
                0x0055B8, 0xC1D0E9, 0x006081, 0x456125, 0x772BCA, 0x8A4600, 0xB20042, 0x725325, 0x0055B8,
            ], border: [0x0055B8, 0x006081], angle: nil)),
            (SampleThemes.catppuccinLatte, reference("catppuccin-latte", false, [
                0xEFF1F5, 0xEBEDF2, 0xE6E9EF, 0xDCE0E8, 0xD0D4DE, 0xBCC0CC, 0x41445E, 0x585B6D, 0x7C7F8F, 0xEFF1F5,
                0x8230E7, 0xE5DBFF, 0x006A95, 0x1C7300, 0xA5368B, 0xAD4000, 0xC80033, 0x8E5600, 0x0D57E5,
            ], border: [0x8839EF], angle: 0)),
            (SampleThemes.cottonCandy, reference("cotton-candy", true, [
                0x191125, 0x1D152A, 0x21192F, 0x271F35, 0x372F44, 0x524B5E, 0xE9E6EF, 0xABA6B2, 0x73678C, 0x191125,
                0x8EAFFE, 0x21203D, 0x61E6FF, 0x58E3DC, 0xE1A4ED, 0xFEB79E, 0xF097C5, 0xF9DD7D, 0x8EAFFE,
            ], border: [0x61E6FF, 0xE1A4ED], angle: 45)),
            (SampleThemes.futurism, reference("futurism", true, [
                0x0A1428, 0x0E1B32, 0x12213C, 0x17294A, 0x283A58, 0x475772, 0xF0F8FF, 0xABB4BF, 0x64738C, 0x0A1428,
                0x00BFFF, 0x002B4C, 0xF0F8FF, 0x00BFFF, 0xFF42A4, 0xFF7AB8, 0xFF42A4, 0x6991CF, 0xF0F8FF,
            ], border: [0xFF42A4, 0xF0F8FF], angle: nil)),
            (SampleThemes.lowContrast, reference("low-contrast", true, [
                0x424242, 0x464646, 0x4A4A4A, 0x4F4F4F, 0x515151, 0x565656, 0xE6E6E6, 0xC3C3C3, 0x9D9D9D, 0x424242,
                0xA3C1FF, 0x494F5E, 0xA8C7C7, 0xB3C5B3, 0xCDB4FF, 0xFFAE7F, 0xE4B5B4, 0xC2C2A3, 0xA3C1FF,
            ], border: [0x979797, 0x979797], angle: nil)),
        ]
        for (theme, palette) in want { assertNearPalette(ThemePalette.of(theme), palette) }
    }
}
