import AppKit
import FluxKit
import SwiftUI

/// The touchpad windows, 1 per computer. A window gives the pointer back to
/// this Mac when it closes or stops being the key window.
@MainActor
final class TouchpadWindows: NSObject, NSWindowDelegate {
    static let shared = TouchpadWindows()

    private struct Entry {
        let window: NSWindow
        let controller: TouchpadController
    }
    private var windows: [String: Entry] = [:]

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// Shows the touchpad of a computer. Remote input can type in any window
    /// of the computer, so a new window asks for Touch ID or the password of
    /// this Mac first, like the phone asks for its screen lock.
    func open(_ device: DeviceSnapshot, app: AppModel) {
        if front(device.id) { return }
        ReplyLock.run(
            reason: "control the pointer and the keys of \(device.name)",
            action: { [weak self] in self?.show(device, app: app) },
            onError: { app.show($0) }
        )
    }

    private func front(_ deviceId: String) -> Bool {
        guard let entry = windows[deviceId] else { return false }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func show(_ device: DeviceSnapshot, app: AppModel) {
        guard !front(device.id), let plugin = app.core.plugin(RemoteInputPlugin.self) else { return }
        let controller = TouchpadController(device: device, app: app, plugin: plugin)
        let hosting = NSHostingController(rootView: TouchpadView(controller: controller))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Touchpad and Keyboard for \(device.name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 600, height: 520))
        if !window.setFrameUsingName("Touchpad") { window.center() }
        window.setFrameAutosaveName("Touchpad")
        windows[device.id] = Entry(window: window, controller: controller)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func entry(_ notification: Notification) -> (key: String, value: Entry)? {
        guard let window = notification.object as? NSWindow else { return nil }
        return windows.first { $0.value.window === window }
    }

    func windowDidResignKey(_ notification: Notification) {
        entry(notification)?.value.controller.release()
    }

    func windowWillClose(_ notification: Notification) {
        guard let entry = entry(notification) else { return }
        entry.value.controller.close()
        windows[entry.key] = nil
    }

    @objc private func appResigned() {
        for entry in windows.values { entry.controller.release() }
    }
}
