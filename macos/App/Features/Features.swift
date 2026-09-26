import FluxKit
import SwiftUI

// Each feature adds one line to each list that it uses. Keep one entry per
// line so that features merge without conflicts.

enum PluginRegistry {
    @MainActor
    static func make() -> [FluxPlugin] {
        [
            PingPlugin(),
            MicPlugin(),
            NotificationsPlugin(),
            FindMyPhonePlugin(),
            BatteryPlugin(),
            DndPlugin(),
            BrowsePlugin(),
            SharePlugin(),
            ClipboardPlugin(),
            CaptureWatchPlugin(),
        ]
    }
}

/// The sections of a paired computer, in display order.
struct FeatureSections: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareSection(device: device)
            ClipboardSection(device: device)
            MicSection(device: device)
            SystemSection(device: device)
            BrowseSection(device: device)
        }
    }
}

/// The Features tab of the settings window.
struct FeatureSettings: View {
    var body: some View {
        Group {
            ShareSettings()
            DndSettings()
        }
    }
}

/// Menu bar items for one connected, paired computer.
struct FeatureMenuItems: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareMenuItems(device: device)
            MicMenuItem(device: device)
            RingMenuItem(device: device)
            BrowseMenuItem(device: device)
        }
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        SystemFeature.didLaunch(model: model)
        BrowseFeature.didLaunch()
        ShareServices.install(model: model)
    }

    /// Files dropped on the Dock icon or opened with Flux.
    static func open(urls: [URL], model: AppModel) {
        ShareActions.open(urls: urls, model: model)
    }
}
