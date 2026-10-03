import FluxKit
import SwiftUI

/// The touchpad and the keyboard for a computer: the pad, the key rows, the
/// type field, and the mic key. The computer runs the input only while its
/// remote_input setting is on.
struct TouchpadView: View {
    @Bindable var controller: TouchpadController

    var body: some View {
        Group {
            if let d = controller.device, d.paired {
                if !d.online {
                    ContentUnavailableView("\(d.name) is offline", systemImage: "wifi.slash",
                                           description: Text("The touchpad works when \(d.name) is connected."))
                } else if !RemoteInputPlugin.supported(d) {
                    ContentUnavailableView("Update Flux on \(d.name)", systemImage: "cursorarrow.motionlines",
                                           description: Text("This version of Flux on \(d.name) does not take input from this Mac."))
                } else if !controller.ready {
                    ContentUnavailableView("Remote input is off", systemImage: "cursorarrow.motionlines",
                                           description: Text("On \(d.name), set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`."))
                } else {
                    content
                }
            } else {
                ContentUnavailableView("\(controller.name) is not paired", systemImage: "link",
                                       description: Text("Pair this Mac with \(controller.name) again to use the touchpad."))
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .onChange(of: controller.ready) { _, ready in
            if !ready { controller.release() }
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                TouchpadSurface(controller: controller)
                PadHint(controller: controller).allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(controller.captured ? Color.green : Color.secondary.opacity(0.35), lineWidth: controller.captured ? 2 : 1)
            )
            .frame(minHeight: 200)
            RemoteKeyRows(target: controller)
            VoiceBar(language: controller.app.dictationLanguage, onText: { controller.typeSpoken($0) }) {
                RemoteTypeField(target: controller)
            } send: {
                Button { controller.key(.enter) } label: {
                    Image(systemName: "return")
                        .frame(width: DictationLayout.keySize - 12, height: DictationLayout.keySize - 12)
                }
                .buttonStyle(.bordered)
                .help("Press Enter on \(controller.name)")
                .accessibilityLabel("Enter")
            }
        }
        .padding(16)
    }
}

/// The text in the middle of the pad.
private struct PadHint: View {
    let controller: TouchpadController

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: controller.captured ? "cursorarrow.motionlines" : "cursorarrow.click")
                .font(.system(size: 28))
                .foregroundStyle(controller.captured ? .green : .secondary)
            if controller.captured {
                Text("Controlling \(controller.name)").font(.headline)
                Text("Press Control and Option together to give the pointer back to this Mac.")
            } else {
                Text("Click to control \(controller.name)").font(.headline)
                Text("The pointer, the clicks, the scrolls, and all keys then go to \(controller.name).")
                Text("Control-click is a right-click. Option-click is a middle-click. Press and move to drag.")
                if controller.padFocused {
                    Text("Keys that you type now go to \(controller.name). This Mac keeps its Command shortcuts.")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(20)
    }
}
