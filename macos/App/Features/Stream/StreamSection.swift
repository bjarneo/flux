import AppKit
import FluxKit
import SwiftUI

/// The webcam and the screen mirror of a paired computer.
struct StreamSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let webcam = model.core.plugin(WebcamPlugin.self) {
            WebcamSection(plugin: webcam, model: webcam.model, device: device)
        }
        if let screen = model.core.plugin(ScreenPlugin.self) {
            ScreenSection(plugin: screen, model: screen.model, device: device)
        }
    }
}

/// Stops the streams to a computer from the menu bar.
struct StreamMenuItems: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if let webcam = model.core.plugin(WebcamPlugin.self), webcam.model.status.active(for: device.id) {
            Button("Stop Webcam") { webcam.stop() }
        }
        if let screen = model.core.plugin(ScreenPlugin.self), screen.model.status.active(for: device.id) {
            Button("Stop Screen Mirror") { screen.stop() }
        }
    }
}

private enum PrivacyPane: String {
    case camera = "Privacy_Camera"
    case screen = "Privacy_ScreenCapture"

    func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One line with the state of a stream.
private struct StatusRow: View {
    let status: StreamStatus
    let idle: String

    var body: some View {
        Label {
            Text(status.message.isEmpty ? idle : status.message)
                .foregroundStyle(status.phase == .error ? .red : .primary)
        } icon: {
            switch status.phase {
            case .connecting, .starting: ProgressView().controlSize(.small)
            case .live: Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .idle: Image(systemName: "pause.circle").foregroundStyle(.secondary)
            }
        }
    }
}

private struct WebcamSection: View {
    let plugin: WebcamPlugin
    let model: WebcamModel
    let device: DeviceSnapshot

    private var mine: Bool { model.status.deviceId == device.id }
    private var active: Bool { model.status.active(for: device.id) }

    var body: some View {
        Section("Webcam") {
            StatusRow(status: mine ? model.status : StreamStatus(), idle: "Use the camera of this Mac as Flux Camera on \(device.name).")
            if !device.accepts(PacketType.fluxWebcam) {
                Text("Update Flux on \(device.name) to use this Mac as a webcam.").foregroundStyle(.secondary)
            }
            if WebcamPlugin.cameraAccessDenied {
                HStack {
                    Text("Flux has no access to the camera.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") { PrivacyPane.camera.open() }
                }
            }
            if active, let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            cameraPicker
            if let error = model.cameraError, active {
                Text(error).foregroundStyle(.red)
            }
            Picker("Shape", selection: binding(\.aspect)) {
                ForEach(model.caps.aspects, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Resolution", selection: binding(\.resolution)) {
                ForEach(model.caps.resolutions, id: \.self) { Text(verbatim: "\($0)p").tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Mirror the image", isOn: binding(\.mirror))
            Toggle(isOn: Binding(get: { model.sendsMicrophone }, set: { plugin.setSendsMicrophone($0) })) {
                Text("Also send the microphone")
                Text("Apps on the computer also get Flux Microphone")
            }
            if model.caps.whiteBalance.count > 1 {
                Picker("White balance", selection: binding(\.whiteBalance)) {
                    ForEach(model.caps.whiteBalance, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            SliderRow(title: "Zoom", value: binding(\.zoom), range: 1...max(1.01, model.caps.zoomMax), step: 0.1) { String(format: "%.1f×", $0) }
            SliderRow(title: "Exposure", value: binding(\.exposure), range: model.caps.exposureMin...max(model.caps.exposureMin + 0.01, model.caps.exposureMax), step: max(0.01, model.caps.exposureStep)) {
                String(format: "%+.1f EV", $0)
            }
            SliderRow(title: "Brightness", value: binding(\.brightness), range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            SliderRow(title: "Contrast", value: binding(\.contrast), range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            SliderRow(title: "Saturation", value: binding(\.saturation), range: 0...2, step: 0.05) { String(format: "%.2f", $0) }
            SliderRow(title: "Warmth", value: binding(\.warmth), range: -1...1, step: 0.05) { String(format: "%+.2f", $0) }
            HStack {
                Button("Reset Image") { plugin.reset() }
                Spacer()
                if active {
                    Button("Stop Webcam") { plugin.stop() }
                } else {
                    Button("Start Webcam") { plugin.start(device.id) }
                        .disabled(!device.online || !device.accepts(PacketType.fluxWebcam) || model.cameras.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var cameraPicker: some View {
        if model.cameras.isEmpty {
            LabeledContent("Camera", value: "No camera")
        } else {
            // A saved camera that is gone shows the camera that the stream uses instead.
            Picker("Camera", selection: Binding(
                get: { model.cameras.contains { $0.id == model.config.camera } ? model.config.camera : model.cameras[0].id },
                set: { id in plugin.update { $0.camera = id } }
            )) {
                ForEach(model.cameras) { camera in
                    Text(camera.isContinuity ? "\(camera.name) (Continuity Camera)" : camera.name).tag(camera.id)
                }
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<WebcamConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: key] }, set: { value in plugin.update { $0[keyPath: key] = value } })
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }
}

private struct ScreenSection: View {
    let plugin: ScreenPlugin
    let model: ScreenModel
    let device: DeviceSnapshot

    private var mine: Bool { model.status.deviceId == device.id }
    private var active: Bool { model.status.active(for: device.id) }

    var body: some View {
        Section("Screen mirror") {
            StatusRow(status: mine ? model.status : StreamStatus(), idle: "Show a display of this Mac in a window on \(device.name).")
            if !device.accepts(PacketType.fluxScreen) {
                Text("Update Flux on \(device.name) to mirror this screen.").foregroundStyle(.secondary)
            }
            if !model.hasAccess {
                HStack {
                    Text("Screen recording is off for Flux.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Privacy Settings") { PrivacyPane.screen.open() }
                }
            }
            if model.displays.isEmpty {
                LabeledContent("Display", value: "No display")
            } else {
                Picker("Display", selection: Binding(
                    get: { model.display ?? model.displays[0].id },
                    set: { plugin.select($0) }
                )) {
                    ForEach(model.displays) { display in
                        Text(verbatim: "\(display.name) (\(display.width) × \(display.height))").tag(display.id)
                    }
                }
            }
            HStack {
                Spacer()
                if active {
                    Button("Stop Screen Mirror") { plugin.stop() }
                } else {
                    Button("Mirror Screen") { plugin.start(device.id) }
                        .disabled(!device.online || !device.accepts(PacketType.fluxScreen) || model.displays.isEmpty)
                }
            }
        }
        .onAppear { plugin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in plugin.refresh() }
        .onChange(of: model.status) { plugin.refresh() }
    }
}
