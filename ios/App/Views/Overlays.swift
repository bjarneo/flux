import FluxKit
import SwiftUI
import UIKit

/// The windows over the app for the sheets that must show whatever the app
/// shows: a pairing request, an approval, and a ring. A view presents 1
/// sheet at a time, and a sheet or a file picker of the app covers the
/// root, so a sheet from the root cannot show then. Each of these sheets
/// presents from its own window above the app, the later ones on top.
@MainActor
enum Overlays {
    private static var windows: [OverlayWindow] = []

    /// Adds the windows to the scene of the app, once.
    static func install(model: AppModel) {
        guard windows.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // The first style. Then `AppearanceController` follows the theme.
        let style = model.nightMode.style
        let layers = [AnyView(PairOverlay())] + FeatureOverlays.layers
        for (index, layer) in layers.enumerated() {
            let window = OverlayWindow(windowScene: scene)
            window.windowLevel = .alert + CGFloat(index + 1)
            window.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: layer.modifier(ThemeRoot()).environment(model))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false
            windows.append(window)
        }
    }
}

/// A window that shows only its sheets. A touch that hits no sheet goes to
/// the windows below it, so the window is invisible while it shows nothing.
final class OverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

/// The empty root of an overlay window, which presents the sheets of `modifier`.
struct OverlayLayer<Modifier: ViewModifier>: View {
    let modifier: Modifier

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .modifier(modifier)
    }
}

/// The pairing sheet: a computer that asks to pair, or the computer that
/// the user pairs with.
private struct PairOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear
            .ignoresSafeArea()
            .sheet(item: Binding(
                get: { model.pairSheetDevice.map(PairSheetItem.init) },
                set: { if $0 == nil { model.pairSheetClosed() } }
            )) { item in
                PairSheet(deviceId: item.id)
            }
    }
}
