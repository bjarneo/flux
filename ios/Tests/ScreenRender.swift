import SwiftUI
import UIKit
import XCTest

/// Renders a view in a window of the size of an iPhone 17 Pro and checks
/// that it drew a screen: an image of the window size, with more than a
/// few colors. With TEST_RUNNER_FLUX_SCREENS set, it saves the screen as a
/// PNG in that folder.
@MainActor
enum ScreenRender {
    static let size = CGSize(width: 402, height: 874)

    /// Renders the view and returns the mean luminance of the screen, from 0 to 1.
    @discardableResult
    static func render(_ view: some View, name: String, scheme: ColorScheme = .light, wait: TimeInterval = 0.5,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: view.environment(\.colorScheme, scheme))
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        XCTAssertEqual(image.size, size, "\(name) has the size of the window, in points", file: file, line: line)
        let (colors, luminance) = try sample(image)
        XCTAssertGreaterThan(colors, 8, "\(name) drew more than a plain background", file: file, line: line)
        if let dir = ProcessInfo.processInfo.environment["FLUX_SCREENS"], !dir.isEmpty {
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return luminance
    }

    /// Counts the colors of the image on a grid of points, and averages their luminance.
    private static func sample(_ image: UIImage) throws -> (colors: Int, luminance: Double) {
        let cg = try XCTUnwrap(image.cgImage)
        let (w, h) = (cg.width, cg.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var colors = Set<UInt32>()
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: h, by: 3) {
            for x in stride(from: 0, to: w, by: 3) {
                let i = (y * w + x) * 4
                let (r, g, b) = (UInt32(px[i]), UInt32(px[i + 1]), UInt32(px[i + 2]))
                colors.insert(r << 16 | g << 8 | b)
                total += (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
                count += 1
            }
        }
        return (colors.count, total / Double(count))
    }
}
