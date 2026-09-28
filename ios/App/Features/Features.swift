import FluxKit
import SwiftUI

// Each feature adds one line to each list that it uses. Keep one entry per
// line so that features merge without conflicts.

enum PluginRegistry {
    @MainActor
    static func make() -> [FluxPlugin] {
        [
            PingPlugin(),
            NotificationsPlugin(),
            BatteryPlugin(),
        ]
    }
}

/// The tiles of a paired computer's screen, in reading order.
struct FeatureTiles: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            NotificationsTile(device: device)
        }
    }
}

/// The quick actions under the header of a paired computer.
struct FeatureQuickActions: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
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
        }
    }
}

/// The feature sections of the settings screen.
struct FeatureSettings: View {
    var body: some View {
        Group {
            NotificationSettings()
        }
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        NotificationAccess.shared.refresh()
    }

    /// Runs when the app comes on the screen or leaves it.
    static func sceneChanged(active: Bool, model: AppModel) {
        model.core.plugin(ClipboardPlugin.self)?.setActive(active)
        if active { NotificationAccess.shared.refresh() }
    }
}
