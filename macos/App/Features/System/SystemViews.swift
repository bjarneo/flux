import FluxKit
import SwiftUI

/// The battery of a computer, next to its state in the header.
struct BatteryBadge: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[device.id] {
            Label(battery.charging ? "\(battery.charge)%, charging" : "\(battery.charge)%", systemImage: battery.symbol)
        }
    }
}

@MainActor
enum SystemFeature {
    /// Connects the Focus filter to Do Not Disturb sync.
    static func didLaunch(model: AppModel) {
        if let dnd = model.core.plugin(DndPlugin.self) {
            FocusBridge.start(dnd)
        }
    }
}

extension BatteryState {
    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch charge {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
