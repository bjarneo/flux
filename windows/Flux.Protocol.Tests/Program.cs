using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Flux.Protocol;
using Flux.Windows;
using Makaretu.Dns;

static void Check(bool ok, string why) { if (!ok) throw new Exception(why); }
static async Task Reject(Func<Task> action)
{
    try { await action(); } catch (InvalidDataException) { return; }
    throw new Exception("Expected rejection.");
}
static X509Certificate2 Cert(string id)
{
    using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    return new CertificateRequest("CN=" + id, key, HashAlgorithmName.SHA256)
        .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(2));
}
using var own = Cert(new string('a', 32));
using var peer = Cert(new string('b', 32));
using var changed = Cert(new string('b', 32));
var now = DateTimeOffset.UtcNow;
var pair = new Pairing();
pair.Begin(own, peer, "connection1", now.ToUnixTimeSeconds(), now);
Check(pair.CanAccept(pair.Key, peer, "connection1", now), "Valid approval refused.");
Check(!pair.CanAccept(pair.Key, changed, "connection1", now), "Certificate swap accepted.");
Check(!pair.CanAccept(pair.Key, peer, "connection2", now), "Connection swap accepted.");
Check(!pair.CanAccept(pair.Key, peer, "connection1", now.AddSeconds(30)), "Expired approval accepted.");
Check(!pair.CanAccept("0000000000000000", peer, "connection1", now), "Wrong key accepted.");
Check(PairKey.Compute(new byte[]{1,2}, new byte[]{3,4}, 123) ==
    PairKey.Compute(new byte[]{3,4}, new byte[]{1,2}, 123), "Key order differs.");
Check(PairKey.Compute(new byte[]{1,2}, new byte[]{3,4}, 123) == "C3215A5BE389AC55", "Flux verification-key vector differs.");
var wire = new MemoryStream("identity\nTLS"u8.ToArray());
Check(System.Text.Encoding.UTF8.GetString(await Lines.ReadAsync(wire, 8, default)) == "identity", "Line mismatch.");
Check(wire.ReadByte() == 'T', "Plaintext parser consumed TLS.");
await Reject(async () => { await Lines.ReadAsync(new MemoryStream("abcdef\n"u8.ToArray()), 5, default); });
var header = new byte[5]; BinaryPrimitives.WriteUInt32BigEndian(header, DesktopFrame.MaxBytes + 1);
await Reject(async () => { await DesktopFrame.ReadAsync(new MemoryStream(header), default); });
await Reject(async () => { Identity.Parse(Packet.Create("flux.identity", new {deviceId="short",deviceName="x",protocolVersion=8})); await Task.CompletedTask; });
var identity = new Identity(new string('b',32), "Omarchy",8);
Check(identity.Packet().Body.GetProperty("incomingCapabilities").EnumerateArray().Any(c => c.GetString() == "flux.theme"),
    "Windows must advertise incoming theme support to Omarchy.");
foreach (var (background, foreground, accent) in new[] {
    ("#1a1b26", "#c0caf5", "#7aa2f7"), ("#f7f7fa", "#20212a", "#9999bb"),
    ("#808080", "#f0f0f0", "#777777") }) {
    var themePacket = Packet.Create("flux.theme", new { name = "test", mode = "dark",
        colors = new Dictionary<string,string> { ["background"] = background, ["foreground"] = foreground,
            ["accent"] = accent, ["dark_background"] = background,
            ["green"] = "#55aa55", ["red"] = "#bb5555",
            ["selection"] = background == "#f7f7fa" ? "#101010" : "#ffffff" } });
    Check(OmarchyTheme.TryParse(themePacket.Body, out var theme) && theme is not null,
        "A valid Omarchy theme must parse.");
    foreach (var surface in new[] { theme!.Background, theme.Tile, theme.TileHi, theme.Line })
        foreach (var ink in new[] { theme.Text, theme.Sub, theme.Accent, theme.Green, theme.Red })
            Check(OmarchyTheme.Contrast(surface, ink) >= 4.5,
                "Theme text and status colors need readable contrast on every surface.");
}
Check(!OmarchyTheme.TryParse(Packet.Create("flux.theme", new { colors = new { background = "#ffffff" } }).Body, out _),
    "A theme without a foreground must be ignored.");
Check(!OmarchyTheme.TryParse(Packet.Create("flux.theme", new { colors = new { background = "#ffffff", foreground = "broken" } }).Body, out _),
    "A malformed color must not replace the current theme.");
Console.WriteLine("PASS: Omarchy theme capability, parsing, and light/dark contrast.");
foreach (var invalidVersion in new[] { "8.5", "2147483648", "-2147483649", "1e100", "7", "\"8\"", "null", "false", "[]", "{}" }) {
    using var versionJson = System.Text.Json.JsonDocument.Parse(invalidVersion);
    await Reject(() => {
        Identity.Parse(Packet.Create("flux.identity", new {deviceId=identity.DeviceId,deviceName="Malformed",protocolVersion=versionJson.RootElement}));
        return Task.CompletedTask;
    });
    Check(Identity.Parse(identity.Packet()).Version == 8, "A valid identity after a malformed announcement was rejected.");
}
await Reject(() => {
    Identity.Parse(Packet.Create("flux.identity",new {deviceId=identity.DeviceId,deviceName="Missing version"}));
    return Task.CompletedTask;
});
Console.WriteLine("PASS: malformed discovery versions reject with InvalidDataException; subsequent valid identities still parse.");
var badUnicode = "\uD800";
try { FilePayload.SafeName(badUnicode); throw new Exception("Invalid surrogate was accepted as a file name."); }
catch (ArgumentException) { }
using (var badNameBody = System.Text.Json.JsonDocument.Parse("{\"filename\":\"\\uD800\"}")) {
    var badNamePacket = new Packet(System.Text.Json.JsonSerializer.SerializeToElement(1),
        "flux.share.request", badNameBody.RootElement.Clone())
        {PayloadSize=1, PayloadTransferInfo=new(1739)};
    await Reject(() => { FilePayload.Validate(badNamePacket); return Task.CompletedTask; });
}
var stoppedByForget = new TransferEpoch(); stoppedByForget.Stop("Pairing removed.");
stoppedByForget.Stop("Connection closed.");
var stoppedByReconnect = new TransferEpoch(); stoppedByReconnect.Stop("Connection changed.");
var activeView = new FileTransferView("one", identity.DeviceId, "Peer", "file.bin", "Sent", 0, 1, "Sending");
Check(stoppedByForget.Source.IsCancellationRequested && stoppedByForget.Reason == "Pairing removed." &&
    activeView.WithFailure(new OperationCanceledException(), false, stoppedByForget, false).Status == "Cancelled",
    "Forget must cancel its transfer with a distinct status.");
var reconnectFailure = activeView.WithFailure(new OperationCanceledException(), false, stoppedByReconnect, false);
Check(reconnectFailure.Status == "Failed" && reconnectFailure.Error == "Connection changed.",
    "Reconnect must not be labelled a user cancellation or generic timeout.");
Check(activeView.WithFailure(new OperationCanceledException(), true, new TransferEpoch(), false).Status == "Cancelled",
    "Explicit transfer cancellation must show Cancelled.");
Console.WriteLine("PASS: malformed file names reject before reserving a transfer slot; transfer stop reasons remain distinct.");
await Reject(async () => { identity.VerifySecure(identity with {DeviceId=new string('c',32)}, peer); await Task.CompletedTask; });
var packet = Packet.Decode(Packet.Create("flux.pair", new {pair=true,timestamp=123}).Encode());
Check(packet.Type == "flux.pair" && packet.Body.GetProperty("pair").GetBoolean(), "Packet roundtrip failed.");
pair.Reset(); Check(!pair.CanAccept("",peer,"connection1",now), "Reset approval accepted.");
Check(!pair.Acknowledge(peer,"connection1",now), "Unsolicited acknowledgement accepted.");
pair.Begin(own, peer, "outgoing", now.ToUnixTimeSeconds(), now, outgoing: true);
Check(!pair.CanAccept(pair.Key,peer,"outgoing",now), "Outgoing pairing pinned before remote approval.");
Check(!pair.Acknowledge(changed,"outgoing",now), "Acknowledgement accepted swapped certificate.");
Check(!pair.Acknowledge(peer,"other",now), "Acknowledgement accepted swapped connection.");
Check(!pair.Acknowledge(peer,"outgoing",now.AddSeconds(30)), "Expired acknowledgement accepted.");
Check(pair.Acknowledge(peer,"outgoing",now), "Remote approval refused.");
Check(pair.CanAccept(pair.Key,peer,"outgoing",now), "Acknowledged outgoing pairing refused.");
pair.Reset(); Check(!pair.IsOutgoing && !pair.RemoteAccepted, "Outgoing state survived reset.");

static X509Certificate2 Reload(X509Certificate2 source)
{
    var pfx = source.Export(X509ContentType.Pkcs12, "");
    try { return TlsIdentity.Load(pfx); }
    finally { CryptographicOperations.ZeroMemory(pfx); }
}
using var clientCert = Reload(own);
using var serverCert = Reload(peer);
Check(clientCert.HasPrivateKey && clientCert.RawData.AsSpan().SequenceEqual(own.RawData), "Reload changed the saved identity.");
using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
using var listener = new TcpListener(IPAddress.Loopback, 0);
listener.Start();
using var client = new TcpClient();
var accept = listener.AcceptTcpClientAsync(timeout.Token);
await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, timeout.Token);
using var server = await accept;
using var serverTls = new SslStream(server.GetStream());
using var clientTls = new SslStream(client.GetStream(), false,
    (_, cert, _, _) => cert is not null && cert.GetRawCertData().AsSpan().SequenceEqual(serverCert.RawData),
    (_, _, _, _, _) => clientCert);
await Task.WhenAll(serverTls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
    ServerCertificate = serverCert, ClientCertificateRequired = true,
    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
    RemoteCertificateValidationCallback = (_, cert, _, _) => cert is not null && cert.GetRawCertData().AsSpan().SequenceEqual(clientCert.RawData)
}, timeout.Token), clientTls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
    TargetHost = "flux-test", ClientCertificates = new X509CertificateCollection {clientCert},
    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
}, timeout.Token));
Check(clientTls.IsMutuallyAuthenticated && serverTls.IsMutuallyAuthenticated, "Mutual TLS identity loading failed.");
await clientTls.WriteAsync("flux\n"u8.ToArray(), timeout.Token);
Check(System.Text.Encoding.UTF8.GetString(await Lines.ReadAsync(serverTls,8,timeout.Token)) == "flux", "TLS transport failed.");
Console.WriteLine("PASS: pairing/acknowledgement binding, certificate swaps, expiry, key order, parser bounds, identity preservation and mutual TLS loopback.");

var catalog = new DiscoveryCatalog();
var peerId = new string('b',32);
var instance = peerId + "._flux._udp.local";
var ptr = new PTRRecord {Name = "_flux._udp.local", DomainName = instance};
var srv = new SRVRecord {Name = instance, Target = "omarchy.local", Port = 1716};
var txt = new TXTRecord {Name = instance, Strings = new List<string> {"id="+peerId,"name=Omarchy","protocol=8"}};
var address = new ARecord {Name = "omarchy.local", Address = IPAddress.Parse("192.168.1.10")};
catalog.Add(new ResourceRecord[] {ptr}, now);
Check(!catalog.Peers(own.GetNameInfo(X509NameType.SimpleName,false),now).Any(), "Incomplete discovery accepted.");
Check(catalog.Missing(now).Count() == 2, "Missing SRV/TXT were not requested.");
catalog.Add(new ResourceRecord[] {new PTRRecord {Name = "_flux._udp.local", DomainName = new string('c',32) + "._flux._udp.local"}},now);
Check(catalog.Missing(now).Count() == 4, "A second peer overwrote the first service pointer.");
catalog.Add(new ResourceRecord[] {new PTRRecord {Name = "_flux._udp.local", DomainName = new string('c',32) + "._flux._udp.local", TTL = TimeSpan.Zero}},now);
catalog.Add(new ResourceRecord[] {srv,txt}, now);
Check(catalog.Missing(now).Single().Type == DnsType.A, "Missing host address was not requested.");
catalog.Add(new ResourceRecord[] {address}, now);
Check(catalog.Peers(new string('a',32),now).Single().Identity.Name == "Omarchy", "Fragmented mDNS resolution failed.");
Check(catalog.Peers(peerId,now).Count == 0, "Own identity appeared as another device.");
Check(catalog.Peers(new string('a',32),now.AddMinutes(6)).Count == 0, "Stale discovery survived expiry.");
catalog.Add(new ResourceRecord[] {new TXTRecord {Name = instance, Strings = new List<string> {"id="+peerId,"name=Omarchy","protocol=7"}}},now);
Check(catalog.Peers(new string('a',32),now).Count == 0, "Unsupported protocol offered for connection.");
catalog.Add(new ResourceRecord[] {txt, new SRVRecord {Name = instance, Target = "omarchy.local", Port = 80}},now);
Check(catalog.Peers(new string('a',32),now).Count == 0, "Non-Flux port offered for connection.");
Check(!DiscoveryCatalog.IsLocalAddress(IPAddress.Parse("224.0.0.251")) && !DiscoveryCatalog.IsLocalAddress(IPAddress.Loopback), "Invalid discovery address accepted.");
var announcement = new Identity(new string('a',32),"Windows",8).Packet(1718,new Identity(peerId,"Omarchy",8));
Check(announcement.Body.GetProperty("tcpPort").GetInt32() == 1718 && announcement.Body.GetProperty("targetDeviceId").GetString() == peerId, "Discovery/dial identity lost port or target.");
Check(!new Identity(new string('a',32),"Windows",8).Packet().Body.TryGetProperty("targetDeviceId",out _), "Untargeted identity names a null target.");
Console.WriteLine("PASS: fragmented discovery, missing-record queries, expiry, self/protocol/port/address filtering and discovery wire identity.");

using var readShutdown = new CancellationTokenSource();
using var lifetime = new ReadLifetime(readShutdown.Token, TimeSpan.FromSeconds(1));
// A packet finishes; the next read uses the same lifetime. User acceptance
// between those reads must still be able to disable the unpaired timeout.
lifetime.SetPaired(false);
var firstReadToken = lifetime.Token;
lifetime.SetPaired(false);
lifetime.SetPaired(true);
Check(lifetime.Token == firstReadToken, "Read lifetime was replaced between packets.");
await Task.Delay(TimeSpan.FromMilliseconds(1200));
Check(!lifetime.Token.IsCancellationRequested, "A saved pairing retained the unpaired read timeout.");
readShutdown.Cancel();
Check(lifetime.Token.IsCancellationRequested, "Shutdown did not cancel a paired read.");
using var unpaired = new ReadLifetime(CancellationToken.None, TimeSpan.FromMilliseconds(30));
unpaired.SetPaired(false);
await Task.Delay(80);
Check(unpaired.Token.IsCancellationRequested, "Unpaired idle timeout was disabled.");
Console.WriteLine("PASS: connection-scoped read lifetime, promotion across packet boundaries, unpaired timeout and paired shutdown.");

var discoveredPeer = new DiscoveredPeer(new Identity(peerId,"Pixel",8),IPAddress.Parse("192.168.1.10"),1716);
var savedPeers = new HashSet<string> {peerId};
Check(PeerRow.Create(discoveredPeer,new(peerId,discoveredPeer.Address,true),savedPeers).Status == "Paired — connected", "A confirmed connected peer is labelled untrusted.");
Check(PeerRow.Create(discoveredPeer,new(peerId,discoveredPeer.Address,false),savedPeers).Status == "Connected — pairing needed", "An incomplete pairing is labelled confirmed.");
Check(PeerRow.Create(discoveredPeer,new(null,null,false),savedPeers).Status == "Pairing saved — not connected", "Saved trust is confused with a live connection.");
Check(PeerRow.Create(discoveredPeer,new(peerId,IPAddress.Parse("192.168.1.99"),true),savedPeers).Status == "Pairing saved — not connected", "Another advertised address is labelled authenticated.");
Check(PeerRow.Create(discoveredPeer,new(null,null,false),new HashSet<string>()).Status == "Discovered — not connected", "An untrusted discovery is labelled paired.");
Console.WriteLine("PASS: discovered, connected, confirmed, saved/offline and address-bound peer status.");
var otherAddress = discoveredPeer with { Address=IPAddress.Parse("192.168.1.99") };
var otherPort = otherAddress with { Port=1717 };
PeerRow Row(DiscoveredPeer p) => PeerRow.Create(p,new(null,null,false),savedPeers);
var alternatives = new[] {Row(discoveredPeer),Row(otherAddress),Row(otherPort)};
Check(ReferenceEquals(PeerRow.RestoreSelection(alternatives,otherPort),alternatives[2]), "A refresh changed the selected endpoint's address or port.");
var renamed = otherPort with {Identity=otherPort.Identity with {Name="Updated name",CanTunnel=true}};
var reordered = new[] {Row(renamed),Row(discoveredPeer),Row(otherAddress)};
Check(ReferenceEquals(PeerRow.RestoreSelection(reordered,otherPort),reordered[0]), "Metadata or ordering changes lost the selected endpoint.");
var remaining = new[] {Row(discoveredPeer),Row(otherAddress)};
Check(ReferenceEquals(PeerRow.RestoreSelection(remaining,otherPort),remaining[0]), "A disappeared endpoint did not fall back to its device's remaining address.");
Check(PeerRow.RestoreSelection(Array.Empty<PeerRow>(),otherPort) is null, "An empty device list retained a stale selection.");
Check(ReferenceEquals(PeerRow.RestoreSelection(remaining,null),remaining[0]), "Initial device selection did not choose the first row.");
Console.WriteLine("PASS: selected endpoint retained across address, port, ordering and metadata updates; disappearance and empty-list fallback.");

Check(DiscoveryCatalog.IsLanAdvertisementAddress(IPAddress.Parse("192.168.1.42")), "The Windows LAN address was omitted.");
Check(!DiscoveryCatalog.IsLanAdvertisementAddress(IPAddress.Parse("100.71.227.3")), "A Tailscale overlay address was advertised on the LAN.");
Check(!DiscoveryCatalog.IsLanAdvertisementAddress(IPAddress.Parse("100.64.0.1")) && !DiscoveryCatalog.IsLanAdvertisementAddress(IPAddress.Parse("100.127.255.254")), "Overlay range edge leaked into mDNS.");
Check(DiscoveryCatalog.IsLanAdvertisementAddress(IPAddress.Parse("100.128.0.1")), "An address outside the overlay range was incorrectly filtered.");
var observations = 0;
var ready = await ConnectionAttempt.WaitAsync(_ => Task.FromResult(++observations < 3
    ? new ConnectionObservation(true,false) : new ConnectionObservation(true,true)),TimeSpan.FromSeconds(1),CancellationToken.None);
Check(ready && observations == 3, "Another active handshake was silently treated as the requested connection.");
observations = 0;
Check(!await ConnectionAttempt.WaitAsync(_ => Task.FromResult(++observations < 3
    ? new ConnectionObservation(true,false) : new ConnectionObservation(false,false)),TimeSpan.FromSeconds(1),CancellationToken.None), "An idle slot was treated as an authenticated link.");
try {
    await ConnectionAttempt.WaitAsync(_ => Task.FromResult(new ConnectionObservation(true,false)),TimeSpan.FromMilliseconds(60),CancellationToken.None);
    throw new Exception("A permanently occupied slot did not report a timeout.");
} catch (TimeoutException) { }
using var stoppedRead = new ReadLifetime(CancellationToken.None);
stoppedRead.SetPaired(true); stoppedRead.Stop();
Check(stoppedRead.Token.IsCancellationRequested,"Switching devices did not cancel the old active read.");
Console.WriteLine("PASS: LAN-only advertisement, handshake-slot race, timeout reporting and cancellation when switching peers.");

observations = 0;
Check(await ConnectionAttempt.WaitForTargetAsync(_ => Task.FromResult(++observations < 3
    ? new ConnectionObservation(false,false) : new ConnectionObservation(true,true)),TimeSpan.FromSeconds(1),CancellationToken.None),
    "Reverse connection wait stopped at an idle slot before the target arrived.");
Check(!await ConnectionAttempt.WaitForTargetAsync(_ => Task.FromResult(new ConnectionObservation(true,false)),
    TimeSpan.FromMilliseconds(80),CancellationToken.None), "Another active peer satisfied the reverse connection wait.");
Check(!await ConnectionAttempt.WaitForTargetAsync(_ => Task.FromResult(new ConnectionObservation(false,false)),
    TimeSpan.FromMilliseconds(80),CancellationToken.None), "An idle timeout was reported as a verified reverse connection.");
using var reverseShutdown = new CancellationTokenSource();
reverseShutdown.Cancel();
try {
    await ConnectionAttempt.WaitForTargetAsync(_ => Task.FromResult(new ConnectionObservation(false,false)),
        TimeSpan.FromSeconds(1),reverseShutdown.Token);
    throw new Exception("Shutdown did not cancel the reverse connection wait.");
} catch (OperationCanceledException) { }
Console.WriteLine("PASS: delayed reverse connection after idle slots, unrelated peer rejection, bounded wait and shutdown.");

// Exercise two real TLS transports with the same session objects and registry
// used by Windows. Closing one peer must leave the other transport usable.
using var generatedPhoneCert = Cert(new string('c',32));
using var phoneCert = Reload(generatedPhoneCert);
using var secondListener = new TcpListener(IPAddress.Loopback,0);
secondListener.Start();
using var secondClient = new TcpClient();
using var multiDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
var secondAccept = secondListener.AcceptTcpClientAsync(multiDeadline.Token);
await secondClient.ConnectAsync(IPAddress.Loopback,((IPEndPoint)secondListener.LocalEndpoint).Port,multiDeadline.Token);
using var secondServer = await secondAccept;
using var secondServerTls = new SslStream(secondServer.GetStream(),false,(_,cert,_,_) => cert is not null && cert.GetRawCertData().AsSpan().SequenceEqual(phoneCert.RawData));
using var secondClientTls = new SslStream(secondClient.GetStream(),false,
    (_,cert,_,_) => cert is not null && cert.GetRawCertData().AsSpan().SequenceEqual(serverCert.RawData),(_,_,_,_,_) => phoneCert);
await Task.WhenAll(secondServerTls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
    ServerCertificate=serverCert,ClientCertificateRequired=true,EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,
    CertificateRevocationCheckMode=X509RevocationMode.NoCheck
},multiDeadline.Token),secondClientTls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
    TargetHost="multi-peer-test",ClientCertificates=new X509CertificateCollection {phoneCert},
    EnabledSslProtocols=SslProtocols.Tls12|SslProtocols.Tls13,CertificateRevocationCheckMode=X509RevocationMode.NoCheck
},multiDeadline.Token));
using var firstReads = new ReadLifetime(CancellationToken.None);
using var secondReads = new ReadLifetime(CancellationToken.None);
var desktopSession = new PeerSession(new(new string('a',32),"Omarchy",8),IPAddress.Loopback,1716,serverTls,clientCert,firstReads);
var phoneSession = new PeerSession(new(new string('c',32),"Pixel",8),IPAddress.Loopback,1716,secondServerTls,phoneCert,secondReads);
var registry = new PeerSessions<PeerSession>(2);
Check(registry.TryAdd(desktopSession.Remote.DeviceId,desktopSession) && registry.TryAdd(phoneSession.Remote.DeviceId,phoneSession),"Two different peers could not stay registered together.");
Check(!registry.TryAdd(desktopSession.Remote.DeviceId,phoneSession),"A duplicate device replaced a live peer.");
Check(!registry.TryAdd(new string('d',32),phoneSession),"The device bound was ignored.");
var pairingNow = DateTimeOffset.UtcNow;
desktopSession.Pairing.Begin(serverCert,clientCert,desktopSession.Id,pairingNow.ToUnixTimeSeconds(),pairingNow);
phoneSession.Pairing.Begin(serverCert,phoneCert,phoneSession.Id,pairingNow.ToUnixTimeSeconds(),pairingNow);
Check(!phoneSession.Pairing.CanAccept(desktopSession.Pairing.Key,phoneCert,desktopSession.Id,pairingNow),"Approval for Omarchy could approve the phone.");
Check(!desktopSession.Pairing.CanAccept(phoneSession.Pairing.Key,clientCert,phoneSession.Id,pairingNow),"Approval for the phone could approve Omarchy.");
Check(!registry.Remove(desktopSession.Remote.DeviceId,phoneSession),"Another peer's cleanup removed Omarchy.");
phoneSession.Pairing.Reset();
Check(desktopSession.Pairing.CanAccept(desktopSession.Pairing.Key,clientCert,desktopSession.Id,pairingNow),"Resetting phone pairing affected Omarchy.");
firstReads.SetPaired(true); secondReads.SetPaired(true);
firstReads.Stop();
Check(!secondReads.Token.IsCancellationRequested,"Cancelling Omarchy cancelled the phone's read.");
Check(registry.Remove(desktopSession.Remote.DeviceId,desktopSession),"Disconnected Omarchy was not removed.");
serverTls.Dispose();
await secondClientTls.WriteAsync("phone still connected\n"u8.ToArray(),multiDeadline.Token);
Check(System.Text.Encoding.UTF8.GetString(await Lines.ReadAsync(secondServerTls,64,multiDeadline.Token))=="phone still connected","Closing Omarchy broke the phone's TLS transport.");
var replacement = new PeerSession(desktopSession.Remote,IPAddress.Loopback,1716,secondServerTls,clientCert,firstReads);
Check(registry.TryAdd(desktopSession.Remote.DeviceId,replacement),"Reconnecting a removed device failed.");
Check(!registry.Remove(desktopSession.Remote.DeviceId,desktopSession) && ReferenceEquals(registry.Get(desktopSession.Remote.DeviceId),replacement),"Stale cleanup removed a reconnected peer.");
Check(ReferenceEquals(registry.Get(phoneSession.Remote.DeviceId),phoneSession),"Reconnecting Omarchy replaced the phone.");
Console.WriteLine("PASS: two concurrent TLS peers, independent pairing/read cancellation, duplicate/capacity limits, surviving transport and reconnect cleanup.");

Check(ConnectionPreference.KeepExisting(true,false,TimeSpan.FromSeconds(1),"b","a"),"Larger local ID did not retain its outgoing socket.");
Check(!ConnectionPreference.KeepExisting(false,true,TimeSpan.FromSeconds(1),"b","a"),"Larger local ID retained the wrong crossed dial.");
Check(ConnectionPreference.KeepExisting(false,true,TimeSpan.FromSeconds(1),"a","b"),"The remote endpoint did not choose the same crossed socket.");
Check(!ConnectionPreference.KeepExisting(true,false,TimeSpan.FromSeconds(6),"b","a"),"A stale socket prevented reconnect.");
Check(!registry.Replace(phoneSession.Remote.DeviceId,desktopSession,replacement),"Another device replaced the phone session.");
Console.WriteLine("PASS: matching Go crossed-dial arbitration, stale reconnect preference and guarded session replacement.");

await FilePayloadChecks.RunAsync(clientCert,serverCert,changed);
