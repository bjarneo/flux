import AppKit
import FluxKit
import SwiftUI

/// The sizes of the reply bar.
enum DictationLayout {
    /// The size of the mic key and the send key.
    static let keySize: CGFloat = 34
    static let gap: CGFloat = 8
    /// The inner margin of the listening panel. The stop key sits this far from its corner.
    static let panelPad: CGFloat = 12
    /// A press on the mic key that lasts this long is push to talk. The release then stops the dictation.
    static let hold: TimeInterval = 0.35
}

/// The reply bar with dictation. At rest it shows `field`, the mic key, and
/// `send`. While this Mac listens, 1 panel takes the full width: the
/// language, the time, the live wave, the words, and the stop key in its
/// corner. The mic key is the same view in both layouts and moves into the
/// panel, so a press and hold keeps working while the panel opens. Without
/// `onLanguage`, the panel shows the language but does not open the picker.
struct DictationBar<Field: View, Send: View>: View {
    let dictation: Dictation
    let canDictate: Bool
    let onStart: () -> Void
    let onLanguage: (() -> Void)?
    @ViewBuilder let field: () -> Field
    @ViewBuilder let send: () -> Send

    var body: some View {
        let active = dictation.phase != .idle
        let key = DictationLayout.keySize
        // Without a send key, the mic key rests at the trailing edge.
        let rest = Send.self == EmptyView.self ? 0 : -(key + DictationLayout.gap)
        ZStack(alignment: .bottomTrailing) {
            if active {
                ListeningPanel(dictation: dictation, onLanguage: onLanguage)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            } else {
                HStack(alignment: .bottom, spacing: DictationLayout.gap) {
                    field()
                    // The mic key lies over this place.
                    if canDictate { Color.clear.frame(width: key, height: key) }
                    send()
                }
                .transition(.opacity)
            }
            if canDictate {
                MicKey(dictation: dictation, onStart: onStart)
                    .offset(x: active ? -DictationLayout.panelPad : rest,
                            y: active ? -DictationLayout.panelPad : 0)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: active)
    }
}

/// A text field with a mic key, for the text fields of the app. The words
/// of a dictation go to `onText`. Under the bar, a line tells why a
/// dictation failed. `language` is the dictation language of this Mac.
/// Without `picker`, the panel does not open the language picker, for the
/// search of the picker itself. While `enabled` is off, the mic key hides,
/// unless a dictation runs, so that the user can still stop it.
struct VoiceBar<Field: View, Send: View>: View {
    @Binding var language: String
    var picker = true
    var enabled = true
    let onText: @MainActor (String) -> Void
    @ViewBuilder let field: () -> Field
    @ViewBuilder let send: () -> Send
    @State private var holder = VoiceHolder()
    @State private var canDictate = false
    @State private var picking = false
    @State private var voiceError: String?

    var body: some View {
        let dictation = holder.dictation
        VStack(alignment: .leading, spacing: 6) {
            DictationBar(
                dictation: dictation,
                canDictate: canDictate && (enabled || dictation.phase != .idle),
                onStart: dictate,
                onLanguage: picker ? pickLanguage : nil,
                field: field,
                send: send
            )
            if let problem = voiceError ?? dictation.error {
                HStack(spacing: 10) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if picker && problem == dictation.error && dictation.languageError {
                        Button("Choose a Language") { picking = true }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if problem == DictationText.speechDenied || problem == DictationText.micDenied {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacyURL(problem)) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .task { canDictate = await Task.detached { Dictation.available }.value }
        // The field is gone, so its words have no place.
        .onDisappear {
            holder.starting?.cancel()
            dictation.cancel()
        }
        .sheet(isPresented: $picking) {
            LanguagePicker(selected: language) { tag in
                language = tag
                picking = false
                dictate()
            } onCancel: {
                picking = false
            }
        }
    }

    private func dictate() {
        voiceError = nil
        let dictation = holder.dictation
        let language = language
        let onText = onText
        holder.starting?.cancel()
        holder.starting = Task { @MainActor in
            let problem = await Dictation.authorize()
            // The bar closed while macOS asked for the permissions.
            guard !Task.isCancelled else { return }
            if let problem {
                voiceError = problem
                return
            }
            dictation.start(language: language, hints: []) { spoken in onText(spoken) }
        }
    }

    /// Keeps the words so far and opens the language picker.
    private func pickLanguage() {
        holder.dictation.stopNow()
        picking = true
    }

    private static func privacyURL(_ problem: String) -> URL {
        let pane = problem == DictationText.speechDenied ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

extension VoiceBar where Send == EmptyView {
    /// A bar with the field and the mic key only.
    init(language: Binding<String>, picker: Bool = true, enabled: Bool = true, onText: @escaping @MainActor (String) -> Void,
         @ViewBuilder field: @escaping () -> Field) {
        self.init(language: language, picker: picker, enabled: enabled, onText: onText, field: field, send: { EmptyView() })
    }
}

/// Holds the dictation of a `VoiceBar`. SwiftUI makes a view again at each
/// change, so the holder makes the dictation and its audio engine only when
/// the bar first draws. `starting` waits for the permissions of a new dictation.
final class VoiceHolder {
    @MainActor lazy var dictation = Dictation()
    var starting: Task<Void, Never>?
}

extension View {
    /// The look of a text field next to a mic key: the height of the key and
    /// the frame of the reply field.
    func voiceFieldStyle() -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(minHeight: DictationLayout.keySize)
            .background(shape.fill(Color(nsColor: .textBackgroundColor)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15)))
    }
}

extension AppModel {
    /// The dictation language of this Mac, for all text fields. An empty tag is Automatic.
    var dictationLanguage: Binding<String> {
        let herdr = core.plugin(HerdrPlugin.self)
        return Binding(get: { herdr?.model.dictationLanguage ?? "" }, set: { herdr?.model.dictationLanguage = $0 })
    }
}

/// The key that starts and stops a dictation. A click starts it, and the
/// next click stops it. A press and hold is push to talk: the dictation
/// stops at the release. While this Mac listens, the key is red and sends
/// rings out with the voice.
private struct MicKey: View {
    let dictation: Dictation
    let onStart: () -> Void
    @State private var pressedAt: TimeInterval?
    @State private var stopOnRelease = false

    var body: some View {
        let listening = dictation.phase == .listening
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            switch dictation.phase {
            case .idle: Image(systemName: "mic.fill").foregroundStyle(.secondary)
            case .listening: Image(systemName: "stop.fill").foregroundStyle(.white)
            case .finishing: ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: DictationLayout.keySize, height: DictationLayout.keySize)
        .background(shape.fill(listening ? Color.red : Color.primary.opacity(0.06)))
        .overlay(shape.strokeBorder(listening ? Color.red : Color.primary.opacity(0.12)))
        .background { if listening { MicRings(dictation: dictation) } }
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .help(listening ? "Stop dictation" : "Dictate. Click to start and stop, or press and hold to talk.")
        .accessibilityElement()
        .accessibilityLabel(listening ? "Stop dictation" : "Dictate")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private func press() {
        guard pressedAt == nil else { return }
        pressedAt = ProcessInfo.processInfo.systemUptime
        stopOnRelease = dictation.phase == .listening
        if dictation.phase == .idle { onStart() }
    }

    private func release() {
        guard let at = pressedAt else { return }
        pressedAt = nil
        let held = ProcessInfo.processInfo.systemUptime - at
        if stopOnRelease || (held >= DictationLayout.hold && dictation.phase == .listening) { dictation.stop() }
    }

    private func toggle() {
        switch dictation.phase {
        case .idle: onStart()
        case .listening: dictation.stop()
        case .finishing: break
        }
    }
}

/// 2 rings that spread from the mic key, wider with a louder voice.
private struct MicRings: View {
    let dictation: Dictation

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let voice = CGFloat(dictation.level)
                let reach = 4 + voice * 8
                for k in 0..<2 {
                    let p = CGFloat((t / 1.5 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1))
                    let grow = p * reach
                    let rect = CGRect(x: 10 - grow, y: 10 - grow, width: size.width - 20 + grow * 2, height: size.height - 20 + grow * 2)
                    let ring = Path(roundedRect: rect, cornerRadius: 8 + grow, style: .continuous)
                    gc.stroke(ring, with: .color(.red.opacity(Double((1 - p) * (0.3 + 0.6 * voice)))), lineWidth: 2)
                }
            }
        }
        .padding(-10)
        .allowsHitTesting(false)
    }
}

/// The full-width panel of a dictation: a header with the state, the
/// language, and the time, then the live voice wave, then the words. The
/// final words are bright, and the words that the recognizer still hears
/// are dim. The stop key lies over the lower right corner.
private struct ListeningPanel: View {
    let dictation: Dictation
    let onLanguage: (() -> Void)?

    var body: some View {
        let listening = dictation.phase == .listening
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.7)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.7) % 2 == 0
                    Circle()
                        .fill(listening ? Color.red : TermColors.magenta)
                        .frame(width: 8, height: 8)
                        .opacity(listening && !on ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.6), value: on)
                }
                Text(listening ? "listening" : "transcribing")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(listening ? Color.red : TermColors.magenta)
                LanguageChip(tag: dictation.language, onDevice: dictation.onDevice, action: onLanguage)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(DictationText.clock(ProcessInfo.processInfo.systemUptime - dictation.startedAt))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button { dictation.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Drop the dictation")
                    .accessibilityLabel("Cancel dictation")
            }
            VoiceWave(dictation: dictation)
                .frame(height: 32)
                .padding(.trailing, 6)
            HStack(alignment: .bottom, spacing: 0) {
                Transcript(dictation: dictation)
                // The stop key lies over this place: its width, its margin, and a gap.
                Color.clear.frame(width: DictationLayout.keySize + 12, height: DictationLayout.keySize)
            }
        }
        .padding(EdgeInsets(top: 8, leading: DictationLayout.panelPad, bottom: DictationLayout.panelPad, trailing: 8))
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            // The border runs in the colors of the active window on Omarchy.
            TimelineView(.animation) { context in
                let angle = context.date.timeIntervalSinceReferenceDate / 2.6 * 360
                shape.strokeBorder(
                    AngularGradient(colors: [TermColors.blue, TermColors.cyan, TermColors.magenta, TermColors.blue], center: .center,
                                    angle: .degrees(angle.truncatingRemainder(dividingBy: 360))),
                    lineWidth: 1.5
                )
            }
        }
    }
}

/// The language of the dictation, and where the audio goes. A click opens
/// the language picker. Without `action`, the chip only shows the language.
private struct LanguageChip: View {
    let tag: String
    let onDevice: Bool
    let action: (() -> Void)?

    var body: some View {
        let about = onDevice
            ? "This Mac transcribes \(DictationText.languageName(tag))."
            : "Apple transcribes \(DictationText.languageName(tag)), so the audio goes to Apple."
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .help(about + " Click to choose another language.")
        } else {
            chip.help(about)
        }
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: onDevice ? "laptopcomputer" : "cloud")
            Text(tag.isEmpty ? "language" : tag).font(.caption.monospaced())
            if action != nil {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(.secondary)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
    }
}

/// The words of the dictation, with a blinking caret at the end while this
/// Mac listens. The newest words stay in view.
private struct Transcript: View {
    let dictation: Dictation

    var body: some View {
        let listening = dictation.phase == .listening
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let caret = Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            ScrollView {
                words(caret: listening && caret, listening: listening)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(minHeight: DictationLayout.keySize, maxHeight: 96)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func words(caret: Bool, listening: Bool) -> Text {
        let settled = dictation.settled
        let pending = dictation.pending
        var text: Text
        if settled.isEmpty && pending.isEmpty {
            text = Text(dictation.onDevice
                        ? "Speak now. This Mac transcribes on the device."
                        : "Speak now. Apple transcribes this language, so the audio goes to Apple.")
                .foregroundStyle(.tertiary)
        } else {
            text = Text(settled).foregroundStyle(.primary)
            if !pending.isEmpty {
                text = text + Text(settled.isEmpty ? pending : " " + pending).foregroundStyle(.secondary)
            }
        }
        if listening {
            text = text + Text(" ▍").foregroundStyle(caret ? TermColors.magenta : Color.clear)
        }
        return text
    }
}

/// The live voice wave: rounded bars that scroll from right to left, with
/// the newest level at the right edge. Older bars fade. When the voice is
/// quiet, the bars breathe, so the wave still shows that this Mac listens.
private struct VoiceWave: View {
    let dictation: Dictation
    @State private var wave = WaveState()

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { gc, size in
                let now = ProcessInfo.processInfo.systemUptime
                let live = dictation.phase == .listening && now - dictation.levelAt < 0.4
                wave.step(now, level: live ? dictation.level : 0)
                let barW: CGFloat = 3
                let step = barW + 3
                let mid = size.height / 2
                let minH: CGFloat = 3
                let breath: CGFloat = 2.5
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [TermColors.blue, TermColors.cyan, TermColors.magenta]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
                )
                let t = context.date.timeIntervalSinceReferenceDate
                let count = min(WaveState.bars, Int(size.width / step) + 2)
                for i in 0..<count {
                    let x = size.width - barW / 2 - (CGFloat(i) + wave.progress) * step
                    if x < -barW { break }
                    let rest = minH + breath * CGFloat(0.5 + 0.5 * sin(t * 2 * .pi * 0.8 + Double(i) * 0.45))
                    let h = max(rest, CGFloat(wave.value(i)) * (size.height - 2))
                    // The newest bars are at full strength. The oldest fade out at the left edge.
                    let fade = min(max(x / (size.width * 0.35), 0), 1)
                    var c = gc
                    c.opacity = 0.12 + 0.88 * fade
                    c.fill(Path(roundedRect: CGRect(x: x - barW / 2, y: mid - h / 2, width: barW, height: h), cornerRadius: barW / 2), with: shading)
                }
            }
        }
    }
}

/// The state of `VoiceWave` between frames: a ring of bar heights and a
/// smoothed level.
private final class WaveState {
    static let bars = 128
    private static let sample: TimeInterval = 0.07
    private static let attack: Float = 28
    private static let release: Float = 7

    private var values = [Float](repeating: 0, count: bars)
    private var head = 0
    private var smooth: Float = 0
    private var last: TimeInterval = 0
    private var pushedAt: TimeInterval = 0

    /// The part of the next bar step that has passed, from 0 to 1, for a smooth scroll.
    private(set) var progress: CGFloat = 0

    func step(_ now: TimeInterval, level target: Float) {
        if last == 0 {
            last = now
            pushedAt = now
        }
        let dt = Float(min(max(now - last, 0), 0.1))
        last = now
        // A fast rise and a slow fall, as a level meter moves.
        let rate = target > smooth ? Self.attack : Self.release
        smooth += (target - smooth) * (1 - exp(-rate * dt))
        var elapsed = now - pushedAt
        while elapsed >= Self.sample {
            head = (head + 1) % Self.bars
            // A small random part makes the bars look like a voice, not a meter.
            values[head] = min(max(smooth * Float.random(in: 0.7...1.2), 0), 1)
            pushedAt += Self.sample
            elapsed -= Self.sample
        }
        progress = CGFloat(min(max(elapsed / Self.sample, 0), 1))
    }

    /// The height of bar `i` from 0 to 1. Bar 0 is the newest.
    func value(_ i: Int) -> Float { values[((head - i) % Self.bars + Self.bars) % Self.bars] }
}

/// The language picker of dictation: Automatic, the languages with a
/// speech model on this Mac, and the languages that Apple transcribes.
/// macOS downloads the speech models itself, so the picker points to the
/// Dictation setting of macOS for a language that is not on this Mac.
struct LanguagePicker: View {
    let selected: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    private var languages: SpeechLanguages { SpeechLanguages.shared }

    private static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    var body: some View {
        let preferred = DictationText.languages(Locale.preferredLanguages)
        let rows = LanguageCatalog.rows(onDevice: languages.onDevice ?? [], supported: languages.supported, preferred: preferred, query: query)
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictation Language").font(.headline)
            // A dictation replaces the search. It uses Automatic, because the chosen language can be the one that fails,
            // and its panel does not open this picker again.
            VoiceBar(language: .constant(""), picker: false, onText: { query = DictationText.query($0) }) {
                TextField("Search", text: $query)
                    .voiceFieldStyle()
            }
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    row(title: "Automatic", subtitle: "Uses the languages of this Mac in order: \(preferred.map(DictationText.languageName).joined(separator: ", "))", tag: "")
                }
                Section("On this Mac") {
                    if languages.onDevice == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking the speech models of this Mac…").foregroundStyle(.secondary)
                        }
                    } else {
                        let local = rows.filter(\.onDevice)
                        if local.isEmpty { Text("No language").foregroundStyle(.secondary) }
                        ForEach(local) { row(title: $0.name, subtitle: $0.native, tag: $0.tag) }
                    }
                }
                if languages.onDevice != nil {
                    Section {
                        ForEach(rows.filter { !$0.onDevice }) { row(title: $0.name, subtitle: $0.native, tag: $0.tag) }
                    } header: {
                        Text("Transcribed by Apple")
                    } footer: {
                        Text("The audio of these languages goes to Apple. To use a language on this Mac, add it under Dictation in System Settings > Keyboard. macOS then downloads its speech model when the Mac supports it.")
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Open Keyboard Settings…") { NSWorkspace.shared.open(Self.keyboardSettings) }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 540)
        .onAppear { languages.load() }
    }

    private func row(title: String, subtitle: String, tag: String) -> some View {
        Button { onSelect(tag) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !subtitle.isEmpty && subtitle != title {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if tag == selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
