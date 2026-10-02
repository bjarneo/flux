import AppKit
import FluxKit
import SwiftUI

/// The requests of a computer to start the webcam or the microphone of this
/// Mac. While Flux is the active app, a prompt window shows the request.
/// Otherwise a notification shows it. Only a click on start starts a stream.
@MainActor
enum StreamRequestFeature {
    private static var observer: NSObjectProtocol?
    /// The start that waits for the link of its computer after a click on start.
    private static var pending: PendingStart?
    private static var timer: Task<Void, Never>?

    /// Lets the plugin show the prompt and start a stream after a click on start.
    static func install(model: AppModel) {
        guard let plugin = model.core.plugin(StreamRequestPlugin.self) else { return }
        plugin.model.isAppActive = { NSApp.isActive }
        plugin.model.present = { StreamRequestWindow.shared.show(plugin, app: model) }
        plugin.model.open = { request in StreamRequestFeature.open(request, model: model) }
        plugin.model.openPage = { computerId, kind in StreamRequestFeature.openPage(computerId, kind, model: model) }
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

    /// The page of a stream: the webcam page or the microphone page.
    static func card(_ kind: StreamRequest.Kind) -> MacCard {
        kind == .webcam ? .stream : .mic
    }

    /// Opens the webcam or the microphone page of the computer in a window
    /// and starts the stream with its start code and the saved settings.
    /// While the link to the computer is down, the start waits up to
    /// `PendingStart.wait`.
    static func open(_ request: StreamRequest, model: AppModel) {
        openPage(request.computerId, request.kind, model: model)
        pending = PendingStart(request, now: .now)
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: PendingStart.wait)
            guard !Task.isCancelled else { return }
            check(model: model)
        }
        check(model: model)
    }

    /// Opens the webcam or the microphone page of the computer in a window
    /// and starts nothing. The user then starts the stream on the page. A
    /// computer that is not paired opens nothing.
    static func openPage(_ computerId: String, _ kind: StreamRequest.Kind, model: AppModel) {
        guard model.pairedDevice(computerId) != nil else { return }
        StreamWindows.shared.show(card(kind), deviceId: computerId, app: model)
    }

    /// Starts the waiting stream when the computer is connected. It runs
    /// after each change of the core state. An unpair ends the start at once.
    static func check(model: AppModel) {
        guard let p = pending else { return }
        let device = model.pairedDevice(p.computerId)
        // The camera of a Mac also works while Flux is not the active app.
        let step = p.step(active: true, online: device?.online == true, now: .now)
        guard step != .wait || device == nil else { return }
        pending = nil
        timer?.cancel()
        timer = nil
        guard device != nil else { return }
        guard step == .start else {
            model.show(p.failedText)
            return
        }
        // A stream that the user started in the meantime keeps running.
        guard model.core.plugin(StreamRequestPlugin.self)?.streams(p.kind, to: p.computerId) != true else { return }
        switch p.kind {
        case .webcam: model.core.plugin(WebcamPlugin.self)?.start(p.computerId)
        case .mic: model.core.plugin(MicPlugin.self)?.start(p.computerId)
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
        // The page shows the messages of the app, for example when a start does not reach the computer.
        let host = NSHostingController(rootView: FeaturePage(card: card, deviceId: deviceId).modifier(ToastOverlay()).themeWindow(app))
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
