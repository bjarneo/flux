import FluxKit
import SwiftUI

extension PendingStart {
    /// The screen of the stream: the webcam mode of the camera screen, or
    /// the microphone screen, as under Control.
    static func route(_ kind: StreamRequest.Kind, computerId: String) -> FeatureRoute {
        switch kind {
        case .webcam: return .cameraMode(computerId, .webcam)
        case .mic: return .mic(computerId)
        }
    }
}

/// Opens the stream screen after a tap on start, in the prompt or in the
/// notification, and starts the stream with the start code of the webcam or
/// the microphone and the saved settings.
@MainActor
final class StreamRequestFeature {
    static let shared = StreamRequestFeature()

    private(set) var pending: PendingStart?
    private var timer: Task<Void, Never>?
    private weak var model: AppModel?

    private init() {}

    static func didLaunch(model: AppModel) {
        guard let plugin = model.core.plugin(StreamRequestPlugin.self) else { return }
        shared.model = model
        plugin.model.isAppActive = { [weak model] in model?.isActive == true }
        // The sheet shows the prompt by itself, see `StreamRequestRoot`.
        plugin.model.open = { request in StreamRequestFeature.shared.open(request) }
        plugin.model.openPage = { computerId, kind in StreamRequestFeature.shared.openPage(computerId, kind) }
    }

    /// Opens the screen of the stream under Control and starts the stream
    /// when Flux is on the screen and the computer is connected.
    func open(_ request: StreamRequest) {
        guard model != nil else { return }
        openPage(request.computerId, request.kind)
        pending = PendingStart(request, now: .now)
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: PendingStart.wait)
            guard !Task.isCancelled else { return }
            self?.check()
        }
        check()
    }

    /// Opens the screen of the stream under Control and starts nothing.
    /// The user then starts the stream on that screen. A computer that is
    /// not paired opens nothing.
    func openPage(_ computerId: String, _ kind: StreamRequest.Kind) {
        guard let model, model.device(computerId)?.paired == true else { return }
        model.tab = .control
        model.controlPath = [.feature(PendingStart.route(kind, computerId: computerId))]
    }

    /// Starts the waiting stream when Flux is on the screen and the computer
    /// is connected. It runs after each change of the core state and when
    /// Flux comes on the screen. An unpair ends the start at once.
    func check() {
        guard let p = pending, let model else { return }
        let device = model.device(p.computerId)
        let paired = device?.paired == true
        let step = p.step(active: model.isActive, online: device?.online == true, now: .now)
        guard step != .wait || !paired else { return }
        pending = nil
        timer?.cancel()
        timer = nil
        guard paired else { return }
        guard step == .start else {
            model.show(p.failedText)
            return
        }
        // A stream that the user started in the meantime keeps running.
        guard model.core.plugin(StreamRequestPlugin.self)?.streams(p.kind, to: p.computerId) != true else { return }
        switch p.kind {
        case .webcam: model.core.plugin(WebcamPlugin.self)?.start(p.computerId)
        case .mic: model.core.plugin(MicPlugin.self)?.start(p.computerId)
        }
    }
}

/// Shows the prompt of the newest stream request while Flux is on the
/// screen. Only Start webcam or Start the mic starts a stream. The sheet
/// does not close with a swipe, so that the user answers with a button.
struct StreamRequestRoot: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let plugin = model.core.plugin(StreamRequestPlugin.self) {
            content
                .sheet(item: Binding(get: { model.isActive ? plugin.model.current : nil }, set: { _ in })) { request in
                    StreamRequestSheet(request: request,
                                       start: { plugin.start(request.id) },
                                       notNow: { plugin.dismiss(request.id) })
                        .presentationDetents([.medium, .large])
                        .presentationCornerRadius(20)
                        .interactiveDismissDisabled()
                }
        } else {
            content
        }
    }
}

/// The prompt of 1 stream request: the question, what the start does, and
/// the 2 buttons.
struct StreamRequestSheet: View {
    let request: StreamRequest
    let start: () -> Void
    let notNow: () -> Void
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: request.kind == .webcam ? "web.camera" : "mic")
                    .font(.system(size: iconSize))
                    .foregroundStyle(tn.accent)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(request.kind.detail(computer: request.computerName))
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: TiledMetrics.gap) {
                    Button(request.kind.startLabel, action: start)
                        .buttonStyle(FluxButtonStyle(kind: .filled, fullWidth: true))
                    Button(StreamRequest.notNowLabel, action: notNow)
                        .buttonStyle(FluxButtonStyle(kind: .outlined, fullWidth: true))
                }
                .frame(maxWidth: TiledMetrics.maxActionWidth)
                .padding(.top, 8)
            }
            .padding(24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fluxScreen()
    }
}
