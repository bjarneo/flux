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
        ]
    }
}

/// The tiles of a paired computer's screen, in reading order.
struct FeatureTiles: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareTile(device: device)
            MediaTile(device: device)
            CommandsTile(device: device)
            NotificationsTile(device: device)
            TouchpadTile(device: device)
            DesktopTile(device: device)
        }
    }
}

/// A screen of a feature that the app opens by code, for example after
/// Face ID.
enum FeatureRoute: Hashable {
    case touchpad(String)
    case desktop(String)
}

/// The screen of a feature route.
struct FeatureDestination: View {
    let route: FeatureRoute

    var body: some View {
        switch route {
        case .touchpad(let id): TouchpadScreen(deviceId: id)
        case .desktop(let id): DesktopScreen(deviceId: id)
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
        }
    }
}

/// Views over the whole app, such as Quick Look and the ring.
struct FeatureRoot: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(ShareRoot())
            .modifier(RingRoot())
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        NotificationAccess.shared.refresh()
        ShareFeature.didLaunch(model: model)
        SystemFeature.didLaunch(model: model)
    }

    /// Runs when the app comes on the screen or leaves it.
    static func sceneChanged(active: Bool, model: AppModel) {
        model.core.plugin(ClipboardPlugin.self)?.setActive(active)
        if active { NotificationAccess.shared.refresh() }
        // A computer that connects also gets the new images, through the plugin.
        if active { model.core.plugin(CaptureWatchPlugin.self)?.catchUp() }
    }
}
