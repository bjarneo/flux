import XCTest
@testable import FluxKit

/// The theme setting, the light or dark mode of the windows, and the line of
/// the Computer choice. Ported from ThemePaletteTest.kt and ThemeLabel.kt of
/// the Android app.
final class ThemeModeTests: XCTestCase {
    func testTheComputerSettingFollowsTheComputerOrThePhone() {
        let computer = ThemePalette.of(SampleThemes.neon)
        XCTAssertEqual(ThemeMode.computer.palette(computer: computer, systemDark: false), computer)
        XCTAssertEqual(ThemeMode.computer.palette(computer: nil, systemDark: true), ThemePalette.tokyoNight)
        XCTAssertEqual(ThemeMode.computer.palette(computer: nil, systemDark: false), ThemePalette.tokyoNightDay)
        XCTAssertEqual(ThemeMode.system.palette(computer: computer, systemDark: true), ThemePalette.tokyoNight)
        XCTAssertEqual(ThemeMode.system.palette(computer: computer, systemDark: false), ThemePalette.tokyoNightDay)
        XCTAssertEqual(ThemeMode.light.palette(computer: computer, systemDark: true), ThemePalette.tokyoNightDay)
        XCTAssertEqual(ThemeMode.dark.palette(computer: computer, systemDark: false), ThemePalette.tokyoNight)
    }

    func testTheNightModeFollowsTheComputerTheme() {
        let neon = ThemePalette.of(SampleThemes.neon)
        XCTAssertEqual(ThemeMode.computer.nightMode(computer: neon), ThemeMode.dark)
        XCTAssertEqual(ThemeMode.computer.nightMode(computer: ThemePalette.of(SampleThemes.catppuccinLatte)), ThemeMode.light)
        XCTAssertEqual(ThemeMode.computer.nightMode(computer: nil), ThemeMode.system)
        XCTAssertEqual(ThemeMode.light.nightMode(computer: neon), ThemeMode.light)
        XCTAssertEqual(ThemeMode.dark.nightMode(computer: nil), ThemeMode.dark)
        XCTAssertEqual(ThemeMode.system.nightMode(computer: neon), ThemeMode.system)
    }

    func testComputerIsTheDefaultSetting() {
        XCTAssertEqual(ThemeMode(key: nil), ThemeMode.computer)
        XCTAssertEqual(ThemeMode(key: "unknown"), ThemeMode.computer)
        XCTAssertEqual(ThemeMode(key: "system"), ThemeMode.system)
        XCTAssertEqual(ThemeMode(key: "computer"), ThemeMode.computer)
        XCTAssertEqual(ThemeMode.defaultsKey, "appearance")
    }

    func testTheOldAppearanceValuesStay() {
        // The iPhone and the Mac kept Automatic, Light, or Dark under the same key.
        XCTAssertEqual(ThemeMode(key: "automatic"), ThemeMode.computer)
        XCTAssertEqual(ThemeMode(key: "light"), ThemeMode.light)
        XCTAssertEqual(ThemeMode(key: "dark"), ThemeMode.dark)
    }

    func testTheChoicesAndTheirLabels() {
        XCTAssertEqual(ThemeMode.allCases, [ThemeMode.computer, .system, .light, .dark])
        XCTAssertEqual(ThemeMode.allCases.map { $0.label }, ["Computer", "System", "Light", "Dark"])
        XCTAssertEqual(ThemeMode.allCases.map { $0.id }, ["computer", "system", "light", "dark"])
    }

    func testTheComputerLine() {
        let named = ComputerTheme(deviceId: "A", theme: SampleThemes.cottonCandy, palette: .tokyoNight)
        var blank = SampleThemes.cottonCandy
        blank.name = ""
        let unnamed = ComputerTheme(deviceId: "A", theme: blank, palette: .tokyoNight)
        XCTAssertEqual(ThemeMode.computerLine(theme: nil, themeComputer: nil, scopeComputer: "omarchy-desk", systemDark: true),
                       "Tokyo Night until omarchy-desk sends its theme")
        XCTAssertEqual(ThemeMode.computerLine(theme: nil, themeComputer: nil, scopeComputer: nil, systemDark: false),
                       "Tokyo Night Day until a computer sends its theme")
        XCTAssertEqual(ThemeMode.computerLine(theme: named, themeComputer: "omarchy-desk", scopeComputer: nil, systemDark: true),
                       "cotton-candy from omarchy-desk")
        XCTAssertEqual(ThemeMode.computerLine(theme: named, themeComputer: nil, scopeComputer: nil, systemDark: true),
                       "cotton-candy")
        XCTAssertEqual(ThemeMode.computerLine(theme: unnamed, themeComputer: "omarchy-desk", scopeComputer: nil, systemDark: true),
                       "The theme of omarchy-desk")
        XCTAssertEqual(ThemeMode.computerLine(theme: unnamed, themeComputer: "", scopeComputer: "", systemDark: false),
                       "The theme of a computer")
    }
}
