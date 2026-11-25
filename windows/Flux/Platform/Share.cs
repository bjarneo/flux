using FluxKit;

namespace Flux;

// What the share feature asks of Windows: the clipboard for shared text,
// File Explorer and the default apps for received files and links, and the
// Mark of the Web on received files.
public sealed class WindowsShare(ClipboardPlugin? clipboard) : ISharePlatform
{
    // The clipboard feature puts the text there, so that the sync does not
    // send it back to the computer.
    public void PutText(string text, string deviceId)
    {
        if (clipboard is not null)
        {
            clipboard.PutFromComputer(text, deviceId);
            return;
        }
        try
        {
            System.Windows.Clipboard.SetText(text);
        }
        catch (System.Runtime.InteropServices.ExternalException e)
        {
            FluxLog.Error("app", $"cannot put shared text on the clipboard: {e.Message}");
        }
    }

    public void OpenFile(string path) => ThisComputer.Open(path);

    public void ShowInFolder(string path) => ThisComputer.ShowInFolder(path);

    public void OpenLink(Uri url)
    {
        if (url.Scheme is "http" or "https")
        {
            ThisComputer.Open(url.AbsoluteUri);
        }
    }

    // SmartScreen and Office check a file with this mark before it opens.
    public void MarkDownloaded(string path)
    {
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            // A file system without streams, such as FAT32, takes no mark.
            FluxLog.Info("app", $"cannot mark a received file: {e.Message}");
        }
    }
}

// The notification limit of the notifications feature, for the links of the
// share feature, so that 1 computer cannot flood the screen through both.
public sealed class SharedNotificationLimit(Notifier notifier) : IShareNotificationLimit
{
    public bool AllowsNow(string deviceId) => NotificationLimit.AllowsNow(deviceId);

    public void Delivered(string id, string deviceId) => DeliveredNotifications.Post(notifier, id, deviceId);
}
