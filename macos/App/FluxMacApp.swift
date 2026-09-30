import AppKit
import FluxKit
import SwiftUI

@main
struct FluxMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Flux", id: "main") {
            RootView(launch: delegate.launch)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            if case .ready(let model) = delegate.launch {
                SettingsView().environment(model)
            }
        }

        MenuBarExtra {
            switch delegate.launch {
            case .ready(let model):
                MenuBarView().environment(model)
            case .failed(let message):
                LaunchErrorMenu(message: message)
            }
        } label: {
            MenuBarLabel(launch: delegate.launch)
        }
    }
}

/// The result of starting the core. The files of a Mac user are readable
/// after the login, so a start that failed fails again. Flux does not start
/// the core again. The window and the menu bar show the error until Flux quits.
enum Launch {
    case ready(AppModel)
    case failed(String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let launch: Launch

    override init() {
        Notifier.shared.start()
        do {
            let core = try FluxCore(plugins: PluginRegistry.make())
            launch = .ready(AppModel(core: core))
        } catch {
            launch = .failed(String(describing: error))
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.shared.start()
        ReplyLock.watch()
        guard case .ready(let model) = launch else { return }
        FeatureHooks.didLaunch(model: model)
        model.core.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard case .ready(let model) = launch else { return }
        model.core.stop()
    }

    /// Files dropped on the Dock icon or opened with Flux.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard case .ready(let model) = launch else { return }
        FeatureHooks.open(urls: urls, model: model)
    }

    /// Flux keeps running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct RootView: View {
    let launch: Launch

    var body: some View {
        switch launch {
        case .ready(let model):
            ContentView().environment(model)
        case .failed(let message):
            ContentUnavailableView("Flux could not start", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}

/// The menu bar menu when the core did not start: the error, the window
/// that shows it, and Quit.
struct LaunchErrorMenu: View {
    let message: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Flux could not start")
        Text(message)
        Divider()
        Button("Open Flux") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Flux") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The Flux mark in the menu bar, dimmed while no paired computer is connected.
struct MenuBarLabel: View {
    let launch: Launch

    var body: some View {
        if case .ready(let model) = launch, !model.connectedPaired.isEmpty {
            Image("MenuBarIcon")
        } else {
            Image("MenuBarIconOffline")
        }
    }
}
