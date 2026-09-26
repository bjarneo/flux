import AppKit
import FluxKit
import SwiftUI

/// The camera windows, 1 per computer. Closing a window stops its camera.
@MainActor
final class CameraWindows: NSObject, NSWindowDelegate {
    static let shared = CameraWindows()

    private struct Entry {
        let window: NSWindow
        let model: CameraWindowModel
    }
    private var open: [String: Entry] = [:]

    /// Shows the camera window of a computer in a mode, and opens it when it is not open.
    func show(_ device: DeviceSnapshot, mode: CameraMode, app: AppModel) {
        if let entry = open[device.id] {
            entry.model.mode = mode
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = CameraWindowModel(deviceId: device.id, app: app, mode: mode)
        let hosting = NSHostingController(rootView: CameraView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Camera for \(device.name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 680))
        if !window.setFrameUsingName("Camera") { window.center() }
        window.setFrameAutosaveName("Camera")
        open[device.id] = Entry(window: window, model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = open.first(where: { $0.value.window === window })?.key else { return }
        open[id]?.model.close()
        open[id] = nil
    }
}
