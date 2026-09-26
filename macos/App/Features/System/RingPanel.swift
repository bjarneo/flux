import AppKit
import FluxKit
import Observation
import SwiftUI

/// Shows a floating window with a Stop button while a computer rings this
/// Mac, on every Space, above full-screen apps, without taking the keyboard
/// focus. Closing the window stops the ring too.
@MainActor
final class RingPanel: NSObject, NSWindowDelegate {
    private let model: RingModel
    private var panel: NSPanel?

    init(model: RingModel) {
        self.model = model
        super.init()
        observe()
    }

    private func observe() {
        withObservationTracking {
            update(model.ringingFrom)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update(_ from: String?) {
        guard let from else {
            panel?.close()
            panel = nil
            return
        }
        guard panel == nil else { return }
        let model = model
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.title = "Find my Mac"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: RingView(from: from) { model.stop() })
        p.delegate = self
        p.center()
        panel = p
        // The panel does not take the keyboard focus, so a key that the user
        // types in another app cannot stop the ring by accident.
        p.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        model.stop()
    }
}

/// The content of the ring window. The bell pulses while the Mac rings.
private struct RingView: View {
    let from: String
    let stop: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .scaleEffect(pulse ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text("Find my Mac").font(.headline).foregroundStyle(.secondary)
            Text("\(from) is ringing this Mac")
                .font(.title2)
                .multilineTextAlignment(.center)
            Button(action: stop) {
                Label("I found it", systemImage: "checkmark")
                    .padding(.horizontal, 12)
            }
            .controlSize(.extraLarge)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 380, height: 320)
    }
}
