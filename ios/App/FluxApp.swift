import FluxKit
import SwiftUI
import UIKit

@main
struct FluxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(launch: delegate.launch)
        }
    }
}

/// The result of starting the core.
enum Launch {
    case ready(AppModel)
    case failed(String)
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let launch: Launch

    override init() {
        // The notification delegate must exist before launch ends, so that
        // a tap on a notification that launched Flux arrives.
        Notifier.shared.start()
        do {
            let core = try FluxCore(plugins: PluginRegistry.make())
            launch = .ready(AppModel(core: core))
        } catch {
            launch = .failed(String(describing: error))
        }
        super.init()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if case .ready(let model) = launch {
            // The network starts when the scene becomes active.
            FeatureHooks.didLaunch(model: model)
        }
        return true
    }
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
