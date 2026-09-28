import Foundation

/// A language in the language picker of dictation. `onDevice` is true when
/// this Mac has the speech model of the language, so the audio stays on the
/// Mac.
public struct LanguageRow: Sendable, Hashable, Identifiable {
    public var tag: String
    public var name: String
    public var native: String
    public var onDevice: Bool

    public var id: String { tag }
}

/// The language list of the picker and the choice of Automatic, ported from
/// LanguageCatalog.kt of the Android app. macOS downloads the speech models
/// itself, so the Mac has no download list. The functions use no Speech
/// classes, so the unit tests cover them.
public enum LanguageCatalog {
    /// The rows of the picker: the languages with a model on this Mac, then
    /// the other languages of the recognizer. The languages on this Mac go
    /// in the order of the Mac languages, then by name. The other languages
    /// go by name. `query` keeps the languages whose name, own name, or tag
    /// contains it.
    public static func rows(onDevice: [String], supported: [String], preferred: [String], query: String) -> [LanguageRow] {
        let local = unique(onDevice)
        let rest = unique(supported).filter { !local.contains($0) }
        let byName = { (tags: [String]) in tags.map { ($0, DictationText.languageName($0)) }.sorted { $0.1 < $1.1 }.map(\.0) }
        let ranked = byName(local).enumerated()
            .sorted { (rank($0.element, preferred), $0.offset) < (rank($1.element, preferred), $1.offset) }
            .map(\.element)
        let rows = ranked.map { row($0, onDevice: true) } + byName(rest).map { row($0, onDevice: false) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { r in [r.name, r.native, r.tag].contains { $0.range(of: q, options: .caseInsensitive) != nil } }
    }

    /// The language that Automatic uses: the first Mac language that has a
    /// match in `available`. See `match` for the rules.
    public static func automatic(preferred: [String], available: [String], fallback: String? = nil) -> String? {
        for tag in preferred {
            if let m = match(tag, in: available, fallback: fallback) { return m }
        }
        return nil
    }

    /// The language in `available` for the Mac language `tag`. The Mac
    /// language often has the region of the Mac, such as en-NO, and the
    /// recognizer has no model for it. So a language with the same code
    /// counts too: first `fallback`, the language of the default
    /// recognizer, then the most likely region of the language, such as US
    /// for English, then the first by tag.
    public static func match(_ tag: String, in available: [String], fallback: String? = nil) -> String? {
        let norm = { (s: String) in s.replacingOccurrences(of: "_", with: "-").lowercased() }
        if let exact = available.first(where: { norm($0) == norm(tag) }) { return exact }
        let code = languageCode(tag)
        let same = available.filter { languageCode($0) == code }
        guard !same.isEmpty else { return nil }
        if let fallback, let f = same.first(where: { norm($0) == norm(fallback) }) { return f }
        if let region = likelyRegion(tag), let r = same.first(where: { Locale.Language(identifier: $0).region?.identifier == region }) { return r }
        return same.sorted().first
    }

    /// The name of a language in that language, such as `Deutsch (Deutschland)` for `de-DE`.
    public static func nativeName(_ tag: String) -> String {
        let locale = Locale(identifier: tag)
        guard let name = locale.localizedString(forIdentifier: tag), !name.isEmpty else { return tag }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    private static func row(_ tag: String, onDevice: Bool) -> LanguageRow {
        LanguageRow(tag: tag, name: DictationText.languageName(tag), native: nativeName(tag), onDevice: onDevice)
    }

    /// The place of the first Mac language that `tag` matches: the same tag,
    /// or else the same language code.
    private static func rank(_ tag: String, _ preferred: [String]) -> Int {
        if let i = preferred.firstIndex(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return i }
        return preferred.firstIndex { languageCode($0) == languageCode(tag) }.map { $0 + preferred.count } ?? Int.max
    }

    private static func languageCode(_ tag: String) -> String {
        Locale.Language(identifier: tag).languageCode?.identifier ?? tag.lowercased()
    }

    /// The most likely region of the language and script of `tag`, such as
    /// US for en-NO and CN for zh-Hans.
    private static func likelyRegion(_ tag: String) -> String? {
        let language = Locale.Language(identifier: tag)
        let base = [language.languageCode?.identifier, language.script?.identifier].compactMap { $0 }.joined(separator: "-")
        guard !base.isEmpty else { return nil }
        return Locale.Language(identifier: Locale.Language(identifier: base).maximalIdentifier).region?.identifier
    }

    private static func unique(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }
}
