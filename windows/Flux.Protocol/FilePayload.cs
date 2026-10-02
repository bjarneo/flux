using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;

namespace Flux.Protocol;

public static class FilePayload
{
    public const long MaxBytes = 8L << 30;
    public static string SafeName(string name)
    {
        name = name.Replace('\\','/').Split('/').Last().Normalize(NormalizationForm.FormC);
        name = string.Concat(name.Select(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c) ? '_' : c)).Trim().TrimEnd('.', ' ');
        if (name.Length == 0 || name is "." or "..") name = "file";
        if (Regex.IsMatch(name.Split('.')[0], "\\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\\z", RegexOptions.IgnoreCase)) name = "_" + name;
        var length = Math.Min(name.Length,180);
        if (length < name.Length && char.IsHighSurrogate(name[length-1])) length--;
        return name[..length];
    }
    public static void Validate(Packet packet)
    {
        if (packet.Type != "flux.share.request" || packet.PayloadSize is not > 0 || packet.PayloadSize > MaxBytes || packet.PayloadTransferInfo is null)
            throw new InvalidDataException("Invalid file payload or unsupported size (1 byte to 8 GiB).");
        var info = packet.PayloadTransferInfo;
        if ((info.Port is not null) == (info.Tunnel is not null)) throw new InvalidDataException("Specify one payload port or tunnel.");
        if (info.Port is not null && info.Port is not (>= 1739 and <= 1764)) throw new InvalidDataException("Payload port is outside the Flux range.");
        if (info.Tunnel is not null && !Regex.IsMatch(info.Tunnel,"\\A[A-Za-z0-9_-]{1,128}\\z")) throw new InvalidDataException("Invalid tunnel token.");
        if (!packet.Body.TryGetProperty("filename", out var name) || name.ValueKind != System.Text.Json.JsonValueKind.String)
            throw new InvalidDataException("File payload has no valid filename.");
        try {
            var filename = name.GetString()!;
            if (filename.Length > 1024) throw new InvalidDataException("File payload filename is too long.");
            SafeName(filename);
        } catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) {
            throw new InvalidDataException("File payload filename contains invalid Unicode.", ex);
        }
    }
    private static TcpListener Listen(IPAddress local)
    {
        for (var port = 1739; port <= 1764; port++) {
            var listener = new TcpListener(local,port);
            try { listener.Start(4); return listener; } catch (SocketException) { listener.Stop(); }
        }
        throw new IOException("No free Flux payload port from 1739 to 1764.");
    }
    public static bool MatchesCertificate(X509Certificate? cert, byte[] expected) => cert is not null && cert.GetRawCertData().AsSpan().SequenceEqual(expected);
    private static SslStream Tls(TcpClient client, X509Certificate2 own, byte[] expected) => new(client.GetStream(),false,
        (_,cert,_,_) => MatchesCertificate(cert,expected),(_,_,_,_,_) => own);
    private static async Task<SslStream> AcceptAsync(TcpListener listener, X509Certificate2 own, byte[] expected, IPAddress remote, CancellationToken ct)
    {
        using var wait = CancellationTokenSource.CreateLinkedTokenSource(ct); wait.CancelAfter(TimeSpan.FromSeconds(20));
        for (var tries = 0; tries < 4;) {
            var client = await listener.AcceptTcpClientAsync(wait.Token);
            if (!((IPEndPoint)client.Client.RemoteEndPoint!).Address.Equals(remote)) { client.Dispose(); continue; }
            tries++;
            var tls = Tls(client,own,expected);
            try {
                using var handshake = CancellationTokenSource.CreateLinkedTokenSource(wait.Token); handshake.CancelAfter(TimeSpan.FromSeconds(10));
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                    ServerCertificate=own,ClientCertificateRequired=true,EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,
                    CertificateRevocationCheckMode=X509RevocationMode.NoCheck
                },handshake.Token);
                if (!tls.IsMutuallyAuthenticated || !MatchesCertificate(tls.RemoteCertificate,expected))
                    throw new AuthenticationException("Payload certificate differs from the paired device.");
                return tls;
            } catch (Exception ex) when (ex is AuthenticationException or IOException or OperationCanceledException) {
                tls.Dispose(); client.Dispose(); wait.Token.ThrowIfCancellationRequested();
            }
        }
        throw new AuthenticationException("No payload connection showed the paired device certificate.");
    }
    private static async Task<SslStream> DialAsync(IPAddress local, IPAddress remote, int port, X509Certificate2 own, byte[] expected, CancellationToken ct)
    {
        if (port is < 1739 or > 1764) throw new InvalidDataException("Payload port is outside the Flux range.");
        var client = new TcpClient(local.AddressFamily); client.Client.Bind(new IPEndPoint(local,0));
        SslStream? tls = null;
        try {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(15));
            await client.ConnectAsync(remote,port,deadline.Token);
            tls = Tls(client,own,expected);
            await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
                TargetHost="flux-payload",ClientCertificates=new X509CertificateCollection {own},
                EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,CertificateRevocationCheckMode=X509RevocationMode.NoCheck
            },deadline.Token);
            return tls;
        } catch { tls?.Dispose(); client.Dispose(); throw; }
    }
    public static async Task SendAsync(string path, X509Certificate2 own, byte[] expected, IPAddress local, IPAddress remote,
        Func<Packet,Task> announce, Func<bool> trusted, Action<long> progress, CancellationToken ct,
        Func<Packet,string,CancellationToken,Task<int>>? openTunnel = null)
    {
        await using var file = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,65536,FileOptions.Asynchronous|FileOptions.SequentialScan);
        if (file.Length is <= 0 or > MaxBytes) throw new IOException("This version sends files from 1 byte to 8 GiB.");
        if (openTunnel is not null) {
            var id = Guid.NewGuid().ToString("N");
            var tunneled = Packet.Create("flux.share.request",new {filename=Path.GetFileName(path),numberOfFiles=1,totalPayloadSize=file.Length})
                with {PayloadSize=file.Length,PayloadTransferInfo=new(Tunnel:id)};
            EnsureTrusted(trusted);
            var port = await openTunnel(tunneled,id,ct);
            using var tunnel = await DialAsync(local,remote,port,own,expected,ct);
            await CopyAsync(file,tunnel,file.Length,trusted,progress,ct);
            await FinishSendingAsync(tunnel,ct);
            return;
        }
        using var listener = Listen(local);
        var packet = Packet.Create("flux.share.request",new {filename=Path.GetFileName(path),lastModified=File.GetLastWriteTimeUtc(path).Subtract(DateTime.UnixEpoch).TotalMilliseconds,
            numberOfFiles=1,totalPayloadSize=file.Length}) with {PayloadSize=file.Length,PayloadTransferInfo=new(( (IPEndPoint)listener.LocalEndpoint).Port)};
        using var stopping = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var accepting = AcceptAsync(listener,own,expected,remote,stopping.Token);
        try {
            EnsureTrusted(trusted); await announce(packet);
            using var tls = await accepting;
            listener.Stop();
            await CopyAsync(file,tls,file.Length,trusted,progress,ct);
            await FinishSendingAsync(tls,ct);
        } finally {
            stopping.Cancel();
            listener.Stop();
            // Observe a pending accept if the control announcement failed.
            try { using var abandoned = await accepting; } catch { }
        }
    }
    public static async Task<string> ReceiveAsync(Packet packet, string root, X509Certificate2 own, byte[] expected, IPAddress local, IPAddress remote,
        Func<Packet,Task> reply, Func<bool> trusted, Action<long> progress, CancellationToken ct)
    {
        Validate(packet); EnsureTrusted(trusted);
        using var stopping = CancellationTokenSource.CreateLinkedTokenSource(ct);
        SslStream tls;
        if (packet.PayloadTransferInfo!.Tunnel is string tunnel) {
            using var listener = Listen(local);
            var accepting = AcceptAsync(listener,own,expected,remote,stopping.Token);
            try {
                await reply(Packet.Create("flux.tunnel",new {id=tunnel,port=((IPEndPoint)listener.LocalEndpoint).Port}));
                tls = await accepting;
            } catch {
                stopping.Cancel(); listener.Stop(); try { using var abandoned = await accepting; } catch { }
                throw;
            }
        } else tls = await DialAsync(local,remote,packet.PayloadTransferInfo.Port!.Value,own,expected,ct);
        using (tls) return await SaveAsync(tls,root,packet.Body.GetProperty("filename").GetString()!,packet.PayloadSize!.Value,trusted,progress,ct);
    }
    public static async Task<string> SaveAsync(Stream source, string root, string name, long size, Func<bool> trusted, Action<long> progress, CancellationToken ct)
    {
        if (size is <= 0 or > MaxBytes) throw new InvalidDataException("Invalid file size.");
        Directory.CreateDirectory(root);
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new IOException("The receive folder must not be a symbolic link.");
        var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(root))!);
        if (drive.AvailableFreeSpace < size + (16L << 20)) throw new IOException("Not enough free space to receive this file.");
        name = SafeName(name);
        var temporary = Path.Combine(root,".flux-"+Guid.NewGuid().ToString("N")+".part");
        try {
            await using (var file = new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,FileOptions.Asynchronous)) {
                await CopyAsync(source,file,size,trusted,progress,ct);
                await file.FlushAsync(ct);
            }
            EnsureTrusted(trusted); ct.ThrowIfCancellationRequested();
            for (var suffix = 0; suffix < 10000; suffix++) {
                var filename = suffix == 0 ? name : Path.GetFileNameWithoutExtension(name)+" ("+suffix+")"+Path.GetExtension(name);
                var destination = Path.Combine(root,filename);
                try { File.Move(temporary,destination,false); return destination; }
                catch (IOException) when (File.Exists(destination) || Directory.Exists(destination)) { }
            }
            throw new IOException("Too many files with the same name.");
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static void EnsureTrusted(Func<bool> trusted) { if (!trusted()) throw new IOException("The device is no longer paired or connected."); }
    public static async Task FinishSendingAsync(SslStream tls, CancellationToken ct)
    {
        // Send close_notify and drain TLS post-handshake records before socket
        // disposal. Closing with unread records can reset an otherwise complete
        // payload. EOF is transport completion, not a remote save receipt.
        await tls.ShutdownAsync().WaitAsync(ct);
        using var closing = CancellationTokenSource.CreateLinkedTokenSource(ct); closing.CancelAfter(TimeSpan.FromSeconds(5));
        try {
            if (await tls.ReadAsync(new byte[1],closing.Token) != 0)
                throw new InvalidDataException("Unexpected data after payload send completion.");
        }
        catch (IOException) { }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { }
    }
    public static async Task CopyAsync(Stream source, Stream destination, long size, Func<bool> trusted, Action<long> progress, CancellationToken ct)
    {
        var buffer = new byte[65536]; long copied=0;
        while (copied < size) {
            EnsureTrusted(trusted);
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct); idle.CancelAfter(TimeSpan.FromSeconds(60));
            var count = await source.ReadAsync(buffer.AsMemory(0,(int)Math.Min(buffer.Length,size-copied)),idle.Token);
            if (count == 0) throw new EndOfStreamException("The file ended before its announced size.");
            await destination.WriteAsync(buffer.AsMemory(0,count),idle.Token); copied+=count; progress(copied);
        }
        using var end = CancellationTokenSource.CreateLinkedTokenSource(ct); end.CancelAfter(TimeSpan.FromSeconds(60));
        if (await source.ReadAsync(buffer.AsMemory(0,1),end.Token) != 0) throw new InvalidDataException("The file exceeds its announced size.");
        EnsureTrusted(trusted);
    }
}
