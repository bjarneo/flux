import AppKit
import FluxKit
import SwiftUI

/// The 4 destinations of the sidebar, in order.
enum MacDestination: String, CaseIterable, Identifiable, Hashable {
    case inbox, send, control, computers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .send: return "Send"
        case .control: return "Control"
        case .computers: return "Computers"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .send: return "paperplane"
        case .control: return "slider.horizontal.3"
        case .computers: return "laptopcomputer"
        }
    }

    /// The key of the destination in the Go menu, with Command.
    var shortcut: KeyEquivalent {
        switch self {
        case .inbox: return KeyEquivalent("1")
        case .send: return KeyEquivalent("2")
        case .control: return KeyEquivalent("3")
        case .computers: return KeyEquivalent("4")
        }
    }
}

/// A feature card that opens on a page of its own from Send or Control.
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

/// The sidebar: the 4 destinations, and this Mac at the bottom. The Inbox
/// row counts the items of all computers that need the user.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let count = Inbox.needsYou(model.inboxItems(now: Date()))
        let needs = needsText(count)
        List(selection: Binding<MacDestination?>(
            get: { model.destination },
            set: { if let d = $0 { model.destination = d } }
        )) {
            ForEach(MacDestination.allCases) { d in
                Label(d.title, systemImage: d.systemImage)
                    .badge(d == .inbox ? count : 0)
                    .accessibilityValue(d == .inbox ? needs : "")
                    .tag(d)
            }
        }
        .background(tn.bg)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: FluxCore.deviceType == "laptop" ? "laptopcomputer" : "desktopcomputer")
                Text(model.state.deviceName).lineLimit(1)
                Spacer()
                if !model.state.enabled { Text("Off").foregroundStyle(tn.sub) }
            }
            .font(.caption)
            .foregroundStyle(tn.text)
            .padding(10)
        }
    }
}

/// "1 item needs you", "<n> items need you", or "Nothing needs you".
func needsText(_ count: Int) -> String {
    switch count {
    case 0: return "Nothing needs you"
    case 1: return "1 item needs you"
    default: return "\(count) items need you"
    }
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

/// The Go menu: Command-1 to Command-4 open the destinations, and
/// Command-] shows the next item of the Inbox. Command-R stays with the
/// agents window.
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
            Divider()
            Button("Show the next item") {
                model.destination = .inbox
                model.showNextItem()
            }
            .keyboardShortcut("]", modifiers: .command)
        }
    }
}
