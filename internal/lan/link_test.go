package lan

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"flux/internal/proto"
)

// TestSendQueueLimit checks that Send closes the link when the peer does
// not read and too many bytes wait to be sent.
func TestSendQueueLimit(t *testing.T) {
	old := maxSendQueue
	maxSendQueue = 64 << 10
	defer func() { maxSendQueue = old }()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	// The phone does not read from its link. The close at the end keeps
	// the link, so that the garbage collector does not close its socket.
	onPhone := waitLink(t, phone.links)
	defer onPhone.Close()

	// A packet that is larger than the limit goes when nothing waits.
	big := proto.New(proto.TypePing, map[string]any{"message": strings.Repeat("x", 256<<10)})
	if err := onDesk.Send(big); err != nil {
		t.Fatalf("a lone large packet: %v", err)
	}
	const sends = 128
	errs := make(chan error, sends)
	for range sends {
		go func() { errs <- onDesk.Send(big) }()
	}
	full := false
	for range sends {
		select {
		case err := <-errs:
			full = full || errors.Is(err, errSendQueueFull)
		case <-time.After(10 * time.Second):
			t.Fatal("a Send did not return")
		}
	}
	if !full {
		t.Fatal("no Send reported the full queue")
	}
	select {
	case <-onDesk.Done():
	default:
		t.Fatal("the link stays open")
	}
	if n := onDesk.queued.Load(); n != 0 {
		t.Fatalf("%d bytes stay in the queue", n)
	}
	desk.waitLog(t, "bytes wait to be sent")
}
