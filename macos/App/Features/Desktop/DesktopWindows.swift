import AppKit
import FluxKit
import SwiftUI

/// The remote desktop window. 1 computer streams at a time, as on the
/// phone. The stream stops when the window closes, and it pauses while the
/// window is in the Dock or this Mac sleeps or locks.
@MainActor
final class DesktopWindows: NSObject, NSWindowDelegate {
    static let shared = DesktopWindows()

    private struct Entry {
        let deviceId: String
        let window: NSWindow
        let controller: DesktopController
    }
    private var entry: Entry?
    /// True while the screen of this Mac is locked.
    private var locked = false

    override init() {
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(macPaused), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(macPaused), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(macPaused), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(macResumed), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(macResumed), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// Shows the screen of a computer. The computer can show any window,
    /// such as a password manager, so a new window asks for Touch ID or the
    /// password of this Mac first, like the phone asks for its screen lock.
    func open(_ device: DeviceSnapshot, app: AppModel) {
        if front(device.id) { return }
        ReplyLock.run(
            reason: "show and control the screen of \(device.name)",
            action: { [weak self] in self?.show(device, app: app) },
            onError: { app.show($0) }
        )
    }

    private func front(_ deviceId: String) -> Bool {
        guard let entry, entry.deviceId == deviceId else { return false }
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func show(_ device: DeviceSnapshot, app: AppModel) {
        guard !front(device.id), let plugin = app.core.plugin(DesktopPlugin.self), let input = app.core.plugin(RemoteInputPlugin.self) else { return }
        // The stream of another computer stops with its window.
        entry?.window.close()
        let controller = DesktopController(device: device, app: app, plugin: plugin, input: input)
        let hosting = NSHostingController(rootView: DesktopView(controller: controller))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Desktop of \(device.name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1280, height: 840))
        if !window.setFrameUsingName("Desktop") { window.center() }
        window.setFrameAutosaveName("Desktop")
        entry = Entry(deviceId: device.id, window: window, controller: controller)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    func windowWillClose(_ notification: Notification) {
        guard let entry, entry.window === notification.object as? NSWindow else { return }
        entry.controller.close()
        self.entry = nil
    }

    func windowDidMiniaturize(_ notification: Notification) {
        entry?.controller.pause("The stream stopped while the window was in the Dock.")
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        entry?.controller.resume()
    }

    func windowDidResignKey(_ notification: Notification) {
        entry?.controller.pointerInside = false
    }

    @objc private func macPaused() {
        entry?.controller.pause("The stream stopped while this Mac slept or was locked.")
    }

    @objc private func macResumed() {
        guard !locked, let entry, !entry.window.isMiniaturized else { return }
        entry.controller.resume()
    }

    @objc private func screenLocked() {
        locked = true
        macPaused()
    }

    @objc private func screenUnlocked() {
        locked = false
        macResumed()
    }
}
