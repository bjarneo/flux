import FluxKit
import SwiftUI

/// Photo mode: the preview, the shutter, and the last photo with its send state.
struct PhotoModeView: View {
    let shots: PhotoShots
    let window: CameraWindowModel

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(window: window) {
                LiveCamera(camera: window.camera, what: "take photos") { EmptyView() }
            }
            ControlBar {
                LastPhoto(status: shots.status, retry: shots.retry)
            } center: {
                Shutter(label: "Take Photo", busy: { if case .saving = shots.status { true } else { false } }(), action: shots.shoot)
                    .disabled(!window.camera.running || shots.busy)
            } trailing: {
                EmptyView()
            }
        }
    }
}

/// The thumbnail of the last photo with its send state. A failed photo sends again on click.
private struct LastPhoto: View {
    let status: PhotoShots.Status
    let retry: () -> Void

    var body: some View {
        let (thumb, label, failed): (CGImage?, String, Bool) = switch status {
        case .none: (nil, "", false)
        case .saving: (nil, "Saving…", false)
        case .sending(let t): (t, "Sending…", false)
        case .sent(let t): (t, "Sent", false)
        case .failed(let t, _, _, _): (t, "Click to send again", true)
        }
        if case .none = status {
            EmptyView()
        } else {
            Button(action: retry) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        if let thumb {
                            Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(failed ? Color.accentColor : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!failed)
        }
    }
}

/// Document mode: the preview with the page outline, the pages, and Send PDF.
struct DocumentModeView: View {
    let pages: DocumentPages
    let window: CameraWindowModel

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(window: window) {
                LiveCamera(camera: window.camera, what: "scan pages", outlines: true) { EmptyView() }
                if pages.busy { BusyBadge(text: "Finding the page") }
            }
            if !pages.pages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(pages.pages.enumerated()), id: \.element.id) { i, page in
                            PageThumb(number: i + 1, page: page, pages: pages)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 104)
            }
            if let status = pages.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            ControlBar {
                ImageSources(window: window, multiple: true)
            } center: {
                Shutter(label: "Add Page", busy: pages.busy, action: pages.capture)
                    .disabled(!window.camera.running || pages.sending)
            } trailing: {
                Button(pages.pages.isEmpty ? "Send PDF" : "Send PDF, \(DocumentPages.label(pages.pages.count))", systemImage: "doc.richtext", action: pages.send)
                    .buttonStyle(.borderedProminent)
                    .disabled(pages.pages.isEmpty || pages.sending || pages.busy)
            }
        }
    }
}

/// 1 page of a document. The menu switches between the found page and the whole image.
private struct PageThumb: View {
    let number: Int
    let page: DocumentPages.Page
    let pages: DocumentPages

    var body: some View {
        VStack(spacing: 4) {
            Image(decorative: page.image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(height: 76)
                .background(Color.black.opacity(0.1))
                .overlay(alignment: .topTrailing) {
                    Button { pages.remove(page.id) } label: {
                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove page \(number)")
                }
            Text(page.flat == nil ? "\(number) · whole image" : "\(number)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            if page.flat != nil {
                Button(page.whole ? "Use Found Page" : "Use Whole Image") { pages.toggleWhole(page.id) }
            }
            Button("Remove") { pages.remove(page.id) }
        }
    }
}

/// Signature mode: paper through the camera or a drawing, then the ink in a color.
struct SignatureModeView: View {
    @Bindable var capture: SignatureCapture
    let window: CameraWindowModel
    @State private var previewSize = CGSize.zero
    @State private var canvasSize = CGSize.zero

    var body: some View {
        VStack(spacing: 0) {
            CameraStage(window: window) {
                switch capture.phase {
                case .live where capture.source == .camera:
                    LiveCamera(camera: window.camera, what: "capture a signature") {
                        GuideFrame()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
                    }
                case .live:
                    DrawingCanvas(drawing: $capture.drawing)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                case .working(let image):
                    StillImage(image: image)
                    BusyBadge(text: "Finding the ink")
                case .result(let ink):
                    if let ink {
                        SignaturePreview(ink: ink, color: capture.color)
                    } else {
                        Text(capture.drawn ? "Draw your signature first." : "No ink found. Use a dark pen on white paper, and fill the frame.")
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(32)
                    }
                }
            }
            switch capture.phase {
            case .live:
                ControlBar {
                    Picker("Source", selection: $capture.source) {
                        ForEach(SignatureCapture.Source.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if capture.source == .camera { ImageSources(window: window) }
                } center: {
                    if capture.source == .camera {
                        Shutter(label: "Capture Signature") { capture.capture(preview: previewSize) }
                            .disabled(!window.camera.running)
                    }
                } trailing: {
                    if capture.source == .draw {
                        Button("Undo", systemImage: "arrow.uturn.backward") { capture.drawing.undo() }
                            .keyboardShortcut("z")
                            .disabled(capture.drawing.isEmpty)
                        Button("Clear") { capture.drawing.clear() }
                            .disabled(capture.drawing.isEmpty)
                        Button("Done") { capture.finishDrawing(canvas: canvasSize) }
                            .buttonStyle(.borderedProminent)
                            .disabled(capture.drawing.isEmpty)
                    }
                }
            case .working:
                ControlBar { EmptyView() } center: { EmptyView() } trailing: { EmptyView() }
            case .result(let ink):
                result(ink)
            }
        }
    }

    private func result(_ ink: SignatureInk?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ink {
                HStack(spacing: 8) {
                    ForEach(InkColor.allCases.filter { !(capture.drawn && $0 == .original) }, id: \.self) { c in
                        Button {
                            capture.color = c
                        } label: {
                            Label {
                                Text(c.label)
                            } icon: {
                                Circle().fill(Color(rgb: c.of(ink))).frame(width: 12, height: 12)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(c == capture.color ? .accentColor : nil)
                        .overlay {
                            if c == capture.color {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                    }
                }
            }
            if let failure = capture.failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(capture.drawn ? "Draw Again" : "Retake", systemImage: "arrow.counterclockwise", action: capture.retake)
                if let ink {
                    Button(capture.sending ? "Sending…" : "Send to \(window.deviceName)", systemImage: "paperplane") { capture.send(ink) }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.sending)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(minHeight: 72)
    }
}

/// Dims the preview outside the guide frame, and draws the frame and a signature line.
private struct GuideFrame: View {
    var body: some View {
        ZStack(alignment: .top) {
            Canvas { context, size in
                let frame = SignatureCut.guideFrame(width: size.width, height: size.height)
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRoundedRect(in: frame, cornerSize: CGSize(width: 16, height: 16))
                context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                context.stroke(Path(roundedRect: frame, cornerRadius: 16), with: .color(.accentColor), lineWidth: 2)
                let y = frame.minY + frame.height * 0.75
                var line = Path()
                line.move(to: CGPoint(x: frame.minX + frame.width * 0.08, y: y))
                line.addLine(to: CGPoint(x: frame.maxX - frame.width * 0.08, y: y))
                context.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            Text("Sign with a dark pen. Fit the signature in the frame.")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.top, 18)
        }
        .allowsHitTesting(false)
    }
}

/// A white canvas to sign on with the trackpad, a mouse, or a tablet.
private struct DrawingCanvas: View {
    @Binding var drawing: SignatureDrawing
    @State private var drawingStroke = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                var line = Path()
                line.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.75))
                line.addLine(to: CGPoint(x: size.width * 0.92, y: size.height * 0.75))
                context.stroke(line, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                for stroke in drawing.strokes {
                    context.stroke(Path(SignatureDrawing.path(stroke)), with: .color(.black),
                                   style: StrokeStyle(lineWidth: SignatureDrawing.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            if drawing.isEmpty {
                Text("Sign here with the trackpad, a mouse, or a tablet")
                    .foregroundStyle(.gray)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if drawingStroke {
                        drawing.extend(value.location)
                    } else {
                        drawingStroke = true
                        drawing.begin(value.location)
                    }
                }
                .onEnded { _ in drawingStroke = false }
        )
    }
}

/// The signature on a light checkerboard, so that the ink and the transparent background both show.
private struct SignaturePreview: View {
    let ink: SignatureInk
    let color: InkColor

    var body: some View {
        ZStack {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                let cell: CGFloat = 10
                var y: CGFloat = 0, row = 0
                while y < size.height {
                    var x: CGFloat = row % 2 == 0 ? 0 : cell
                    while x < size.width {
                        context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color(white: 0.894)))
                        x += cell * 2
                    }
                    y += cell
                    row += 1
                }
            }
            if let image = CameraImages.image(ink, rgb: color.of(ink)) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
            }
        }
    }
}

private extension Color {
    /// A color from 0xRRGGBB.
    init(rgb: Int) {
        self.init(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
