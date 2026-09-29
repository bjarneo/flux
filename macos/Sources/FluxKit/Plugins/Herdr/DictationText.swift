import Foundation

/// A text field value after an insert: the text and the cursor. The cursor
/// counts UTF-16 units, as the selection of an AppKit text view does.
public struct DictationEdit: Sendable, Equatable {
    public var text: String
    public var cursor: Int

    public init(_ text: String, _ cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

/// The text rules of dictation, ported from DictationText.kt of the Android
/// app. The functions use no Speech classes, so the unit tests cover them.
public enum DictationText {
    /// Characters that follow a word with no space before them.
    private static let closing = ",.;:!?)]}'\""
    /// Characters at the end of a dictation that a search drops.
    private static let queryEnd: Set<Character> = [",", ".", ";", ":", "!", "?"]

    /// Puts `spoken` in `text` in place of the selection from `start` to
    /// `end`, in UTF-16 units. A space goes between the spoken text and a
    /// word that it would touch. At the start of the text or of a sentence,
    /// the first letter becomes a capital. With `sentences` off, the case
    /// stays, for example for a command. The cursor goes after the spoken
    /// text.
    public static func insert(_ text: String, start: Int, end: Int, spoken: String, sentences: Bool = true) -> DictationEdit {
        let s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let units = Array(text.utf16)
        let a = min(max(min(start, end), 0), units.count)
        let b = min(max(max(start, end), a), units.count)
        if s.isEmpty { return DictationEdit(text, b) }
        let before = String(decoding: units[..<a], as: UTF16.self)
        let after = String(decoding: units[b...], as: UTF16.self)
        let words = sentences && startsSentence(before) ? s.prefix(1).uppercased() + s.dropFirst() : s
        let lead = !before.isEmpty && !(before.last?.isWhitespace ?? true) && !closing.contains(words.first ?? " ") ? " " : ""
        let trail = !after.isEmpty && !(after.first?.isWhitespace ?? true) && !closing.contains(after.first ?? " ") ? " " : ""
        let inserted = lead + words + trail
        return DictationEdit(before + inserted + after, before.utf16.count + inserted.utf16.count)
    }

    /// The words of a dictation as a search. The recognizer ends a sentence
    /// with punctuation, which a search does not need.
    public static func query(_ spoken: String) -> String {
        var s = Substring(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = s.last, queryEnd.contains(last) { s = s.dropLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words of a dictation as a command for a terminal. The recognizer
    /// writes a sentence, so the punctuation at the end goes, and a first
    /// word such as "Git" becomes "git". A word such as "README" stays.
    public static func command(_ spoken: String) -> String {
        let s = query(spoken)
        let first = s.prefix { $0 != " " }
        let capitalized = first.count > 1 && first.first?.isUppercase == true && first.dropFirst().allSatisfy(\.isLowercase)
        return capitalized ? s.prefix(1).lowercased() + s.dropFirst() : s
    }

    /// Joins 2 texts with 1 space.
    public static func join(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return "\(a) \(b)"
    }

    /// The words of `text`, split at white space.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Adds the final text `next` to the final text so far. A recognizer
    /// sends a final text in 1 of 3 forms: only the new words, the whole
    /// text again with the new words, or the same words a second time. Only
    /// the new words go into the result. Case and punctuation do not matter
    /// for the compare, because a later text can add them.
    public static func merge(_ settled: String, _ next: String) -> String {
        let old = words(settled)
        let new = words(next)
        if new.isEmpty { return settled.trimmingCharacters(in: .whitespacesAndNewlines) }
        if old.isEmpty || startsWith(new, old) { return next.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A repeat of 1 word can be real speech, such as "yes".
        if new.count >= 2 && endsWith(old, new) { return settled.trimmingCharacters(in: .whitespacesAndNewlines) }
        return join(settled, next)
    }

    /// The words of the partial text `partial` that are not in the final
    /// text `settled` yet.
    public static func unsettled(_ settled: String, _ partial: String) -> String {
        let old = words(settled)
        let new = words(partial)
        if !old.isEmpty && startsWith(new, old) { return new.dropFirst(old.count).joined(separator: " ") }
        return partial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the partial text `next` starts a new utterance instead of
    /// going on with `previous`. After a pause, the macOS recognizer can
    /// start its text again with only the new words. A revision of the same
    /// words keeps the first word, or keeps the length.
    public static func restarted(previous: String, next: String) -> Bool {
        let old = words(previous)
        let new = words(next)
        guard old.count >= 2, let first = new.first else { return false }
        return new.count < old.count && key(first) != key(old[0])
    }

    /// The input level from 0 to 1 for a level in dBFS. A quiet room is
    /// about -50 dBFS at the built-in microphone, and a loud voice about
    /// -12 dBFS. The square root lifts quiet speech, so the wave shows it.
    public static func level(decibels: Float) -> Float {
        guard !decibels.isNaN else { return 0 }
        let linear = min(max((decibels - silentDb) / (loudDb - silentDb), 0), 1)
        return linear.squareRoot()
    }

    /// The minutes and seconds of `seconds`, such as `0:07` or `12:30`.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.isFinite ? seconds : 0), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The Mac language tags without blanks, repeats, and the undefined
    /// language, with `-` between the parts.
    public static func languages(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-") }
            .filter { !$0.isEmpty && $0 != "und" && seen.insert($0).inserted }
    }

    /// The English name of a language tag, such as `English (United Kingdom)` for `en-GB`.
    public static func languageName(_ tag: String) -> String {
        guard tag != "und", let name = Locale(identifier: "en").localizedString(forIdentifier: tag), !name.isEmpty else { return tag }
        return name
    }

    /// The message when the recognizer supports none of the device languages.
    public static func unsupported(_ tags: [String], platform: FluxPlatform = .current) -> String {
        "The speech recognizer of \(platform.deviceNoun) supports none of its languages: \(tags.map(languageName).joined(separator: ", ")). Choose a language."
    }

    /// The message when the recognizer does not support the language `tag` that the user chose.
    public static func notSupported(_ tag: String, platform: FluxPlatform = .current) -> String {
        "The speech recognizer of \(platform.deviceNoun) does not support \(languageName(tag)). Choose another language."
    }

    public static var speechDenied: String { speechDenied(platform: .current) }
    public static var micDenied: String { micDenied(platform: .current) }
    public static var noMicrophone: String { noMicrophone(platform: .current) }

    static func speechDenied(platform: FluxPlatform) -> String {
        "Allow Flux in \(platform.settingsApp) > Privacy & Security > Speech Recognition to dictate"
    }

    static func micDenied(platform: FluxPlatform) -> String {
        "Allow Flux in \(platform.settingsApp) > Privacy & Security > Microphone to dictate"
    }

    static func noMicrophone(platform: FluxPlatform) -> String {
        "\(platform.deviceNounStart) has no microphone input. Connect a microphone, then try again."
    }

    /// True for a recognizer error that means only that nobody spoke.
    public static func isSilence(domain: String, code: Int) -> Bool {
        domain == "kAFAssistantErrorDomain" && code == 1110
    }

    /// The message for a recognizer error.
    public static func message(domain: String, code: Int, description: String, platform: FluxPlatform = .current) -> String {
        if domain == NSURLErrorDomain {
            return "Apple's speech servers are not reachable. Check the network, or choose a language that \(platform.deviceNoun) transcribes on the device."
        }
        return "Dictation stopped: \(description) (\(domain) \(code)). Try again."
    }

    private static let silentDb: Float = -50
    private static let loudDb: Float = -12

    private static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func startsWith(_ words: [String], _ prefix: [String]) -> Bool {
        words.count >= prefix.count && prefix.indices.allSatisfy { key(words[$0]) == key(prefix[$0]) }
    }

    private static func endsWith(_ words: [String], _ suffix: [String]) -> Bool {
        words.count >= suffix.count && suffix.indices.allSatisfy { key(words[words.count - suffix.count + $0]) == key(suffix[$0]) }
    }

    private static func startsSentence(_ before: String) -> Bool {
        var t = Substring(before)
        while let c = t.last, c == " " || c == "\t" { t.removeLast() }
        guard let last = t.last else { return true }
        return last == "\n" || ".!?".contains(last)
    }
}
