// Renders the iOS app icon into App/Assets.xcassets/AppIcon.appiconset and
// the accent color into AccentColor.colorset.
// The mark and colors match dist/flux.svg, the Android launcher icon, and
// the dark macOS icon: the Flux mark, Φ phi, on a Tokyo Night tile. iOS
// rounds the corners, so the tile fills the square and has no alpha.
// The accent is the blue of the mark: Tokyo Night in dark mode and Tokyo
// Night Day in light mode.
//
//   swift ios/tools/render-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("App/Assets.xcassets")

let top: UInt32 = 0x24283B
let bottom: UInt32 = 0x16161E
let ringColor: UInt32 = 0xC0CAF5
let barColor: UInt32 = 0x7AA2F7
let accentLight: UInt32 = 0x2E7DE9
let accentDark: UInt32 = 0x7AA2F7

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Draws the 1024-pixel icon without alpha.
func render() -> Data {
    let pixels = 1024
    let cg = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let tile = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    // A light from the top.
    let gradient = CGGradient(colorsSpace: nil, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // The mark: a 16-unit box that takes 88/128 of the tile, as in dist/flux.svg.
    let unit = tile.width * 88 / 128 / 16
    let origin = CGPoint(x: tile.midX - 8 * unit, y: tile.midY - 8 * unit)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
    }
    // The ring: 10 units at 3 units, with a 2-unit stroke.
    let ring = CGMutablePath()
    ring.addRect(box(3, 3, 10, 10))
    ring.addRect(box(5, 5, 6, 6))
    cg.addPath(ring)
    cg.setFillColor(color(ringColor))
    cg.fillPath(using: .evenOdd)
    // The bar: 2 by 14 units at 7 and 1 units, over the ring.
    cg.setFillColor(color(barColor))
    cg.fill(box(7, 1, 2, 14))

    return NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!
}

func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func components(_ hex: UInt32) -> [String: String] {
    [
        "red": String(format: "0x%02X", hex >> 16 & 0xFF),
        "green": String(format: "0x%02X", hex >> 8 & 0xFF),
        "blue": String(format: "0x%02X", hex & 0xFF),
        "alpha": "1.000",
    ]
}

let info = ["author": "xcode", "version": 1] as [String: Any]
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try writeJSON(["info": info], to: assets.appendingPathComponent("Contents.json"))

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
try render().write(to: iconSet.appendingPathComponent("icon_1024.png"))
try writeJSON([
    "images": [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"]],
    "info": info,
], to: iconSet.appendingPathComponent("Contents.json"))

let accent = assets.appendingPathComponent("AccentColor.colorset")
try FileManager.default.createDirectory(at: accent, withIntermediateDirectories: true)
try writeJSON([
    "colors": [
        ["idiom": "universal", "color": ["color-space": "srgb", "components": components(accentLight)]],
        [
            "idiom": "universal",
            "appearances": [["appearance": "luminosity", "value": "dark"]],
            "color": ["color-space": "srgb", "components": components(accentDark)],
        ],
    ],
    "info": info,
], to: accent.appendingPathComponent("Contents.json"))
