import AudioToolbox
import AVFoundation
import FluxKit
import SwiftUI

/// Plays the ring: a loud looping tone, which sounds with the silent switch
/// on, and a vibration with each loop. It shares the audio session with the
/// microphone stream and dictation, so a ring plays through a recording
/// and does not end it.
@MainActor
final class Ringer {
    static let shared = Ringer()

    private var player: AVAudioPlayer?
    private var vibration: Timer?

    private init() {}

    /// Starts the sound. It returns an error message when the sound cannot play.
    func start() -> String? {
        guard player == nil else { return nil }
        do {
            try AudioSession.activate(.ring)
        } catch {
            return error.localizedDescription
        }
        do {
            let p = try AVAudioPlayer(data: RingTone.wav(), fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1
            p.volume = 1
            p.play()
            player = p
        } catch {
            AudioSession.deactivate(.ring)
            return error.localizedDescription
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let t = Timer(timeInterval: 1.2, repeats: true) { _ in AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        RunLoop.main.add(t, forMode: .common)
        vibration = t
        return nil
    }

    func stop() {
        vibration?.invalidate()
        vibration = nil
        guard let p = player else { return }
        p.stop()
        player = nil
        AudioSession.deactivate(.ring)
    }
}

/// Rings over the whole app while a computer rings this iPhone.
struct RingRoot: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let ring = model.core.plugin(RingPlugin.self) {
            content
                .fullScreenCover(isPresented: Binding(get: { ring.model.ringing != nil }, set: { if !$0 { ring.stop() } })) {
                    RingScreen(from: ring.model.ringing ?? "") { ring.stop() }
                }
                .onChange(of: ring.model.ringing, initial: true) { _, from in
                    if from != nil {
                        if let error = Ringer.shared.start() { model.show("The ring cannot play: \(error)") }
                    } else {
                        Ringer.shared.stop()
                    }
                }
        } else {
            content
        }
    }
}

/// The full-screen ring with its Stop button.
struct RingScreen: View {
    let from: String
    let stop: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 88, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .scaleEffect(pulse ? 1.08 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("\(from) is ringing this iPhone")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Stop the ring when you found it.")
                    .font(.title3)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            Spacer()
            Button(action: stop) {
                Text("Stop")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .clipShape(Capsule())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .onAppear { pulse = true }
    }
}
