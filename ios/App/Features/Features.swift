import FluxKit
import SwiftUI

// Each feature adds one line to each list that it uses. Keep one entry per
// line so that features merge without conflicts.

enum PluginRegistry {
    @MainActor
    static func make() -> [FluxPlugin] {
        [
            PingPlugin(),
            SharePlugin(),
            ClipboardPlugin(images: true),
            CaptureWatchPlugin(),
            MprisPlugin(),
            RunCommandPlugin(),
            NotificationsPlugin(),
            BatteryPlugin(),
            DndPlugin(),
            RingPlugin(),
            RemoteInputPlugin(),
            DesktopPlugin(),
            HerdrPlugin(),
            BrowsePlugin(),
            WebcamPlugin(),
            MicPlugin(),
            ApprovePlugin(),
        ]
    }
}

/// The tiles of a paired computer's screen, in reading order.
struct FeatureTiles: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareTile(device: device)
            CameraTile(device: device)
            MediaTile(device: device)
            MicTile(device: device)
            CommandsTile(device: device)
            NotificationsTile(device: device)
            TouchpadTile(device: device)
            DesktopTile(device: device)
            AgentsTile(device: device)
            BrowseTile(device: device)
            ApproveTile(device: device)
        }
    }
}

/// A screen of a feature that the app opens by code, for example after
/// Face ID.
enum FeatureRoute: Hashable {
    case touchpad(String)
    case desktop(String)
    case agents(String)
    case agent(String, String)
    case terminal(String, String)
    case browse(String)
    case camera(String)
    case mic(String)
    case approve(String)
}

/// The screen of a feature route.
struct FeatureDestination: View {
    let route: FeatureRoute

    var body: some View {
        switch route {
        case .touchpad(let id): TouchpadScreen(deviceId: id)
        case .desktop(let id): DesktopScreen(deviceId: id)
        case .agents(let id): AgentsScreen(deviceId: id)
        case .agent(let id, let pane): AgentScreen(deviceId: id, pane: pane)
        case .terminal(let id, let pane): TerminalScreen(deviceId: id, pane: pane)
        case .browse(let id): BrowseScreen(deviceId: id)
        case .camera(let id): CameraScreen(deviceId: id)
        case .mic(let id): MicScreen(deviceId: id)
        case .approve(let id): ApproveScreen(deviceId: id)
        }
    }
}

/// The quick actions under the header of a paired computer.
struct FeatureQuickActions: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            SendFilesQuickAction(device: device)
            SendPhotosQuickAction(device: device)
            SendClipboardQuickAction(device: device)
            PingQuickAction(device: device)
        }
    }
}

/// Banners on a computer's screen for something that waits for the user.
struct FeatureBanners: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ApproveBanner(device: device)
        }
    }
}

/// Short states in the header of a connected computer.
struct FeatureBadges: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            BatteryBadge(device: device)
            DndBadge(device: device)
        }
    }
}

/// The feature sections of the settings screen.
struct FeatureSettings: View {
    var body: some View {
        Group {
            ShareSettings()
            DndSettings()
            NotificationSettings()
            AgentSettings()
        }
    }
}

/// Views over the whole app, such as Quick Look.
struct FeatureRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(ShareRoot())
    }
}

/// Sheets that show over the whole app, also over its sheets, each from its
/// own window, see `Overlays`. The later ones are on top.
@MainActor
enum FeatureOverlays {
    static let layers: [AnyView] = [
        AnyView(OverlayLayer(modifier: ApproveRoot())),
        AnyView(OverlayLayer(modifier: RingRoot())),
    ]

    /// True while one of them shows, or the pairing sheet.
    static func shown(model: AppModel) -> Bool {
        model.pairSheetDevice != nil
            || ApprovePresenter.shared.state.isPresented
            || model.core.plugin(RingPlugin.self)?.model.ringing != nil
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        NotificationAccess.shared.refresh()
        ShareFeature.didLaunch(model: model)
        SystemFeature.didLaunch(model: model)
        AgentsFeature.didLaunch(model: model)
        BrowseFeature.didLaunch()
        ApproveFeature.didLaunch(model: model)
    }

    /// Runs after each change of the core state.
    static func stateChanged(_ state: CoreState, model: AppModel) {
        QueuedShares.shared.stateChanged(state)
    }

    /// Runs when the app comes on the screen or leaves it.
    static func sceneChanged(active: Bool, model: AppModel) {
        model.core.plugin(ClipboardPlugin.self)?.setActive(active)
        if active { NotificationAccess.shared.refresh() }
        // A computer that connects also gets the new images, through the plugin.
        if active { model.core.plugin(CaptureWatchPlugin.self)?.catchUp() }
        // Items from the share extension go to the computers that are connected.
        if active { QueuedShares.shared.drain() }
        // A link from a notification that opened Flux.
        if active { ShareFeature.shared.openPendingLink() }
        // iOS turns off the camera of an app that leaves the screen.
        if !active { model.core.plugin(WebcamPlugin.self)?.stopInBackground() }
    }

    /// Runs when the app stops being active: it leaves the screen, or iOS
    /// covers it, for example with Notification Center.
    static func leftActive(model: AppModel) {
        // The words of a dictation that runs on would go out later.
        Dictation.cancelAll()
    }

    /// True while a feature runs in the background and needs the links:
    /// the microphone stream, which keeps Flux running with the audio
    /// background mode.
    static func runsInBackground(model: AppModel) -> Bool {
        model.core.plugin(MicPlugin.self)?.model.status.active == true
    }

    /// True while the screen of the iPhone must stay on: the webcam or the
    /// remote desktop streams, also from another screen of Flux, or the
    /// touchpad shows. A stream stops when the iPhone locks by itself.
    static func keepsScreenOn(model: AppModel) -> Bool {
        model.core.plugin(WebcamPlugin.self)?.model.status.active == true
            || model.core.plugin(DesktopPlugin.self)?.model.status.active == true
            || model.touchpadOpen
    }
}
