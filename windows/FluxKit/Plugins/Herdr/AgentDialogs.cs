using System.Security.Cryptography;
using System.Text;

namespace FluxKit;

// The question of a blocked agent. Question is the line that asks, or
// empty. Lines are the lines above the choices, for example the command that
// a choice approves. Choices are the numbered choices or the menu row, and
// the list is empty for a question with free text. Id is the first 16 hex
// digits of the SHA-256 of the question, the lines, and the labels of the
// choices. At is the time of the read. It is a port of AgentDialogs.kt of
// the Android app, with the same test vectors.
public sealed record AgentDialog(string Question, ValueList<string> Lines, ValueList<AgentChoice> Choices, bool Command, string Id, DateTimeOffset At);

public static class AgentDialogs
{
    // How many lines a dialog read asks for. It is the scan range of AgentChoice.Find.
    public const int ReadLines = 40;

    // How long a dialog read waits for the answer. A later answer is not used.
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(3);

    // The lines above the choices that AgentDialog keeps.
    const int DialogLines = 4;

    // The ID of a dialog: the first 16 hex digits of the SHA-256 of its
    // question, lines, and labels.
    public static string Id(string question, IEnumerable<string> lines, IEnumerable<string> labels)
    {
        // The separator is a control character that a terminal line does not hold.
        var text = string.Join('\0', new[] { question }.Concat(lines).Append("\u0001").Concat(labels));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..16];
    }

    // Parses the dialog at the end of output. It returns null for an output
    // with an error or with no lines. An output with no choices gives a
    // dialog with an empty choice list. Then the question is the last line
    // that ends with a question mark, or empty.
    public static AgentDialog? Parse(HerdrOutput output, DateTimeOffset at)
    {
        if (output.Error is not null || output.Lines.Count == 0)
        {
            return null;
        }
        var texts = output.Lines.Select(l => l.Text).ToArray();
        var choices = output.Choices;
        var ask = AgentAsk.Find(texts, DialogLines);
        var question = ask?.Question is { Length: > 0 } q ? q
            : choices.Count == 0 ? texts.TakeLast(12).LastOrDefault(l => l.Trim().EndsWith('?'))?.Trim() ?? "" : "";
        var lines = ask?.Lines ?? ValueList<string>.Empty;
        return new AgentDialog(question, lines, choices, ask?.Command ?? false, Id(question, lines, choices.Select(c => c.Label)), at);
    }

    // True when a Reply may send its text: the new read has no choices and
    // its ID is dialogId, the dialog of the notification.
    public static bool ReplyMatches(AgentDialog? dialog, string dialogId) =>
        dialog is not null && dialogId.Length > 0 && dialog.Choices.Count == 0 && dialog.Id == dialogId;
}
