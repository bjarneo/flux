import FluxKit
import SwiftUI

/// The pairing sheet of one computer.
struct PairSheetItem: Identifiable {
    let id: String
}

/// The 3 destinations in a tab bar: Chats, Control, and Computers. Each
/// tab has its own navigation stack. A tap on the open tab goes back to its
/// root. The Chats badge counts the items of all computers that need the
/// user. The chat of a computer or an agent opens on the stack of Chats.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: Binding(get: { model.tab }, set: { model.select($0) })) {
            NavigationStack(path: $model.chatPath) {
                ChatsView().routeDestinations()
            }
            .modifier(ThemedTabBar())
            .tabItem { Label("Chats", systemImage: "text.bubble") }
            .badge(badgeText)
            .tag(AppTab.chat)
            NavigationStack(path: $model.controlPath) {
                ControlView().routeDestinations()
            }
            .modifier(ThemedTabBar())
            .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
            .tag(AppTab.control)
            NavigationStack(path: $model.computersPath) {
                ComputersView().routeDestinations()
            }
            .modifier(ThemedTabBar())
            .tabItem { Label("Computers", systemImage: "laptopcomputer") }
            .tag(AppTab.computers)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastBanner(message: toast.message)
                    .id(toast.id)
                    // Above the tab bar.
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.dismissToast() }
            }
        }
        .animation(.snappy, value: model.toast)
        // The iPhone ticks when the tab changes.
        .sensoryFeedback(.selection, trigger: model.tab)
        .modifier(FeatureRoot())
        .targetPicker()
        .onAppear { Overlays.install(model: model) }
        // An overlay sheet shows above the keyboard of the app only when the keyboard goes.
        .onChange(of: FeatureOverlays.shown(model: model)) { _, shown in
            if shown { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
        .onChange(of: model.nightMode, initial: true) { _, night in AppearanceController.apply(night) }
    }

    /// The number of items that need the user on all computers: 1 to 9, then 9+.
    private var badgeText: Text? {
        let n = Inbox.needsYou(model.inboxItems())
        guard n > 0 else { return nil }
        return Text(verbatim: n > 9 ? "9+" : String(n))
    }
}
