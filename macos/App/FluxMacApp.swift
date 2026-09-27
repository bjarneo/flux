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
            if case .ready(let model) = delegate.launch {
                MenuBarView().environment(model)
            }
        } label: {
            MenuBarLabel(launch: delegate.launch)
        }
    }
}

/// The result of starting the core.
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
