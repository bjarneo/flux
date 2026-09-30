import AppIntents
import FluxKit
import Foundation

/// Sends text to the clipboard of the paired computers without opening
/// Flux. The user makes a shortcut with Get Clipboard and then this action,
/// and runs it with Back Tap, the Action button, or Control Center. iOS
/// gives the clipboard only to the app on the screen, so the Shortcuts app
/// reads it and gives the text to this action.
///
/// The action runs in the background. It starts the links, sends
/// flux.clipboard to each paired computer that connects in time, waits
/// until the links wrote it, and closes the links again when Flux is not on
/// the screen. It asks the user nothing before the send, because a question
/// in the background can drop the network.
struct SendTextToComputerIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Text to Computer"
    static let description: IntentDescription? = "Puts the text on the clipboard of your paired Omarchy computers. Flux stays closed."
    /// The action does not run while the iPhone is locked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// How long the action waits for a computer. iOS ends an action after
    /// about 30 seconds.
    static let linkTimeout: Duration = .seconds(20)

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @Parameter(title: "Skip unchanged text", default: false)
    var skipUnchanged: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = text
        guard let model = await ClipboardIntentBridge.waitForModel(), let clipboard = model.core.plugin(ClipboardPlugin.self) else {
            throw ClipboardIntentError.notStarted
        }
        guard model.core.enabled else { throw ClipboardIntentError.off }
        guard !model.paired.isEmpty else { throw ClipboardIntentError.notPaired }
        switch ClipboardIntentText.check(value, skipUnchanged: skipUnchanged, unchanged: clipboard.isUnchanged(value)) {
        case .empty: throw ClipboardIntentError.empty
        case .tooLarge: throw ClipboardIntentError.tooLarge
        case .unchanged: return .result(dialog: "Flux sent this text already")
        case .send: break
        }
        let sent = await model.withBackgroundLink(timeout: Self.linkTimeout) { ids in
            await clipboard.sendText(value, to: ids)
        }
        guard !sent.isEmpty else { throw ClipboardIntentError.notConnected }
        let names = sent.compactMap { id in model.core.withDevice(id) { $0.name } }
        return .result(dialog: "Sent to \(names.joined(separator: ", "))")
    }
}

/// Opens Flux and sends the clipboard to the connected computers, for Siri,
/// Spotlight, and the Action button. iOS lets only the app on the screen
/// read the clipboard, so this action opens Flux. A copy that went out
/// already when Flux opened does not go again.
struct SendClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Clipboard"
    static let description: IntentDescription? = "Opens Flux and sends what you copied to your connected Omarchy computers."
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = await ClipboardIntentBridge.waitForModel(), let clipboard = model.core.plugin(ClipboardPlugin.self) else {
            throw ClipboardIntentError.notStarted
        }
        guard model.core.enabled else { throw ClipboardIntentError.off }
        guard !model.paired.isEmpty else { throw ClipboardIntentError.notPaired }
        guard await ClipboardIntentBridge.waitUntilActive(model) else { throw ClipboardIntentError.notStarted }
        let ids = await model.core.waitForPairedLinks(timeout: .seconds(15))
            .filter { id in model.core.withDevice(id) { $0.accepts(PacketType.clipboard) } == true }
        guard !ids.isEmpty else { throw ClipboardIntentError.notConnected }
        // The toasts of Flux show the result.
        if !clipboard.sentLatestCopy { clipboard.sendClipboard(to: ids) }
        return .result()
    }
}

/// The App Shortcut for Siri and Spotlight. It needs no setup.
struct FluxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendClipboardIntent(),
            phrases: [
                "Send clipboard with \(.applicationName)",
                "Send my clipboard to my computer with \(.applicationName)",
            ],
            shortTitle: "Send Clipboard",
            systemImageName: "doc.on.clipboard"
        )
    }
}

/// What Send Text to Computer does with its text.
enum ClipboardIntentText: Equatable {
    case send
    /// The text has only spaces or is empty.
    case empty
    /// The computer takes at most 1 MB.
    case tooLarge
    /// Flux sent the same text last, or a computer put it on the clipboard.
    case unchanged

    /// Checks the text before Flux starts a link. `unchanged` is true for the
    /// last text that Flux sent or that a computer put on the clipboard. It
    /// counts only with Skip unchanged text, for example in an automation
    /// that runs each time an app closes.
    static func check(_ text: String, skipUnchanged: Bool, unchanged: Bool) -> ClipboardIntentText {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if text.utf8.count > SharePlugin.maxText { return .tooLarge }
        if skipUnchanged, unchanged { return .unchanged }
        return .send
    }
}

/// Why a clipboard action did not send. Shortcuts shows the text.
enum ClipboardIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notStarted
    case off
    case notPaired
    case empty
    case tooLarge
    case notConnected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notStarted: "Flux did not start. Open Flux, then try again."
        case .off: "Flux is off. Turn it on in the settings of Flux."
        case .notPaired: "No computer is paired. Open Flux and pair a computer."
        case .empty: "The clipboard has no text."
        case .tooLarge: "The text is larger than 1 MB. Send it as a file."
        case .notConnected: "No computer connected. Check that the computer runs Flux and is on the same network."
        }
    }
}

/// Connects the clipboard actions to the model of the running app, like
/// `FocusBridge`. iOS starts Flux in the background for an action, so the
/// action waits for the end of the launch.
@MainActor
enum ClipboardIntentBridge {
    static weak var model: AppModel?

    /// The model, after at most 2 seconds of launch. It is nil when the core
    /// did not start, or in the demo, which starts no feature.
    static func waitForModel() async -> AppModel? {
        for _ in 0..<20 {
            if let model { return model }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model
    }

    /// Waits at most 5 seconds for Flux to come on the screen.
    static func waitUntilActive(_ model: AppModel) async -> Bool {
        for _ in 0..<50 {
            if model.isActive { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return model.isActive
    }
}
