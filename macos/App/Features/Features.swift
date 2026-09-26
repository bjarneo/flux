import FluxKit
import SwiftUI

// Each feature adds one line to each list that it uses. Keep one entry per
// line so that features merge without conflicts.

enum PluginRegistry {
    @MainActor
    static func make() -> [FluxPlugin] {
        [
            PingPlugin(),
            MprisPlugin(),
            MacMediaPlugin(),
            RunCommandPlugin(),
        ]
    }
}

/// The sections of a paired computer, in display order.
struct FeatureSections: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            MediaSection(device: device)
            CommandsSection(device: device)
        }
    }
}

/// The Features tab of the settings window.
struct FeatureSettings: View {
    var body: some View {
        Group {
            MediaSettings()
        }
    }
}

/// Menu bar items for one connected, paired computer.
struct FeatureMenuItems: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            MediaMenuItems(device: device)
            CommandsMenu(device: device)
        }
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
    }

    /// Files dropped on the Dock icon or opened with Flux.
    static func open(urls: [URL], model: AppModel) {
    }
}
