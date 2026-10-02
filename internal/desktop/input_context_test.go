package desktop

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPointerContextCancellationClosesConnectionDuringWaylandSetup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wayland-test")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("WAYLAND_DISPLAY", path)
	accepted := make(chan *net.UnixConn, 1)
	go func() {
		conn, err := listener.AcceptUnix()
		if err == nil {
			accepted <- conn
		}
	}()
	pointer := NewPointer()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- pointer.MoveContext(ctx, 1, 1) }()
	var connection *net.UnixConn
	select {
	case connection = <-accepted:
	case <-time.After(time.Second):
		t.Fatal("pointer did not connect")
	}
	defer connection.Close()
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled setup succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("pointer cancellation blocked on compositor")
	}
	pointer.Quarantine()
	if pointer.MoveContext(context.Background(), 1, 1) == nil {
		t.Fatal("quarantined pointer reconnected")
	}
}

func TestWtypeCancellationKillsAndReapsDirectProcess(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := "#!/bin/sh\nprintf '%s' $$ > '" + pidFile + "'\nexec sleep 60\n"
	if err := os.WriteFile(filepath.Join(dir, "wtype"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Keyboard{}.TypeContext(ctx, "harmless test", nil) }()
	var pid int
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if data, err := os.ReadFile(pidFile); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
			if pid > 0 {
				break
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pid == 0 {
		t.Fatal("fake wtype did not start")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled keyboard process succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("wtype cancellation did not reap its process")
	}
	if err := syscall.Kill(pid, 0); err != syscall.ESRCH {
		t.Fatalf("direct wtype process remains after cancellation: %v", err)
	}
}
