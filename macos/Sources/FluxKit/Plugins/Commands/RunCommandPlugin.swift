import Foundation
import Observation

/// A command that the computer publishes.
public struct RemoteCommand: Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var command: String
    public var id: String { key }

    public init(key: String, name: String, command: String) {
        self.key = key
        self.name = name
        self.command = command
    }

    /// The commands of a kdeconnect.runcommand packet. The computer sends
    /// commandList as a JSON string, in the order that it shows them, or as
    /// an object. An object arrives without its key order, so its commands
    /// sort by name.
    public static func list(from p: Packet) -> [RemoteCommand] {
        switch p.body["commandList"] {
        case .string(let text)?:
            guard case .object(let obj)? = JSONValue.parse(Data(text.utf8)) else { return [] }
            return JSONKeys.ordered(text).compactMap { key in obj[key].flatMap { command(key, $0) } }
        case .object(let obj)?:
            return obj.compactMap { command($0.key, $0.value) }.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
            }
        default:
            return []
        }
    }

    private static func command(_ key: String, _ value: JSONValue) -> RemoteCommand? {
        guard let o = value.object else { return nil }
        return RemoteCommand(key: key, name: o["name"]?.string ?? key, command: o["command"]?.string ?? "")
    }
}

/// Reads the member names of a JSON object text in order, which
/// JSONSerialization does not keep.
enum JSONKeys {
    /// The top-level keys of the object, first occurrence first. It returns
    /// what it read before the first syntax error.
    static func ordered(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var i = 0
        var keys: [String] = []
        var seen = Set<String>()

        func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        // Moves past a string that starts at i and returns its raw bytes, quotes included.
        func skipString() -> ArraySlice<UInt8>? {
            let start = i
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case 0x5C: i += 2
                case 0x22:
                    i += 1
                    return bytes[start..<i]
                default: i += 1
                }
            }
            return nil
        }
        // Moves past one value, up to the comma or brace that ends it.
        func skipValue() {
            var depth = 0
            while i < bytes.count {
                switch bytes[i] {
                case 0x22: _ = skipString(); continue
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    if depth == 0 { return }
                    depth -= 1
                case 0x2C where depth == 0: return
                default: break
                }
                i += 1
            }
        }

        skipSpace()
        guard i < bytes.count, bytes[i] == 0x7B else { return [] }
        i += 1
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x22, let raw = skipString(),
                  case .string(let key)? = JSONValue.parse(Data(raw)) else { return keys }
            if seen.insert(key).inserted { keys.append(key) }
            skipSpace()
            guard i < bytes.count, bytes[i] == 0x3A else { return keys }
            i += 1
            skipValue()
            guard i < bytes.count, bytes[i] == 0x2C else { return keys }
            i += 1
        }
    }
}

/// The commands of each computer, for the UI.
@MainActor
@Observable
public final class CommandsModel {
    public private(set) var lists: [String: [RemoteCommand]] = [:]

    public init() {}

    /// The commands of the computer, or nil until its list arrives.
    public func commands(_ deviceId: String) -> [RemoteCommand]? { lists[deviceId] }

    fileprivate func set(_ deviceId: String, _ list: [RemoteCommand]) { lists[deviceId] = list }
}

/// kdeconnect.runcommand.request out, kdeconnect.runcommand in: this Mac runs
/// the commands that the computer publishes.
public final class RunCommandPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: CommandsModel

    @MainActor
    public init() { model = CommandsModel() }

    public let incoming = [PacketType.runCommand]
    public let outgoing = [PacketType.runCommandRequest]

    public func attach(core: FluxCore) { self.core = core }

    public func handle(_ packet: Packet, from device: Device) {
        let id = device.id
        let list = RemoteCommand.list(from: packet)
        DispatchQueue.main.async { [model] in
            MainActor.assumeIsolated { model.set(id, list) }
        }
    }

    /// Asks the computer for its commands.
    public func request(_ deviceId: String) {
        core?.send(Packet(PacketType.runCommandRequest, ["requestCommandList": true]), to: deviceId)
    }

    /// Runs the command on the computer.
    public func run(_ deviceId: String, _ command: RemoteCommand) {
        guard let core else { return }
        if core.send(Packet(PacketType.runCommandRequest, ["key": command.key]), to: deviceId) {
            FluxLog.plugin.info("sent command \(command.key, privacy: .public)")
            core.toast("Ran “\(command.name)”")
        } else {
            FluxLog.plugin.info("command \(command.key, privacy: .public) not sent, no open link")
            core.toast("Not connected. Try again in a moment")
        }
    }
}
