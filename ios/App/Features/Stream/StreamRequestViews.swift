import FluxKit
import SwiftUI

/// A start that waits after a tap on start: the webcam needs Flux on the
/// screen, and both streams need the link to the computer. A tap on the
/// notification opens Flux, and the link can come back a moment later.
struct PendingStart: Equatable {
    /// How long a start waits for Flux on the screen and for the link.
    static let wait: Duration = .seconds(15)

    let kind: StreamRequest.Kind
    let computerId: String
    let computerName: String
    let deadline: ContinuousClock.Instant

    enum Step: Equatable {
        case wait
        case start
        /// The link did not come back before the deadline.
        case giveUp
    }

    /// The next step of the start.
    func step(active: Bool, online: Bool, now: ContinuousClock.Instant) -> Step {
        if active && online { return .start }
        return now < deadline ? .wait : .giveUp
    }

    /// The message when the stream did not start.
    var failedText: String {
        switch kind {
        case .webcam: return "The webcam did not start, because \(computerName) is not connected."
        case .mic: return "The microphone did not start, because \(computerName) is not connected."
        }
    }

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
    }

    /// Opens the screen of the stream under Control and starts the stream
    /// when Flux is on the screen and the computer is connected.
    func open(_ request: StreamRequest) {
        guard let model else { return }
        model.tab = .control
        model.controlPath = [.feature(PendingStart.route(request.kind, computerId: request.computerId))]
        pending = PendingStart(kind: request.kind, computerId: request.computerId, computerName: request.computerName,
                               deadline: ContinuousClock.now + PendingStart.wait)
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: PendingStart.wait)
            guard !Task.isCancelled else { return }
            self?.check()
        }
        check()
    }

    /// Starts the waiting stream when Flux is on the screen and the computer
    /// is connected. It runs after each change of the core state and when
    /// Flux comes on the screen.
    func check() {
        guard let p = pending, let model else { return }
        let step = p.step(active: model.isActive, online: model.device(p.computerId)?.online == true, now: .now)
        guard step != .wait else { return }
        pending = nil
        timer?.cancel()
        timer = nil
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
