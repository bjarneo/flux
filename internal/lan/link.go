package lan

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"sync"
	"time"

	"flux/internal/proto"
)

// Link is an authenticated TLS connection to one device.
type Link struct {
	Identity proto.Identity
	Cert     *x509.Certificate
	Addr     *net.TCPAddr
	// Outgoing is true when this computer opened the TCP connection.
	Outgoing bool
	Started  time.Time
	// PeerPort is the TCP listener port of the peer, or 0 when unknown.
	PeerPort int

	provider *Provider
	conn     *tls.Conn
	reader   *bufio.Reader
	wmu      sync.Mutex
	once     sync.Once
	done     chan struct{}
	tun      tunnels
}

func newLink(p *Provider, conn *tls.Conn, reader *bufio.Reader, id proto.Identity, cert *x509.Certificate, outgoing bool) *Link {
	addr, _ := conn.RemoteAddr().(*net.TCPAddr)
	return &Link{
		Identity: id, Cert: cert, Addr: addr, Outgoing: outgoing, Started: time.Now(),
		provider: p, conn: conn, reader: reader, done: make(chan struct{}),
	}
}

// raceWindow is the time in which a second link to the same device counts
// as a simultaneous connection and not as a reconnect.
const raceWindow = 5 * time.Second

// Preferred decides between 2 links to the same device. When both devices
// connect to each other at the same time, each side can keep a different
// socket and close the other one, so both links die. In the race window,
// both sides keep the link that the device with the larger ID opened.
// After the window, the new link always wins, because the old socket can
// be dead without an error.
func Preferred(old, next *Link, selfID string) *Link {
	if time.Since(old.Started) > raceWindow {
		return next
	}
	opener := func(l *Link) string {
		if l.Outgoing {
			return selfID
		}
		return l.Identity.DeviceID
	}
	larger := max(selfID, next.Identity.DeviceID)
	if opener(old) == larger && opener(next) != larger {
		return old
	}
	return next
}

// DeviceID returns the ID of the peer.
func (l *Link) DeviceID() string { return l.Identity.DeviceID }

// IP returns the IP address of the peer.
func (l *Link) IP() string {
	if l.Addr == nil {
		return ""
	}
	return l.Addr.IP.String()
}

// LocalAddr returns the local address of the link. Its IP is the address
// that the peer can reach this computer on.
func (l *Link) LocalAddr() net.Addr { return l.conn.LocalAddr() }

// Send writes one packet. It is safe to call from more than one goroutine.
func (l *Link) Send(p *proto.Packet) error {
	line, err := p.Marshal()
	if err != nil {
		return err
	}
	l.wmu.Lock()
	defer l.wmu.Unlock()
	select {
	case <-l.done:
		return net.ErrClosed
	default:
	}
	_ = l.conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
	if _, err := l.conn.Write(line); err != nil {
		l.Close()
		return err
	}
	return nil
}

// Receive reads packets and calls handle for each one until the link
// closes. It returns the error that closed the link.
func (l *Link) Receive(handle func(*proto.Packet)) error {
	defer l.Close()
	_ = l.conn.SetReadDeadline(time.Time{})
	for {
		line, err := readLine(l.reader, proto.MaxPacketSize)
		if err != nil {
			return err
		}
		if len(line) == 0 {
			continue
		}
		p, err := proto.Unmarshal(line)
		if err != nil {
			l.provider.logf("%s: bad packet: %v", l.Identity.DeviceName, err)
			continue
		}
		handle(p)
	}
}

// Close closes the link. It is safe to call more than once.
func (l *Link) Close() {
	l.once.Do(func() {
		close(l.done)
		_ = l.conn.Close()
	})
}

// Done returns a channel that is closed when the link closes.
func (l *Link) Done() <-chan struct{} { return l.done }

var errLineTooLong = errors.New("packet too large")

// readLine reads one newline-terminated line without the newline.
func readLine(r *bufio.Reader, max int) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := r.ReadSlice('\n')
		buf = append(buf, chunk...)
		if len(buf) > max {
			return nil, errLineTooLong
		}
		if err == nil {
			return trimNewline(buf), nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

func trimNewline(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}
