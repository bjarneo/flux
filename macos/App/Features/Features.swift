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
            ClipboardPlugin(),
            CaptureWatchPlugin(),
            MprisPlugin(),
            RunCommandPlugin(),
            RemoteInputPlugin(),
            DesktopPlugin(),
            HerdrPlugin(),
            BrowsePlugin(),
            WebcamPlugin(),
            ScreenPlugin(),
            MicPlugin(),
            NotificationsPlugin(),
            BatteryPlugin(),
            DndPlugin(),
            ApprovePlugin(),
        ]
    }
}

/// The cards of a paired computer's dashboard, in reading order. The grid
/// fills rows from this order, so neighbors of similar size come together.
struct FeatureSections: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareSection(device: device)
            MediaSection(device: device)
            CameraSection(device: device)
            MicSection(device: device)
            ClipboardSection(device: device)
            CommandsSection(device: device)
            InputSection(device: device)
            DesktopSection(device: device)
            AgentsSection(device: device)
            StreamSection(device: device)
            ApproveSection(device: device)
        }
    }
}

/// The quick actions in the header of a paired computer.
struct FeatureQuickActions: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ShareQuickActions(device: device)
            BrowseQuickAction(device: device)
        }
    }
}

/// Short states next to the name of a paired computer.
struct FeatureBadges: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            BatteryBadge(device: device)
        }
    }
}

/// Banners above the cards for things that need attention now.
struct FeatureBanners: View {
    let device: DeviceSnapshot

    var body: some View {
        Group {
            ApproveBanner(device: device)
        }
    }
}

/// The Features tab of the settings window.
struct FeatureSettings: View {
    var body: some View {
        Group {
            ShareSettings()
            AgentSettings()
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
            CameraMenuItem(device: device)
            MediaMenuItems(device: device)
            CommandsMenu(device: device)
            InputMenuItem(device: device)
            DesktopMenuItem(device: device)
            AgentsMenuItem(device: device)
            BrowseMenuItem(device: device)
            StreamMenuItems(device: device)
            MicMenuItem(device: device)
            ApproveMenuItem(device: device)
        }
    }
}

@MainActor
enum FeatureHooks {
    /// Runs once after launch, before the network starts.
    static func didLaunch(model: AppModel) {
        SystemFeature.didLaunch(model: model)
        BrowseFeature.didLaunch()
        AgentsFeature.didLaunch(model: model)
        ShareServices.install(model: model)
        ApprovePromptWindow.install(model: model)
    }

    /// Files dropped on the Dock icon or opened with Flux.
    static func open(urls: [URL], model: AppModel) {
        ShareActions.open(urls: urls, model: model)
    }
}
