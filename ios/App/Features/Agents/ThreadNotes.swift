import FluxKit
import SwiftUI

/// A note in the place of the dock of an agent thread. It shows the link
/// state, see `LinkNote`, the note that Agent control is off, or the note
/// that the question changed. `retry` adds the Retry button. `busy` shows
/// a spinner while the computer connects.
struct ThreadNoteCard: View {
    let title: String
    var detail = ""
    var retry: (() -> Void)?
    var busy = false
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            }
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DockShape().fill(tn.tile).ignoresSafeArea(edges: .bottom))
        .accessibilityElement(children: .contain)
    }
}

extension ThreadNoteCard {
    /// The note for the link state of a thread.
    init(link note: ThreadNote, retry: @escaping () -> Void) {
        self.init(title: note.title, detail: note.detail, retry: note.state == .unreachable ? retry : nil, busy: note.state == .connecting)
    }

    /// The note while Agent control is off on the computer `name`. It names the Access card.
    static func controlOff(_ name: String) -> ThreadNoteCard {
        ThreadNoteCard(title: "Agent control is off on \(name)",
                       detail: "To answer from this iPhone, turn on Agent control in Flux on the computer, on the Access card.")
    }

    /// The note after an answer from a notification found a new question.
    static var questionChanged: ThreadNoteCard { ThreadNoteCard(title: "The question changed. Pick again.") }
}
