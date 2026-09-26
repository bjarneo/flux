import FluxKit
import SwiftUI

/// Text mode: the preview with text boxes, the shutter, and the editable result.
struct TextModeView: View {
    @Bindable var scan: TextScan
    let window: CameraWindowModel

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(window: window) {
                switch scan.phase {
                case .live:
                    LiveCamera(camera: window.camera, what: "scan text", outlines: true) { EmptyView() }
                case .reading(let image):
                    StillImage(image: image)
                    BusyBadge(text: "Reading text")
                case .result(let image):
                    StillImage(image: image)
                }
            }
            switch scan.phase {
            case .live:
                ControlBar {
                    ImageSources(window: window)
                } center: {
                    Shutter(label: "Scan Text", action: scan.capture)
                        .disabled(!window.camera.running)
                } trailing: {
                    EmptyView()
                }
            case .reading:
                ControlBar { EmptyView() } center: { EmptyView() } trailing: { EmptyView() }
            case .result:
                result
            }
        }
    }

    private var result: some View {
        VStack(spacing: 12) {
            if scan.text.isEmpty {
                Text("No text found. Move closer or add light.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                TextEditor(text: $scan.text)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
            }
            HStack {
                Spacer()
                Button("Retake", systemImage: "arrow.counterclockwise", action: scan.retake)
                if !scan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Send to \(window.deviceName)", systemImage: "paperplane", action: scan.send)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// QR mode: the preview with code outlines, and the result sheet of a code.
struct CodeModeView: View {
    let scan: CodeScan
    let window: CameraWindowModel

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(window: window) {
                switch scan.phase {
                case .live:
                    LiveCamera(camera: window.camera, what: "scan codes", outlines: true) { EmptyView() }
                case .found(let image, _), .missing(let image):
                    StillImage(image: image)
                }
            }
            switch scan.phase {
            case .live:
                ControlBar {
                    Text("Point the camera at a code").foregroundStyle(.secondary)
                } center: {
                    EmptyView()
                } trailing: {
                    ImageSources(window: window)
                }
            case .found(_, let sheet):
                CodeSheetView(sheet: sheet, run: scan.run, again: scan.again)
            case .missing:
                HStack {
                    Text("No code found in this image.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Again", systemImage: "qrcode.viewfinder", action: scan.again)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(minHeight: 72)
            }
        }
    }
}

/// The type line, the value, and the 2 actions of a code.
private struct CodeSheetView: View {
    let sheet: CodeSheet
    let run: (CodeAction) -> Void
    let again: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.accentColor)
            ScrollView {
                Text(sheet.value)
                    .font(.title3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(Array(sheet.actions.enumerated()), id: \.offset) { i, action in
                    if i == 0 {
                        Button(action.verb, systemImage: icon(action.verb)) { run(action) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(action.verb, systemImage: icon(action.verb)) { run(action) }
                    }
                }
                Spacer()
                Button("Scan Again", systemImage: "qrcode.viewfinder", action: again)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// The icon for the verb of a code action, such as Open, Copy, or Save.
    private func icon(_ verb: String) -> String {
        switch verb.split(separator: " ").first?.lowercased() {
        case "open": "arrow.up.forward.app"
        case "copy": "doc.on.doc"
        case "save": "square.and.arrow.down"
        default: "paperplane"
        }
    }
}
