import FluxKit
import SwiftUI

/// Sends a ping, which the computer shows as a notification.
struct PingQuickAction: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if model.core.plugin(PingPlugin.self) != nil, device.accepts(PacketType.ping) {
            QuickAction(title: "Ping", systemImage: "bell.badge") {
                model.core.plugin(PingPlugin.self)?.ping(device.id)
            }
            .accessibilityHint("Shows a notification on \(device.name)")
        }
    }
}
