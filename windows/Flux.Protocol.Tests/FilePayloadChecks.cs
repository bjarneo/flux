using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using Flux.Protocol;

internal static class FilePayloadChecks
{
    private static void Check(bool value,string error) { if (!value) throw new Exception(error); }
    private static async Task Fails(Func<Task> action)
    {
        try { await action(); } catch (Exception e) when (e is InvalidDataException or EndOfStreamException or IOException or OperationCanceledException) { return; }
        throw new Exception("Expected file transfer failure.");
    }
    private static async Task WriteClient(int port, X509Certificate2 own, byte[] peer, byte[] content, CancellationToken ct)
    {
        using var tcp = new TcpClient(); await tcp.ConnectAsync(IPAddress.Loopback,port,ct);
        using var tls = new SslStream(tcp.GetStream(),false,(_,cert,_,_) => FilePayload.MatchesCertificate(cert,peer),(_,_,_,_,_)=>own);
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {TargetHost="payload-test",ClientCertificates=new X509CertificateCollection {own},
            EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,CertificateRevocationCheckMode=X509RevocationMode.NoCheck},ct);
        await tls.WriteAsync(content,ct);
        await FilePayload.FinishSendingAsync(tls,ct);
    }
    private static TcpListener Listener()
    {
        for (var port=12070;port<=12099;port++) {
            var l=new TcpListener(IPAddress.Loopback,port);
            try { l.Start(); return l; } catch (SocketException) { l.Stop(); }
        }
        throw new IOException("No test payload port.");
    }
    private static async Task<byte[]> ReadServer(TcpListener listener,X509Certificate2 own,byte[] peer,CancellationToken ct)
    {
        using var tcp=await listener.AcceptTcpClientAsync(ct);
        using var tls=new SslStream(tcp.GetStream(),false,(_,cert,_,_)=>FilePayload.MatchesCertificate(cert,peer));
        await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {ServerCertificate=own,ClientCertificateRequired=true,
            EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,CertificateRevocationCheckMode=X509RevocationMode.NoCheck},ct);
        using var received=new MemoryStream(); await tls.CopyToAsync(received,ct); return received.ToArray();
    }
    public static async Task RunAsync(X509Certificate2 own,X509Certificate2 peer,X509Certificate2 wrong)
    {
        var root=Path.Combine(Path.GetTempPath(),"flux-file-checks-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try {
            var content=new byte[200001]; new Random(42).NextBytes(content);
            var input=Path.Combine(root,"input.bin"); await File.WriteAllBytesAsync(input,content,deadline.Token);
            var inbox=Path.Combine(root,"inbox");
            Task<string>? receiving=null;
            await FilePayload.SendAsync(input,own,peer.RawData,IPAddress.Loopback,IPAddress.Loopback,p=> {
                var decoded=Packet.Decode(p.Encode());
                Check(decoded.PayloadSize==content.Length && decoded.PayloadTransferInfo?.Port is >=12070 and <=12099,"Payload envelope did not roundtrip.");
                receiving=FilePayload.ReceiveAsync(decoded,inbox,peer,own.RawData,IPAddress.Loopback,IPAddress.Loopback,_=>Task.CompletedTask,()=>true,_=>{},deadline.Token);
                return Task.CompletedTask;
            },()=>true,_=>{},deadline.Token);
            var saved=await receiving!;
            Check((await File.ReadAllBytesAsync(saved,deadline.Token)).AsSpan().SequenceEqual(content),"Direct file TLS roundtrip changed the bytes.");
            var duplicate=await FilePayload.SaveAsync(new MemoryStream(content),inbox,"input.bin",content.Length,()=>true,_=>{},deadline.Token);
            Check(saved!=duplicate && File.Exists(saved),"A same-name transfer overwrote an existing file.");
            Check(FilePayload.SafeName("../../CON.txt")=="_CON.txt" && FilePayload.SafeName("C:\\folder\\a.txt:stream")=="a.txt_stream","Windows path/device/ADS filename was not sanitized.");
            var reverse=Packet.Create("flux.share.request",new {filename="reverse.bin"}) with {PayloadSize=content.Length,PayloadTransferInfo=new(Tunnel:"abc123")};
            Task? writing=null;
            var reversed=await FilePayload.ReceiveAsync(reverse,inbox,own,peer.RawData,IPAddress.Loopback,IPAddress.Loopback,p=> {
                Check(p.Type=="flux.tunnel" && p.Body.GetProperty("id").GetString()=="abc123","Reverse tunnel reply lost its token.");
                var port=p.Body.GetProperty("port").GetInt32();
                writing=Task.Run(async()=> {
                    try { await WriteClient(port,wrong,own.RawData,content,deadline.Token); } catch (Exception e) when (e is AuthenticationException or IOException) { }
                    await WriteClient(port,peer,own.RawData,content,deadline.Token);
                });
                return Task.CompletedTask;
            },()=>true,_=>{},deadline.Token);
            await writing!;
            Check((await File.ReadAllBytesAsync(reversed,deadline.Token)).AsSpan().SequenceEqual(content),"Wrong certificate captured the reverse tunnel or corrupted its data.");
            using var phoneListener=Listener(); Task<byte[]>? phoneReceive=null;
            await FilePayload.SendAsync(input,own,peer.RawData,IPAddress.Loopback,IPAddress.Loopback,_=>throw new Exception("Android send took the direct-port path."),()=>true,_=>{},deadline.Token,
                (p,id,ct)=> {
                    Check(p.PayloadTransferInfo?.Tunnel==id && p.PayloadTransferInfo.Port is null,"Phone send did not announce a tunnel payload.");
                    phoneReceive=ReadServer(phoneListener,peer,own.RawData,ct);
                    return Task.FromResult(((IPEndPoint)phoneListener.LocalEndpoint).Port);
                });
            Check((await phoneReceive!).AsSpan().SequenceEqual(content),"Outgoing phone tunnel changed the file.");
            var before=Directory.GetFiles(inbox).Length;
            await Fails(()=>FilePayload.SaveAsync(new MemoryStream(new byte[]{1}),inbox,"short.bin",2,()=>true,_=>{},deadline.Token));
            await Fails(()=>FilePayload.SaveAsync(new MemoryStream(new byte[]{1,2}),inbox,"long.bin",1,()=>true,_=>{},deadline.Token));
            await Fails(()=>FilePayload.SaveAsync(new MemoryStream(content),inbox,"unpaired.bin",content.Length,()=>false,_=>{},deadline.Token));
            using var cancelled=new CancellationTokenSource(); cancelled.Cancel();
            await Fails(()=>FilePayload.SaveAsync(new MemoryStream(content),inbox,"cancelled.bin",content.Length,()=>true,_=>{},cancelled.Token));
            Check(Directory.GetFiles(inbox).Length==before && !Directory.GetFiles(inbox,"*.part").Any(),"Failed transfer left a partial or final file.");
            var bad=reverse with {PayloadTransferInfo=new(80)};
            await Fails(()=>{FilePayload.Validate(bad);return Task.CompletedTask;});
            await Fails(()=>{FilePayload.Validate(reverse with {PayloadTransferInfo=new(12070,"abc")});return Task.CompletedTask;});
            await Fails(()=>{FilePayload.Validate(reverse with {PayloadSize=FilePayload.MaxBytes+1});return Task.CompletedTask;});
            Console.WriteLine("PASS: payload envelope, direct/reverse/phone-tunnel TLS, wrong certificate rejection, exact bytes, safe names, collision protection and failure cleanup.");
        } finally { Directory.Delete(root,true); }
    }
}
