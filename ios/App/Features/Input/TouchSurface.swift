import FluxKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A view that reports its fingers and takes the keys of a hardware
/// keyboard, for the touchpad and the remote desktop. Each finger has a
/// number that grows, so the lowest number is the earliest finger. A touch
/// makes the view the first responder, so that the keys go to it, unless
/// `keepsFocus` says that a text field keeps the keyboard.
final class TouchSurfaceView: UIView {
    /// Gets the fingers on the view after each touch event, by number. No
    /// fingers means that the last one lifted.
    var onTouches: (([Int: CGPoint]) -> Void)?
    /// iOS took the touches, for example for a system gesture.
    var onCancel: (() -> Void)?
    /// Gets each key press of a hardware keyboard. It returns false for a
    /// key that stays on the iPhone.
    var onKey: ((UIKey) -> Bool)?
    /// Gets the new size of the view.
    var onSize: ((CGSize) -> Void)?
    /// True when a text field keeps the keyboard. On the remote desktop, a
    /// touch then keeps the keyboard of the iPhone, so that the user can
    /// click a field on the computer and type at once.
    var keepsFocus: (() -> Bool)?

    private var numbers: [ObjectIdentifier: Int] = [:]
    private var points: [Int: CGPoint] = [:]
    private var nextNumber = 1
    private var sentKeys = Set<UIPress>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addGestureRecognizer(TouchClaim())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        onSize?(bounds.size)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder && keepsFocus?() != true { becomeFirstResponder() }
        for t in touches {
            let n = nextNumber
            nextNumber += 1
            numbers[ObjectIdentifier(t)] = n
            points[n] = t.location(in: self)
        }
        onTouches?(points)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let n = numbers[ObjectIdentifier(t)] { points[n] = t.location(in: self) }
        }
        onTouches?(points)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let n = numbers.removeValue(forKey: ObjectIdentifier(t)) { points[n] = nil }
        }
        onTouches?(points)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        numbers = [:]
        points = [:]
        onCancel?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, onKey?(key) == true {
                sentKeys.insert(press)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(sentKeys)
        sentKeys.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(sentKeys)
        sentKeys.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }
}

/// Claims the fingers on a touch view. iOS 26 goes back when a finger
/// swipes right anywhere on a screen, which would end a drag or a scroll
/// on the pad and close the screen. That swipe waits for this recognizer
/// to fail, and it does not fail while fingers are on the view. It lets the
/// touches through to the view.
final class TouchClaim: UIGestureRecognizer {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let down = (event.allTouches ?? []).filter { $0.view === view && $0.phase != .ended && $0.phase != .cancelled }
        state = down.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        if #available(iOS 26.0, *), let pop = navigationController?.interactiveContentPopGestureRecognizer, other === pop {
            return true
        }
        return super.shouldBeRequiredToFail(by: other)
    }

    /// The navigation controller of the view, through the responder chain.
    private var navigationController: UINavigationController? {
        var r: UIResponder? = view
        while let next = r?.next {
            if let vc = next as? UIViewController, let nav = vc.navigationController ?? (vc as? UINavigationController) { return nav }
            r = next
        }
        return nil
    }
}

/// Runs a check at a time in the future, such as the hold of a finger. A
/// new time replaces the old one.
@MainActor
final class Deadline {
    private var task: Task<Void, Never>?

    /// Runs `action` at `time` in system uptime, or cancels with nil.
    func set(_ time: TimeInterval?, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = nil
        guard let time else { return }
        let wait = max(0, time - Self.now)
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { action() }
        }
    }

    func cancel() { set(nil) {} }

    /// The time of touch events and deadlines, in system uptime.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A tap of the Taptic Engine when a finger holds, as the Android app buzzes.
@MainActor
enum HoldFeedback {
    static func play() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}
