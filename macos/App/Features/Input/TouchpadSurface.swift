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
final class TouchpadSurfaceView: NSView, NSTextInputClient {
    let controller: TouchpadController
    private var chord = ReleaseChord()
    /// True when the next mouse up belongs to a press that the pad used.
    private var skipUp = false
    /// The text of a dead key while macOS composes, such as ´ before e.
    private var marked = ""
    private var area: NSTrackingArea?
    private var monitor: Any?

    init(controller: TouchpadController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
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

    /// Watches the keys of the window for a held pointer, and takes the
    /// keyboard focus, so that keys go to the computer from the start.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.intercept(event) ?? false }
            return used ? nil : event
        }
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

    override func keyDown(with event: NSEvent) {
        guard controller.ready else { return super.keyDown(with: event) }
        chord.interrupt()
        let press = RemoteInput.press(keyCode: event.keyCode, flags: event.modifierFlags, plain: event.charactersIgnoringModifiers,
                                      optionIsAlt: controller.optionIsAlt, commandIsSuper: controller.captured)
        switch press {
        case .key(let k, let held):
            // A special key ends a dead key that waits.
            if !marked.isEmpty {
                inputContext?.discardMarkedText()
                marked = ""
            }
            controller.key(k, held: held)
        case .text(let text, let held):
            controller.text(text, held: held)
        case .compose:
            interpretKeyEvents([event])
        case .ignore:
            super.keyDown(with: event)
        }
    }

    /// While the pad holds the pointer, each key goes to the computer before
    /// the menus of this Mac see it, so Command shortcuts reach the computer.
    private func intercept(_ event: NSEvent) -> Bool {
        guard controller.captured, event.window === window else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        if controller.captured && chord.flags(event.modifierFlags) { controller.release() }
        super.flagsChanged(with: event)
    }

    /// Commands of the text input system, such as moveLeft:, have their own
    /// special keys, so they do nothing here.
    override func doCommand(by selector: Selector) {}

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        controller.text(Self.plain(string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = Self.plain(string) }

    /// macOS keeps the marked text as typed text.
    func unmarkText() {
        let text = marked
        marked = ""
        controller.text(text)
    }

    func selectedRange() -> NSRange { NSRange(location: marked.utf16.count, length: 0) }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// An input method shows its window at the center of the pad.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 20), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
}
