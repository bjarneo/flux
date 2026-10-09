using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Flux.Protocol;

namespace Flux.Windows;

// Clipboard APIs run only on the WPF dispatcher (STA). No clipboard contents
// are persisted, logged, or published merely because the app starts.
internal sealed class TextClipboard : IDisposable
{
    private readonly Companion companion;
    private readonly ClipboardText text = new();
    private readonly DispatcherTimer timer;
    private readonly string settingsPath;
    private bool sending;
    private CancellationTokenSource syncLifetime = new();
    private readonly object pendingLock = new();
    private (string DeviceId, string ConnectionId, Packet Packet)? pending;
    private bool disposed;
    private uint sequence;
    public bool Enabled { get; private set; }
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();
    public TextClipboard(Companion companion, Dispatcher dispatcher)
    {
        this.companion = companion;
        settingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Flux.Windows", "clipboard-settings.json");
        try { Enabled = File.Exists(settingsPath) && JsonSerializer.Deserialize<bool>(File.ReadAllText(settingsPath)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { Enabled = false; }
        sequence = GetClipboardSequenceNumber();
        text.Observe("", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        // The current clipboard is deliberately not read or sent on startup.
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, Tick, dispatcher);
        companion.ClipboardReceived += Received;
    }
    public void SetEnabled(bool enabled)
    {
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(enabled));
        syncLifetime.Cancel();
        syncLifetime = new CancellationTokenSource();
        Enabled = enabled;
        lock (pendingLock) pending = null;
        sequence = GetClipboardSequenceNumber();
        text.Observe("", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }
    public async Task<int> SendNowAsync()
    {
        if (disposed) throw new ObjectDisposedException(nameof(TextClipboard));
        if (Clipboard.ContainsData("ExcludeClipboardContentFromMonitorProcessing"))
            throw new IOException("This application has excluded its clipboard from sharing.");
        var copiedSequence = GetClipboardSequenceNumber();
        var value = Clipboard.ContainsText(TextDataFormat.UnicodeText) ? Clipboard.GetText(TextDataFormat.UnicodeText) : "";
        if (!ClipboardText.Valid(value)) throw new IOException("Copy some text first (up to 1 MiB). Images are not supported.");
        var count = await companion.SendClipboardAsync(value, CancellationToken.None);
        if (count > 0 && GetClipboardSequenceNumber() == copiedSequence) {
            text.Observe(value, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            sequence = copiedSequence;
        }
        return count;
    }
    private async void Tick(object? sender, EventArgs args)
    {
        if (!Enabled || sending || disposed) return;
        sending = true;
        try {
            // Observe local changes before checking reconnect timestamps.
            var current = GetClipboardSequenceNumber();
            if (current != sequence) {
                var value = !Clipboard.ContainsData("ExcludeClipboardContentFromMonitorProcessing") && Clipboard.ContainsText(TextDataFormat.UnicodeText)
                    ? Clipboard.GetText(TextDataFormat.UnicodeText) : "";
                sequence = current;
                if (text.Local(value, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))
                    await companion.SendClipboardAsync(value, syncLifetime.Token);
            }
            (string DeviceId, string ConnectionId, Packet Packet)? incoming;
            lock (pendingLock) { incoming = pending; pending = null; }
            if (incoming is not { } copy) return;
            try {
                await companion.ApplyClipboardAsync(copy.DeviceId, copy.ConnectionId, () => {
                    if (!Enabled || disposed || !text.TryReceive(copy.Packet, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), out var value)) return;
                    Clipboard.SetText(value, TextDataFormat.UnicodeText);
                    text.Observe(value, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    sequence = GetClipboardSequenceNumber();
                });
            } catch (ExternalException) {
                // Keep one pending copy and retry when another process releases
                // the clipboard. A newer remote copy replaces this one.
                lock (pendingLock) pending ??= copy;
            }
        } catch (Exception ex) when (ex is ExternalException or IOException or OperationCanceledException or ObjectDisposedException) { }
        finally { sending = false; }
    }
    private void Received(string deviceId, string connectionId, Packet packet)
    {
        // A bounded mailbox avoids queueing arbitrarily many texts on the UI.
        lock (pendingLock) {
            if (!disposed && Enabled && ClipboardText.TryParse(packet, out _))
                pending = (deviceId, connectionId, packet);
        }
    }
    public void Dispose()
    {
        lock (pendingLock) { disposed = true; pending = null; }
        syncLifetime.Cancel();
        timer.Stop(); companion.ClipboardReceived -= Received;
    }
}
