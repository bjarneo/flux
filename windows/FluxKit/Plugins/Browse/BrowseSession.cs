using System.Net.Sockets;
using System.Security.Authentication;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace FluxKit;

// A failure of Get files with a message for the user.
internal sealed class BrowseError(string message) : Exception(message);

// One SSH session with the SFTP subsystem. A browse window keeps 1 session
// for its lifetime. A tunnel carries 1 session, so the next window asks the
// computer for a new one. BrowseSession.swift of the Mac app has the same
// rules.
internal sealed class BrowseSession
{
    readonly SftpClient sftp;
    readonly LoopbackBridge bridge;

    BrowseSession(SftpClient sftp, LoopbackBridge bridge)
    {
        this.sftp = sftp;
        this.bridge = bridge;
    }

    // Connects with the offer. The computer connects to this device through
    // the tunnel of the offer, and a loopback bridge feeds the TLS stream to
    // the SSH client. onClose runs when the connection ends for any reason.
    public static async Task<BrowseSession> OpenAsync(SftpOffer offer, FluxTls tls, byte[]? certificate, Action<Packet> announce,
                                                     Action onClose, CancellationToken ct = default)
    {
        if (certificate is null)
        {
            throw new BrowseError("the link is not ready");
        }
        var stream = await Tunnel.AcceptAsync(tls, certificate, offer.Tunnel, announce, ct: ct).ConfigureAwait(false);
        var bridge = LoopbackBridge.Open(stream);
        try
        {
            var info = new ConnectionInfo(bridge.Host, bridge.Port, offer.User, new PasswordAuthenticationMethod(offer.User, offer.Password))
            {
                Timeout = TimeSpan.FromSeconds(8),
            };
            var sftp = new SftpClient(info);
            // The computer makes a new host key for each session. The
            // password comes over the paired TLS link, so the key is not
            // pinned.
            sftp.HostKeyReceived += (_, e) => e.CanTrust = true;
            try
            {
                await sftp.ConnectAsync(ct).ConfigureAwait(false);
            }
            catch (Exception e) when (IsFailure(e))
            {
                sftp.Dispose();
                throw;
            }
            _ = bridge.Completion.ContinueWith(_ => onClose(), TaskScheduler.Default);
            return new BrowseSession(sftp, bridge);
        }
        catch (Exception e) when (IsFailure(e))
        {
            bridge.Close();
            throw;
        }
    }

    // The entries of a folder, as the browser shows them.
    public async Task<IReadOnlyList<BrowseEntry>> ListAsync(string path, CancellationToken ct = default)
    {
        var entries = new List<BrowseEntry>();
        await foreach (var f in sftp.ListDirectoryAsync(path, ct).ConfigureAwait(false))
        {
            if (f.Name is "." or "..")
            {
                continue;
            }
            entries.Add(BrowseEntry.FromAttributes(path, f.Name, f.IsDirectory, f.Length,
                new DateTimeOffset(DateTime.SpecifyKind(f.LastWriteTimeUtc, DateTimeKind.Utc))));
        }
        return BrowseEntry.Listing(entries);
    }

    // Copies a remote file into the stream and reports the bytes written so
    // far, at most 10 times each second and once at the end. SSH.NET keeps
    // several reads in flight, so the round trip time does not limit the
    // speed.
    public async Task DownloadAsync(string path, Stream output, Action<long> progress, CancellationToken ct)
    {
        var counted = new CountingStream(output, progress);
        await sftp.DownloadFileAsync(path, counted, ct).ConfigureAwait(false);
        counted.Report();
    }

    // Ends the SFTP channel, the SSH connection, and the tunnel.
    public async Task CloseAsync()
    {
        await Task.Run(() =>
        {
            try
            {
                sftp.Disconnect();
            }
            catch (Exception e) when (IsFailure(e))
            {
            }
            sftp.Dispose();
        }).ConfigureAwait(false);
        bridge.Close();
    }

    // True for the exceptions of a session that fails or ends.
    internal static bool IsFailure(Exception e) =>
        e is SshException or BrowseError or IOException or SocketException or TimeoutException or ObjectDisposedException or
            InvalidOperationException or OperationCanceledException or UnauthorizedAccessException or AuthenticationException;

    // A short reason for the user.
    internal static string Describe(Exception e) => e switch
    {
        OperationCanceledException => "Canceled",
        SshAuthenticationException => "the computer refused the password",
        _ when e.Message.Length > 0 => e.Message,
        _ => e.GetType().Name,
    };

    // Counts the bytes that the download writes and reports them through a
    // throttle.
    sealed class CountingStream(Stream inner, Action<long> progress) : Stream
    {
        ProgressThrottle throttle;
        long written;

        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => written;

        public override long Position
        {
            get => written;
            set => throw new NotSupportedException();
        }

        public void Report() => progress(written);

        public override void Write(byte[] buffer, int offset, int count)
        {
            inner.Write(buffer, offset, count);
            Wrote(count);
        }

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            inner.Write(buffer);
            Wrote(buffer.Length);
        }

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await inner.WriteAsync(buffer, cancellationToken).ConfigureAwait(false);
            Wrote(buffer.Length);
        }

        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => inner.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        void Wrote(int count)
        {
            written += count;
            if (throttle.Due())
            {
                progress(written);
            }
        }
    }
}
