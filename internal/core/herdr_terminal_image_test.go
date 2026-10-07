package core

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
	"image"
	"image/color"
	"image/png"
	"log"
	"strings"
	"testing"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// realPNG returns a valid PNG of w by h pixels.
func realPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 60), G: uint8(y * 60), B: 128, A: 255})
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// hugePNG returns a small PNG whose header declares w by h pixels, as a
// decompression bomb does. The CRC of the header stays valid.
func hugePNG(t *testing.T, w, h uint32) []byte {
	t.Helper()
	data := realPNG(t, 1, 1)
	// The IHDR chunk starts after the 8-byte signature with its length and
	// its type. Its data has 13 bytes, and its CRC follows.
	ihdr := data[16:29]
	binary.BigEndian.PutUint32(ihdr[0:4], w)
	binary.BigEndian.PutUint32(ihdr[4:8], h)
	binary.BigEndian.PutUint32(data[29:33], crc32.ChecksumIEEE(data[12:29]))
	return data
}

// openControl opens the control stream ts1 of the agent pane w1:p1.
func openControl(t *testing.T, d *Daemon, dev *Device, desk *lan.Link, answers <-chan map[string]any) {
	t.Helper()
	d.cfg.HerdrControl = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
}

// echoedInputs returns the next n terminal.input texts that the echo
// bridge sent back. It skips the first frame of the bridge.
func echoedInputs(t *testing.T, answers <-chan map[string]any, n int) []string {
	t.Helper()
	var got []string
	for len(got) < n {
		a := nextAnswer(t, answers)
		if a["kind"] != "terminal_frame" {
			t.Fatalf("answer = %v", a)
		}
		text := frameText(t, a)
		if text == "ready" {
			continue
		}
		var rec map[string]any
		if json.Unmarshal([]byte(text), &rec) != nil || rec["type"] != "terminal.input" {
			t.Fatalf("echoed %q", text)
		}
		got = append(got, str(rec["text"]))
	}
	return got
}

// sendImage sends data as the payload of a terminal_paste_image.
func sendImage(ctx context.Context, t *testing.T, phone *lan.Link, data []byte) {
	t.Helper()
	p := proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"})
	go func() {
		if err := phone.SendWithPayload(ctx, p, bytes.NewReader(data), int64(len(data)), nil); err != nil {
			t.Logf("send payload: %v", err)
		}
	}()
}

// waitImageEnd waits until no image paste holds the clipboard.
func waitImageEnd(t *testing.T, d *Daemon) {
	t.Helper()
	waitFor(t, "the end of the image paste", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return !d.herdrJobs.imaging
	})
}

// Only a current control session of an agent may paste an image, and its
// payload is bounded before the transfer.
func TestHerdrTerminalPasteImagePolicy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	openControl(t, d, dev, desk, answers)

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"}))
	if a := nextInputError(t, answers); a["code"] != herdrInputInvalid ||
		!strings.Contains(str(a["error"]), "empty") || a["image"] != true {
		t.Fatalf("empty image = %v", a)
	}
	big := proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"})
	big.PayloadSize = desktop.MaxClipboardImage + 1
	big.PayloadTransferInfo = &proto.TransferInfo{Port: 12070}
	d.handleHerdr(dev, desk, big)
	if a := nextInputError(t, answers); a["code"] != herdrInputInvalid ||
		!strings.Contains(str(a["error"]), "larger than") {
		t.Fatalf("large image = %v", a)
	}
	// While another paste holds the clipboard, a paste gets paste_failed.
	d.mu.Lock()
	d.herdrJobs.imaging = true
	d.mu.Unlock()
	busy := proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste_image", "session": "ts1"})
	busy.PayloadSize = 10
	busy.PayloadTransferInfo = &proto.TransferInfo{Port: 12070}
	d.handleHerdr(dev, desk, busy)
	if a := nextInputError(t, answers); a["code"] != herdrPasteFailed {
		t.Fatalf("busy paste = %v", a)
	}
	d.mu.Lock()
	d.herdrJobs.imaging = false
	d.mu.Unlock()

	// A stale session and a foreign device get no answer.
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

// A shell pane takes no image paste, so Ctrl+V never reaches a shell.
func TestHerdrTerminalPasteImageNeedsAnAgent(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	d.cfg.HerdrTerminals = true
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2"}}
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	p := proto.New(proto.TypeFluxHerdr, map[string]any{"kind": "terminal_paste_image", "session": "ts1"})
	p.PayloadSize = 10
	p.PayloadTransferInfo = &proto.TransferInfo{Port: 12070}
	d.handleHerdr(dev, desk, p)
	if a := nextInputError(t, answers); a["code"] != herdrInputInvalid ||
		!strings.Contains(str(a["error"]), "agent") {
		t.Fatalf("shell image paste = %v", a)
	}
}

// An image paste puts the PNG on the desktop clipboard and then sends
// Ctrl+V to the same pane. A key that the phone typed during the transfer
// goes after Ctrl+V, so Enter cannot submit the prompt before the image.
func TestHerdrTerminalPasteImageOverLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	clip := &memClipboard{}
	d.clip = clip
	logs := &logLines{}
	d.logger = log.New(logs, "", 0)
	desk, phone, _, phoneID := linkPair(t, ctx)
	dev := &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: desk}
	answers := herdrAnswers(t, phone)
	openControl(t, d, dev, desk, answers)
	go desk.Receive(func(p *proto.Packet) { d.handleHerdr(dev, desk, p) })

	// The paste holds the clipboard, so Enter waits for the image.
	d.mu.Lock()
	tr := d.herdrStreams["ts1"]
	d.mu.Unlock()
	if d.startHerdrImage(tr, func() {}) != herdrImageStarted {
		t.Fatal("the image paste did not start")
	}
	if err := phone.Send(proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input", "session": "ts1", "key": "enter"})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "fluxd to hold Enter", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(tr.held) == 1
	})
	img := realPNG(t, 4, 4)
	if err := d.clip.SetImage(img, "image/png"); err != nil {
		t.Fatal(err)
	}
	d.endHerdrImage(tr, len(img))
	if got := echoedInputs(t, answers, 2); got[0] != herdrTerminalPasteKey || got[1] != "\r" {
		t.Fatalf("inputs = %q, want Ctrl+V and then Enter", got)
	}
	waitImageEnd(t, d)

	// The full paste over the link.
	clip.mu.Lock()
	clip.image, clip.mime = nil, ""
	clip.mu.Unlock()
	img = realPNG(t, 3, 2)
	sendImage(ctx, t, phone, img)
	if got := waitImage(t, clip); !bytes.Equal(got, img) {
		t.Fatal("the clipboard does not hold the PNG")
	}
	clip.mu.Lock()
	mime := clip.mime
	clip.mu.Unlock()
	if mime != "image/png" {
		t.Fatalf("clipboard mime = %q, want image/png", mime)
	}
	if got := echoedInputs(t, answers, 1); got[0] != herdrTerminalPasteKey {
		t.Fatalf("input = %q, want Ctrl+V", got)
	}
	waitFor(t, "the log of the image", func() bool { return logs.has("pasted an image of") })
	waitFor(t, "the log of Enter", func() bool { return logs.has("pressed Enter") })
}

// fluxd refuses an image that is not a PNG or that declares a very large
// size. It reads only the header, so a bomb takes no memory.
func TestHerdrTerminalPasteImageRefusals(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	clip := &memClipboard{}
	d.clip = clip
	desk, phone, _, phoneID := linkPair(t, ctx)
	dev := &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: desk}
	answers := herdrAnswers(t, phone)
	openControl(t, d, dev, desk, answers)
	go desk.Receive(func(p *proto.Packet) { d.handleHerdr(dev, desk, p) })

	for _, c := range []struct {
		name string
		data []byte
		want string
	}{
		{"jpeg", testJPEG(t), "not a PNG"},
		{"text", []byte("hello, this is not an image"), "not a PNG"},
		{"bomb", hugePNG(t, 65535, 65535), "larger than"},
		{"wide", hugePNG(t, herdrImageMaxSide+1, 1), "on a side"},
		{"pixels", hugePNG(t, 8000, 8000), "million pixels"},
	} {
		sendImage(ctx, t, phone, c.data)
		if a := nextInputError(t, answers); a["code"] != herdrInputInvalid || !strings.Contains(str(a["error"]), c.want) {
			t.Fatalf("%s: answer = %v", c.name, a)
		}
		waitImageEnd(t, d)
	}
	clip.mu.Lock()
	defer clip.mu.Unlock()
	if clip.image != nil {
		t.Fatal("a refused image reached the clipboard")
	}
}

// An image that arrives after the release of its stream does not change
// the clipboard, and its reservation ends.
func TestHerdrTerminalPasteImageAfterRelease(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	openControl(t, d, dev, desk, answers)

	d.mu.Lock()
	tr := d.herdrStreams["ts1"]
	d.mu.Unlock()
	if d.startHerdrImage(tr, func() {}) != herdrImageStarted {
		t.Fatal("the image paste did not start")
	}
	d.herdrTerminalRelease(dev, desk, "", "ts1")
	if d.herdrImageCurrent(tr) {
		t.Fatal("a released stream is current for its image")
	}
	d.endHerdrImage(tr, 0)
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.herdrJobs.imaging || tr.imaging {
		t.Fatal("the image reservation stayed")
	}
}

// The image check reads only the header of a PNG.
func TestHerdrTerminalPNG(t *testing.T) {
	if why := herdrTerminalPNG(realPNG(t, 4, 4)); why != "" {
		t.Fatalf("a small PNG was refused: %q", why)
	}
	if why := herdrTerminalPNG(testJPEG(t)); why == "" {
		t.Fatal("a JPEG must be refused, because the phone converts each image to PNG")
	}
	if why := herdrTerminalPNG(testPNG(4)); why == "" {
		t.Fatal("a PNG with a broken header must be refused")
	}
	if why := herdrTerminalPNG(hugePNG(t, 7000, 7000)); why == "" {
		t.Fatal("a PNG above the pixel limit must be refused")
	}
	if why := herdrTerminalPNG(hugePNG(t, 2048, 2048)); why != "" {
		t.Fatalf("a PNG of 2048 by 2048 pixels was refused: %q", why)
	}
}
