package lan

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"sync"
	"sync/atomic"
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

	// maxLine is the longest line that Receive reads: maxUnpairedLine until
	// the device is paired, then proto.MaxPacketSize. badLogged is true
	// after Receive logged a line that is not a packet.
	maxLine   atomic.Int64
	badLogged atomic.Bool

	// queued is the number of bytes of the packets in Send, which wait for
	// wmu or which Send writes now.
	queued atomic.Int64
}

// maxSendQueue is the largest number of bytes that can wait in Send on 1
// link. Each Send waits while the peer does not read, so without a limit
// the waiting packets can fill the memory. Send then closes the link. The
// tests change it.
var maxSendQueue int64 = 32 << 20

var errSendQueueFull = errors.New("the peer does not read the packets")

func newLink(p *Provider, conn *tls.Conn, reader *bufio.Reader, id proto.Identity, cert *x509.Certificate, outgoing bool) *Link {
	addr, _ := conn.RemoteAddr().(*net.TCPAddr)
	l := &Link{
		Identity: id, Cert: cert, Addr: addr, Outgoing: outgoing, Started: time.Now(),
		provider: p, conn: conn, reader: reader, done: make(chan struct{}),
	}
	l.maxLine.Store(maxUnpairedLine)
	return l
}

// SetPaired sets the longest packet that the link reads. A device that is
// not paired can send only lines of up to 64 KiB, so that it cannot fill
// the memory before the user pairs it.
func (l *Link) SetPaired(paired bool) {
	if paired {
		l.maxLine.Store(proto.MaxPacketSize)
	} else {
		l.maxLine.Store(maxUnpairedLine)
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
// It closes the link when more than maxSendQueue bytes wait in Send. A
// packet that nothing waits before always goes, also when it is larger.
func (l *Link) Send(p *proto.Packet) error {
	line, err := p.Marshal()
	if err != nil {
		return err
	}
	n := int64(len(line))
	if q := l.queued.Add(n); q > maxSendQueue && q > n {
		l.queued.Add(-n)
		l.provider.logf("%s: closed the link, because %d bytes wait to be sent", l.Identity.DeviceName, q)
		l.Close()
		return errSendQueueFull
	}
	defer l.queued.Add(-n)
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
	// The limit can rise while Receive waits for a line, when the user
	// accepts a pairing, so readLine reads it for each part of the line.
	limit := func() int {
		if n := int(l.maxLine.Load()); n > 0 {
			return n
		}
		return maxUnpairedLine
	}
	for {
		line, err := readLineFunc(l.reader, limit)
		if err != nil {
			return err
		}
		if len(line) == 0 {
			continue
		}
		p, err := proto.Unmarshal(line)
		if err != nil {
			// A peer can send such lines in a loop, so the log shows the
			// first one only.
			if l.badLogged.CompareAndSwap(false, true) {
				l.provider.logf("%s: bad packet: %v", l.Identity.DeviceName, err)
			}
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
	return readLineFunc(r, func() int { return max })
}

// readLineFunc is readLine with a limit that max returns for each part of
// the line.
func readLineFunc(r *bufio.Reader, max func() int) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := r.ReadSlice('\n')
		buf = append(buf, chunk...)
		if len(buf) > max() {
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
