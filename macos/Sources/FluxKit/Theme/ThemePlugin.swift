import Foundation
import Observation

/// The Omarchy themes of the paired computers, for the UI. `ThemePlugin`
/// changes it on the main actor.
@MainActor
@Observable
public final class ThemeModel {
    /// The theme of each computer and the last theme. Each entry holds its palette.
    public private(set) var book = ThemeBook()

    init() {}

    /// The theme of the computer in `scope`, or the last theme without a scope.
    public func current(scope: String?) -> ComputerTheme? { book.current(scope: scope) }

    /// The name of the theme of each computer, by device ID.
    public func names() -> [String: String] { book.names() }

    func put(_ id: String, _ theme: OmarchyTheme) -> Bool { book.put(id, theme) }

    func forget(_ id: String) -> Bool { book.forget(id) }

    func load(_ saved: JSONValue?, keep: (String) -> Bool) { book.load(saved, keep: keep) }
}

/// flux.theme in: the computer sends its active Omarchy theme when it
/// connects and when the theme changes. docs/omarchy.md describes it. Flux
/// keeps the theme of each paired computer, so that the next start draws
/// the theme at once.
public final class ThemePlugin: FluxPlugin, @unchecked Sendable {
    /// The key of the saved book in `FluxCore.defaults`.
    public static let defaultsKey = "theme.computers"

    public let incoming = [PacketType.fluxTheme]
    public let outgoing: [String] = []
    public let model: ThemeModel
    private weak var core: FluxCore?

    @MainActor
    public init() { model = ThemeModel() }

    /// Loads the saved book. The apps make the core on the main thread, so
    /// the first frame can draw the saved theme.
    public func attach(core: FluxCore) {
        self.core = core
        let data = core.defaults.data(forKey: Self.defaultsKey)
        let paired = Set(core.trust.all().map(\.id))
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.load(data, paired: paired) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.load(data, paired: paired) } }
        }
    }

    /// An unpair from either side forgets the theme of the computer. A link
    /// that only drops keeps it. The core lock is held.
    public func onDisconnected(_ device: Device) {
        guard !device.paired else { return }
        let id = device.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.forget(id) } }
    }

    /// The core lock is held, on a network thread. The main queue keeps the
    /// order of the packets.
    public func handle(_ packet: Packet, from device: Device) {
        guard packet.type == PacketType.fluxTheme, let theme = OmarchyTheme.parse(packet.body) else { return }
        let id = device.id
        DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(theme, from: id) } }
    }

    /// Takes a theme from a computer and saves the book when it changed.
    @MainActor
    func receive(_ theme: OmarchyTheme, from deviceId: String) {
        guard model.put(deviceId, theme) else { return }
        save()
        FluxLog.plugin.info("theme: \(theme.name, privacy: .public) from \(deviceId, privacy: .public)")
    }

    /// Forgets the theme of a computer that is no longer paired.
    @MainActor
    func forget(_ deviceId: String) {
        guard model.forget(deviceId) else { return }
        save()
    }

    /// Restores the saved book. It keeps only the computers in `paired`.
    @MainActor
    func load(_ data: Data?, paired: Set<String>) {
        model.load(data.flatMap { JSONValue.parse($0) }, keep: { paired.contains($0) })
    }

    @MainActor
    private func save() {
        core?.defaults.set(model.book.json().serialized(), forKey: Self.defaultsKey)
    }
}
