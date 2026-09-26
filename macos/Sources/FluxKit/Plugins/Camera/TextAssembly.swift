import Foundation

/// A rectangle in pixels. The origin is the top left corner.
public struct ScanBox: Equatable, Sendable {
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int

    public init(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var width: Int { right - left }
    public var height: Int { bottom - top }

    func union(_ o: ScanBox) -> ScanBox {
        ScanBox(min(left, o.left), min(top, o.top), max(right, o.right), max(bottom, o.bottom))
    }
}

/// One line of recognized text.
public struct ScanLine: Equatable, Sendable {
    public var text: String
    public var box: ScanBox

    public init(_ text: String, _ box: ScanBox) {
        self.text = text
        self.box = box
    }
}

/// One block of recognized text, such as a paragraph or a label.
public struct ScanBlock: Equatable, Sendable {
    public var lines: [ScanLine]
    public var box: ScanBox

    public init(_ lines: [ScanLine], _ box: ScanBox) {
        self.lines = lines
        self.box = box
    }
}

/// Turns recognized blocks into plain text. The recognizer returns blocks in
/// no fixed order, so this puts them in reading order: rows from top to
/// bottom, and blocks in a row from left to right.
public enum TextAssembly {
    /// The part of the smaller height that 2 blocks must share vertically to
    /// be in the same row.
    private static let rowOverlap = 0.5

    /// Returns the text of the blocks. Blocks are separated by an empty line.
    public static func assemble(_ blocks: [ScanBlock]) -> String {
        readingOrder(blocks)
            .map { block in joinLines(block.lines.sorted { ($0.box.top, $0.box.left) < ($1.box.top, $1.box.left) }.map(\.text)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Returns the blocks in reading order.
    public static func readingOrder(_ blocks: [ScanBlock]) -> [ScanBlock] {
        var rows: [[ScanBlock]] = []
        for b in stableSorted(blocks, by: \.box.top) {
            if let row = rows.last, row.contains(where: { sameRow($0.box, b.box) }) {
                rows[rows.count - 1].append(b)
            } else {
                rows.append([b])
            }
        }
        return rows.flatMap { stableSorted($0, by: \.box.left) }
    }

    /// Joins the lines of 1 block. Each line keeps its own row, so lists,
    /// addresses, and code stay as they are. A word that the line end splits
    /// with a hyphen becomes whole again.
    public static func joinLines(_ lines: [String]) -> String {
        var out = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = line.first else { continue }
            if out.isEmpty {
                out = line
            } else if endsWithSplitWord(out) && first.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += "\n" + line
            }
        }
        return out
    }

    private static func endsWithSplitWord(_ text: String) -> Bool {
        let tail = text.suffix(2)
        return tail.count == 2 && tail.last == "-" && tail.first!.isLetter
    }

    private static func sameRow(_ a: ScanBox, _ b: ScanBox) -> Bool {
        let overlap = min(a.bottom, b.bottom) - max(a.top, b.top)
        let smaller = min(a.height, b.height)
        return smaller > 0 && Double(overlap) >= Double(smaller) * rowOverlap
    }

    /// Sorts like Kotlin's sortedBy: elements with equal keys keep their order.
    private static func stableSorted<T>(_ items: [T], by key: (T) -> Int) -> [T] {
        items.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    // MARK: Lines to blocks

    /// Groups recognized lines into blocks. ML Kit on Android returns blocks,
    /// but Vision returns lines. Lines join a block when they are stacked
    /// closely with similar heights and overlap horizontally, like the lines
    /// of a paragraph. Pieces of 1 line that sit next to each other join into
    /// 1 line first.
    public static func blocks(from lines: [ScanLine]) -> [ScanBlock] {
        var blocks: [ScanBlock] = []
        for line in mergePieces(lines) {
            let candidates = blocks.indices.filter { continues(blocks[$0], with: line) }
            // The nearest block above wins.
            if let i = candidates.min(by: { line.box.top - blocks[$0].box.bottom < line.box.top - blocks[$1].box.bottom }) {
                blocks[i].lines.append(line)
                blocks[i].box = blocks[i].box.union(line.box)
            } else {
                blocks.append(ScanBlock([line], line.box))
            }
        }
        return blocks
    }

    /// True when the line is the next line of the paragraph that the block holds.
    private static func continues(_ block: ScanBlock, with line: ScanLine) -> Bool {
        guard let last = block.lines.last else { return false }
        let a = last.box, b = line.box
        let height = max(a.height, b.height)
        guard height > 0, min(a.height, b.height) * 5 >= height * 3 else { return false }
        let gap = b.top - a.bottom
        guard gap >= -height / 2, gap * 5 <= height * 4 else { return false }
        let overlap = min(a.right, b.right) - max(a.left, b.left)
        return overlap > 0 || abs(a.left - b.left) <= height
    }

    /// Joins pieces of 1 line: they share most of their height and the gap
    /// between them is at most the line height.
    private static func mergePieces(_ lines: [ScanLine]) -> [ScanLine] {
        var out: [ScanLine] = []
        for line in lines.sorted(by: { ($0.box.left, $0.box.top) < ($1.box.left, $1.box.top) }) {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if let i = out.lastIndex(where: { piece in
                let gap = line.box.left - piece.box.right
                return sameRow(piece.box, line.box) && gap >= -piece.box.height && gap <= max(piece.box.height, line.box.height)
            }) {
                out[i].text += " " + text
                out[i].box = out[i].box.union(line.box)
            } else {
                out.append(ScanLine(text, line.box))
            }
        }
        return out.sorted { ($0.box.top, $0.box.left) < ($1.box.top, $1.box.left) }
    }
}
