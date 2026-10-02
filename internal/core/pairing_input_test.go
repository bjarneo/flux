package core

import (
	"flux/internal/lan"
	"flux/internal/proto"
	"testing"
	"time"
)

func TestPairPacketFromReplacedLinkCannotUnpairCurrentPeer(t *testing.T) {
	d, dev, old, _, _, _ := approvalFixture(t)
	current := &lan.Link{Identity: old.Identity, Cert: old.Cert}
	d.mu.Lock()
	dev.link = current
	d.mu.Unlock()
	d.handlePair(dev, old, proto.New(proto.TypePair, map[string]any{"pair": false}))
	d.mu.Lock()
	paired := dev.Paired
	d.mu.Unlock()
	_, trusted := d.trust.Get(dev.ID)
	if !paired || !trusted {
		t.Fatal("old TLS link unpaired replacement")
	}
}

func TestSameLinkRepairRevokesInputGrantWithoutResurrection(t *testing.T) {
	d, dev, l, _, n, states := approvalFixture(t)
	r := approveFixture(t, d, dev, l, n, states, approvalID1)
	d.handleMousepadLink(dev, l, mousepad(`{"key":"old grant"}`))
	queued := <-d.inputQ
	d.handlePair(dev, l, proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()}))
	if !r.dead.Load() {
		t.Fatal("repair retained input grant")
	}
	d.mu.Lock()
	dev.Paired = true
	dev.clearPairingLocked()
	d.mu.Unlock()
	if d.runApprovedInput(queued) == nil {
		t.Fatal("repair revived queued native input")
	}
}
