import Foundation

/// Text recognition assembly. Port of Android `scan/TextAssembly.kt`.
///
/// The recognizer (`VNRecognizeTextRequest` on iOS, ML Kit on Android)
/// returns blocks in no fixed order; this puts them in reading order —
/// rows top to bottom, blocks in a row left to right — and joins each
/// block's lines, healing words the line end split with a hyphen.
public struct ScanBox: Sendable, Equatable {
    /// Pixels, origin top-left (Vision observation boxes are converted to
    /// this space in `CapturePipelines` before assembly).
    public var left, top, right, bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var height: Int { bottom - top }
}

/// One line of recognized text.
public struct ScanLine: Sendable, Equatable {
    public var text: String
    public var box: ScanBox

    public init(_ text: String, box: ScanBox) {
        self.text = text
        self.box = box
    }
}

/// One block of recognized text, such as a paragraph or a label.
public struct ScanBlock: Sendable, Equatable {
    public var lines: [ScanLine]
    public var box: ScanBox

    public init(lines: [ScanLine], box: ScanBox) {
        self.lines = lines
        self.box = box
    }
}

public enum TextAssembly {
    /// The part of the smaller height two blocks must share vertically to
    /// be in the same row.
    private static let rowOverlap = 0.5

    /// Returns the text of the blocks. Blocks are separated by an empty line.
    public static func assemble(_ blocks: [ScanBlock]) -> String {
        readingOrder(blocks)
            .map { joinLines($0.lines.sorted { $0.box.top == $1.box.top ? $0.box.left < $1.box.left : $0.box.top < $1.box.top }.map(\.text)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Returns the blocks in reading order.
    public static func readingOrder(_ blocks: [ScanBlock]) -> [ScanBlock] {
        var rows: [[ScanBlock]] = []
        for b in blocks.sorted(by: { $0.box.top < $1.box.top }) {
            if rows.isEmpty || !rows[rows.count - 1].contains(where: { sameRow($0.box, b.box) }) {
                rows.append([b])
            } else {
                rows[rows.count - 1].append(b)
            }
        }
        return rows.flatMap { $0.sorted(by: { $0.box.left < $1.box.left }) }
    }

    /// Joins the lines of one block. Each line keeps its own row, so lists,
    /// addresses, and code stay as they are. A word the line end splits
    /// with a hyphen becomes whole again.
    public static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if out.isEmpty {
                out = line
                continue
            }
            if endsWithSplitWord(out), let first = line.first, first.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += "\n" + line
            }
        }
        return out
    }

    private static func endsWithSplitWord(_ text: String) -> Bool {
        guard text.count >= 2, text.last == "-" else { return false }
        return text.dropLast().last?.isLetter ?? false
    }

    private static func sameRow(_ a: ScanBox, _ b: ScanBox) -> Bool {
        let overlap = min(a.bottom, b.bottom) - max(a.top, b.top)
        let smaller = min(a.height, b.height)
        return smaller > 0 && Double(overlap) >= Double(smaller) * rowOverlap
    }
}
