package core

import (
	"context"
	"crypto/tls"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// The phone microphone and the phone screen use the design of the webcam.
// The phone opens a TLS listener and sends its port. fluxd connects out to
// it, pins the certificate of the paired phone, and gives the stream to a
// child process on its stdin.
//
// Each stream kind has 1 session. A start claims the session under d.mu
// before any slow work, and it stops the session that ran before. A stop,
// a switch, and a later start then always find the session, also while
// fluxd still dials the phone. The new session waits until the goroutine
// of the old one ends. Before the child process starts, fluxd checks again
// that the session is current and that the device is paired.

// streamLink is the part of a link that a stream uses. Tests give a fake.
type streamLink interface {
	Send(p *proto.Packet) error
	DialPeer(ctx context.Context, port int) (*tls.Conn, error)
	Done() <-chan struct{}
}

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

// sessionCheck is the time between 2 checks of a running session.
var sessionCheck = time.Second

// watchSession ends a session when the link to the device drops, when the
// device is no longer paired, or when allowed returns false. allowed runs
// with d.mu held, and nil allows the session. The pairing code closes the
// link on an unpair. This check also ends the session when the link stays.
func (d *Daemon) watchSession(ctx context.Context, cancel context.CancelFunc, dev *Device, l interface{ Done() <-chan struct{} }, allowed func() bool) {
	every := sessionCheck
	go func() {
		tick := time.NewTicker(every)
		defer tick.Stop()
		for {
			select {
			case <-l.Done():
				cancel()
				return
			case <-ctx.Done():
				return
			case <-tick.C:
			}
			d.mu.Lock()
			ok := dev.Paired && (allowed == nil || allowed())
			d.mu.Unlock()
			if !ok {
				cancel()
				return
			}
		}
	}()
}

// sessionTurn makes the sessions of 1 kind run 1 after the other. A new
// session waits until the goroutine of the session before it ends. That
// goroutine first waits for its own session before, so 2 recorders,
// players, or ffmpeg processes never run at the same time, also when 3
// starts overlap. A flood of starts then also starts no process for a
// session that a later start ended.
type sessionTurn struct {
	// last closes when the goroutine of the last session ends.
	last chan struct{}
}

// take returns the channel that a new session closes when its goroutine
// ends, and the channel of the session before it, or nil. d.mu must be
// held.
func (t *sessionTurn) take() (done, prev chan struct{}) {
	done, prev = make(chan struct{}), t.last
	t.last = done
	return done, prev
}

// waitTurn waits until the goroutine of the session before ends. It
// returns false when the new session ends first.
func waitTurn(ctx context.Context, prev <-chan struct{}) bool {
	if prev != nil {
		select {
		case <-prev:
		case <-ctx.Done():
		}
	}
	return ctx.Err() == nil
}

// endTurn closes done when the goroutine of a session ends. It first waits
// until the goroutine of the session before ends, also when this session
// ended in waitTurn. A later session then waits for all older goroutines.
func endTurn(done chan struct{}, prev <-chan struct{}) {
	if prev != nil {
		<-prev
	}
	close(done)
}

// maxPeerText is the number of characters of a text from a device that
// fluxd writes to the journal.
const maxPeerText = 200

// peerText returns a text from a device for the journal: at most
// maxPeerText characters, in quotes, with each control character escaped.
// A text from a device then cannot add lines to the journal.
func peerText(s string) string {
	n := 0
	for i := range s {
		if n == maxPeerText {
			s = s[:i] + "…"
			break
		}
		n++
	}
	return strconv.Quote(s)
}

// sessionState is the state of the remote sessions. d.mu guards it.
type sessionState struct {
	// inputGen counts the times that remote input turned off. An action of
	// an older generation does not run.
	inputGen uint64
	// inputText is the number of characters of text in the input queue.
	inputText int
	// inputDropped is true after fluxd logged a dropped action. It is false
	// again when an action fits in the queue.
	inputDropped bool
	// inputStop stops the wtype that runs now, or is nil.
	inputStop context.CancelFunc
	// inputWake makes inputLoop check the held buttons at once.
	inputWake chan struct{}

	// browse holds the Browse PC sessions by their number, and browseGen is
	// the number of the last session.
	browse    map[uint64]*browseSession
	browseGen uint64

	// shortcuts holds an entry for each device ID with a flux.shortcuts
	// request in flight. The entry holds the next request, or nil.
	shortcuts map[string]*shortcutJob

	// screenStart is the time of the last screen mirror start of each
	// device ID.
	screenStart map[string]time.Time

	// The turns of the stream sessions.
	desktopTurn, micTurn, screenTurn, webcamTurn sessionTurn

	// streamAsked is the time of the last request of this computer for
	// the webcam or the microphone of a device, by the kind and the
	// device ID.
	streamAsked map[streamAsk]time.Time
}
