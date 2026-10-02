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
        .commands {
            CommandMenu("Go") { GoMenu(launch: delegate.launch) }
        }

        Settings {
            if case .ready(let model) = delegate.launch {
                SettingsView().fluxScreen().modifier(ThemeRoot()).environment(model)
            }
        }

        // A window, not a menu: a menu runs no task when it opens, so the
        // master tile could not read a fresh output for its choices.
        MenuBarExtra {
            switch delegate.launch {
            case .ready(let model):
                MenuBarView().fluxScreen().modifier(ThemeRoot()).environment(model)
            case .failed(let message):
                LaunchErrorMenu(message: message)
            }
        } label: {
            MenuBarLabel(launch: delegate.launch)
        }
        .menuBarExtraStyle(.window)
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
        model.watchTheme()
        FeatureHooks.didLaunch(model: model)
        model.startConnectGrace()
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
            ContentView().fluxScreen().modifier(ThemeRoot()).environment(model)
        case .failed(let message):
            ContentUnavailableView("Flux could not start", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}

/// The menu bar panel when the core did not start: the error, the window
/// that shows it, and Quit.
struct LaunchErrorMenu: View {
    let message: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flux could not start")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Open Flux") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit Flux") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// The Flux mark in the menu bar, dimmed while no paired computer is
/// connected, with the count of the items that need the user.
struct MenuBarLabel: View {
    let launch: Launch

    var body: some View {
        if case .ready(let model) = launch {
            MenuBarMark(model: model)
        } else {
            Image("MenuBarIconOffline")
        }
    }
}

private struct MenuBarMark: View {
    let model: AppModel

    var body: some View {
        let count = Inbox.needsYou(model.inboxItems(now: Date()))
        HStack(spacing: 3) {
            Image(model.connectedPaired.isEmpty ? "MenuBarIconOffline" : "MenuBarIcon")
            if count > 0 {
                Text(count > 9 ? "9+" : "\(count)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 0 ? "Flux" : "Flux, \(needsText(count))")
    }
}
