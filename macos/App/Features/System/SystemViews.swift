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

/// The header action that rings a computer.
struct RingQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.findMyPhone) {
            Tile(title: "Ring", systemImage: "speaker.wave.2") { model.core.plugin(FindMyPhonePlugin.self)?.ring(device.id) }
                .help("Play a sound on \(device.name) until someone stops it")
        }
    }
}

/// A banner while a computer rings this Mac.
struct RingingBanner: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let ring = model.core.plugin(FindMyPhonePlugin.self)?.model, ring.ringingDevice == device.id {
            Banner("\(device.name) is ringing this Mac", systemImage: "speaker.wave.3.fill", tint: .orange) {
                Button("Stop Ringing") { ring.stop() }
                    .keyboardShortcut(.cancelAction)
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
