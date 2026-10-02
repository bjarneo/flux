import AppKit
import FluxKit
import SwiftUI
import UserNotifications

/// The browse windows, 1 per computer. Closing a window ends its SSH session.
@MainActor
final class BrowseWindows: NSObject, NSWindowDelegate {
    static let shared = BrowseWindows()

    private struct Entry {
        let window: NSWindow
        let browser: BrowseModel
    }
    private var open: [String: Entry] = [:]
    private weak var plugin: BrowsePlugin?

    /// Shows the browse window of a computer, and opens it when it is not open.
    func show(_ deviceId: String, app: AppModel) {
        if let entry = open[deviceId] {
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let plugin = app.core.plugin(BrowsePlugin.self), let browser = plugin.browser(for: deviceId) else { return }
        self.plugin = plugin
        let hosting = NSHostingController(rootView: BrowseView(browser: browser).themeWindow(app))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Files on \(browser.deviceName)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 780, height: 540))
        if !window.setFrameUsingName("Browse") { window.center() }
        window.setFrameAutosaveName("Browse")
        open[deviceId] = Entry(window: window, browser: browser)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asks before a close stops running downloads.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = open.values.first(where: { $0.window === sender }), entry.browser.activeDownloads > 0 else { return true }
        let count = entry.browser.activeDownloads
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Stop the download?" : "Stop \(count) downloads?"
        alert.informativeText = "Closing the window ends the session with \(entry.browser.deviceName), and unfinished files are deleted."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = open.first(where: { $0.value.window === window })?.key else { return }
        open[id] = nil
        plugin?.close(id)
    }
}

@MainActor
enum BrowseFeature {
    /// Opens a downloaded file from its notification, or shows it in Finder.
    static func didLaunch() {
        Notifier.shared.register(category: BrowsePlugin.downloadCategory, actions: [
            UNNotificationAction(identifier: "reveal", title: "Show in Finder"),
        ]) { action, info, _ in
            guard let path = info[BrowsePlugin.pathKey] as? String else { return }
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if action == "reveal" {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else if action == UNNotificationDefaultActionIdentifier {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
