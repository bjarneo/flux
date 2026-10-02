import AppKit
import FluxKit
import SwiftUI

/// The main window: the sidebar with the 4 destinations, and the stack of
/// the selected destination in the detail column.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.destination {
            case .inbox:
                NavigationStack(path: $model.inboxPath) { InboxView() }
            case .send:
                NavigationStack(path: $model.sendPath) { SendView() }
            case .control:
                NavigationStack(path: $model.controlPath) { ControlView() }
            case .computers:
                NavigationStack(path: $model.computersPath) { ComputersPage() }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
        .sheet(item: Binding(
            get: { model.pairingSheet.flatMap { id in model.state.devices.first { $0.id == id } } },
            set: { model.pairingSheet = $0?.id }
        )) { device in
            PairRequestSheet(device: device)
        }
    }
}

/// Tells the user that macOS blocks the local network for Flux, and where
/// to allow it. Discovery and links fail without it.
struct LocalNetworkNotice: View {
    static let text = "Flux needs Local Network access to find and reach computers. Turn on Flux in System Settings > Privacy & Security > Local Network."
    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Network is off", systemImage: "wifi.exclamationmark")
                .font(.body.weight(.medium))
            Text(Self.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { NSWorkspace.shared.open(Self.settings) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

extension DeviceSnapshot {
    var symbol: String {
        switch type {
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        case "tablet": return "ipad"
        case "tv": return "tv"
        default: return "iphone"
        }
    }

    var statusText: String {
        switch pairState {
        case .requested: return "Waiting for the computer"
        case .incoming: return "Wants to pair"
        case .paired: return online ? "Connected" : "Offline"
        case .none: return online ? "Not paired" : "Offline"
        }
    }
}
