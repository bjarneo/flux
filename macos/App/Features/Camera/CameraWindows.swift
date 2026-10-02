import AppKit
import FluxKit
import SwiftUI

/// The camera windows, 1 per computer. Closing a window stops its camera,
/// and the camera pauses while its window does not show.
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
        let hosting = NSHostingController(rootView: CameraView(model: model).themeWindow(app))
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

    func windowDidMiniaturize(_ notification: Notification) {
        visibilityChanged(notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        visibilityChanged(notification)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        visibilityChanged(notification)
    }

    /// Turns the camera off while its window is in the Dock or behind other
    /// windows, and on again when the window shows.
    private func visibilityChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = open.values.first(where: { $0.window === window }) else { return }
        entry.model.camera.setVisible(!window.isMiniaturized && window.occlusionState.contains(.visible))
    }
}
