import AppKit
import FluxKit
import SwiftUI

/// The requests of a computer to start the webcam or the microphone of this
/// Mac. While Flux is the active app, a prompt window shows the request.
/// Otherwise a notification shows it. Only a click on start starts a stream.
@MainActor
enum StreamRequestFeature {
    private static var observer: NSObjectProtocol?

    /// Lets the plugin show the prompt and start a stream after a click on start.
    static func install(model: AppModel) {
        guard let plugin = model.core.plugin(StreamRequestPlugin.self) else { return }
        plugin.model.isAppActive = { NSApp.isActive }
        plugin.model.present = { StreamRequestWindow.shared.show(plugin, app: model) }
        plugin.model.open = { request in StreamRequestFeature.open(request, model: model) }
        // A request that waits shows when Flux becomes the active app. A
        // click on the notification also makes Flux active, and its start
        // ends the request, so the check waits for that click first.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    plugin.expire()
                    if NSApp.isActive, plugin.model.current != nil { StreamRequestWindow.shared.show(plugin, app: model) }
                }
            }
        }
    }

    /// Opens the webcam or the microphone page of the computer in a window
    /// and starts the stream with its start code and the saved settings.
    static func open(_ request: StreamRequest, model: AppModel) {
        switch request.kind {
        case .webcam:
            StreamWindows.shared.show(.stream, deviceId: request.computerId, app: model)
            model.core.plugin(WebcamPlugin.self)?.start(request.computerId)
        case .mic:
            StreamWindows.shared.show(.mic, deviceId: request.computerId, app: model)
            model.core.plugin(MicPlugin.self)?.start(request.computerId)
        }
    }
}

/// The window of the stream prompt. It floats over other windows, and it
/// closes when no request is open. Its close button is Not now for each
/// open request.
@MainActor
final class StreamRequestWindow: NSObject, NSWindowDelegate {
    static let shared = StreamRequestWindow()

    private var window: NSWindow?
    private weak var plugin: StreamRequestPlugin?

    /// The prompt has a fixed size. A window that follows the SwiftUI size
    /// loops in Auto Layout when the wrapped text changes height.
    private static let size = NSSize(width: 440, height: 320)

    /// Shows the newest open request.
    func show(_ plugin: StreamRequestPlugin, app: AppModel) {
        guard plugin.model.current != nil else { return }
        self.plugin = plugin
        let w = window ?? make(plugin, app: app)
        if window == nil {
            w.center()
            window = w
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// Hides the window. The requests stay as they are.
    func hide() {
        window?.orderOut(nil)
    }

    private func make(_ plugin: StreamRequestPlugin, app: AppModel) -> NSWindow {
        let host = NSHostingController(rootView: StreamRequestPrompt(plugin: plugin) { [weak self] in self?.hide() }.themeWindow(app))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(Self.size)
        w.title = "Flux"
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.delegate = self
        return w
    }

    /// The close button of the window. `hide` does not come here.
    func windowWillClose(_ notification: Notification) {
        guard let plugin else { return }
        for request in plugin.model.requests { plugin.dismiss(request.id) }
    }
}

/// The prompt of the newest stream request: the question, what the start
/// does, Not now, and the start button. Start is not the default button,
/// so that a key press for another window cannot start a stream.
struct StreamRequestPrompt: View {
    let plugin: StreamRequestPlugin
    let close: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(spacing: 14) {
            if let request = plugin.model.current {
                Image(systemName: request.kind == .webcam ? "web.camera" : "mic")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(request.kind.detail(computer: request.computerName))
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: TiledMetrics.gap) {
                    Button(StreamRequest.notNowLabel) { plugin.dismiss(request.id) }
                        .buttonStyle(FluxButtonStyle(kind: .outlined))
                        .keyboardShortcut(.cancelAction)
                    Button(request.kind.startLabel) { plugin.start(request.id) }
                        .buttonStyle(FluxButtonStyle(kind: .filled))
                }
                .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The last request ended: started, Not now, timed out, or unpaired.
        .onChange(of: plugin.model.current == nil) { _, gone in
            if gone { close() }
        }
    }
}

/// The windows of the webcam page and the microphone page of a computer,
/// which a click on start opens. Each computer has 1 window for each page.
/// The page is the same as under Control.
@MainActor
final class StreamWindows: NSObject, NSWindowDelegate {
    static let shared = StreamWindows()

    private var open: [String: NSWindow] = [:]

    /// Shows the page of the computer, and opens its window when it is not open.
    func show(_ card: MacCard, deviceId: String, app: AppModel) {
        let key = "\(card.rawValue) \(deviceId)"
        if let window = open[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let name = app.pairedDevice(deviceId)?.name ?? "the computer"
        let host = NSHostingController(rootView: FeaturePage(card: card, deviceId: deviceId).themeWindow(app))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "\(card.title) for \(name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(card == .stream ? NSSize(width: 640, height: 680) : NSSize(width: 560, height: 440))
        window.center()
        open[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = open.first(where: { $0.value === window })?.key else { return }
        open[key] = nil
    }
}
