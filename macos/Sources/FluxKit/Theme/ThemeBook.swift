import Foundation

/// The theme of 1 computer and its palette after the contrast guard.
public struct ComputerTheme: Sendable, Equatable {
    public var deviceId: String
    public var theme: OmarchyTheme
    public var palette: ThemePalette

    /// The name of the theme, for example "tokyo-night". It can be empty.
    public var name: String { theme.name }

    public init(deviceId: String, theme: OmarchyTheme, palette: ThemePalette) {
        self.deviceId = deviceId
        self.theme = theme
        self.palette = palette
    }
}

/// The Omarchy themes of the computers, and the rules that pick the theme
/// that the Computer setting draws. It is a port of ThemeBook.kt of the
/// Android app.
///
/// A computer sends its theme on each connect, so a theme that comes again
/// changes nothing. The last theme is the theme that changed most recently.
/// Without a scope, the app draws the last theme. A reconnect, or the first
/// theme of a newly paired computer, does not change the last theme.
public struct ThemeBook: Sendable, Equatable {
    /// The computer whose theme the app draws without a scope.
    public private(set) var lastId: String?
    /// The device IDs in the order of change. The last one changed most recently.
    private var order: [String] = []
    private var themes: [String: ComputerTheme] = [:]

    public init() {}

    /// Takes the theme that the computer `id` sent. The theme becomes the
    /// last theme when no last theme exists, when this computer sent the
    /// last theme, or when the theme on this computer changed. Returns true
    /// when the book changed and must be saved.
    @discardableResult
    public mutating func put(_ id: String, _ theme: OmarchyTheme) -> Bool {
        let old = themes[id]
        if let old, old.theme == theme {
            if lastId != nil { return false }
            lastId = id
            return true
        }
        add(id, theme)
        if lastId == nil || lastId == id || old != nil { lastId = id }
        return true
    }

    /// Forgets the theme of a computer that is no longer paired. When it was
    /// the last theme, the remaining theme that changed most recently takes
    /// its place. Returns true when the book changed and must be saved.
    @discardableResult
    public mutating func forget(_ id: String) -> Bool {
        guard themes.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        if lastId == id { lastId = order.last }
        return true
    }

    /// The theme to draw. With a `scope`, it is the theme of that computer,
    /// or nil when that computer sent no theme. Without a scope, it is the
    /// last theme.
    public func current(scope: String?) -> ComputerTheme? {
        guard let key = scope ?? lastId else { return nil }
        return themes[key]
    }

    /// The theme of the computer `id`, or nil.
    public func theme(_ id: String) -> ComputerTheme? { themes[id] }

    /// The name of the theme of each computer, by device ID.
    public func names() -> [String: String] { themes.mapValues { $0.name } }

    /// The book in the form that `load` reads:
    /// {"last": id, "computers": [{"id": id, "theme": <packet form>}]}.
    /// "last" is absent when no last theme exists.
    public func json() -> JSONValue {
        var out: [String: JSONValue] = [:]
        if let lastId { out["last"] = .string(lastId) }
        var computers: [JSONValue] = []
        for id in order {
            guard let t = themes[id] else { continue }
            computers.append(.object(["id": .string(id), "theme": .object(t.theme.json())]))
        }
        out["computers"] = .array(computers)
        return .object(out)
    }

    /// Restores the book from `saved`, the form of `json()`. It keeps only
    /// the computers that `keep` accepts, for example the paired computers.
    /// It ignores an entry that it cannot read.
    public mutating func load(_ saved: JSONValue?, keep: (String) -> Bool = { _ in true }) {
        themes = [:]
        order = []
        lastId = nil
        guard let object = saved?.object else { return }
        let entries: [JSONValue] = object["computers"]?.array ?? []
        for entry in entries {
            guard let e = entry.object, let id = e["id"]?.string, keep(id),
                  let body = e["theme"]?.object, let theme = OmarchyTheme.parse(body) else { continue }
            add(id, theme)
        }
        if let last = object["last"]?.string, themes[last] != nil {
            lastId = last
        } else {
            lastId = order.last
        }
    }

    /// Puts the theme of `id` at the end of the order, with its new palette.
    private mutating func add(_ id: String, _ theme: OmarchyTheme) {
        order.removeAll { $0 == id }
        order.append(id)
        themes[id] = ComputerTheme(deviceId: id, theme: theme, palette: ThemePalette.of(theme))
    }
}
