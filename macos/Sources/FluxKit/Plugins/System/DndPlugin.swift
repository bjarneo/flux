import Foundation
import Observation

/// Syncs Do Not Disturb between this Mac and the computers with flux.dnd
/// {"on": bool}. Each side sends the state only after a local change, and a
/// guard keeps a change from going back to the side that made it.
///
/// macOS has no public API that reads or sets Focus for an app without the
/// Communication Notifications entitlement, which needs an Apple provisioning
/// profile. So Flux uses the two public hooks that remain:
/// - Reading: the Flux Focus filter (App Intents `SetFocusFilterIntent`). The
///   user adds it to the Focus modes that silence the computers, and macOS
///   calls it when such a Focus turns on or off. The app forwards that to
///   `focusChanged(_:)`.
/// - Setting: Shortcuts that the user picks, one that turns a Focus on and one
///   that turns it off, run with `/usr/bin/shortcuts run`.
public final class DndPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: DndModel
    /// Applying a state runs a shortcut, and macOS reports the Focus change
    /// through the filter after that, so the wait is longer than on the phone.
    private let dndGuard = DndGuard(settleMs: 10_000)

    public let incoming = [PacketType.fluxDnd]
    public let outgoing = [PacketType.fluxDnd]

    static let syncKey = "dnd.sync"
    static let shortcutOnKey = "dnd.shortcutOn"
    static let shortcutOffKey = "dnd.shortcutOff"

    @MainActor
    public init() { model = DndModel() }

    public func attach(core: FluxCore) {
        self.core = core
        let defaults = core.defaults
        let model = model
        DispatchQueue.main.async { model.load(defaults) }
    }

    /// Sets the Focus state at launch, so that the start is not a change.
    public func start(focusOn on: Bool) {
        _ = dndGuard.local(on, now: Self.now())
        let model = model
        Task { @MainActor in model.focusOn = on }
    }

    /// Handles a Focus change on this Mac, reported by the Flux Focus filter.
    public func focusChanged(_ on: Bool) {
        let model = model
        Task { @MainActor in model.focusOn = on }
        guard let core, dndGuard.local(on, now: Self.now()), sync(core) else { return }
        FluxLog.plugin.info("Do Not Disturb is \(on ? "on" : "off", privacy: .public) on this Mac")
        send(on, except: nil)
    }

    /// Handles flux.dnd from a computer. The shortcut runs in a Task, because
    /// the core lock is held.
    public func handle(_ packet: Packet, from device: Device) {
        guard let core, let on = packet.bool("on"), sync(core) else { return }
        let key = on ? Self.shortcutOnKey : Self.shortcutOffKey
        guard let shortcut = core.defaults.string(forKey: key), !shortcut.isEmpty else {
            FluxLog.plugin.info("no shortcut turns Focus \(on ? "on" : "off", privacy: .public)")
            return
        }
        guard dndGuard.remote(on, now: Self.now()) else { return }
        FluxLog.plugin.info("\(device.name, privacy: .public) turned Do Not Disturb \(on ? "on" : "off", privacy: .public)")
        let from = device.id
        let model = model
        Task.detached { [self] in
            let error = await Shortcuts.run(shortcut)
            if let error {
                FluxLog.plugin.error("shortcut \(shortcut, privacy: .public) failed: \(error, privacy: .public)")
                core.toast("The shortcut \(shortcut) failed: \(error)")
            }
            await MainActor.run { model.lastError = error.map { "\(shortcut): \($0)" } }
            send(on, except: from)
        }
    }

    private func sync(_ core: FluxCore) -> Bool { core.defaults.object(forKey: Self.syncKey) as? Bool ?? true }

    /// Sends the state to each connected computer that accepts flux.dnd, except `except`.
    private func send(_ on: Bool, except: String?) {
        guard let core else { return }
        for d in core.connectedPaired() where d.id != except && d.accepts(PacketType.fluxDnd) {
            _ = d.send(Packet(PacketType.fluxDnd, ["on": on]))
        }
    }

    private static func now() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
}

/// The Do Not Disturb settings and state for the UI.
@MainActor
@Observable
public final class DndModel {
    /// The Focus state that the Focus filter reported, or nil before the first report.
    public internal(set) var focusOn: Bool?
    /// The last shortcut error, or nil after a shortcut that worked.
    public internal(set) var lastError: String?
    /// The names of the user's shortcuts, for the pickers.
    public private(set) var shortcuts: [String] = []

    public var sync = true {
        didSet { defaults?.set(sync, forKey: DndPlugin.syncKey) }
    }
    public var shortcutOn = "" {
        didSet { defaults?.set(shortcutOn, forKey: DndPlugin.shortcutOnKey) }
    }
    public var shortcutOff = "" {
        didSet { defaults?.set(shortcutOff, forKey: DndPlugin.shortcutOffKey) }
    }

    @ObservationIgnored private var defaults: UserDefaults?

    init() {}

    func load(_ defaults: UserDefaults) {
        sync = defaults.object(forKey: DndPlugin.syncKey) as? Bool ?? true
        shortcutOn = defaults.string(forKey: DndPlugin.shortcutOnKey) ?? ""
        shortcutOff = defaults.string(forKey: DndPlugin.shortcutOffKey) ?? ""
        self.defaults = defaults
    }

    /// Reads the shortcut names with `shortcuts list`.
    public func reloadShortcuts() async {
        shortcuts = await Shortcuts.list()
    }
}

/// Runs the Shortcuts command-line tool.
enum Shortcuts {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// Runs a shortcut and returns nil, or the error message.
    static func run(_ name: String) async -> String? {
        let (status, _, err) = await exec(["run", name])
        guard status != 0 else { return nil }
        let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "exit status \(status)" : message
    }

    static func list() async -> [String] {
        let (status, out, _) = await exec(["list"])
        guard status == 0 else { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Runs the tool on a background thread and returns the exit status,
    /// stdout, and stderr. Both pipes are read while the tool runs, so a
    /// long output cannot block it.
    private static func exec(_ args: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = tool
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(returning: (-1, "", error.localizedDescription))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}
