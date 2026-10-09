using System.Text;
using System.Text.Json;

namespace Flux.Protocol;

public sealed class ClipboardText
{
    public const int MaxBytes = 1 << 20;
    private string last = "";
    private long changedAt;
    public static bool Valid(string text) => text.Length > 0 && !text.Contains('\0') && text.Length <= MaxBytes && Encoding.UTF8.GetByteCount(text) <= MaxBytes;
    public void Observe(string text, long now) { last = text; changedAt = now; }
    public bool Local(string text, long now)
    {
        if (text == last) return false;
        Observe(text, now);
        return Valid(text);
    }
    public static bool TryParse(Packet packet, out string text)
    {
        text = "";
        if (packet.Body.ValueKind != JsonValueKind.Object || packet.Type is not ("flux.clipboard" or "flux.clipboard.connect") ||
            !packet.Body.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String) return false;
        var value = content.GetString()!;
        if (!Valid(value)) return false;
        text = value;
        return true;
    }
    public bool TryReceive(Packet packet, long now, out string text)
    {
        if (!TryParse(packet, out text) || text == last) return false;
        if (packet.Type == "flux.clipboard.connect") {
            if (!packet.Body.TryGetProperty("timestamp", out var stamp) || stamp.ValueKind != JsonValueKind.Number || !stamp.TryGetInt64(out var time) ||
                time <= 0 || Math.Min(time, now) <= changedAt) return false;
        }
        return true;
    }
}
