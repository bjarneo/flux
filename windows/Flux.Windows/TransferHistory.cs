using System.IO;
using System.Text.Json;

namespace Flux.Windows;

// Append completed metadata only; no file or clipboard contents are stored.
internal sealed class TransferHistory(string path)
{
    public IEnumerable<FileTransferView> Load()
    {
        if (!File.Exists(path)) yield break;
        foreach (var line in File.ReadLines(path)) {
            FileTransferView? view = null;
            try { if (line.Length <= 32768) view = JsonSerializer.Deserialize<FileTransferView>(line); }
            catch (JsonException) { }
            if (view is not null && !view.IsActive && !string.IsNullOrEmpty(view.Id) &&
                !string.IsNullOrEmpty(view.DeviceId) && view.Name is not null && view.Status is not null) yield return view;
        }
    }
    public void Save(FileTransferView view)
    {
        if (view.IsActive) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
        if (stream.Length > 0) {
            stream.Seek(-1, SeekOrigin.End);
            if (stream.ReadByte() != '\n') stream.WriteByte((byte)'\n');
        }
        stream.Seek(0, SeekOrigin.End);
        using var writer = new StreamWriter(stream);
        writer.WriteLine(JsonSerializer.Serialize(view, new JsonSerializerOptions { IgnoreReadOnlyProperties = true }));
    }
}
