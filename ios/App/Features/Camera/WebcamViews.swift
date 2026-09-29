import AVFoundation
import FluxKit
import SwiftUI

/// The Webcam mode of the camera screen. The iPhone camera becomes a webcam
/// named Flux Camera on the computer. The preview shows what the computer
/// gets, with the same shape, mirror, and colors, while the stream runs.
/// iOS gives the camera only to the app on the screen, so the stream stops
/// when Flux leaves the screen.
struct WebcamPanel: View {
    @Environment(AppModel.self) private var model
    let deviceId: String

    var body: some View {
        if let plugin = model.core.plugin(WebcamPlugin.self) {
            WebcamControls(plugin: plugin, webcam: plugin.model, deviceId: deviceId)
        }
    }
}

private struct WebcamControls: View {
    @Environment(AppModel.self) private var model
    let plugin: WebcamPlugin
    let webcam: WebcamModel
    let deviceId: String
    @State private var access = CameraAccess.current
    @State private var settingsOpen = false

    private var device: DeviceSnapshot? { model.device(deviceId) }
    private var name: String { device?.name ?? "the computer" }
    private var mine: Bool { webcam.status.deviceId == deviceId }
    private var active: Bool { webcam.status.active(for: deviceId) }

    var body: some View {
        VStack(spacing: 14) {
            preview
                // The webcam makes preview images only while this view shows them.
                .onAppear { plugin.setPreviewShown(true) }
                .onDisappear { plugin.setPreviewShown(false) }
            if access == .authorized, !webcam.cameras.isEmpty {
                status
                HStack(spacing: 8) {
                    if webcam.caps.cameras.count > 1 {
                        let front = webcam.config.camera == "front"
                        Button(front ? "Back camera" : "Front camera", systemImage: "arrow.triangle.2.circlepath.camera") {
                            plugin.update { $0.camera = front ? "back" : "front" }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Settings", systemImage: "slider.horizontal.3") { settingsOpen = true }
                        .buttonStyle(.bordered)
                }
                Button {
                    if active { plugin.stop() } else { plugin.start(deviceId) }
                } label: {
                    Label(active ? "Stop webcam" : "Start webcam", systemImage: active ? "stop.fill" : "video.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(active ? .red : .accentColor)
                .disabled(!active && !canStart)
                Text("Apps on \(name) see this iPhone as Flux Camera. Keep Flux on the screen while you stream.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .sheet(isPresented: $settingsOpen) {
            WebcamSettingsSheet(plugin: plugin, webcam: webcam, streaming: active)
                .presentationDetents([.medium, .large])
        }
        // The screen stays on while the iPhone streams.
        .onChange(of: active, initial: true) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            access = CameraAccess.current
        }
    }

    private var canStart: Bool {
        guard let device else { return false }
        return device.online && device.accepts(PacketType.fluxWebcam) && !webcam.cameras.isEmpty
    }

    /// The frames that the computer gets, or the reason there are none.
    @ViewBuilder
    private var preview: some View {
        ZStack {
            Color.black
            switch access {
            case .denied:
                CameraNotice("Flux cannot use the camera", systemImage: "video.slash",
                             detail: "Allow the camera for Flux in Settings to use this iPhone as a webcam.") {
                    Button("Open Settings") { AppSettings.open() }
                        .buttonStyle(.borderedProminent)
                }
            case .notDetermined:
                CameraNotice("Flux needs the camera", systemImage: "video", detail: "Allow the camera to use this iPhone as a webcam.") {
                    Button("Allow Camera") { Task { access = await CameraAccess.request() } }
                        .buttonStyle(.borderedProminent)
                }
            case .authorized:
                if webcam.cameras.isEmpty {
                    CameraNotice("No camera", systemImage: "video.slash",
                                 detail: "This iPhone has no camera that Flux can use as a webcam.") { EmptyView() }
                } else if active, let image = webcam.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "web.camera").font(.largeTitle)
                        Text(active ? "Starting the camera…" : "The preview shows while the webcam streams.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(24)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        // At most 360 points high, so that the controls stay on the screen.
        .frame(maxWidth: 360 * aspect)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            if active, webcam.status.phase == .live {
                Label("LIVE", systemImage: "circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.red))
                    .padding(12)
            }
        }
    }

    private var aspect: CGFloat { CGFloat(webcam.config.width) / CGFloat(max(1, webcam.config.height)) }

    @ViewBuilder
    private var status: some View {
        if let device, device.online, !device.accepts(PacketType.fluxWebcam) {
            Text("Update Flux on \(name) to use this iPhone as a webcam.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let error = webcam.cameraError, active {
            Text(error).font(.subheadline).foregroundStyle(.red)
        } else if mine, webcam.status.phase == .live {
            VStack(spacing: 2) {
                Text(webcam.status.message).font(.subheadline.weight(.semibold))
                Text(verbatim: "\(webcam.config.width) × \(webcam.config.height)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } else if mine, !webcam.status.message.isEmpty {
            Text(webcam.status.message)
                .font(.subheadline)
                .foregroundStyle(webcam.status.phase == .error ? .red : .secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Ready. Press Start webcam to use this iPhone as a webcam on \(name).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// All webcam settings. The computer can change the same settings.
private struct WebcamSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let plugin: WebcamPlugin
    let webcam: WebcamModel
    let streaming: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Shape", selection: binding(\.aspect)) {
                        ForEach(webcam.caps.aspects, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: binding(\.resolution)) {
                        ForEach(webcam.caps.resolutions, id: \.self) { Text(verbatim: "\($0)p").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(verbatim: "Shape and quality · \(webcam.config.width) × \(webcam.config.height)")
                } footer: {
                    if streaming { Text("A new shape or quality starts the stream again.") }
                }
                Section {
                    if webcam.caps.cameras.count > 1 {
                        Picker("Camera", selection: binding(\.camera)) {
                            ForEach(webcam.caps.cameras, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Mirror", isOn: binding(\.mirror))
                    Toggle(isOn: Binding(get: { webcam.sendsMicrophone }, set: { plugin.setSendsMicrophone($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also send the microphone")
                            Text("Apps on the computer also get Flux Microphone").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Image") {
                    if webcam.caps.zoomMax > 1 {
                        slider("Zoom", \.zoom, 1...webcam.caps.zoomMax, step: 0.1) { String(format: "%.1f×", $0) }
                    }
                    if webcam.caps.exposureMax > webcam.caps.exposureMin {
                        slider("Exposure", \.exposure, webcam.caps.exposureMin...webcam.caps.exposureMax, step: max(0.01, webcam.caps.exposureStep)) {
                            String(format: "%+.1f EV", $0)
                        }
                    }
                    if webcam.caps.whiteBalance.count > 1 {
                        Picker("White balance", selection: binding(\.whiteBalance)) {
                            ForEach(webcam.caps.whiteBalance, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    slider("Brightness", \.brightness, -1...1, step: 0.05) { String(format: "%+.2f", $0) }
                    slider("Contrast", \.contrast, 0...2, step: 0.05) { String(format: "%.2f", $0) }
                    slider("Saturation", \.saturation, 0...2, step: 0.05) { String(format: "%.2f", $0) }
                    slider("Warmth", \.warmth, -1...1, step: 0.05) { v in
                        v <= -0.01 ? String(format: "Cooler %.2f", -v) : v >= 0.01 ? String(format: "Warmer %.2f", v) : "Neutral"
                    }
                    Button("Reset Image", systemImage: "arrow.counterclockwise") { plugin.reset() }
                }
            }
            .navigationTitle("Webcam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<WebcamConfig, Double>, _ range: ClosedRange<Double>, step: Double,
                        label: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label(webcam.config[keyPath: key]))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding(key), in: range, step: step)
        }
    }

    private func binding<T>(_ key: WritableKeyPath<WebcamConfig, T>) -> Binding<T> {
        Binding(get: { webcam.config[keyPath: key] }, set: { value in plugin.update { $0[keyPath: key] = value } })
    }
}
