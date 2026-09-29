import SwiftUI

/// The full-screen Find-my-phone overlay. Ports Android `RingOverlay`
/// (`ui/Components.kt`): a pulsing bell on the primary color while the
/// phone rings, with an "I found it" stop action.
///
/// iOS cannot override the silent switch for third parties: the overlay
/// pairs the loudest allowed sound + vibration (`RingerBridge`) with this
/// full-screen surface + a time-sensitive notification. A second
/// `findmyphone.request` while ringing stops it (toggle).
public struct RingView: View {
    public var from: String
    public var onStop: () -> Void

    @State private var pulse = false

    public init(from: String, onStop: @escaping () -> Void) {
        self.from = from
        self.onStop = onStop
    }

    public var body: some View {
        ZStack {
            Color.accentColor.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.white)
                    .scaleEffect(pulse ? 1.12 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .accessibilityLabel("Ringing")
                Text("Find my phone")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                Text("\(from) is ringing this phone")
                    .font(.title)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button("I found it", action: onStop)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
            .padding(32)
        }
        .onAppear { pulse = true }
    }
}

struct RingView_Previews: PreviewProvider {
    static var previews: some View {
        RingView(from: "omarchy-xps", onStop: {})
            .previewDisplayName("ring")
    }
}
