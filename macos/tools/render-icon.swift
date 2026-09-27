// Renders the macOS app icons into App/Assets.xcassets: the dark bundle icon
// (AppIcon.appiconset), the light Dock icon (AppIconLight.imageset), and the
// menu bar template icons (MenuBarIcon and MenuBarIconOffline), which copy
// dist/flux-symbolic.svg.
// The mark and dark colors match dist/flux.svg and the Android launcher
// icon: the Flux mark, Φ phi, on a Tokyo Night tile, on the macOS icon grid.
// The light icon uses Tokyo Night Day colors.
//
//   swift macos/tools/render-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("App/Assets.xcassets")

/// The colors of one icon variant.
struct Palette {
    let top: UInt32
    let bottom: UInt32
    let border: UInt32
    let ring: UInt32
    let bar: UInt32
    let shadow: CGFloat
}

let dark = Palette(top: 0x24283B, bottom: 0x16161E, border: 0x292E42, ring: 0xC0CAF5, bar: 0x7AA2F7, shadow: 0.35)
let light = Palette(top: 0xF7F8FB, bottom: 0xE1E2E7, border: 0xC4C8DA, ring: 0x343B58, bar: 0x2E7DE9, shadow: 0.22)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws the icon on a 1024-unit canvas scaled to the pixel size.
func render(pixels: Int, _ palette: Palette) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // The tile: 824 units with a margin of 100, as in the macOS icon grid.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, palette.shadow))
    cg.addPath(shape)
    cg.setFillColor(color(palette.bottom))
    cg.fillPath()
    cg.restoreGState()

    // A light from the top, and the border of dist/flux.svg.
    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(palette.top), color(palette.bottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    cg.setStrokeColor(color(palette.border))
    cg.setLineWidth(4)
    cg.strokePath()

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
    cg.setFillColor(color(palette.ring))
    cg.fillPath(using: .evenOdd)
    // The bar: 2 by 14 units at 7 and 1 units, over the ring.
    cg.setFillColor(color(palette.bar))
    cg.fill(box(7, 1, 2, 14))

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

let info = ["author": "xcode", "version": 1] as [String: Any]
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try writeJSON(["info": info], to: assets.appendingPathComponent("Contents.json"))

// The bundle icon, in every size that macOS uses.
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var icons: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale, dark).write(to: iconSet.appendingPathComponent(name))
        icons.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
try writeJSON(["images": icons, "info": info], to: iconSet.appendingPathComponent("Contents.json"))

// The light Dock icon, which the app sets at run time.
let lightSet = assets.appendingPathComponent("AppIconLight.imageset")
try FileManager.default.createDirectory(at: lightSet, withIntermediateDirectories: true)
try render(pixels: 512, light).write(to: lightSet.appendingPathComponent("icon_light_512.png"))
try render(pixels: 1024, light).write(to: lightSet.appendingPathComponent("icon_light_512@2x.png"))
try writeJSON([
    "images": [
        ["idiom": "mac", "scale": "1x", "filename": "icon_light_512.png"],
        ["idiom": "mac", "scale": "2x", "filename": "icon_light_512@2x.png"],
    ],
    "info": info,
], to: lightSet.appendingPathComponent("Contents.json"))

/// Draws the 16-unit mark of dist/flux-symbolic.svg in black, 1 point per
/// unit, for a template image. alpha dims the offline icon.
func renderSymbolic(scale: Int, alpha: CGFloat) -> Data {
    let pixels = 16 * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    cg.setFillColor(color(0x000000, alpha))
    // The ring and the bar as rectangles that do not overlap, so that the
    // crossing is not darker when alpha is below 1.
    cg.fill([
        CGRect(x: 7, y: 1, width: 2, height: 14),  // the bar
        CGRect(x: 3, y: 3, width: 2, height: 10),  // the ring, left
        CGRect(x: 11, y: 3, width: 2, height: 10), // the ring, right
        CGRect(x: 5, y: 3, width: 2, height: 2),   // the ring, bottom
        CGRect(x: 9, y: 3, width: 2, height: 2),
        CGRect(x: 5, y: 11, width: 2, height: 2),  // the ring, top
        CGRect(x: 9, y: 11, width: 2, height: 2),
    ])
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

for (name, alpha) in [("MenuBarIcon", CGFloat(1)), ("MenuBarIconOffline", CGFloat(0.45))] {
    let set = assets.appendingPathComponent("\(name).imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let file = "\(name)\(scale == 2 ? "@2x" : "").png"
        try renderSymbolic(scale: scale, alpha: alpha).write(to: set.appendingPathComponent(file))
        images.append(["idiom": "mac", "scale": "\(scale)x", "filename": file])
    }
    try writeJSON([
        "images": images,
        "info": info,
        "properties": ["template-rendering-intent": "template"],
    ], to: set.appendingPathComponent("Contents.json"))
}

print("Wrote \(icons.count) bundle icons, the light icon, and the menu bar icons to \(assets.path)")
