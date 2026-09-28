import Foundation
import Observation
#if os(macOS)
import IOKit.ps
#else
import UIKit
#endif

/// A battery charge and whether the charger is plugged in.
public struct BatteryState: Equatable, Sendable {
    public var charge: Int
    public var charging: Bool

    public init(charge: Int, charging: Bool) {
        self.charge = charge
        self.charging = charging
    }

    /// Reads a kdeconnect.battery packet. A negative charge means that the
    /// device has no battery.
    public init?(packet p: Packet) {
        guard let charge = p.int("currentCharge"), charge >= 0 else { return nil }
        self.charge = charge
        charging = p.bool("isCharging") ?? false
    }

    /// The kdeconnect.battery packet. thresholdEvent 1 means "battery low":
    /// 15% or less and not charging.
    public var packet: Packet {
        Packet(PacketType.battery, [
            "currentCharge": charge,
            "isCharging": charging,
            "thresholdEvent": charge <= 15 && !charging ? 1 : 0,
        ])
    }

    /// Maps a battery level from 0 to 1. A negative level means that the
    /// device reports no battery, like the iOS simulator.
    init?(level: Float, charging: Bool) {
        guard level >= 0 else { return nil }
        charge = Swift.min(100, Swift.max(0, Int((level * 100).rounded())))
        self.charging = charging
    }

    #if os(macOS)
    /// The battery of this device, or nil when it has none.
    public static func current() -> BatteryState? { mac() }

    /// The internal battery of this Mac, or nil when the Mac has none.
    /// Charging means that the Mac runs on AC power, like the phone that
    /// reports "plugged in".
    public static func mac() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSIsPresentKey] as? Bool != false,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charge = Swift.min(100, Swift.max(0, current * 100 / max))
            return BatteryState(charge: charge, charging: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
    #else
    /// The battery of the iPhone, or nil in the simulator. Charging means
    /// that the charger is plugged in, also when the battery is full.
    @MainActor
    public static func current() -> BatteryState? {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return BatteryState(level: device.batteryLevel, charging: device.batteryState == .charging || device.batteryState == .full)
    }
    #endif
}

/// kdeconnect.battery in both directions. This device sends its battery when
/// a computer connects, when a computer asks (kdeconnect.battery.request),
/// and when the battery changes. A Mac without an internal battery neither
/// advertises nor sends a battery. The battery that a computer sends shows in
/// the computer's section.
public final class BatteryPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    /// The batteries of the computers.
    public let model: BatteryModel
    private let hasBattery: Bool
    private let lock = NSLock()
    private var last: BatteryState?

    public let incoming: [String]
    public let outgoing: [String]

    @MainActor
    public init() {
        model = BatteryModel()
        let state = BatteryState.current()
        hasBattery = state != nil
        #if os(iOS)
        last = state
        #endif
        incoming = hasBattery ? [PacketType.battery, PacketType.batteryRequest] : [PacketType.battery]
        outgoing = hasBattery ? [PacketType.battery] : []
    }

    public func attach(core: FluxCore) {
        self.core = core
        guard hasBattery else { return }
        #if os(macOS)
        last = BatteryState.mac()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let plugin = Unmanaged<BatteryPlugin>.fromOpaque(context).takeUnretainedValue()
            plugin.batteryChanged(BatteryState.mac())
        }, context)?.takeRetainedValue() else { return }
        // The run loop keeps the source, and the plugin lives as long as the process.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        #else
        // The observers stay, and the plugin lives as long as the process.
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.batteryChanged(BatteryState.current()) }
            }
        }
        #endif
    }

    public func onConnected(_ device: Device) {
        send(to: device)
    }

    public func onDisconnected(_ device: Device) {
        let id = device.id
        let model = model
        Task { @MainActor in model.computers[id] = nil }
    }

    public func handle(_ packet: Packet, from device: Device) {
        switch packet.type {
        case PacketType.battery:
            let id = device.id
            let state = BatteryState(packet: packet)
            let model = model
            Task { @MainActor in model.computers[id] = state }
        case PacketType.batteryRequest:
            send(to: device)
        default:
            break
        }
    }

    private func send(to device: Device) {
        #if os(macOS)
        let current = BatteryState.mac()
        #else
        // Network threads do not touch UIDevice, so the last reported state goes out.
        let current = lock.withLock { last }
        #endif
        guard hasBattery, device.accepts(PacketType.battery), let state = current else { return }
        _ = device.send(state.packet)
    }

    /// Runs on the main queue when a power source changes: IOKit on macOS,
    /// UIDevice notifications on iOS.
    private func batteryChanged(_ state: BatteryState?) {
        guard let core, let state else { return }
        let changed = lock.withLock {
            defer { last = state }
            return last != state
        }
        guard changed else { return }
        for d in core.connectedPaired() where d.accepts(PacketType.battery) {
            _ = d.send(state.packet)
        }
    }
}

/// The batteries that the computers report, by device ID.
@MainActor
@Observable
public final class BatteryModel {
    public internal(set) var computers: [String: BatteryState] = [:]

    init() {}
}
