import FluxKit
import SwiftUI

/// The battery of a computer, in the header.
struct BatteryBadge: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[device.id] {
            Label(battery.text, systemImage: battery.symbol)
                .accessibilityLabel("Battery \(battery.text)")
        }
    }
}

extension BatteryState {
    /// The charge, and whether the computer charges.
    var text: String { charging ? "\(charge)%, charging" : "\(charge)%" }

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
