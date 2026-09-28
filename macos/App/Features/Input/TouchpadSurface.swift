import AppKit
import FluxKit
import SwiftUI

/// Hosts the pad of the touchpad window.
struct TouchpadSurface: NSViewRepresentable {
    let controller: TouchpadController

    func makeNSView(context: Context) -> TouchpadSurfaceView { TouchpadSurfaceView(controller: controller) }

    func updateNSView(_ view: TouchpadSurfaceView, context: Context) {}

    static func dismantleNSView(_ view: TouchpadSurfaceView, coordinator: ()) { view.controller.release() }
}

/// The pad. A click gives it the pointer of this Mac, and Control and Option
/// together give the pointer back. While it holds the pointer, it sends the
/// motion, the clicks, the scrolls, and each key to the computer. While it
/// has the keyboard focus, keys go to the computer too, but the Mac keeps
/// its Command shortcuts.
final class TouchpadSurfaceView: RemoteKeyView {
    let controller: TouchpadController
    private var chord = ReleaseChord()
    /// True when the next mouse up belongs to a press that the pad used.
    private var skipUp = false
    private var area: NSTrackingArea?

    init(controller: TouchpadController) {
        self.controller = controller
        super.init(keyTarget: controller)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller.padFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        controller.padFocused = false
        controller.release()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { controller.release() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Takes the keyboard focus, so that keys go to the computer from the start.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    // MARK: Mouse

    /// A press on the free pad takes the pointer and does not click.
    private func take() {
        window?.makeFirstResponder(self)
        controller.capture()
    }

    override func mouseDown(with event: NSEvent) {
        guard controller.captured else {
            take()
            skipUp = true
            return
        }
        chord.interrupt()
        // Clicks carry no modifiers, so Control-click is the right button
        // as on the Mac, and Option-click the middle button as in XQuartz.
        if event.modifierFlags.contains(.control) {
            controller.click(.right)
            skipUp = true
        } else if event.modifierFlags.contains(.option) {
            controller.click(.middle)
            skipUp = true
        } else {
            controller.leftDown()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if skipUp {
            skipUp = false
            return
        }
        controller.leftUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard controller.captured else { return take() }
        chord.interrupt()
        controller.click(.right)
    }

    override func rightMouseUp(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {
        guard controller.captured else { return take() }
        chord.interrupt()
        if event.buttonNumber == 2 { controller.click(.middle) }
    }

    override func otherMouseUp(with event: NSEvent) {}

    override func mouseMoved(with event: NSEvent) { motion(event) }
    override func mouseDragged(with event: NSEvent) { motion(event) }
    override func rightMouseDragged(with event: NSEvent) { motion(event) }
    override func otherMouseDragged(with event: NSEvent) { motion(event) }

    /// The deltas of a held pointer are the motion of the trackpad or the
    /// mouse, with the acceleration of macOS. A positive dy moves down.
    private func motion(_ event: NSEvent) {
        guard controller.captured else { return }
        controller.moved(dx: event.deltaX, dy: event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        guard controller.captured else { return super.scrollWheel(with: event) }
        chord.interrupt()
        controller.scrolled(event)
    }

    // MARK: Keys

    override func willSendKey() { chord.interrupt() }

    override func flagsChanged(with event: NSEvent) {
        if controller.captured && chord.flags(event.modifierFlags) { controller.release() }
        super.flagsChanged(with: event)
    }
}
