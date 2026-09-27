//go:build linux

package lan

import (
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

func TestSetUserTimeout(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	c, err := net.Dial("tcp4", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	setUserTimeout(c)
	raw, err := c.(*net.TCPConn).SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var got int
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		got, gerr = unix.GetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_USER_TIMEOUT)
	}); err != nil || gerr != nil {
		t.Fatal(err, gerr)
	}
	if got != int(userTimeout.Milliseconds()) {
		t.Fatalf("TCP_USER_TIMEOUT is %d ms, want %d", got, userTimeout.Milliseconds())
	}
}
