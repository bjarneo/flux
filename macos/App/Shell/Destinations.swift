import AppKit
import FluxKit
import SwiftUI

/// The 3 destinations of the window, in order. Chats is the list in the
/// sidebar, and Control and Computers are the 2 rows under it.
enum MacDestination: String, CaseIterable, Identifiable, Hashable {
    case chats, control, computers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .control: return "Control"
        case .computers: return "Computers"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: return "text.bubble"
        case .control: return "slider.horizontal.3"
        case .computers: return "laptopcomputer"
        }
    }

    /// The key of the destination in the Go menu, with Command.
    var shortcut: KeyEquivalent {
        switch self {
        case .chats: return KeyEquivalent("1")
        case .control: return KeyEquivalent("2")
        case .computers: return KeyEquivalent("3")
        }
    }
}

/// 1 chat of the Chats list: the chat of a paired computer, or the chat of
/// 1 herdr agent in `pane` of a computer.
enum ChatOpen: Hashable {
    case computer(String)
    case agent(String, pane: String)

    /// The computer of the chat.
    var deviceId: String {
        switch self {
        case .computer(let id), .agent(let id, _): return id
        }
    }
}

/// The computer of the sheet that starts an agent from the window.
struct AgentStart: Identifiable {
    let id: String
}

/// A feature card that opens on a page of its own from Control.
enum MacCard: String, Hashable {
    case share, clipboard, media, commands, mic, stream

    var title: String {
        switch self {
        case .share: return "Text and links"
        case .clipboard: return "Clipboard"
        case .media: return "Media"
        case .commands: return "Commands"
        case .mic: return "Microphone"
        case .stream: return "Webcam and screen mirror"
        }
    }
}

/// A page on top of a destination.
enum MacRoute: Hashable {
    /// The pairing of a computer that is not paired.
    case pairing(String)
    /// A feature card for a computer.
    case card(MacCard, String)
    /// The page of a paired computer, with its Touch ID approval.
    case computer(String)
}

/// The page of a route in the stack of a destination.
struct MacRouteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    let route: MacRoute

    var body: some View {
        Group {
            switch route {
            case .pairing(let id):
                if let device = model.state.devices.first(where: { $0.id == id }) {
                    PairingView(device: device)
                        .navigationTitle(device.name)
                        .navigationSubtitle(device.ip.isEmpty ? device.statusText : "\(device.statusText) · \(device.ip)")
                } else {
                    ContentUnavailableView("The computer is gone", systemImage: "desktopcomputer")
                }
            case .card(.media, let id):
                // The media page follows the app design, with the player in a dock.
                MediaPage(deviceId: id)
            case .card(let card, let id):
                FeaturePage(card: card, deviceId: id)
            case .computer(let id):
                ComputerPage(deviceId: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tn.bg)
    }
}

/// The root of a destination: its title, the scope menu in the toolbar,
/// and the theme background.
struct DestinationRoot: ViewModifier {
    let destination: MacDestination
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(tn.bg)
            .navigationTitle(destination.title)
            .toolbar {
                ToolbarItem(placement: .navigation) { ScopeMenu() }
            }
            .navigationDestination(for: MacRoute.self) { MacRouteView(route: $0) }
    }
}

extension View {
    /// Makes the view the root of a destination. See `DestinationRoot`.
    func destinationRoot(_ destination: MacDestination) -> some View {
        modifier(DestinationRoot(destination: destination))
    }
}

/// The Go menu: Command-1 to Command-3 open the destinations. Command-1
/// shows the chat that was open last. Command-R and Command-D stay with the
/// agent chat and the agents window.
struct GoMenu: View {
    let launch: Launch
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .ready(let model) = launch {
            ForEach(MacDestination.allCases) { d in
                Button(d.title) {
                    model.go(d)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(d.shortcut, modifiers: .command)
            }
        }
    }
}
