import AVFoundation
import FluxKit
import SwiftUI
import UIKit

/// The video of the remote desktop with its touches. The display layer
/// decodes the H.264 frames of `DesktopVideo`, and a touch view over it
/// reports the fingers and takes the keys of a hardware keyboard.
struct DesktopVideoSurface: UIViewRepresentable {
    let controller: DesktopController

    func makeUIView(context: Context) -> DesktopSurfaceView {
        let view = DesktopSurfaceView()
        controller.plugin.video.attach(view.display)
        update(view)
        return view
    }

    func updateUIView(_ view: DesktopSurfaceView, context: Context) { update(view) }

    static func dismantleUIView(_ view: DesktopSurfaceView, coordinator: ()) {
        view.detach?()
    }

    private func update(_ view: DesktopSurfaceView) {
        let controller = controller
        view.videoFrame = controller.viewport.videoFrame
        view.display.isHidden = !controller.live
        view.touches.onTouches = { controller.touched($0) }
        view.touches.onCancel = { controller.endTouches() }
        view.touches.onKey = { controller.control && controller.keys.press($0) }
        view.touches.onSize = { controller.layout(view: $0) }
        view.touches.keepsFocus = { controller.keys.fieldFocused }
        // A new surface can take the video before this one goes away.
        view.detach = { [weak plugin = controller.plugin, weak display = view.display] in
            if let display { plugin?.video.detach(display) }
        }
    }
}

/// A black view with the video at its zoom and pan, and the touch view on top.
final class DesktopSurfaceView: UIView {
    let display = AVSampleBufferDisplayLayer()
    let touches = TouchSurfaceView()
    /// Takes the video from the layer when the view goes away.
    var detach: (() -> Void)?
    /// The rectangle of the video in the view.
    var videoFrame: CGRect = .zero {
        didSet { if videoFrame != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        display.videoGravity = .resize
        layer.addSublayer(display)
        addSubview(touches)
        touches.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Remote desktop"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        touches.frame = bounds
        // The frame follows the zoom at once, without an animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = videoFrame
        CATransaction.commit()
    }
}
