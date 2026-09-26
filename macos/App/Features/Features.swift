import FluxKit
import SwiftUI

// Each feature adds one line to each list that it uses. Keep one entry per
// line so that features merge without conflicts.

enum PluginRegistry {
    @MainActor
    static func make() -> [FluxPlugin] {
        [
            PingPlugin(),
            ApprovePlugin(),
        ]
    }
}

/// The sections of a paired computer, in display order.
struct FeatureSections: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ApproveSection(device: device)
        }
    }
}

/// The Features tab of the settings window.
struct FeatureSettings: View {
    var body: some View {
        Group {
        }
    }
}

/// Menu bar items for one connected, paired computer.
struct FeatureMenuItems: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ApproveMenuItem(device: device)
        }
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        ApprovePromptWindow.install(model: model)
    }

    /// Files dropped on the Dock icon or opened with Flux.
    static func open(urls: [URL], model: AppModel) {
    }
}
