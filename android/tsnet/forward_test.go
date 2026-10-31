package main

import (
	"bytes"
	"io"
	"net"
	"testing"
	"time"
)

func TestForwardCopiesBothWays(t *testing.T) {
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		c, err := echo.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_, _ = io.Copy(c, c)
	}()

	proxy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.Close()

	ctx, cancel := contextWithTimeout(t, 5*time.Second)
	defer cancel()
	go serve(ctx, proxy, echo.Addr().String(), t.Logf)

	c, err := net.Dial("tcp", proxy.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	want := []byte("flux tsnet forwarding")
	if _, err := c.Write(want); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(want))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestParsePorts(t *testing.T) {
	got, err := parsePorts("")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(fluxPorts) {
		t.Fatalf("got %d ports, want %d", len(got), len(fluxPorts))
	}
	if got[0] != 12070 || got[len(got)-1] != 12108 {
		t.Fatalf("range is %d to %d", got[0], got[len(got)-1])
	}
	got, err = parsePorts("12100, 12070")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != 12100 || got[1] != 12070 {
		t.Fatalf("got %v", got)
	}
	if _, err := parsePorts("0"); err == nil {
		t.Fatal("port 0 accepted")
	}
}
