import Foundation

/// A feature that handles packets of some types for paired devices.
///
/// The core calls `onConnected`, `onDisconnected`, and `handle` with the core
/// lock held, on a network thread. A plugin that blocks moves its work to a
/// Task. A plugin publishes UI state through its own `@MainActor` model.
public protocol FluxPlugin: AnyObject, Sendable {
    /// Packet types that this device accepts because of this plugin.
    var incoming: [String] { get }
    /// Packet types that this device sends because of this plugin.
    var outgoing: [String] { get }
    /// Packet types that the core routes to this plugin. The core reads them
    /// once, before the network starts. The default is `incoming`. A plugin
    /// whose `incoming` changes with a setting lists every type that it may
    /// accept.
    var handledTypes: [String] { get }
    /// Called once, after the core exists and before the network starts.
    func attach(core: FluxCore)
    /// A paired device connected, or a connected device finished pairing.
    func onConnected(_ device: Device)
    /// The link to a paired device closed.
    func onDisconnected(_ device: Device)
    /// A packet with a type from `incoming` arrived from a paired device.
    func handle(_ packet: Packet, from device: Device)
}

public extension FluxPlugin {
    var handledTypes: [String] { incoming }
    func attach(core: FluxCore) {}
    func onConnected(_ device: Device) {}
    func onDisconnected(_ device: Device) {}
}
