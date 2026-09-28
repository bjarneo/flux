import FluxKit
import SwiftUI

/// The pairing sheet of one computer.
struct PairSheetItem: Identifiable {
    let id: String
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ComputersView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .device(let id): DeviceView(deviceId: id)
                    case .settings: SettingsView()
                    }
                }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBanner(message: toast.message)
                    .id(toast.id)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.dismissToast() }
            }
        }
        .animation(.snappy, value: model.toast)
        .sheet(item: Binding(
            get: { model.pairSheetDevice.map(PairSheetItem.init) },
            set: { if $0 == nil { model.pairingSheet = nil } }
        )) { item in
            PairSheet(deviceId: item.id)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
        .onChange(of: appearance, initial: true) { _, value in AppearanceController.apply(value) }
    }
}
