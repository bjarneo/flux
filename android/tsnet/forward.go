package main

import (
	"context"
	"io"
	"net"
	"os"
	"syscall"
	"time"
)

// serve accepts connections on ln and copies each one to target. It returns
// when ctx ends or the listener closes.
func serve(ctx context.Context, ln net.Listener, target string, logf func(string, ...any)) {
	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go forward(conn, target, logf)
	}
}

// forward copies between a tailnet connection and the local listener. The
// local listener must see a clean TCP stream, so this is a plain byte copy.
func forward(conn net.Conn, target string, logf func(string, ...any)) {
	defer conn.Close()
	d := net.Dialer{Timeout: 5 * time.Second}
	up, err := d.Dial("tcp", target)
	if err != nil {
		logf("forward %s: %v", target, err)
		return
	}
	defer up.Close()
	done := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(up, conn)
		if c, ok := up.(interface{ CloseWrite() error }); ok {
			_ = c.CloseWrite()
		}
		done <- struct{}{}
	}()
	_, _ = io.Copy(conn, up)
	<-done
}

// exitOnStdinEOF cancels cancel when stdin closes. The app holds the write
// end, so the node exits when the app process does.
func exitOnStdinEOF(cancel func()) {
	var b [64]byte
	for {
		if _, err := os.Stdin.Read(b[:]); err != nil {
			cancel()
			return
		}
	}
}

// watchParent cancels cancel when the process pid no longer exists, so that
// the node does not outlive the app that started it.
func watchParent(pid int, cancel func()) {
	for {
		time.Sleep(5 * time.Second)
		p, err := os.FindProcess(pid)
		if err != nil {
			cancel()
			return
		}
		if err := p.Signal(os.Signal(syscall.Signal(0))); err != nil {
			cancel()
			return
		}
	}
}
