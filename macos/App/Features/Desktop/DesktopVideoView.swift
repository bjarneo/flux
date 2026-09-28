import AVFoundation
import AppKit
import FluxKit
import SwiftUI

/// Hosts the video of the remote desktop.
struct DesktopVideo: NSViewRepresentable {
    let controller: DesktopController

    func makeNSView(context: Context) -> DesktopVideoView { DesktopVideoView(controller: controller) }

    func updateNSView(_ view: DesktopVideoView, context: Context) {}

    static func dismantleNSView(_ view: DesktopVideoView, coordinator: ()) { view.controller.endPointer() }
}

/// The video of the computer screen. The video keeps the shape of the
/// monitor, with bars at the sides or at the top and the bottom. The mouse
/// over the video goes to the computer with its position on the monitor:
/// a move, a click, a drag, and a scroll. While the view has the keyboard
/// focus, keys go to the computer, and Command is Super while the pointer
/// is over the video.
final class DesktopVideoView: RemoteKeyView {
    let controller: DesktopController
    private let display = AVSampleBufferDisplayLayer()
    private var area: NSTrackingArea?
    /// True when the next mouse up belongs to a press that clicked already.
    private var skipUp = false

    init(controller: DesktopController) {
        self.controller = controller
        super.init(keyTarget: controller)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The positions have a top left origin, like the monitor.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        CATransaction.commit()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            controller.plugin.video.attach(nil)
            controller.pointerInside = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Shows the stream on this view, and takes the keyboard focus.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        controller.plugin.video.attach(display)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    // MARK: Positions

    private var geometry: DesktopGeometry {
        let s = controller.status
        return DesktopGeometry(view: bounds.size, video: CGSize(width: s?.width ?? 0, height: s?.height ?? 0))
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { controller.pointerInside = true }

    override func mouseExited(with event: NSEvent) { controller.pointerInside = false }

    override func mouseMoved(with event: NSEvent) {
        if !controller.pointerInside { controller.pointerInside = true }
        controller.hover(geometry.position(point(event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        guard let at = geometry.position(p) else {
            skipUp = true
            return
        }
        // Clicks carry no modifiers, so Control-click is the right button
        // as on the Mac, and Option-click the middle button as in XQuartz.
        if event.modifierFlags.contains(.control) {
            controller.click(.right, at: at)
            skipUp = true
        } else if event.modifierFlags.contains(.option) {
            controller.click(.middle, at: at)
            skipUp = true
        } else {
            skipUp = false
            controller.leftDown(p, at: at)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !skipUp, let at = geometry.position(point(event), clamp: true) else { return }
        controller.leftDragged(point(event), at: at)
    }

    override func mouseUp(with event: NSEvent) {
        if skipUp {
            skipUp = false
            return
        }
        guard let at = geometry.position(point(event), clamp: true) else { return }
        controller.leftUp(point(event), at: at, clickCount: event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let at = geometry.position(point(event)) else { return }
        controller.click(.right, at: at)
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let at = geometry.position(point(event)) else { return }
        controller.click(.middle, at: at)
    }

    override func otherMouseUp(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        let g = geometry
        guard let at = g.position(point(event)) else { return }
        controller.scrolled(event, at: at, scale: g.scale)
    }
}
