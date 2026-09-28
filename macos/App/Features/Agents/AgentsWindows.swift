import AppKit
import FluxKit
import Observation
import SwiftUI

/// The state of 1 agents window: the selected agent, the reply drafts of
/// each agent, and the dictation.
@MainActor
@Observable
final class AgentsWindowModel {
    let deviceId: String
    let app: AppModel
    let plugin: HerdrPlugin
    /// The pane of the selected agent.
    var selection: String?
    /// The reply text of each pane. A draft stays when the user selects another agent.
    var drafts: [String: String] = [:]
    /// The cursor of each reply field, in UTF-16 units.
    var cursors: [String: NSRange] = [:]
    let dictation = Dictation()

    init(deviceId: String, app: AppModel, plugin: HerdrPlugin, selection: String?) {
        self.deviceId = deviceId
        self.app = app
        self.plugin = plugin
        self.selection = selection
    }

    var device: DeviceSnapshot? { app.state.devices.first { $0.id == deviceId } }
    var herdr: HerdrState? { plugin.model.states[deviceId] }

    /// Puts dictated words in the draft of `pane` at its cursor.
    func insert(_ spoken: String, pane: String) {
        let text = drafts[pane] ?? ""
        let cursor = cursors[pane] ?? NSRange(location: (text as NSString).length, length: 0)
        let edit = DictationText.insert(text, start: cursor.location, end: cursor.location + cursor.length, spoken: spoken)
        drafts[pane] = edit.text
        cursors[pane] = NSRange(location: edit.cursor, length: 0)
    }

    func close() {
        dictation.cancel()
        if let selection { plugin.closeOutput(deviceId, pane: selection) }
    }
}

/// The agents windows, 1 per computer.
@MainActor
final class AgentsWindows: NSObject, NSWindowDelegate {
    static let shared = AgentsWindows()

    private struct Entry {
        let window: NSWindow
        let model: AgentsWindowModel
    }
    private var open: [String: Entry] = [:]

    /// Shows the agents window of a computer, and opens it when it is not
    /// open. `pane` selects that agent.
    func show(_ deviceId: String, pane: String? = nil, app: AppModel) {
        if let entry = open[deviceId] {
            if let pane { entry.model.selection = pane }
            entry.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let plugin = app.core.plugin(HerdrPlugin.self) else { return }
        let model = AgentsWindowModel(deviceId: deviceId, app: app, plugin: plugin, selection: pane)
        let hosting = NSHostingController(rootView: AgentsView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Agents on \(model.device?.name ?? "the computer")"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 620))
        if !window.setFrameUsingName("Agents") { window.center() }
        window.setFrameAutosaveName("Agents")
        open[deviceId] = Entry(window: window, model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = open.first(where: { $0.value.window === window })?.key else { return }
        open[id]?.model.close()
        open[id] = nil
    }
}

@MainActor
enum AgentsFeature {
    /// A click on an agent notification opens the output of the agent.
    static func didLaunch(model: AppModel) {
        model.core.plugin(HerdrPlugin.self)?.model.open = { [weak model] id, pane in
            guard let model else { return }
            AgentsWindows.shared.show(id, pane: pane, app: model)
        }
    }
}
