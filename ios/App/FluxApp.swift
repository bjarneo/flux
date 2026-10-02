import FluxKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

@main
struct FluxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(starter: delegate.starter)
        }
    }
}

/// The result of starting the core.
enum Launch {
    case ready(AppModel)
    case failed(String)
}

/// Starts the core. Before the first unlock after a restart, iOS keeps the
/// files of Flux locked, and FluxKit cannot read the identity. The start
/// then fails and makes no new identity. Flux starts the core again when
/// iOS unlocks the files, and when Flux becomes active. Each of these
/// events tries once, so a start that keeps failing does not loop.
@MainActor
@Observable
final class CoreStarter {
    private(set) var launch: Launch
    /// The observers that start the core again while the identity is locked.
    @ObservationIgnored private(set) var observers: [NSObjectProtocol] = []
    /// True after launch ended. The features start only after that.
    @ObservationIgnored private var launched = false
    /// True after the features started.
    @ObservationIgnored private var started = false

    /// The center of the unlock and activation notifications.
    private let center: NotificationCenter
    /// Makes the core, see `make`.
    private let makeCore: @MainActor () -> (launch: Launch, locked: Bool)
    /// Starts the features, see `FeatureHooks.didLaunch`.
    private let startHooks: @MainActor (AppModel) -> Void

    static let lockedNote = "Flux tries again when you unlock this iPhone and when Flux opens."

    /// The tests give their own center, core, and features.
    init(center: NotificationCenter = .default,
         make: @escaping @MainActor () -> (launch: Launch, locked: Bool) = CoreStarter.make,
         didLaunch: @escaping @MainActor (AppModel) -> Void = { FeatureHooks.didLaunch(model: $0) }) {
        self.center = center
        makeCore = make
        startHooks = didLaunch
        let (launch, locked) = make()
        self.launch = launch
        if locked { waitForUnlock() }
    }

    /// Makes the core. `locked` is true when the identity did not read.
    static func make() -> (launch: Launch, locked: Bool) {
        do {
            let core = try FluxCore(plugins: PluginRegistry.make())
            return (.ready(AppModel(core: core, demo: DemoMode.isOn)), false)
        } catch let error as IdentityUnreadable {
            return (.failed("\(error)\n\n\(lockedNote)"), true)
        } catch {
            return (.failed(String(describing: error)), false)
        }
    }

    private func waitForUnlock() {
        guard observers.isEmpty else { return }
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retry() }
            })
        }
    }

    /// Starts the core again after a start that could not read the identity.
    private func retry() {
        guard case .failed = launch else { return }
        let (next, locked) = makeCore()
        launch = next
        if !locked {
            for o in observers { center.removeObserver(o) }
            observers = []
        }
        startFeatures()
    }

    /// Call it when launch ends. A core that starts later starts its features then.
    func didFinishLaunching() {
        launched = true
        startFeatures()
    }

    /// Starts the features once, after launch ended and the core started.
    /// The network starts when the scene becomes active. The demo starts no
    /// feature, see `DemoMode`.
    private func startFeatures() {
        guard launched, !started, case .ready(let model) = launch else { return }
        started = true
        if !model.demo { startHooks(model) }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let starter: CoreStarter

    override init() {
        // The notification delegate must exist before launch ends, so that
        // a tap on a notification that launched Flux arrives. Flux asks for
        // the permission at the first pairing, see `NotificationAccess.ask`.
        UNUserNotificationCenter.current().delegate = Notifier.shared
        starter = CoreStarter()
        super.init()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ReplyLock.watch()
        starter.didFinishLaunching()
        return true
    }
}

struct RootView: View {
    let starter: CoreStarter

    var body: some View {
        switch starter.launch {
        case .ready(let model):
            // The model must wrap ThemeRoot, which reads it.
            ContentView().modifier(ThemeRoot()).environment(model)
        case .failed(let message):
            ContentUnavailableView("Flux could not start", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }
}
