import FluxKit
import SwiftUI

/// The battery of a computer and the button that rings it.
struct SystemSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        Section("System") {
            if let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[device.id] {
                LabeledContent("Battery") {
                    Label(battery.charging ? "\(battery.charge)%, charging" : "\(battery.charge)%", systemImage: battery.symbol)
                }
            }
            if let ring = model.core.plugin(FindMyPhonePlugin.self)?.model, ring.ringingDevice == device.id {
                LabeledContent("\(device.name) is ringing this Mac") {
                    Button("Stop ringing") { ring.stop() }
                }
            }
            LabeledContent("Find my computer") {
                Button("Ring") { model.core.plugin(FindMyPhonePlugin.self)?.ring(device.id) }
                    .disabled(!device.online || !device.accepts(PacketType.findMyPhone))
                    .help("Play a sound on \(device.name) until someone stops it")
            }
        }
    }
}

/// The menu bar items that ring a computer and stop its ring on this Mac.
struct RingMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let ring = model.core.plugin(FindMyPhonePlugin.self)?.model, ring.ringingDevice == device.id {
            Button("Stop ringing") { ring.stop() }
        }
        if device.accepts(PacketType.findMyPhone) {
            Button("Ring \(device.name)") { model.core.plugin(FindMyPhonePlugin.self)?.ring(device.id) }
        }
    }
}

@MainActor
enum SystemFeature {
    private static var ringPanel: RingPanel?

    /// Shows the ring window while a computer rings this Mac, and connects
    /// the Focus filter to Do Not Disturb sync.
    static func didLaunch(model: AppModel) {
        if let ring = model.core.plugin(FindMyPhonePlugin.self) {
            ringPanel = RingPanel(model: ring.model)
        }
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
