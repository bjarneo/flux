using System.Globalization;

namespace FluxKit;

// A text field value after an insert: the text and the cursor. The cursor
// counts UTF-16 units, as the selection of a WPF text box does.
public sealed record DictationEdit(string Text, int Cursor);

// The text rules of dictation, ported from DictationText.swift of the Mac
// app and DictationText.kt of the Android app. The functions use no speech
// API, so the unit tests cover them. The WPF app runs the speech recognizer
// of Windows and uses these rules for its text.
public static class DictationText
{
    // Characters that follow a word with no space before them.
    const string Closing = ",.;:!?)]}'\"";

    // Characters at the end of a dictation that a search drops.
    const string QueryEnd = ",.;:!?";

    const float SilentDb = -50;
    const float LoudDb = -12;

    // Puts spoken in text in place of the selection from start to end, in
    // UTF-16 units. A space goes between the spoken text and a word that it
    // would touch. At the start of the text or of a sentence, the first
    // letter becomes a capital. With sentences off, the case stays, for
    // example for a command. The cursor goes after the spoken text.
    public static DictationEdit Insert(string text, int start, int end, string spoken, bool sentences = true)
    {
        var s = spoken.Trim();
        var a = Math.Min(Math.Max(Math.Min(start, end), 0), text.Length);
        var b = Math.Min(Math.Max(Math.Max(start, end), a), text.Length);
        if (s.Length == 0)
        {
            return new DictationEdit(text, b);
        }
        var before = text[..a];
        var after = text[b..];
        var words = sentences && StartsSentence(before) ? Capitalize(s) : s;
        var lead = before.Length > 0 && !char.IsWhiteSpace(before[^1]) && !Closing.Contains(words[0]) ? " " : "";
        var trail = after.Length > 0 && !char.IsWhiteSpace(after[0]) && !Closing.Contains(after[0]) ? " " : "";
        var inserted = lead + words + trail;
        return new DictationEdit(before + inserted + after, before.Length + inserted.Length);
    }

    // The text with its first character in upper case.
    static string Capitalize(string s)
    {
        var first = StringInfo.GetNextTextElementLength(s, 0);
        return s[..first].ToUpperInvariant() + s[first..];
    }

    // The words of a dictation as a search. The recognizer ends a sentence
    // with punctuation, which a search does not need.
    public static string Query(string spoken) => spoken.Trim().TrimEnd(QueryEnd.ToCharArray()).Trim();

    // The words of a dictation as a command for a terminal. The recognizer
    // writes a sentence, so the punctuation at the end goes, and a first
    // word such as "Git" becomes "git". A word such as "README" stays.
    public static string Command(string spoken)
    {
        var s = Query(spoken);
        var space = s.IndexOf(' ');
        var first = space < 0 ? s : s[..space];
        var capitalized = first.Length > 1 && char.IsUpper(first[0]) && first.Skip(1).All(char.IsLower);
        return capitalized ? s[..1].ToLowerInvariant() + s[1..] : s;
    }

    // Joins 2 texts with 1 space.
    public static string Join(string first, string second)
    {
        var a = first.Trim();
        var b = second.Trim();
        if (a.Length == 0)
        {
            return b;
        }
        if (b.Length == 0)
        {
            return a;
        }
        return $"{a} {b}";
    }

    // The words of text, split at white space.
    public static IReadOnlyList<string> Words(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    // Adds the final text next to the final text so far. A recognizer sends
    // a final text in 1 of 3 forms: only the new words, the whole text again
    // with the new words, or the same words a second time. Only the new
    // words go into the result. Case and punctuation do not matter for the
    // compare, because a later text can add them.
    public static string Merge(string settled, string next)
    {
        var old = Words(settled);
        var words = Words(next);
        if (words.Count == 0)
        {
            return settled.Trim();
        }
        if (old.Count == 0 || StartsWith(words, old))
        {
            return next.Trim();
        }
        // A repeat of 1 word can be real speech, such as "yes".
        if (words.Count >= 2 && EndsWith(old, words))
        {
            return settled.Trim();
        }
        return Join(settled, next);
    }

    // The words of the partial text partial that are not in the final text
    // settled yet.
    public static string Unsettled(string settled, string partial)
    {
        var old = Words(settled);
        var words = Words(partial);
        if (old.Count > 0 && StartsWith(words, old))
        {
            return string.Join(" ", words.Skip(old.Count));
        }
        return partial.Trim();
    }

    // True when the partial text next starts a new utterance instead of
    // going on with previous. After a pause, a recognizer can start its text
    // again with only the new words. A revision of the same words keeps the
    // first word, or keeps the length.
    public static bool Restarted(string previous, string next)
    {
        var old = Words(previous);
        var words = Words(next);
        if (old.Count < 2 || words.Count == 0)
        {
            return false;
        }
        return words.Count < old.Count && Key(words[0]) != Key(old[0]);
    }

    // The input level from 0 to 1 for a level in dBFS. A quiet room is
    // about -50 dBFS at a built-in microphone, and a loud voice about -12
    // dBFS. The square root lifts quiet speech, so the wave shows it.
    public static float Level(float decibels)
    {
        if (float.IsNaN(decibels))
        {
            return 0;
        }
        var linear = Math.Clamp((decibels - SilentDb) / (LoudDb - SilentDb), 0, 1);
        return MathF.Sqrt(linear);
    }

    // The minutes and seconds of seconds, such as 0:07 or 12:30.
    public static string Clock(double seconds)
    {
        var s = Math.Max((int)(double.IsFinite(seconds) ? seconds : 0), 0);
        return $"{s / 60}:{s % 60:00}";
    }

    // The language tags without blanks, repeats, and the undefined
    // language, with - between the parts.
    public static IReadOnlyList<string> Languages(IEnumerable<string> tags)
    {
        var seen = new HashSet<string>();
        return tags.Select(t => t.Trim().Replace('_', '-'))
            .Where(t => t.Length > 0 && t != "und" && seen.Add(t))
            .ToArray();
    }

    // The English name of a language tag, such as "English (United Kingdom)" for en-GB.
    public static string LanguageName(string tag)
    {
        if (tag == "und")
        {
            return tag;
        }
        try
        {
            var name = CultureInfo.GetCultureInfo(tag).EnglishName;
            return name.Length == 0 ? tag : name;
        }
        catch (CultureNotFoundException)
        {
            return tag;
        }
    }

    // The message when the recognizer supports none of the languages of this computer.
    public static string Unsupported(IEnumerable<string> tags) =>
        $"The speech recognizer of this computer supports none of its languages: {string.Join(", ", tags.Select(LanguageName))}. Choose a language.";

    // The message when the recognizer does not support the language tag that the user chose.
    public static string NotSupported(string tag) =>
        $"The speech recognizer of this computer does not support {LanguageName(tag)}. Choose another language.";

    // The message when this computer has no microphone.
    public static string NoMicrophone => "This computer has no microphone input. Connect a microphone, then try again.";

    static string Key(string word) => new(word.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    static bool StartsWith(IReadOnlyList<string> words, IReadOnlyList<string> prefix) =>
        words.Count >= prefix.Count && prefix.Select((p, i) => Key(words[i]) == Key(p)).All(x => x);

    static bool EndsWith(IReadOnlyList<string> words, IReadOnlyList<string> suffix) =>
        words.Count >= suffix.Count && suffix.Select((s, i) => Key(words[words.Count - suffix.Count + i]) == Key(s)).All(x => x);

    static bool StartsSentence(string before)
    {
        var t = before.TrimEnd(' ', '\t');
        if (t.Length == 0)
        {
            return true;
        }
        return t[^1] is '\n' or '.' or '!' or '?';
    }
}
