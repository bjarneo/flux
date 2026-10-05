package core

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"flux/internal/proto"
)

// Only a current control session may paste an image, and its payload is bounded.
func TestHerdrTerminalPasteImagePolicy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"}))
	if a := nextInputError(t, answers); a["code"] != "invalid_input" ||
		!strings.Contains(str(a["error"]), "empty") {
		t.Fatalf("empty image = %v", a)
	}
	big := proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"})
	big.PayloadSize = herdrTerminalImageMax + 1
	big.PayloadTransferInfo = &proto.TransferInfo{Port: 12070}
	d.handleHerdr(dev, desk, big)
	if a := nextInputError(t, answers); a["code"] != "invalid_input" ||
		!strings.Contains(str(a["error"]), "larger than") {
		t.Fatalf("large image = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts9"}))
	d.handleHerdr(&Device{ID: "tablet", Paired: true}, desk,
		proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_paste_image", "session": "ts1"}))
	deadline := time.After(300 * time.Millisecond)
	for {
		select {
		case a := <-answers:
			if a["kind"] != "terminal_frame" {
				t.Fatalf("a stale image paste reached the phone: %v", a)
			}
		case <-deadline:
			return
		}
	}
}

// Image paste updates the desktop clipboard before sending Ctrl+V to the same pane.
func TestHerdrTerminalPasteImageOverLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	clip := &memClipboard{}
	d.clip = clip
	desk, phone, _, phoneID := linkPair(t, ctx)
	dev := &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: desk}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	go desk.Receive(func(p *proto.Packet) { d.handleHerdr(dev, desk, p) })
	img := testPNG(9)
	p := proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"})
	go func() {
		if err := phone.SendWithPayload(ctx, p, bytes.NewReader(img), int64(len(img)), nil); err != nil {
			t.Logf("send payload: %v", err)
		}
	}()
	if got := waitImage(t, clip); !bytes.Equal(got, img) {
		t.Fatalf("clipboard image = %d bytes, want %d", len(got), len(img))
	}
	for {
		a := nextAnswer(t, answers)
		if a["kind"] != "terminal_frame" {
			t.Fatalf("answer = %v", a)
		}
		text := frameText(t, a)
		if text == "ready" {
			continue
		}
		var rec map[string]any
		if json.Unmarshal([]byte(text), &rec) != nil {
			t.Fatalf("echoed %q", text)
		}
		if rec["type"] != "terminal.input" || rec["text"] != "\x16" {
			t.Fatalf("paste key = %v, want Ctrl+V", rec)
		}
		break
	}
}
