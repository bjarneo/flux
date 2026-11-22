import FluxKit
import SwiftUI

/// The chat of 1 herdr agent in the detail column: the thread and the dock
/// of the agents window, with the chat top bar in the window toolbar. The
/// toolbar shows the picture of the agent with its status dot, the task,
/// the agent, the project, and the computer, and the Changes key. The
/// drafts of each agent stay while the user opens other chats. A dictation
/// stops when the chat closes.
struct AgentChat: View {
    let deviceId: String
    let pane: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let agents = model.agentModel(deviceId) {
            let name = agents.device?.name ?? "the computer"
            let online = agents.device?.online == true
            Group {
                // A computer that is not reachable keeps the last output of the agent. The thread says so, see `LinkNote`.
                if !online && agents.plugin.model.output(deviceId, pane: pane) == nil {
                    ContentUnavailableView {
                        Label("\(name) is not reachable", systemImage: "wifi.slash")
                    } description: {
                        Text("The agent shows when \(name) connects again.")
                    } actions: {
                        Button("Retry") { model.retry() }
                    }
                    .navigationTitle(name)
                } else if agents.herdr == nil {
                    ProgressView("Loading the agents of \(name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle(name)
                } else {
                    AgentDetail(model: agents, pane: pane, name: name, chat: true)
                }
            }
            .task(id: online) {
                if online { agents.plugin.request(deviceId) }
            }
            // A dictation that waits for the permissions also stops. The model selects no pane, so no output closes.
            .onDisappear { agents.close() }
        } else {
            ContentUnavailableView("No agents on this Mac", systemImage: "brain")
                .navigationTitle("Chats")
        }
    }
}

/// The sheet that starts an agent on a computer from the window, see
/// `NewAgentSheet`. When the computer reports the new agent, the sheet
/// closes and the chat of the agent opens.
struct StartAgentSheet: View {
    let deviceId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let agents = model.agentModel(deviceId) {
            NewAgentSheet(model: agents, name: agents.device?.name ?? "the computer")
                .onAppear { agents.selection = nil }
                .onChange(of: agents.selection) { _, pane in
                    guard let pane else { return }
                    agents.selection = nil
                    model.open(.agent(deviceId, pane: pane))
                }
                // The sheet can close in the same update that selects the new agent. Then only this opens its chat.
                .onDisappear {
                    guard let pane = agents.selection else { return }
                    agents.selection = nil
                    model.open(.agent(deviceId, pane: pane))
                }
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView("No agents on this Mac", systemImage: "brain")
                Button("Close") { model.startAgent = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .frame(width: 400, height: 240)
        }
    }
}
