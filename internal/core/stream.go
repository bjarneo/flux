package core

import (
	"context"
	"os/exec"
	"syscall"

	"flux/internal/lan"
)

// The phone microphone and the phone screen use the design of the webcam.
// The phone opens a TLS listener and sends its port. fluxd connects out to
// it, pins the certificate of the paired phone, and gives the stream to a
// child process on its stdin.

// childCommand returns a command that stops with ctx. The kernel also
// stops it when fluxd exits, so that no Flux Microphone source or mirror
// window stays after a crash.
func childCommand(ctx context.Context, path string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	return cmd
}

// cancelOnLinkDown cancels a stream when the link to the phone drops.
func cancelOnLinkDown(ctx context.Context, l *lan.Link, cancel context.CancelFunc) {
	go func() {
		select {
		case <-l.Done():
			cancel()
		case <-ctx.Done():
		}
	}()
}
