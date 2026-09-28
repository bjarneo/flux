import AppIntents
import FluxKit

/// The Flux Focus filter. The user adds it to a Focus in Settings > Focus
/// and turns on "Do Not Disturb on computers". iOS calls `perform` with that
/// value when the Focus turns on, and with the default value (false) when it
/// turns off. This is the only public way for an app to learn about Focus
/// changes. iOS gives apps no way to set the Focus, so the iPhone reports its
/// Focus and does not follow the computers.
struct FluxFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Flux"
    static let description: IntentDescription? = "Turns on Do Not Disturb on your Omarchy computers while this Focus is on."

    @Parameter(title: "Do Not Disturb on computers", default: false)
    var computerDnd: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: computerDnd ? "Do Not Disturb on computers" : "Computers unchanged")
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [FluxFocusFilter] {
        let filter = FluxFocusFilter()
        filter.computerDnd = true
        return [filter]
    }

    func perform() async throws -> some IntentResult {
        let on = computerDnd
        await MainActor.run { FocusBridge.plugin?.focusChanged(on) }
        return .result()
    }
}

/// Connects the Focus filter to the Do Not Disturb plugin of the running app.
@MainActor
enum FocusBridge {
    static weak var plugin: DndPlugin?

    /// Reads the Focus filter state at launch, so that the start is not a change.
    static func start(_ dnd: DndPlugin) {
        plugin = dnd
        Task {
            let on = (try? await FluxFocusFilter.current)?.computerDnd ?? false
            dnd.start(focusOn: on)
        }
    }
}
