import FluxKit
import SwiftUI

/// The dictation of 1 text field of the app. It asks for the permissions,
/// checks that the microphone is free, and starts the dictation in the
/// languages of the iPhone. `error` tells why a dictation did not start.
@MainActor
@Observable
final class VoiceTyping {
    let dictation = Dictation()
    private(set) var error: String?
    /// True when the iPhone has a speech recognizer. It is read once, off the main thread.
    private(set) var available = false
    @ObservationIgnored private var starting: Task<Void, Never>?

    var active: Bool { dictation.phase != .idle }

    /// Reads whether the iPhone can dictate.
    func load() async {
        available = await Task.detached { Dictation.available }.value
    }

    /// Starts a dictation, or stops the one that runs. The words go to `onText` when it ends.
    func toggle(_ core: FluxCore, hints: [String] = [], onText: @escaping @MainActor (String) -> Void) {
        if active {
            dictation.stop()
            return
        }
        error = nil
        if let problem = MicFeature.dictationProblem(core) {
            error = problem
            return
        }
        starting?.cancel()
        starting = Task { @MainActor in
            let problem = await Dictation.authorize()
            // The field closed while iOS asked for the permissions.
            guard !Task.isCancelled else { return }
            if let problem {
                error = problem
                return
            }
            // The dictation uses the languages of the iPhone.
            dictation.start(language: "", hints: hints, onDone: onText)
        }
    }

    /// Ends the dictation without words, because its field is gone.
    func cancel() {
        starting?.cancel()
        dictation.cancel()
    }
}

/// The mic key of a text field. A tap starts a dictation, and the next tap
/// stops it. While the iPhone listens, the key is red.
struct VoiceKey: View {
    @Environment(AppModel.self) private var model
    let voice: VoiceTyping
    var hints: [String] = []
    var height: CGFloat = 44
    let onText: @MainActor (String) -> Void

    var body: some View {
        let active = voice.active
        Button {
            voice.toggle(model.core, hints: hints, onText: onText)
        } label: {
            Image(systemName: active ? "stop.fill" : "mic")
                .foregroundStyle(active ? .red : .secondary)
                .frame(width: 44, height: height)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "Stop the dictation" : "Dictate")
    }
}

/// The words while the iPhone listens, and why a dictation failed.
struct VoiceStatus: View {
    let voice: VoiceTyping

    var body: some View {
        let dictation = voice.dictation
        if voice.active {
            Text(dictation.pending.isEmpty && dictation.settled.isEmpty ? "Listening…" : DictationText.join(dictation.settled, dictation.pending))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if let problem = voice.error ?? dictation.error {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A text field with a mic key, like VoiceField of the Android app and
/// VoiceBar of the Mac app. The words of a dictation go to `onText`: a
/// search takes them in place of the search, and other fields at the end of
/// their text. Under the field, `VoiceStatus` shows the words and the
/// errors. While `enabled` is off, the mic key hides, unless a dictation
/// runs, so that the user can still stop it.
struct VoiceField<Field: View>: View {
    var hints: [String] = []
    var enabled = true
    var keyHeight: CGFloat = 44
    let onText: @MainActor (String) -> Void
    @ViewBuilder let field: () -> Field
    @State private var voice = VoiceTyping()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                field()
                if voice.available && (enabled || voice.active) {
                    VoiceKey(voice: voice, hints: hints, height: keyHeight, onText: onText)
                }
            }
            VoiceStatus(voice: voice)
        }
        .task { await voice.load() }
        // The field is gone, so its words have no place.
        .onDisappear { voice.cancel() }
    }
}

extension DictationText {
    /// Puts the words of a dictation at the end of `text`. A SwiftUI text
    /// field does not tell the cursor, so the words go at the end.
    static func append(_ text: String, _ spoken: String, sentences: Bool = true) -> String {
        let end = text.utf16.count
        return insert(text, start: end, end: end, spoken: spoken, sentences: sentences).text
    }
}
