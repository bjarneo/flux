using System.Globalization;

namespace FluxKit;

public enum TransferState
{
    Running,
    Done,
    Failed,
    Canceled,
}

// 1 file that moves between this computer and a computer with fluxd.
public sealed record FileTransfer
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string DeviceId { get; init; }
    public required string Name { get; init; }
    public bool Incoming { get; init; }

    // The size in bytes, or a negative number when it is unknown.
    public long Size { get; init; }
    public long Bytes { get; init; }
    public TransferState State { get; init; } = TransferState.Running;

    // Why the transfer failed, or null.
    public string? Error { get; init; }

    // The file on this computer: the saved file, or the file that goes out.
    public string? File { get; init; }

    // The start time and the end time. Ended is null while the transfer runs.
    public DateTimeOffset Started { get; init; } = DateTimeOffset.Now;
    public DateTimeOffset? Ended { get; init; }

    // The part that is done, from 0 to 1, or null when the size is unknown.
    public double? Fraction => Size > 0 ? Math.Min(1, (double)Bytes / Size) : null;
}

public enum SentKind
{
    Link,
    Text,

    // A text scan of the camera. The computer saves it as a text file in its
    // scan folder.
    Scan,
    Clip,
    ClipImage,
}

// 1 link, text, or clip that this device sent to a computer, for the Send
// thread. The files are in ShareModel.Transfers. ClipStamp is the clipboard
// sequence number of a clip that went out, or 0.
public sealed record SentItem
{
    // The most characters of a text or a link that an item keeps.
    public const int MaxText = 400;

    // Makes an item. A text with more than MaxText characters keeps its start
    // and ends with "…".
    public SentItem(string deviceId, SentKind kind, string text, DateTimeOffset? at = null, long clipStamp = 0)
    {
        DeviceId = deviceId;
        Kind = kind;
        var t = text.Trim();
        var info = new StringInfo(t);
        Text = info.LengthInTextElements > MaxText ? info.SubstringByTextElements(0, MaxText - 1) + "…" : t;
        At = at ?? DateTimeOffset.Now;
        ClipStamp = clipStamp;
    }

    public Guid Id { get; init; } = Guid.NewGuid();
    public string DeviceId { get; }
    public SentKind Kind { get; }
    public string Text { get; }
    public DateTimeOffset At { get; }
    public long ClipStamp { get; }
}

// The share state that the UI shows: the transfers, newest first, the links,
// texts, and clips that went out, oldest first, and the download folder. The
// sent items stay in memory only. Change it only on the UI thread.
public sealed class ShareModel : Model
{
    // The number of transfers that the list keeps.
    internal const int MaxTransfers = 50;

    // The number of sent items that the list keeps.
    public const int MaxSent = 60;

    ValueList<FileTransfer> transfers = ValueList<FileTransfer>.Empty;
    ValueList<SentItem> sent = ValueList<SentItem>.Empty;
    string downloadFolder = "";

    public ValueList<FileTransfer> Transfers
    {
        get => transfers;
        private set => Set(ref transfers, value);
    }

    // The links, texts, and clips that went out, oldest first, at most MaxSent.
    public ValueList<SentItem> Sent
    {
        get => sent;
        private set => Set(ref sent, value);
    }

    public string DownloadFolder
    {
        get => downloadFolder;
        internal set => Set(ref downloadFolder, value);
    }

    internal void Start(FileTransfer t) => Transfers = ValueList.From(transfers.Prepend(t).Take(MaxTransfers));

    // Shows a transfer that runs again, for example the next chunk of a
    // resumable file after a lost link. A transfer that left the list comes
    // back at the top.
    internal void Resume(FileTransfer t)
    {
        if (!transfers.Any(x => x.Id == t.Id))
        {
            Start(t);
            return;
        }
        Update(t.Id, x => x with { State = TransferState.Running, Error = null, Ended = null });
    }

    internal void Progress(Guid id, long bytes) =>
        Update(id, t => t.State == TransferState.Running ? t with { Bytes = Math.Max(t.Bytes, bytes) } : t);

    internal void Finish(Guid id, string? file, TransferState state, string? error = null) => Update(id, t =>
    {
        t = t with { State = state, Error = state == TransferState.Failed ? error : null, Ended = DateTimeOffset.Now };
        if (state == TransferState.Done && t.Size > 0)
        {
            t = t with { Bytes = t.Size };
        }
        if (file is not null)
        {
            t = t with { File = file, Name = Path.GetFileName(file) };
        }
        return t;
    });

    // Adds a link, a text, or a clip that went out.
    internal void Record(SentItem item) => Sent = Appending(sent, item);

    // The list with the item at the end, without the oldest items above max.
    internal static ValueList<SentItem> Appending(IReadOnlyList<SentItem> list, SentItem item, int max = MaxSent) =>
        ValueList.From(list.Append(item).TakeLast(max));

    // Removes the transfers that ended.
    public void ClearFinished() => Transfers = ValueList.From(transfers.Where(t => t.State == TransferState.Running));

    void Update(Guid id, Func<FileTransfer, FileTransfer> change)
    {
        var list = transfers.ToArray();
        var i = Array.FindIndex(list, t => t.Id == id);
        if (i < 0)
        {
            return;
        }
        list[i] = change(list[i]);
        Transfers = ValueList.From(list);
    }
}
