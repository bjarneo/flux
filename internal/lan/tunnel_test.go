package lan

import (
	"context"
	"strings"
	"testing"
)

// A fast peer can answer before OpenTunnel waits. The reply must stay for
// OpenTunnel, and a second reply must not block the packet handler.
func TestTunnelReplyBeforeOpen(t *testing.T) {
	l := &Link{}
	id := l.NewTunnelID()
	l.TunnelReady(id, 0, "busy")
	l.TunnelReady(id, 0, "again")
	_, err := l.OpenTunnel(context.Background(), id)
	if err == nil || !strings.Contains(err.Error(), "busy") {
		t.Fatalf("OpenTunnel = %v, want the first reply of the device", err)
	}
	if _, err := l.OpenTunnel(context.Background(), id); err == nil || !strings.Contains(err.Error(), "no tunnel") {
		t.Fatalf("OpenTunnel after the end = %v, want no tunnel", err)
	}
}

func TestCancelTunnel(t *testing.T) {
	l := &Link{}
	id := l.NewTunnelID()
	l.CancelTunnel(id)
	if _, err := l.OpenTunnel(context.Background(), id); err == nil || !strings.Contains(err.Error(), "no tunnel") {
		t.Fatalf("OpenTunnel after CancelTunnel = %v, want no tunnel", err)
	}
}
