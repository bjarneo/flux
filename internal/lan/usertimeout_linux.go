//go:build linux

package lan

import (
	"net"
	"time"

	"golang.org/x/sys/unix"
)

// userTimeout is how long sent data can wait for an acknowledgment before
// the kernel closes a link. Keepalive probes find a dead peer only while no
// data waits. Without this limit, a phone that leaves the Wi-Fi while data
// is in flight keeps its link open for about 15 minutes. fluxd then counts
// the phone as online and does not dial its other addresses. A payload or
// tunnel connection to that phone also stays open for that time.
const userTimeout = 30 * time.Second

// setUserTimeout sets TCP_USER_TIMEOUT on a link, payload, or tunnel
// connection.
func setUserTimeout(c net.Conn) {
	tc, ok := c.(*net.TCPConn)
	if !ok {
		return
	}
	raw, err := tc.SyscallConn()
	if err != nil {
		return
	}
	_ = raw.Control(func(fd uintptr) {
		_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_USER_TIMEOUT, int(userTimeout.Milliseconds()))
	})
}
