import FluxKit
import SwiftUI

/// The background of a card, like the cards of the Mac dashboard, on the
/// grouped background of iOS.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.35)))
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

/// An SF Symbol on a tinted rounded square, the icon of a feature.
struct FeatureIcon: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.opacity(0.15)))
            .accessibilityHidden(true)
    }
}

/// The grid of feature tiles on a computer's screen. Tiles that a feature
/// does not show for the computer take no place.
struct FeatureGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            content
        }
    }
}

/// One feature on a computer's screen: a rounded tile with an icon, a title,
/// and a short state. It runs an action or opens a screen. Every tile has the
/// same height, so the grid stays even.
struct FeatureTile<Destination: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    var subtitle: String?
    var badge: Int = 0
    private let kind: Kind

    /// The height of the content of every tile, inside the padding.
    static var height: CGFloat { 100 }

    private enum Kind {
        case action(() -> Void)
        case destination(Destination)
    }

    init(_ title: String, systemImage: String, tint: Color, subtitle: String? = nil, badge: Int = 0, action: @escaping () -> Void) where Destination == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.subtitle = subtitle
        self.badge = badge
        kind = .action(action)
    }

    init(_ title: String, systemImage: String, tint: Color, subtitle: String? = nil, badge: Int = 0, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.subtitle = subtitle
        self.badge = badge
        kind = .destination(destination())
    }

    var body: some View {
        switch kind {
        case .action(let action):
            Button(action: action) { label }
                .buttonStyle(TileButtonStyle())
        case .destination(let destination):
            NavigationLink { destination } label: { label }
                .buttonStyle(TileButtonStyle())
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                FeatureIcon(systemImage: systemImage, tint: tint)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

/// A tile that dims while pressed or disabled.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .cardBackground()
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// The look of a quick action: a round tinted icon over a short title. The
/// quick actions sit side by side in one bar, apart from the feature tiles.
struct QuickActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A quick action that dims while pressed or disabled.
struct QuickActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuickBody(configuration: configuration)
    }

    private struct QuickBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .opacity(enabled ? (configuration.isPressed ? 0.5 : 1) : 0.4)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// A quick action that runs at once.
struct QuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuickActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(QuickActionStyle())
    }
}

/// A short colored state, such as Connected.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// The 8-character key that both sides show while they pair.
struct KeyView: View {
    let key: String

    var body: some View {
        Text(key.isEmpty ? "--------" : key)
            .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
            .kerning(4)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(key.isEmpty ? "No key yet" : "Key \(key.map(String.init).joined(separator: " "))")
    }
}

/// A transient message at the bottom of the screen.
struct ToastBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 24)
            .accessibilityAddTraits(.isStaticText)
    }
}

extension DeviceSnapshot {
    var symbol: String { DeviceSymbol.name(type) }

    var statusText: String {
        switch pairState {
        case .requested: return "Waiting for the computer"
        case .incoming: return "Wants to pair"
        case .paired: return online ? "Connected" : "Not reachable"
        case .none: return online ? "Not paired" : "Not reachable"
        }
    }
}
