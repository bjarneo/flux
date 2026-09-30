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
	"slices"
	"strconv"
	"strings"
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
	// Trusted returns the certificate that a link of the device must
	// present: the pinned certificate of a paired device, or the
	// certificate of an open pairing. ok is false when any certificate can
	// link. A nil certificate with ok true refuses every link.
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

	// FreePorts makes Start listen on TCP and UDP ports that the system
	// picks. Tests use it, so that test runs at the same time do not share
	// ports. TCPPort and UDPPort return the ports.
	FreePorts bool
}

// Limits for connections that are not links yet. maxHandshakes is the
// number of incoming connections that can wait for their identity and
// their TLS handshake at the same time. maxHandshakesPerIP is the part of
// 1 address. maxDials is the number of outgoing connections to devices
// without a pin that can run at the same time.
const (
	maxHandshakes      = 32
	maxHandshakesPerIP = 4
	maxDials           = 16
)

// attemptWindow is the time in which the provider opens at most 1
// connection to a device.
const attemptWindow = time.Second

// Provider owns the discovery socket and the TCP listener.
type Provider struct {
	cfg     Config
	tcp     *net.TCPListener
	udp     *net.UDPConn
	tcpPort int
	// selfID returns the device ID of this computer. The ID does not change
	// while the daemon runs, so the provider reads it once.
	selfID func() string

	mu       sync.Mutex
	attempts map[string]time.Time

	// pruned is the last time that shouldAttempt removed old attempts.
	// handshakes and perIP count the incoming connections before their
	// link, and dials holds 1 token for each outgoing connection to a
	// device without a pin. udpPort is the port of the discovery socket.
	// anyPort is true when a peer can listen outside MinTCPPort to
	// MaxTCPPort, for tests and development.
	pruned     time.Time
	handshakes int
	perIP      map[string]int
	dials      chan struct{}
	udpPort    int
	anyPort    bool
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
	p := &Provider{cfg: cfg, attempts: map[string]time.Time{}, perIP: map[string]int{}, dials: make(chan struct{}, maxDials)}
	p.selfID = sync.OnceValue(func() string { return p.cfg.Identity().DeviceID })
	// A daemon with other ports runs next to another daemon on 1 computer,
	// for a test or for development. Its peers use other ports too.
	p.anyPort = cfg.FreePorts || cfg.FirstTCPPort != MinTCPPort
	return p
}

func (p *Provider) logf(format string, args ...any) { p.cfg.Logf(format, args...) }

// TCPPort returns the port of the TCP listener.
func (p *Provider) TCPPort() int { return p.tcpPort }

// UDPPort returns the port of the discovery socket.
func (p *Provider) UDPPort() int { return p.udpPort }

// peerPort reports whether a device can listen on port. Flux devices
// listen on a port from MinTCPPort to MaxTCPPort, so discovery cannot make
// fluxd connect to another service.
func (p *Provider) peerPort(port int) bool {
	if port <= 0 || port > 65535 {
		return false
	}
	return p.anyPort || (port >= MinTCPPort && port <= MaxTCPPort)
}

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
	first, last, udpPort := p.cfg.FirstTCPPort, max(MaxTCPPort, p.cfg.FirstTCPPort+48), p.cfg.UDPPort
	if p.cfg.FreePorts {
		first, last, udpPort = 0, 0, 0
	}
	for port := first; port <= last; port++ {
		l, err := lc.Listen(ctx, "tcp", fmt.Sprintf(":%d", port))
		if err == nil {
			p.tcp = l.(*net.TCPListener)
			p.tcpPort = p.tcp.Addr().(*net.TCPAddr).Port
			break
		}
	}
	if p.tcp == nil {
		return fmt.Errorf("no free TCP port from %d to %d", p.cfg.FirstTCPPort, MaxTCPPort)
	}
	ulc := net.ListenConfig{Control: reuseAddr}
	uc, err := ulc.ListenPacket(ctx, "udp4", fmt.Sprintf(":%d", udpPort))
	if err != nil {
		p.tcp.Close()
		return fmt.Errorf("UDP port %d: %w", udpPort, err)
	}
	p.udp = uc.(*net.UDPConn)
	p.udpPort = p.udp.LocalAddr().(*net.UDPAddr).Port
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
	// tcpPort lets the peer connect back later without UDP.
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
	all, _ := net.Interfaces()
	var ifaces []net.Interface
	for _, ifc := range all {
		if ifc.Flags&net.FlagUp != 0 && ifc.Flags&net.FlagBroadcast != 0 && ifc.Flags&net.FlagLoopback == 0 {
			ifaces = append(ifaces, ifc)
		}
	}
	nets := ipv4Nets(ifaces)
	for _, ifc := range ifaces {
		for _, ipn := range nets[ifc.Index] {
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

// interfaceNets returns the IPv4 networks of ifaces by interface index. It
// asks the system once for each interface.
func interfaceNets(ifaces []net.Interface) map[int][]*net.IPNet {
	out := map[int][]*net.IPNet{}
	for _, ifc := range ifaces {
		addrs, _ := ifc.Addrs()
		for _, a := range addrs {
			if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
				out[ifc.Index] = append(out[ifc.Index], ipn)
			}
		}
	}
	return out
}

func (p *Provider) udpLoop(ctx context.Context) {
	buf := make([]byte, maxIdentitySize)
	own := p.selfID()
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
		if pkt.Decode(&id) != nil || id.DeviceID == own || !proto.ValidDeviceID(id.DeviceID) || !p.peerPort(id.TCPPort) {
			continue
		}
		ip := from.IP.String()
		if p.cfg.OnIdentity != nil {
			p.cfg.OnIdentity(id, ip)
		}
		p.DialAddrs(ctx, []string{net.JoinHostPort(ip, strconv.Itoa(id.TCPPort))}, id)
	}
}

// shouldAttempt limits outgoing connections to 1 per device each second.
// Once a second it removes the entries that are older than that, so that
// the map holds only the devices of the last seconds.
func (p *Provider) shouldAttempt(deviceID string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if now.Sub(p.pruned) >= attemptWindow {
		for id, t := range p.attempts {
			if now.Sub(t) >= attemptWindow {
				delete(p.attempts, id)
			}
		}
		p.pruned = now
	}
	if t, ok := p.attempts[deviceID]; ok && now.Sub(t) < attemptWindow {
		return false
	}
	p.attempts[deviceID] = now
	return true
}

// forgetAttempt lets the next trigger connect to the device at once.
func (p *Provider) forgetAttempt(deviceID string) {
	p.mu.Lock()
	delete(p.attempts, deviceID)
	p.mu.Unlock()
}

// Dial opens a link to a device at a known address, for example one that
// mDNS found or the last address of a paired device. This computer opens
// the connection, so it passes a firewall that blocks incoming traffic.
// target needs DeviceID and ProtocolVersion.
func (p *Provider) Dial(ctx context.Context, ip string, port int, target proto.Identity) {
	p.DialAny(ctx, []string{ip}, port, target)
}

// DialAny opens a link to a device that listens on port at one of hosts.
// Each host is an IP address or a host name, for example the last address
// of a paired device and its Tailscale name. DialAny prefers the first
// host. See dialFirst for the order.
func (p *Provider) DialAny(ctx context.Context, hosts []string, port int, target proto.Identity) {
	addrs := make([]string, 0, len(hosts))
	for _, h := range hosts {
		addrs = append(addrs, net.JoinHostPort(h, strconv.Itoa(port)))
	}
	p.DialAddrs(ctx, addrs, target)
}

// DialAddrs opens a link to a device at one of addrs. Each address is a
// host and a port, for example the last address of a paired device and an
// address that discovery reported. DialAddrs prefers the first address and
// skips an address whose port is not a Flux port. At most maxDials
// connections to devices without a pin run at the same time. A dial to a
// paired device or to a device with an open pairing takes no token, so
// that devices on the network cannot hold every token and keep the paired
// devices offline.
func (p *Provider) DialAddrs(ctx context.Context, addrs []string, target proto.Identity) {
	var ok []string
	for _, a := range addrs {
		_, port, err := net.SplitHostPort(a)
		if n, _ := strconv.Atoi(port); err == nil && p.peerPort(n) && !slices.Contains(ok, a) {
			ok = append(ok, a)
		}
	}
	if len(ok) == 0 || !proto.ValidDeviceID(target.DeviceID) {
		return
	}
	if target.DeviceID == p.selfID() || p.cfg.HasLink(target.DeviceID) || !p.shouldAttempt(target.DeviceID) {
		return
	}
	_, pinned := p.cfg.Trusted(target.DeviceID)
	if !pinned {
		select {
		case p.dials <- struct{}{}:
		default:
			// The next trigger tries again.
			p.forgetAttempt(target.DeviceID)
			return
		}
	}
	if target.ProtocolVersion == 0 {
		target.ProtocolVersion = proto.ProtocolVersion
	}
	go func() {
		if !pinned {
			defer func() { <-p.dials }()
		}
		p.connect(ctx, ok, target)
	}()
}

// connect opens a link to a device that listens at one of addrs. This side
// opens the TCP connection, sends its identity in plain text, and then acts
// as the TLS server. When an address accepts the TCP connection but the
// link fails, connect tries the other addresses. A different device can use
// the old address of the phone on another network.
func (p *Provider) connect(ctx context.Context, addrs []string, target proto.Identity) {
	d := net.Dialer{Timeout: 5 * time.Second, KeepAliveConfig: keepAlive}
	for len(addrs) > 0 {
		conn, i, err := dialFirst(ctx, &d, addrs)
		if err != nil {
			p.logf("connect to %s (%s): %v", proto.CleanName(target.DeviceName), strings.Join(addrs, ", "), err)
			// A failed attempt must not block the next trigger, for example the
			// UDP broadcast of a device that starts a moment later.
			p.forgetAttempt(target.DeviceID)
			return
		}
		// The port that answered is the listener port of the peer.
		_, port, _ := net.SplitHostPort(addrs[i])
		target.TCPPort, _ = strconv.Atoi(port)
		if p.open(conn, target) || p.cfg.HasLink(target.DeviceID) {
			// A link is up, so HasLink stops the next dials. After the link
			// drops, the next trigger can connect at once.
			p.forgetAttempt(target.DeviceID)
			return
		}
		addrs = slices.Delete(addrs, i, i+1)
	}
}

// open writes the plain identity on a new outgoing connection and runs the
// TLS handshake as the server. It reports whether the link is up.
func (p *Provider) open(conn net.Conn, udpID proto.Identity) bool {
	setUserTimeout(conn)
	line, _ := p.plainIdentity(udpID).Marshal()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := conn.Write(line); err != nil {
		conn.Close()
		return false
	}
	tc := tls.Server(conn, serverConfig(p.cfg.Cert))
	return p.finish(tc, udpID, true)
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
		host := remoteHost(conn)
		if !p.startHandshake(host) {
			conn.Close()
			continue
		}
		go func() {
			defer p.endHandshake(host)
			p.accept(conn)
		}()
	}
}

// startHandshake reserves a place for 1 incoming connection from host. It
// reports false when too many connections wait for their link, in total or
// from host.
func (p *Provider) startHandshake(host string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.handshakes >= maxHandshakes || p.perIP[host] >= maxHandshakesPerIP {
		return false
	}
	p.handshakes++
	p.perIP[host]++
	return true
}

// endHandshake frees the place of startHandshake.
func (p *Provider) endHandshake(host string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.handshakes--
	if p.perIP[host]--; p.perIP[host] <= 0 {
		delete(p.perIP, host)
	}
}

// remoteHost returns the IP address of the peer of conn.
func remoteHost(conn net.Conn) string {
	if a, ok := conn.RemoteAddr().(*net.TCPAddr); ok {
		return a.IP.String()
	}
	return conn.RemoteAddr().String()
}

// accept handles a TCP connection from a device that received our UDP
// broadcast. The device sends its identity in plain text, and this side
// acts as the TLS client.
func (p *Provider) accept(conn net.Conn) {
	setUserTimeout(conn)
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
	own := p.selfID()
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

// maxAppText is the longest app name and app version that a link keeps.
const maxAppText = 32

// finish runs the TLS handshake, checks the certificate, and exchanges the
// identity again over TLS for protocol version 8. It reports whether it
// passed a new link to OnLink.
func (p *Provider) finish(tc *tls.Conn, plainID proto.Identity, outgoing bool) bool {
	fail := func(format string, args ...any) {
		p.logf("%s: "+format, append([]any{proto.CleanName(plainID.DeviceName)}, args...)...)
		tc.Close()
	}
	if plainID.ProtocolVersion < proto.ProtocolVersion {
		fail("protocol version %d is too old", plainID.ProtocolVersion)
		return false
	}
	if err := tc.Handshake(); err != nil {
		fail("TLS handshake: %v", err)
		return false
	}
	cert, err := peerCert(tc)
	if err != nil {
		fail("%v", err)
		return false
	}
	if cert.Subject.CommonName != plainID.DeviceID {
		fail("certificate CN %q does not match device ID", cert.Subject.CommonName)
		return false
	}
	if pinned, ok := p.cfg.Trusted(plainID.DeviceID); ok {
		switch {
		case pinned == nil:
			fail("no valid pinned certificate, link refused")
			return false
		case !bytes.Equal(pinned.Raw, cert.Raw):
			fail("certificate differs from the pinned certificate, link refused")
			return false
		}
	}
	reader := bufio.NewReaderSize(tc, 64<<10)
	line, _ := p.secureIdentity().Marshal()
	if _, err := tc.Write(line); err != nil {
		fail("send identity: %v", err)
		return false
	}
	raw, err := readLine(reader, maxIdentitySize)
	if err != nil {
		fail("read identity: %v", err)
		return false
	}
	pkt, err := proto.Unmarshal(raw)
	if err != nil || pkt.Type != proto.TypeIdentity {
		fail("expected identity after TLS")
		return false
	}
	var id proto.Identity
	if err := json.Unmarshal(pkt.Body, &id); err != nil || id.DeviceID != plainID.DeviceID || id.ProtocolVersion != plainID.ProtocolVersion {
		fail("identity after TLS does not match")
		return false
	}
	_ = tc.SetDeadline(time.Time{})
	id.DeviceName = proto.CleanName(id.DeviceName)
	id.DeviceType = proto.CleanType(id.DeviceType)
	id.App, id.AppVersion = proto.CleanText(id.App, maxAppText), proto.CleanText(id.AppVersion, maxAppText)
	link := newLink(p, tc, reader, id, cert, outgoing)
	// The listener port of the peer: the port that this side dialed, or the
	// port that the peer put in its plain identity.
	link.PeerPort = plainID.TCPPort
	p.cfg.OnLink(link)
	return true
}
