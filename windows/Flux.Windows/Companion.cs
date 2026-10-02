using System.IO;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.NetworkInformation;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Flux.Protocol;
using Makaretu.Dns;

namespace Flux.Windows;

internal sealed class Companion : IDisposable
{
    private readonly CancellationTokenSource shutdown = new();
    private readonly SemaphoreSlim state = new(1, 1);
    private readonly SemaphoreSlim connect = new(1, 1);
    private readonly SemaphoreSlim handshakes = new(8, 8);
    private readonly PeerSessions<PeerSession> sessions = new();
    private readonly HashSet<string> dialing = new();
    private readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Flux.Windows");
    private readonly X509Certificate2 own;
    private readonly Identity identity;
    private readonly ConcurrentDictionary<string, string> pins;
    private readonly Dictionary<string, SavedPeer> savedPeers;
    private readonly Dictionary<string, string> themeBodies = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, CancellationTokenSource> activeTransfers = new();
    private readonly ConcurrentDictionary<string, byte> userCancelledTransfers = new();
    private TcpListener? listener;
    private ServiceDiscovery? discovery;
    private ServiceProfile? profile;
    private UdpClient? udp;
    private readonly DiscoveryCatalog catalog = new();
    private readonly object discoveryLock = new();
    private readonly HashSet<string> queries = new();
    private readonly Dictionary<string, DiscoveredPeer> udpPeers = new();
    private IPAddress[] addresses = Array.Empty<IPAddress>();
    private IPAddress[] advertisedAddresses = Array.Empty<IPAddress>();
    public event Action<IReadOnlyList<DiscoveredPeer>>? PeersChanged;
    public event Action<PeerConnection>? ConnectionChanged;
    public event Action<IReadOnlyList<string>>? SavedPairsChanged;
    public IReadOnlyList<string> SavedPeerIds => pins.Keys.ToArray();
    public event Action<IReadOnlyList<SavedPeer>>? SavedPeersChanged;
    public IReadOnlyList<SavedPeer> SavedPeers => savedPeers.Values.Where(p => pins.ContainsKey(p.DeviceId)).ToArray();
    public string NetworkSummary => $"Windows IPv4: {string.Join(", ", addresses.Select(a => a.ToString()))}; LAN announcement: {string.Join(", ", advertisedAddresses.Select(a => a.ToString()))}; TCP {ListenPort}; UDP discovery {(udp is null ? "unavailable" : "1716")}.";
    private int ListenPort => ((IPEndPoint)listener!.LocalEndpoint).Port;
    public event Action<string, string, string, bool, bool>? Changed;
    public event Action<PeerView>? ViewChanged;
    public event Action<FileTransferView>? TransferChanged;
    public event Action<string, OmarchyTheme?>? ThemeChanged;
    public IReadOnlyDictionary<string, OmarchyTheme> SavedThemes => themeBodies
        .Where(pair => pins.ContainsKey(pair.Key))
        .Select(pair => (pair.Key, Valid: ParseTheme(pair.Value)))
        .Where(pair => pair.Valid is not null)
        .ToDictionary(pair => pair.Key, pair => pair.Valid!, StringComparer.Ordinal);
    public string ReceiveDirectory { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Flux");
    public event Action<string>? Diagnostic;
    private void Record(string detail) => Diagnostic?.Invoke(DateTimeOffset.Now.ToString("HH:mm:ss") + " " + detail);

    public Companion()
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "identity.dpapi");
        if (File.Exists(path)) {
            var pfx = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
            try { own = TlsIdentity.Load(pfx); }
            finally { CryptographicOperations.ZeroMemory(pfx); }
        } else {
            using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest("CN=" + Guid.NewGuid().ToString("N"), key, HashAlgorithmName.SHA256);
            using var generated = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            var pfx = generated.Export(X509ContentType.Pkcs12, "");
            try {
                own = TlsIdentity.Load(pfx);
                Save(path, ProtectedData.Protect(pfx, null, DataProtectionScope.CurrentUser));
            }
            finally { CryptographicOperations.ZeroMemory(pfx); }
        }
        identity = new(own.GetNameInfo(X509NameType.SimpleName, false), "Flux Windows", 8);
        var trust = Path.Combine(directory, "trust.json");
        pins = new(File.Exists(trust) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(trust))
            ?? throw new InvalidDataException("Cannot read saved trust.") : new Dictionary<string, string>());
        var peersPath = Path.Combine(directory, "peers.json");
        try {
            savedPeers = File.Exists(peersPath)
                ? JsonSerializer.Deserialize<Dictionary<string, SavedPeer>>(File.ReadAllText(peersPath))
                    ?? new Dictionary<string, SavedPeer>()
                : new Dictionary<string, SavedPeer>();
        } catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException) {
            // This cache carries display and reconnect hints only; trust.json
            // remains the sole authority for paired certificates.
            savedPeers = new Dictionary<string, SavedPeer>();
        }
        foreach (var key in savedPeers.Where(p => p.Value is null || p.Key != p.Value.DeviceId || !Identity.ValidId(p.Key) ||
            !IPAddress.TryParse(p.Value.Address, out var address) || !DiscoveryCatalog.IsLocalAddress(address) ||
            p.Value.Port is < 1716 or > 1764).Select(p => p.Key).ToArray())
            savedPeers.Remove(key);
        var themesPath = Path.Combine(directory, "themes.json");
        try {
            if (File.Exists(themesPath)) {
                var bodies = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(themesPath));
                if (bodies is not null) foreach (var (id, body) in bodies.Take(16))
                    if (Identity.ValidId(id) && pins.ContainsKey(id) && body.Length <= 8192 && ParseTheme(body) is not null)
                        themeBodies[id] = body;
            }
        } catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException) {
            Record("Could not load saved theme: " + ex.GetType().Name);
        }
    }
    private static OmarchyTheme? ParseTheme(string body)
    {
        try { using var document = JsonDocument.Parse(body); return OmarchyTheme.TryParse(document.RootElement, out var theme) ? theme : null; }
        catch (JsonException) { return null; }
    }
    // The caller holds state. Theme data is only cached for a paired, current peer.
    private void SetThemeLocked(string id, string? body, OmarchyTheme? theme)
    {
        if (body is null) themeBodies.Remove(id); else themeBodies[id] = body;
        try { Save(Path.Combine(directory, "themes.json"), JsonSerializer.SerializeToUtf8Bytes(themeBodies)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
            Record("Could not save device theme: " + ex.GetType().Name);
        }
        ThemeChanged?.Invoke(id, theme);
    }
    private static void Save(string path, byte[] bytes)
    {
        var temp = path + ".tmp";
        using (var f = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None)) {
            f.Write(bytes); f.Flush(true);
        }
        File.Move(temp, path, true);
    }
    private void Notify(string status, string detail, string key = "")
    {
        Record(status + ": " + detail);
        Changed?.Invoke(status, detail, key, false, false);
    }
    public async Task StartAsync()
    {
        for (var port = 1716; port <= 1764; port++) {
            var candidate = new TcpListener(IPAddress.Any, port);
            try { candidate.Start(4); listener = candidate; break; }
            catch (SocketException) { candidate.Stop(); }
        }
        if (listener is null) throw new IOException("No free Flux port from 1716 to 1764.");
        addresses = NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address)
            .Where(DiscoveryCatalog.IsLocalAddress).Distinct().ToArray();
        if (addresses.Length == 0) throw new IOException("No active IPv4 LAN address. Connect Windows to the same LAN as Omarchy.");
        advertisedAddresses = addresses.Where(DiscoveryCatalog.IsLanAdvertisementAddress).ToArray();
        if (advertisedAddresses.Length == 0) throw new IOException("No LAN IPv4 address is available for discovery. Initial pairing needs the local network, rather than only a Tailscale address.");
        profile = new ServiceProfile(identity.DeviceId, "_flux._udp", (ushort)ListenPort, advertisedAddresses);
        profile.AddProperty("id", identity.DeviceId); profile.AddProperty("name", identity.Name);
        profile.AddProperty("type", "laptop"); profile.AddProperty("protocol", "8");
        discovery = new ServiceDiscovery(); discovery.Advertise(profile);
        discovery.Mdns.AnswerReceived += OnDiscoveryAnswer;
        try {
            udp = new UdpClient(AddressFamily.InterNetwork);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, 1716)); udp.EnableBroadcast = true;
            _ = ReadDiscoveryAsync();
        } catch (SocketException) { udp?.Dispose(); udp = null; }
        _ = ListenAsync();
        Notify("Searching for Flux devices", "Keep Flux open on the phone and Omarchy. Select a discovered device and Connect, then Pair.");
        await FindAsync();
    }
    private void OnDiscoveryAnswer(object? sender, MessageEventArgs e)
    {
        if (shutdown.IsCancellationRequested) return;
        try {
            List<(DomainName Name, DnsType Type)> missing;
            lock (discoveryLock) {
                var now = DateTimeOffset.UtcNow;
                catalog.Add(e.Message.Answers.Concat(e.Message.AdditionalRecords), now);
                missing = catalog.Missing(now).Where(q => queries.Count < 128 && queries.Add($"{q.Type}:{q.Name}")).ToList();
                PublishPeers();
            }
            foreach (var question in missing) discovery?.Mdns.SendQuery(question.Name, type: question.Type);
        } catch (Exception ex) { if (!shutdown.IsCancellationRequested) Notify("Discovery needs attention", ex.Message); }
    }
    private void PublishPeers() => PeersChanged?.Invoke(catalog.Peers(identity.DeviceId, DateTimeOffset.UtcNow)
        .Concat(udpPeers.Values).GroupBy(p => (p.Identity.DeviceId,p.Address,p.Port)).Select(g => g.Last()).Take(128).ToArray());
    private async Task ReadDiscoveryAsync()
    {
        try {
            while (!shutdown.IsCancellationRequested) {
                var received = await udp!.ReceiveAsync(shutdown.Token);
                if (received.Buffer.Length > 8192 || !DiscoveryCatalog.IsLocalAddress(received.RemoteEndPoint.Address)) continue;
                try {
                    var packet = Packet.Decode(received.Buffer); var found = Identity.Parse(packet);
                    if (found.DeviceId == identity.DeviceId || !packet.Body.TryGetProperty("tcpPort", out var port) ||
                        !port.TryGetInt32(out var number) || number is < 1716 or > 1764) continue;
                    lock (discoveryLock) {
                        if (udpPeers.Count < 128 || udpPeers.ContainsKey(found.DeviceId)) {
                            udpPeers[found.DeviceId] = new(found, received.RemoteEndPoint.Address, number); PublishPeers();
                        }
                    }
                } catch (Exception ex) when (ex is JsonException or InvalidDataException or InvalidOperationException or KeyNotFoundException) { }
            }
        } catch (OperationCanceledException) { }
        catch (Exception ex) { if (!shutdown.IsCancellationRequested) Notify("UDP discovery stopped", ex.Message); }
    }
    // Session pairing/read state is guarded by its own Gate. The global state
    // lock protects only registration and trust-file writes, never network I/O.
    private async Task NotifyPeerAsync(PeerSession session, string status, string detail)
    {
        await state.WaitAsync();
        try {
        var current = sessions.Get(session.Remote.DeviceId);
        if ((!session.Closed && !ReferenceEquals(current, session)) || (session.Closed && current is not null)) return;
        Record(session.Remote.Name + ": " + status + ": " + detail);
        ConnectionChanged?.Invoke(new(session.Remote.DeviceId, session.Address, session.Paired, !session.Closed));
        ViewChanged?.Invoke(new(session.Remote.DeviceId, session.Id,
            new(session.Remote, session.Address, session.Port), status, detail,
            PairKey.Format(session.Pairing.Key), !session.Closed && !session.Paired && session.Pairing.Key.Length == 0,
            !session.Closed && session.Pairing.CanAccept(session.Pairing.Key, session.Certificate, session.Id, DateTimeOffset.UtcNow)));
        } finally { state.Release(); }
    }
    public async Task FindAsync()
    {
        if (profile is null) throw new IOException("Discovery has not started.");
        lock (discoveryLock) { queries.Clear(); udpPeers.Clear(); PublishPeers(); }
        discovery!.QueryServiceInstances("_flux._udp");
        if (udp is not null) await udp.SendAsync(identity.Packet(ListenPort).Encode(), new IPEndPoint(IPAddress.Broadcast, 1716), shutdown.Token);
        await AnnounceAsync(profile);
        Record("Discovery refreshed. Existing device connections remain open.");
    }
    private async Task<PeerSession?> GetSessionAsync(string id)
    {
        await state.WaitAsync(shutdown.Token);
        try { return sessions.Get(id); } finally { state.Release(); }
    }
    public async Task ConnectAsync(DiscoveredPeer target)
    {
        await connect.WaitAsync(shutdown.Token);
        try {
            var existing = await GetSessionAsync(target.Identity.DeviceId);
            if (existing is not null) {
                await existing.Gate.WaitAsync(shutdown.Token);
                try { await NotifyPeerAsync(existing, "Already connected to " + existing.Remote.Name, "Other device connections remain open."); }
                finally { existing.Gate.Release(); }
                return;
            }
            Notify("Connecting to " + target.Identity.Name, "Announcing Windows and asking this device to connect back. Other connections stay open.");
            if (profile is not null) await AnnounceAsync(profile);
            using var announce = new UdpClient(AddressFamily.InterNetwork);
            await announce.SendAsync(identity.Packet(ListenPort).Encode(), new IPEndPoint(target.Address, 1716), shutdown.Token);
            await Task.Delay(TimeSpan.FromSeconds(2), shutdown.Token);
            if (await GetSessionAsync(target.Identity.DeviceId) is not null) return;
            await state.WaitAsync(shutdown.Token);
            try { dialing.Add(target.Identity.DeviceId); } finally { state.Release(); }
            var tcp = new TcpClient();
            try {
                Notify("Opening TCP to " + target.Identity.Name, "Connecting to " + target.Address + ":" + target.Port + ". Timeout: 5 seconds.");
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(5));
                await tcp.ConnectAsync(target.Address, target.Port, timeout.Token);
            } catch (Exception ex) {
                tcp.Dispose();
                await state.WaitAsync();
                try { dialing.Remove(target.Identity.DeviceId); } finally { state.Release(); }
                shutdown.Token.ThrowIfCancellationRequested();
                var reason = ex is SocketException socket ? socket.SocketErrorCode.ToString()
                    : ex is OperationCanceledException ? "Timed out after 5 seconds" : ex.GetType().Name;
                Notify("Waiting for " + target.Identity.Name + " to connect to Windows", reason + ". Listening for its return connection for up to 35 seconds.");
                if (profile is not null) await AnnounceAsync(profile);
                if (await ConnectionAttempt.WaitForTargetAsync(token => ObserveAsync(target.Identity.DeviceId, token), TimeSpan.FromSeconds(35), shutdown.Token)) return;
                throw new IOException("Direct TCP failed: " + reason + ". No verified return connection arrived within 35 seconds. See Connection diagnostics.", ex);
            }
            if (!await handshakes.WaitAsync(0, shutdown.Token)) {
                tcp.Dispose();
                await state.WaitAsync();
                try { dialing.Remove(target.Identity.DeviceId); } finally { state.Release(); }
                throw new IOException("Too many TLS handshakes are in progress. Try Connect again.");
            }
            var authenticated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _ = RunAsync(tcp, target.Identity, authenticated, target.Port);
            await authenticated.Task.WaitAsync(TimeSpan.FromSeconds(12), shutdown.Token);
        } finally { connect.Release(); }
    }
    private async Task<ConnectionObservation> ObserveAsync(string id, CancellationToken token)
    {
        await state.WaitAsync(token);
        try { return new(dialing.Contains(id), sessions.Get(id) is not null); } finally { state.Release(); }
    }
    private async Task AnnounceAsync(ServiceProfile profile)
    {
        try { await Task.Run(() => discovery!.Announce(profile), shutdown.Token); }
        catch (OperationCanceledException) { }
        catch (Exception) when (shutdown.IsCancellationRequested) { }
    }
    private async Task ListenAsync()
    {
        try {
            while (!shutdown.IsCancellationRequested) {
                var tcp = await listener!.AcceptTcpClientAsync(shutdown.Token);
                if (!await handshakes.WaitAsync(0, shutdown.Token)) {
                    Record("Incoming TCP refused: eight TLS handshakes are already in progress.");
                    tcp.Dispose(); continue;
                }
                Record("Incoming TCP from " + tcp.Client.RemoteEndPoint + "; reading its Flux identity.");
                _ = RunAsync(tcp);
            }
        } catch (OperationCanceledException) { }
        catch (SocketException) when (shutdown.IsCancellationRequested) { }
        catch (Exception ex) { Notify("Listener stopped", ex.Message); }
    }
    private async Task RunAsync(TcpClient tcp, Identity? dialTarget = null, TaskCompletionSource? authenticated = null, int? peerPort = null)
    {
        var phase = "plain identity exchange";
        var lastType = "none";
        var detail = "The connection ended.";
        var handshakeHeld = true;
        PeerSession? session = null;
        X509Certificate2? certificate = null;
        using var reads = new ReadLifetime(shutdown.Token);
        try {
            using (tcp) {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(10));
                var plainPacket = dialTarget is null ? Packet.Decode(await Lines.ReadAsync(tcp.GetStream(), 8192, deadline.Token)) : dialTarget.Packet();
                var plain = Identity.Parse(plainPacket);
                if (plain.DeviceId == identity.DeviceId) throw new InvalidDataException("Self connection refused.");
                if (dialTarget is not null) await tcp.GetStream().WriteAsync(identity.Packet(ListenPort, dialTarget).Encode(), deadline.Token);
                if (plainPacket.Body.TryGetProperty("targetDeviceId", out var target) && target.GetString() != identity.DeviceId)
                    throw new InvalidDataException("Connection names another device.");
                if (plainPacket.Body.TryGetProperty("targetProtocolVersion", out var version) && version.ToString() != "8")
                    throw new InvalidDataException("Connection names another protocol.");
                using var tls = new SslStream(tcp.GetStream(), false, (_, cert, _, _) => {
                    if (cert is null) return false;
                    using var leaf = X509CertificateLoader.LoadCertificate(cert.GetRawCertData());
                    return leaf.GetNameInfo(X509NameType.SimpleName, false) == plain.DeviceId &&
                        (!pins.TryGetValue(plain.DeviceId, out var pin) || pin == Convert.ToBase64String(leaf.RawData));
                }, (_, _, _, _, _) => own);
                phase = "TLS handshake";
                if (dialTarget is not null) await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                    ServerCertificate = own, ClientCertificateRequired = true,
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, deadline.Token);
                else await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
                    TargetHost = plain.DeviceId, ClientCertificates = new X509CertificateCollection { own },
                    EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, deadline.Token);
                var cert = certificate = X509CertificateLoader.LoadCertificate(tls.RemoteCertificate!.GetRawCertData());
                Record("TLS handshake completed with " + plain.Name + " using " + tls.SslProtocol + "; checking secure identity.");
                phase = "secure identity exchange";
                await tls.WriteAsync(identity.Packet().Encode(), deadline.Token);
                var secure = Identity.Parse(Packet.Decode(await Lines.ReadAsync(tls, 8192, deadline.Token)));
                plain.VerifySecure(secure, cert);
                var address = ((IPEndPoint)tcp.Client.RemoteEndPoint!).Address;
                var port = peerPort ?? (plainPacket.Body.TryGetProperty("tcpPort", out var incomingPort) && incomingPort.TryGetInt32(out var advertisedPort) ? advertisedPort : 1716);
                // A discovery port is a hint only; keep a valid Flux range for rows.
                if (port is < 1716 or > 1764) port = 1716;
                var candidate = new PeerSession(secure, address, port, tls, cert, reads,
                    ((IPEndPoint)tcp.Client.LocalEndPoint!).Address) { Outgoing = dialTarget is not null };
                await state.WaitAsync(shutdown.Token);
                try {
                    if (pins.TryGetValue(secure.DeviceId, out var currentPin) && currentPin != Convert.ToBase64String(cert.RawData))
                        throw new InvalidDataException("The peer certificate changed during the handshake.");
                    candidate.Paired = pins.ContainsKey(secure.DeviceId);
                    var previous = sessions.Get(secure.DeviceId);
                    if (previous is not null) {
                        if (ConnectionPreference.KeepExisting(previous.Outgoing, candidate.Outgoing,
                            DateTimeOffset.UtcNow - previous.Started, identity.DeviceId, secure.DeviceId)) {
                            Record("Crossed dial to " + secure.Name + " ignored; keeping the same preferred socket as the peer.");
                            authenticated?.TrySetResult(); return;
                        }
                        sessions.Replace(secure.DeviceId, previous, candidate);
                        previous.RevokeTransfers("Connection changed.");
                        previous.Reads.Stop();
                        Record("Replacing only " + secure.Name + " with its verified reconnect. Other devices remain connected.");
                    } else if (!sessions.TryAdd(secure.DeviceId, candidate)) throw new IOException("The sixteen-device connection limit was reached.");
                    session = candidate;
                } finally { state.Release(); }
                reads.SetPaired(session.Paired);
                if (session.Paired) await RememberPeerAsync(session);
                handshakes.Release(); handshakeHeld = false;
                await session.Gate.WaitAsync(shutdown.Token);
                try { await NotifyPeerAsync(session, session.Paired ? "Paired with " + secure.Name : "Connected to " + secure.Name,
                    session.Paired ? "The saved certificate matches. Other connections remain open." : "Select this device to Pair or confirm its incoming request."); }
                finally { session.Gate.Release(); }
                authenticated?.TrySetResult();
                phase = "packet read";
                while (!shutdown.IsCancellationRequested) {
                    await session.Gate.WaitAsync(shutdown.Token);
                    int limit;
                    try { reads.SetPaired(session.Paired); limit = session.Paired ? 16 << 20 : 64 << 10; }
                    finally { session.Gate.Release(); }
                    var packet = Packet.Decode(await Lines.ReadAsync(tls, limit, reads.Token));
                    lastType = packet.Type;
                    if (packet.Type == "flux.theme") {
                        if (packet.Body.GetRawText().Length <= 8192 && OmarchyTheme.TryParse(packet.Body, out var theme)) {
                            await state.WaitAsync(shutdown.Token);
                            try {
                                if (!session.Closed && session.Paired && ReferenceEquals(sessions.Get(secure.DeviceId), session) &&
                                    pins.ContainsKey(secure.DeviceId))
                                    SetThemeLocked(secure.DeviceId, packet.Body.GetRawText(), theme);
                            } finally { state.Release(); }
                        }
                        continue;
                    }
                    if (packet.Type == "flux.tunnel") {
                        if (session.Paired && !session.Closed && packet.Body.TryGetProperty("id",out var token) && token.ValueKind == JsonValueKind.String &&
                            session.Tunnels.TryGetValue(token.GetString()!,out var waiting)) {
                            if (packet.Body.TryGetProperty("error",out var error) && error.ValueKind == JsonValueKind.String && error.GetString()!.Length > 0)
                                waiting.TrySetException(new IOException("The peer could not open its file tunnel."));
                            else if (packet.Body.TryGetProperty("port",out var tunnelPort) && tunnelPort.TryGetInt32(out var value) && value is >= 1739 and <= 1764)
                                waiting.TrySetResult(value);
                            else waiting.TrySetException(new IOException("Invalid file tunnel port."));
                        }
                        continue;
                    }
                    if (packet.Type == "flux.share.request") {
                        await QueueReceiveAsync(session, packet); continue;
                    }
                    if (packet.Type != "flux.pair") continue;
                    await session.Gate.WaitAsync(shutdown.Token);
                    try {
                        if (!ReferenceEquals(await GetSessionAsync(secure.DeviceId), session)) break;
                        if (!packet.Body.TryGetProperty("pair", out var wants) || wants.ValueKind != JsonValueKind.True) {
                            if (!await RevokeCurrentTrustAsync(session, "Pairing removed by the peer.")) break;
                            session.Pairing.Reset();
                            await NotifyPeerAsync(session, "Not paired", "This device sent flux.pair=false. Other pairings are unchanged."); continue;
                        }
                        if (!packet.Body.TryGetProperty("timestamp", out var timestamp) || !timestamp.TryGetInt64(out var seconds)) {
                            if (session.Pairing.Acknowledge(cert, session.Id, DateTimeOffset.UtcNow)) {
                                await NotifyPeerAsync(session, "Your confirmation is needed for " + secure.Name, "Compare all 16 characters and accept the matching key here within 30 seconds.");
                                continue;
                            }
                            await SendAsync(session, Packet.Create("flux.pair", new { pair = false })); continue;
                        }
                        if (session.Paired && !await RevokeCurrentTrustAsync(session, "Peer requested new pairing.")) break;
                        session.Pairing.Begin(own, cert, session.Id, seconds, DateTimeOffset.UtcNow);
                        await NotifyPeerAsync(session, "Pair with " + secure.Name, "Compare all 16 characters on this device. Accept only when both keys match.");
                        _ = ExpireAsync(session, session.Pairing.Key);
                    } finally { session.Gate.Release(); }
                }
            }
        } catch (OperationCanceledException) { detail = phase == "packet read" ? "Shutdown or this device's unpaired idle timer expired." : "The " + phase + " exceeded its 10-second deadline."; }
        catch (EndOfStreamException) { detail = "The peer closed the connection during " + phase + ". Last packet type: " + lastType; }
        catch (Exception ex) { detail = phase + ": " + ex.GetType().Name + ": " + ex.Message + ". Last packet type: " + lastType; }
        finally {
            Record((session?.Remote.Name ?? dialTarget?.Name ?? "Incoming peer") + ": " + detail);
            if (handshakeHeld) handshakes.Release();
            if (session is not null) {
                await session.Gate.WaitAsync();
                try {
                    session.StopTransfers("Connection closed."); session.Closed = true; session.Pairing.Reset();
                    await state.WaitAsync();
                    try {
                        sessions.Remove(session.Remote.DeviceId, session);
                    } finally { state.Release(); }
                    await NotifyPeerAsync(session, "Disconnected from " + session.Remote.Name, detail);
                }
                finally { session.Gate.Release(); }
            }
            if (dialTarget is not null) {
                await state.WaitAsync();
                try { dialing.Remove(dialTarget.DeviceId); } finally { state.Release(); }
            }
            authenticated?.TrySetException(new IOException(detail));
            // Pair/transfer actions use this certificate under session.Gate.
            // Keep it alive until cleanup has marked the session closed.
            certificate?.Dispose();
        }
    }
    private async Task<PeerSession> RequireSessionAsync(string id, string? connectionId = null)
    {
        var session = await GetSessionAsync(id) ?? throw new IOException("This device is not connected. Select it and Connect first.");
        if (connectionId is not null && session.Id != connectionId) throw new IOException("The connection changed. Compare the current key again.");
        return session;
    }
    private async Task EnsureCurrentAsync(PeerSession session)
    {
        if (session.Closed || !ReferenceEquals(await GetSessionAsync(session.Remote.DeviceId), session))
            throw new IOException("This device's connection changed. Select its current pairing request again.");
    }
    public async Task RequestPairAsync(string deviceId)
    {
        var session = await RequireSessionAsync(deviceId);
        await session.Gate.WaitAsync(shutdown.Token);
        try {
            await EnsureCurrentAsync(session);
            if (session.Closed || session.Paired || session.Pairing.Key.Length > 0) throw new IOException("This device is disconnected, already paired, or has a pending pairing.");
            var now = DateTimeOffset.UtcNow;
            session.Pairing.Begin(own, session.Certificate, session.Id, now.ToUnixTimeSeconds(), now, outgoing: true);
            try { await SendAsync(session, Packet.Create("flux.pair", new { pair = true, timestamp = now.ToUnixTimeSeconds() })); }
            catch { session.Pairing.Reset(); throw; }
            await NotifyPeerAsync(session, "Pair with " + session.Remote.Name, "Accept the matching key on this device, then confirm it here within 30 seconds.");
            _ = ExpireAsync(session, session.Pairing.Key);
        } finally { session.Gate.Release(); }
    }
    private async Task ExpireAsync(PeerSession session, string key)
    {
        try {
            await Task.Delay(TimeSpan.FromSeconds(30), shutdown.Token);
            await session.Gate.WaitAsync(shutdown.Token);
            try {
                if (!session.Closed && !session.Paired && session.Pairing.Key == key && ReferenceEquals(await GetSessionAsync(session.Remote.DeviceId), session)) {
                    session.Pairing.Reset();
                    await SendAsync(session, Packet.Create("flux.pair", new { pair = false }));
                    await NotifyPeerAsync(session, "Pairing expired for " + session.Remote.Name, "Key comparison was not completed within 30 seconds. Other devices are unaffected.");
                }
            } finally { session.Gate.Release(); }
        } catch (OperationCanceledException) { }
        catch (Exception ex) { Record("Pairing timer: " + ex.GetType().Name + ": " + ex.Message); }
    }
    private void SavePins()
    {
        Save(Path.Combine(directory, "trust.json"), JsonSerializer.SerializeToUtf8Bytes(pins));
        SavedPairsChanged?.Invoke(pins.Keys.ToArray());
    }
    private async Task RememberPeerAsync(PeerSession session)
    {
        await state.WaitAsync(shutdown.Token);
        try {
            if (!pins.ContainsKey(session.Remote.DeviceId)) return;
            savedPeers[session.Remote.DeviceId] = new(session.Remote.DeviceId, session.Remote.Name, session.Address.ToString(), session.Port);
            try { Save(Path.Combine(directory, "peers.json"), JsonSerializer.SerializeToUtf8Bytes(savedPeers));
                SavedPeersChanged?.Invoke(SavedPeers); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
                Record("Could not save device display metadata: " + ex.GetType().Name);
            }
        } finally { state.Release(); }
    }
    // Call only while state is held. Session registration and trust removal
    // share this lock, so a handshake cannot inherit a pin being forgotten.
    private void RemovePinLocked(string id)
    {
        pins.TryRemove(id, out var oldPin);
        try { SavePins(); }
        catch { if (oldPin is not null) pins[id] = oldPin; throw; }
        savedPeers.Remove(id);
        SetThemeLocked(id, null, null);
        try { Save(Path.Combine(directory, "peers.json"), JsonSerializer.SerializeToUtf8Bytes(savedPeers)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) {
            Record("Could not remove device display metadata: " + ex.GetType().Name);
        }
        SavedPeersChanged?.Invoke(SavedPeers);
    }
    private async Task RemovePinAsync(string id)
    {
        await state.WaitAsync(shutdown.Token);
        try { RemovePinLocked(id); } finally { state.Release(); }
    }
    private async Task<bool> RevokeCurrentTrustAsync(PeerSession session, string reason)
    {
        await state.WaitAsync(shutdown.Token);
        try {
            if (session.Closed || !ReferenceEquals(sessions.Get(session.Remote.DeviceId), session)) return false;
            if (pins.ContainsKey(session.Remote.DeviceId)) RemovePinLocked(session.Remote.DeviceId);
            session.RevokeTransfers(reason);
            session.Paired = false;
            session.Reads.SetPaired(false);
            return true;
        } finally { state.Release(); }
    }
    public async Task ForgetAsync(string deviceId)
    {
        while (true) {
            var session = await GetSessionAsync(deviceId);
            if (session is null) {
                await state.WaitAsync(shutdown.Token);
                try {
                    if (sessions.Get(deviceId) is not null) continue;
                    if (!pins.ContainsKey(deviceId)) throw new IOException("This device has no saved pairing.");
                    RemovePinLocked(deviceId);
                    break;
                } finally { state.Release(); }
            }
            await session.Gate.WaitAsync(shutdown.Token);
            try {
                await state.WaitAsync(shutdown.Token);
                try {
                    if (!ReferenceEquals(sessions.Get(deviceId), session) || session.Closed) continue;
                    if (!pins.ContainsKey(deviceId)) throw new IOException("This device has no saved pairing.");
                    RemovePinLocked(deviceId);
                    session.RevokeTransfers("Pairing removed.");
                    session.Paired = false;
                    session.Pairing.Reset(); session.Reads.SetPaired(false);
                } finally { state.Release(); }
                break;
            } finally { session.Gate.Release(); }
        }
        await NotifyForgottenPeerAsync(deviceId);
    }
    private async Task NotifyForgottenPeerAsync(string deviceId)
    {
        // The authenticated socket may be replaced after trust removal.
        // Recheck the current socket and retry if it changes during notice.
        for (var attempt = 0; attempt < 3; attempt++) {
            var session = await GetSessionAsync(deviceId);
            if (session is null) return;
            await session.Gate.WaitAsync(shutdown.Token);
            try {
                if (session.Closed || !ReferenceEquals(await GetSessionAsync(deviceId), session)) continue;
                if (pins.ContainsKey(deviceId)) return; // A fresh pairing won the race.
                try { await SendAsync(session, Packet.Create("flux.pair", new { pair = false })); }
                catch (Exception ex) { Record("Could not notify forgotten peer: " + ex.GetType().Name); }
                await NotifyPeerAsync(session, "Pairing removed", "This device must pair again before sharing files.");
            } finally { session.Gate.Release(); }
            if (ReferenceEquals(await GetSessionAsync(deviceId), session)) return;
        }
    }
    private async Task SendAsync(PeerSession session, Packet packet, CancellationToken ct = default)
    {
        if (session.Closed) throw new IOException("This device's connection ended.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token, ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        await session.Write.WaitAsync(timeout.Token);
        try {
            await session.Stream.WriteAsync(packet.Encode(), timeout.Token);
        } finally { session.Write.Release(); }
    }
    public async Task AcceptAsync(string deviceId, string connectionId, string displayedKey)
    {
        var session = await RequireSessionAsync(deviceId, connectionId);
        await session.Gate.WaitAsync(shutdown.Token);
        try {
            await EnsureCurrentAsync(session);
            if (session.Closed || !session.Pairing.CanAccept(displayedKey, session.Certificate, session.Id, DateTimeOffset.UtcNow))
                throw new IOException("The pairing expired or the connection changed.");
            await state.WaitAsync(shutdown.Token);
            try {
                pins[deviceId] = Convert.ToBase64String(session.Certificate.RawData);
                try { SavePins(); } catch { pins.TryRemove(deviceId, out _); throw; }
            } finally { state.Release(); }
            if (!session.Pairing.IsOutgoing) {
                try { await SendAsync(session, Packet.Create("flux.pair", new { pair = true })); }
                catch { await RemovePinAsync(deviceId); throw; }
            }
            session.Reads.SetPaired(true); session.Paired = true; session.Pairing.Reset();
            await RememberPeerAsync(session);
            await NotifyPeerAsync(session, "Paired with " + session.Remote.Name, "Pairing is saved for this device. Other connections remain open.");
        } finally { session.Gate.Release(); }
    }
    public async Task RejectAsync(string deviceId, string connectionId)
    {
        var session = await RequireSessionAsync(deviceId, connectionId);
        await session.Gate.WaitAsync(shutdown.Token);
        try {
            await EnsureCurrentAsync(session);
            if (session.Closed || session.Pairing.Key.Length == 0) throw new IOException("There is no current pairing to reject on this device.");
            session.Pairing.Reset(); await SendAsync(session, Packet.Create("flux.pair", new { pair = false }));
            await NotifyPeerAsync(session, "Pairing rejected for " + session.Remote.Name, "No other device was changed.");
        } finally { session.Gate.Release(); }
    }
    private async Task QueueReceiveAsync(PeerSession session, Packet packet)
    {
        if (packet.PayloadTransferInfo is null) return; // Text/link sharing is outside this milestone.
        await session.Gate.WaitAsync(shutdown.Token);
        var reserved = false;
        try {
            if (!session.Paired || session.Closed || !ReferenceEquals(await GetSessionAsync(session.Remote.DeviceId), session)) {
                Record("Ignored file from an unpaired or stale connection."); return;
            }
            try { FilePayload.Validate(packet); }
            catch (Exception ex) { Record("Invalid file announcement: " + ex.Message); return; }
            if (!await session.FileSlots.WaitAsync(0, shutdown.Token)) { Record("File receive refused: four transfers are already active for this device."); return; }
            reserved = true;
            var expected = session.Certificate.RawData;
            var epoch = session.TransferLifetime;
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token, session.Reads.Token, epoch.Source.Token);
            _ = TransferAsync(session, null, packet, expected, cancellation, epoch);
            reserved = false;
        } finally { if (reserved) session.FileSlots.Release(); session.Gate.Release(); }
    }
    public async Task SendFileAsync(string deviceId, string path)
    {
        var session = await RequireSessionAsync(deviceId);
        await session.Gate.WaitAsync(shutdown.Token);
        byte[] expected;
        CancellationTokenSource cancellation;
        TransferEpoch epoch;
        var reserved = false;
        try {
            await EnsureCurrentAsync(session);
            if (!session.Paired) throw new IOException("Pair this device before sending a file.");
            if (!await session.FileSlots.WaitAsync(0, shutdown.Token)) throw new IOException("Four file transfers are already active for this device.");
            reserved = true;
            expected = session.Certificate.RawData;
            epoch = session.TransferLifetime;
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token, session.Reads.Token, epoch.Source.Token);
            reserved = false;
        } finally { if (reserved) session.FileSlots.Release(); session.Gate.Release(); }
        await TransferAsync(session,path,null,expected,cancellation,epoch);
    }
    private async Task TransferAsync(PeerSession session, string? path, Packet? packet, byte[] expected,
        CancellationTokenSource cancellation, TransferEpoch epoch)
    {
        using (cancellation) {
            var view = new FileTransferView(Guid.NewGuid().ToString("N"), session.Remote.DeviceId, session.Remote.Name,
                path is null ? "Incoming file" : "Outgoing file",
                path is null ? "Received" : "Sent",0,packet?.PayloadSize ?? 0,path is null ? "Receiving" : "Sending");
            var last = DateTimeOffset.MinValue;
            void Progress(long bytes) {
                view = view with {Bytes=bytes};
                if (DateTimeOffset.UtcNow-last > TimeSpan.FromMilliseconds(250)) { last=DateTimeOffset.UtcNow; TransferChanged?.Invoke(view); }
            }
            try {
                view = view with {Name=path is null ? FilePayload.SafeName(packet!.Body.GetProperty("filename").GetString()!)
                    : System.IO.Path.GetFileName(path)};
                activeTransfers[view.Id] = cancellation;
                if (path is not null) view = view with {Size=new FileInfo(path).Length};
                TransferChanged?.Invoke(view);
                var received = "";
                if (path is null) received = await FilePayload.ReceiveAsync(packet!,ReceiveDirectory,own,expected,session.LocalAddress,session.Address,
                    p => SendAsync(session,p,cancellation.Token),() => session.Paired && !session.Closed,Progress,cancellation.Token);
                else await FilePayload.SendAsync(path,own,expected,session.LocalAddress,session.Address,
                    p => SendAsync(session,p,cancellation.Token),() => session.Paired && !session.Closed,Progress,cancellation.Token,
                    session.Remote.CanTunnel ? (p,id,ct) => OpenFileTunnelAsync(session,p,id,ct) : null);
                view = view with {Status=path is null ? "Saved" : "Sent — receipt not confirmed",Path=received,Bytes=view.Size};
            } catch (Exception ex) {
                var cancelledByUser = userCancelledTransfers.ContainsKey(view.Id);
                view = view.WithFailure(ex, cancelledByUser, epoch, shutdown.IsCancellationRequested);
                Record("File transfer failed: " + ex.GetType().Name + ": " + ex.Message);
            } finally {
                activeTransfers.TryRemove(view.Id, out _);
                userCancelledTransfers.TryRemove(view.Id, out _);
                session.FileSlots.Release(); TransferChanged?.Invoke(view);
            }
        }
    }
    public bool CancelTransfer(string transferId)
    {
        if (!activeTransfers.TryGetValue(transferId, out var cancellation)) return false;
        userCancelledTransfers.TryAdd(transferId, 0);
        try { cancellation.Cancel(); return true; }
        catch (ObjectDisposedException) { userCancelledTransfers.TryRemove(transferId, out _); return false; }
    }
    private async Task<int> OpenFileTunnelAsync(PeerSession session, Packet packet, string id, CancellationToken ct)
    {
        var waiting = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!session.Tunnels.TryAdd(id,waiting)) throw new IOException("Duplicate file tunnel token.");
        try {
            await SendAsync(session,packet,ct);
            return await waiting.Task.WaitAsync(TimeSpan.FromSeconds(30),ct);
        } finally { session.Tunnels.TryRemove(id,out _); }
    }
    public void Dispose()
    {
        shutdown.Cancel(); listener?.Stop(); udp?.Dispose(); discovery?.Dispose();
        // Cancellation stops each read independently. RunAsync owns and closes
        // its socket, TLS stream and peer certificate; no shared link is closed.
    }
}
