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
                    case .feature(let route): FeatureDestination(route: route)
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
        .modifier(FeatureRoot())
        .onAppear { Overlays.install(model: model) }
        // An overlay sheet shows above the keyboard of the app only when the keyboard goes.
        .onChange(of: FeatureOverlays.shown(model: model)) { _, shown in
            if shown { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
        .onChange(of: appearance, initial: true) { _, value in AppearanceController.apply(value) }
    }
}
