import FluxKit
import SwiftUI

/// The screen of a route on the navigation stack of a tab. Each screen
/// takes the theme surfaces once at its root, see `View.fluxScreen()`.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .settings: SettingsView().fluxScreen()
        case .computer(let id): ComputerPage(deviceId: id).fluxScreen()
        case .feature(let r): FeatureDestination(route: r).fluxScreen()
        }
    }
}

/// The root of a tab: the theme background, the title for VoiceOver and
/// the back buttons, and the scope chip in the place of the visible title.
struct TabRoot: ViewModifier {
    let title: String
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .background(tn.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ScopeChip() }
            }
            .toolbarBackground(tn.bg, for: .navigationBar)
            .toolbarColorScheme(tn.dark ? .dark : .light, for: .navigationBar)
    }
}

/// The tab bar of the theme. It goes on the navigation stack of a tab, so
/// that the screens that the stack pushes keep it.
struct ThemedTabBar: ViewModifier {
    @Environment(\.tn) private var tn

    func body(content: Content) -> some View {
        content
            .toolbarBackground(tn.tile, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(tn.dark ? .dark : .light, for: .tabBar)
    }
}

extension View {
    /// See `TabRoot`.
    func tabRoot(_ title: String) -> some View {
        modifier(TabRoot(title: title))
    }

    /// The screens of the routes, see `RouteDestination`.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}
