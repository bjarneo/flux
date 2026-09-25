package lan

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"syscall"
	"time"

	"flux/internal/proto"
)

// Config connects the provider to the daemon.
type Config struct {
	Cert tls.Certificate
	// Identity returns the current identity of this device. The provider
	// sets the TCP port.
	Identity func() proto.Identity
	// Trusted returns the pinned certificate of a paired device.
	Trusted func(deviceID string) (*x509.Certificate, bool)
	// HasLink reports whether a live link to the device exists. The
	// provider does not start a second connection for that device.
	HasLink func(deviceID string) bool
	// OnLink receives each new authenticated link.
	OnLink func(*Link)
	// OnIdentity receives each identity seen by UDP. The daemon uses it to
	// list devices that are not paired yet.
	OnIdentity func(id proto.Identity, ip string)
	Logf       func(format string, args ...any)
	// UDPPort and FirstTCPPort change the protocol ports for tests. Zero
	// means 1716.
	UDPPort      int
	FirstTCPPort int
	// LoopbackOnly sends broadcasts to 127.255.255.255 only. Tests use it,
	// so no packet leaves the computer.
	LoopbackOnly bool
}

// Provider owns the discovery socket and the TCP listener.
type Provider struct {
	cfg     Config
	tcp     *net.TCPListener
	udp     *net.UDPConn
	tcpPort int

	mu       sync.Mutex
	attempts map[string]time.Time
}

// New returns a provider. Call Start to open the sockets.
func New(cfg Config) *Provider {
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	if cfg.UDPPort == 0 {
		cfg.UDPPort = UDPPort
	}
	if cfg.FirstTCPPort == 0 {
		cfg.FirstTCPPort = MinTCPPort
	}
	return &Provider{cfg: cfg, attempts: map[string]time.Time{}}
}

func (p *Provider) logf(format string, args ...any) { p.cfg.Logf(format, args...) }

// TCPPort returns the port of the TCP listener.
func (p *Provider) TCPPort() int { return p.tcpPort }

var keepAlive = net.KeepAliveConfig{Enable: true, Idle: 10 * time.Second, Interval: 5 * time.Second, Count: 3}

// reuseAddr sets SO_REUSEADDR and SO_BROADCAST on a socket.
func reuseAddr(_, _ string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		if serr == nil {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
		}
	})
	if err != nil {
		return err
	}
	return serr
}

// Start opens the TCP listener on the first free port from 1716 to 1764
// and the UDP discovery socket on port 1716.
func (p *Provider) Start(ctx context.Context) error {
	lc := net.ListenConfig{KeepAliveConfig: keepAlive}
	for port := p.cfg.FirstTCPPort; port <= max(MaxTCPPort, p.cfg.FirstTCPPort+48); port++ {
		l, err := lc.Listen(ctx, "tcp", fmt.Sprintf(":%d", port))
		if err == nil {
			p.tcp = l.(*net.TCPListener)
			p.tcpPort = port
			break
		}
	}
	if p.tcp == nil {
		return fmt.Errorf("no free TCP port from %d to %d", p.cfg.FirstTCPPort, MaxTCPPort)
	}
	ulc := net.ListenConfig{Control: reuseAddr}
	uc, err := ulc.ListenPacket(ctx, "udp4", fmt.Sprintf(":%d", p.cfg.UDPPort))
	if err != nil {
		p.tcp.Close()
		return fmt.Errorf("UDP port %d: %w", p.cfg.UDPPort, err)
	}
	p.udp = uc.(*net.UDPConn)
	go p.acceptLoop(ctx)
	go p.udpLoop(ctx)
	go func() {
		<-ctx.Done()
		p.tcp.Close()
		p.udp.Close()
	}()
	return nil
}

// udpIdentity returns the identity for UDP. Only this form has tcpPort.
func (p *Provider) udpIdentity() *proto.Packet {
	id := p.cfg.Identity()
	id.TCPPort = p.tcpPort
	return proto.New(proto.TypeIdentity, id)
}

// plainIdentity returns the identity that the connecting side writes
// before TLS. It names the device that it answers.
func (p *Provider) plainIdentity(target proto.Identity) *proto.Packet {
	id := p.cfg.Identity()
	// tcpPort lets the peer connect back later without UDP. KDE Connect
	// peers ignore it here.
	id.TCPPort = p.tcpPort
	id.TargetDeviceID = target.DeviceID
	id.TargetProtocolVersion = proto.ProtocolVersion
	return proto.New(proto.TypeIdentity, id)
}

// secureIdentity returns the identity that both sides write after TLS.
func (p *Provider) secureIdentity() *proto.Packet {
	return proto.New(proto.TypeIdentity, p.cfg.Identity())
}

// Broadcast sends the identity to every IPv4 broadcast address.
func (p *Provider) Broadcast() {
	line, err := p.udpIdentity().Marshal()
	if err != nil || p.udp == nil {
		return
	}
	addrs := broadcastAddrs()
	if p.cfg.LoopbackOnly {
		addrs = []net.IP{net.IPv4(127, 255, 255, 255)}
	}
	for _, addr := range addrs {
		if _, err := p.udp.WriteToUDP(line, &net.UDPAddr{IP: addr, Port: p.cfg.UDPPort}); err != nil {
			p.logf("broadcast to %s: %v", addr, err)
		}
	}
}

// Announce sends the identity to one address. The daemon calls it for the
// last known address of each paired device.
func (p *Provider) Announce(ip string) {
	if addr := net.ParseIP(ip); addr != nil {
		p.AnnounceTo(&net.UDPAddr{IP: addr, Port: p.cfg.UDPPort})
	}
}

// AnnounceTo sends the identity to one UDP address.
func (p *Provider) AnnounceTo(addr *net.UDPAddr) {
	if p.udp == nil {
		return
	}
	if line, err := p.udpIdentity().Marshal(); err == nil {
		_, _ = p.udp.WriteToUDP(line, addr)
	}
}

func broadcastAddrs() []net.IP {
	out := []net.IP{net.IPv4bcast}
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagBroadcast == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP.To4() == nil {
				continue
			}
			ip, mask := ipn.IP.To4(), ipn.Mask
			if len(mask) == 16 {
				mask = mask[12:]
			}
			b := make(net.IP, 4)
			for i := range b {
				b[i] = ip[i] | ^mask[i]
			}
			out = append(out, b)
		}
	}
	return out
}

func (p *Provider) udpLoop(ctx context.Context) {
	buf := make([]byte, maxIdentitySize)
	own := p.cfg.Identity().DeviceID
	for {
		n, from, err := p.udp.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		pkt, err := proto.Unmarshal(bytes.TrimSpace(buf[:n]))
		if err != nil || pkt.Type != proto.TypeIdentity {
			continue
		}
		var id proto.Identity
		if pkt.Decode(&id) != nil || id.DeviceID == own || !proto.ValidDeviceID(id.DeviceID) || id.TCPPort == 0 {
			continue
		}
		ip := from.IP.String()
		if p.cfg.OnIdentity != nil {
			p.cfg.OnIdentity(id, ip)
		}
		if p.cfg.HasLink(id.DeviceID) || !p.shouldAttempt(id.DeviceID) {
			continue
		}
		go p.connect(ctx, ip, id)
	}
}

// shouldAttempt limits outgoing connections to 1 per device each second.
func (p *Provider) shouldAttempt(deviceID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if t, ok := p.attempts[deviceID]; ok && time.Since(t) < time.Second {
		return false
	}
	p.attempts[deviceID] = time.Now()
	return true
}

// Dial opens a link to a device at a known address, for example one that
// mDNS found or the last address of a paired device. This computer opens
// the connection, so it passes a firewall that blocks incoming traffic.
// target needs DeviceID and ProtocolVersion.
func (p *Provider) Dial(ctx context.Context, ip string, port int, target proto.Identity) {
	if port <= 0 || port > 65535 || !proto.ValidDeviceID(target.DeviceID) {
		return
	}
	if target.DeviceID == p.cfg.Identity().DeviceID || p.cfg.HasLink(target.DeviceID) || !p.shouldAttempt(target.DeviceID) {
		return
	}
	if target.ProtocolVersion == 0 {
		target.ProtocolVersion = proto.ProtocolVersion
	}
	target.TCPPort = port
	go p.connect(ctx, ip, target)
}

// connect answers a UDP identity. This side opens the TCP connection, sends
// its identity in plain text, and then acts as the TLS server.
func (p *Provider) connect(ctx context.Context, ip string, udpID proto.Identity) {
	d := net.Dialer{Timeout: 5 * time.Second, KeepAliveConfig: keepAlive}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(ip, fmt.Sprint(udpID.TCPPort)))
	if err != nil {
		p.logf("connect to %s (%s): %v", udpID.DeviceName, ip, err)
		// A failed attempt must not block the next trigger, for example the
		// UDP broadcast of a device that starts a moment later.
		p.mu.Lock()
		delete(p.attempts, udpID.DeviceID)
		p.mu.Unlock()
		return
	}
	line, _ := p.plainIdentity(udpID).Marshal()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(line); err != nil {
		conn.Close()
		return
	}
	tc := tls.Server(conn, serverConfig(p.cfg.Cert))
	p.finish(tc, udpID, true)
}

func (p *Provider) acceptLoop(ctx context.Context) {
	for {
		conn, err := p.tcp.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go p.accept(conn)
	}
}

// accept handles a TCP connection from a device that received our UDP
// broadcast. The device sends its identity in plain text, and this side
// acts as the TLS client.
func (p *Provider) accept(conn net.Conn) {
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	r := bufio.NewReaderSize(conn, 4096)
	line, err := readLine(r, maxIdentitySize)
	if err != nil {
		conn.Close()
		return
	}
	pkt, err := proto.Unmarshal(line)
	if err != nil || pkt.Type != proto.TypeIdentity {
		conn.Close()
		return
	}
	var id proto.Identity
	own := p.cfg.Identity().DeviceID
	if pkt.Decode(&id) != nil || !proto.ValidDeviceID(id.DeviceID) || id.DeviceID == own {
		conn.Close()
		return
	}
	// A peer that names a target must name this device.
	if (id.TargetDeviceID != "" && id.TargetDeviceID != own) || (id.TargetProtocolVersion != nil && id.TargetVersion() != proto.ProtocolVersion) {
		conn.Close()
		return
	}
	if r.Buffered() > 0 {
		// The TLS handshake must start on a clean stream.
		conn.Close()
		return
	}
	tc := tls.Client(conn, clientConfig(p.cfg.Cert))
	p.finish(tc, id, false)
}

// finish runs the TLS handshake, checks the certificate, and exchanges the
// identity again over TLS for protocol version 8.
func (p *Provider) finish(tc *tls.Conn, plainID proto.Identity, outgoing bool) {
	fail := func(format string, args ...any) {
		p.logf("%s: "+format, append([]any{plainID.DeviceName}, args...)...)
		tc.Close()
	}
	if err := tc.Handshake(); err != nil {
		fail("TLS handshake: %v", err)
		return
	}
	cert, err := peerCert(tc)
	if err != nil {
		fail("%v", err)
		return
	}
	if cert.Subject.CommonName != plainID.DeviceID {
		fail("certificate CN %q does not match device ID", cert.Subject.CommonName)
		return
	}
	if pinned, ok := p.cfg.Trusted(plainID.DeviceID); ok && !bytes.Equal(pinned.Raw, cert.Raw) {
		fail("certificate changed since pairing, link refused")
		return
	}
	reader := bufio.NewReaderSize(tc, 64<<10)
	id := plainID
	if plainID.ProtocolVersion >= 8 {
		line, _ := p.secureIdentity().Marshal()
		if _, err := tc.Write(line); err != nil {
			fail("send identity: %v", err)
			return
		}
		raw, err := readLine(reader, maxIdentitySize)
		if err != nil {
			fail("read identity: %v", err)
			return
		}
		pkt, err := proto.Unmarshal(raw)
		if err != nil || pkt.Type != proto.TypeIdentity {
			fail("expected identity after TLS")
			return
		}
		var secure proto.Identity
		if err := json.Unmarshal(pkt.Body, &secure); err != nil || secure.DeviceID != plainID.DeviceID || secure.ProtocolVersion != plainID.ProtocolVersion {
			fail("identity after TLS does not match")
			return
		}
		id = secure
	}
	_ = tc.SetDeadline(time.Time{})
	id.DeviceName = proto.CleanName(id.DeviceName)
	link := newLink(p, tc, reader, id, cert, outgoing)
	// The listener port of the peer: the port that this side dialed, or the
	// port that the peer put in its plain identity.
	link.PeerPort = plainID.TCPPort
	p.cfg.OnLink(link)
}
