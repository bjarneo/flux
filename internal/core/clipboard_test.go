package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"flux/internal/config"
	"flux/internal/proto"
)

// testPNG returns the start of a PNG file with the byte b after it, so
// that each value makes a different image.
func testPNG(b byte) []byte {
	return append([]byte("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"), b)
}

func clipDaemon(t *testing.T, auto bool) (*Daemon, *memClipboard) {
	clip := &memClipboard{}
	return &Daemon{
		cfg:     &config.Config{AutoClipboard: auto},
		clip:    clip,
		clipDir: t.TempDir(),
		devices: map[string]*Device{},
		logger:  log.New(io.Discard, "", 0),
	}, clip
}

func clipFiles(t *testing.T, dir string) int {
	names, err := filepath.Glob(filepath.Join(dir, "clip-*"))
	if err != nil {
		t.Fatal(err)
	}
	return len(names)
}

func TestClipImageHistory(t *testing.T) {
	d, _ := clipDaemon(t, true)
	for i := range maxClipImages + 2 {
		d.addClipLocked(ClipEntry{Text: fmt.Sprint("text ", i), Dir: "out"})
		if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(byte(i)), "image/png"); err != nil {
			t.Fatal(err)
		}
	}
	images := 0
	for _, e := range d.clipboard {
		if e.Image != "" {
			images++
			if e.Text != "" {
				t.Errorf("image entry has text %q", e.Text)
			}
		}
	}
	if images != maxClipImages {
		t.Errorf("history has %d images, want %d", images, maxClipImages)
	}
	if n := clipFiles(t, d.clipDir); n != maxClipImages {
		t.Errorf("folder has %d images, want %d", n, maxClipImages)
	}
	if len(d.clipboard) != maxClipImages+maxClipImages+2 {
		t.Errorf("history has %d entries", len(d.clipboard))
	}

	// The same image again changes only the time of the top entry.
	top := d.clipboard[0]
	if err := d.addClipImage(ClipEntry{Dir: "in", Time: 99}, testPNG(maxClipImages+1), "image/png"); err != nil {
		t.Fatal(err)
	}
	if d.clipboard[0].Image != top.Image || d.clipboard[0].Time != 99 {
		t.Errorf("top entry %+v", d.clipboard[0])
	}
	if n := clipFiles(t, d.clipDir); n != maxClipImages {
		t.Errorf("folder has %d images after a repeat, want %d", n, maxClipImages)
	}
}

func TestClipHistoryDropsOldImages(t *testing.T) {
	d, _ := clipDaemon(t, true)
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}
	for i := range maxClipboard {
		d.addClipLocked(ClipEntry{Text: fmt.Sprint(i), Dir: "out"})
	}
	if len(d.clipboard) != maxClipboard {
		t.Fatalf("history has %d entries", len(d.clipboard))
	}
	if n := clipFiles(t, d.clipDir); n != 0 {
		t.Errorf("the image of a dropped entry stays on disk")
	}
}

func TestReceiveClipImage(t *testing.T) {
	d, clip := clipDaemon(t, true)
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	jpeg := []byte("\xff\xd8\xff\xe0\x00\x10JFIF\x00")
	d.receiveClipImage(dev, &clipFetch{}, jpeg)
	waitIdle(t, d, &d.content.clipQ)
	if clip.mime != "image/jpeg" || !bytes.Equal(clip.image, jpeg) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].Dir != "in" || d.clipboard[0].DeviceName != "Pixel 8" {
		t.Fatalf("history %+v", d.clipboard)
	}
	if filepath.Ext(d.clipboard[0].Image) != ".jpg" {
		t.Errorf("image path %s", d.clipboard[0].Image)
	}

	// Data that is not an image stays off the clipboard.
	clip.image, clip.mime = nil, ""
	d.receiveClipImage(dev, &clipFetch{}, []byte("#!/bin/sh\nrm -rf ~\n"))
	waitIdle(t, d, &d.content.clipQ)
	if clip.image != nil || len(d.clipboard) != 1 {
		t.Errorf("clipboard has %q, history has %d entries", clip.image, len(d.clipboard))
	}

	// Without automatic sync, the image goes only into the history.
	d.cfg.AutoClipboard = false
	d.receiveClipImage(dev, &clipFetch{}, testPNG(2))
	waitIdle(t, d, &d.content.clipQ)
	if clip.image != nil || len(d.clipboard) != 2 {
		t.Errorf("clipboard has %q, history has %d entries", clip.image, len(d.clipboard))
	}

	// An image that arrives after an unpair is dropped.
	d.cfg.AutoClipboard = true
	dev.Paired = false
	d.receiveClipImage(dev, &clipFetch{}, testPNG(3))
	waitIdle(t, d, &d.content.clipQ)
	if clip.image != nil || len(d.clipboard) != 2 {
		t.Errorf("unpaired: clipboard has %q, history has %d entries", clip.image, len(d.clipboard))
	}
}

// A text that a device copies after an image stays on the clipboard and at
// the top of the history, also when the image arrives after the text.
func TestClipTextStopsOlderImage(t *testing.T) {
	d, clip := clipDaemon(t, true)
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	ctx, cancel := context.WithCancel(context.Background())
	f := &clipFetch{cancel: cancel}
	d.content.clipImages = map[string]*clipFetch{dev.ID: f}
	d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": "newer text"}))
	if ctx.Err() == nil {
		t.Fatal("the text did not stop the image")
	}
	d.receiveClipImage(dev, f, testPNG(1))
	waitIdle(t, d, &d.content.clipQ)
	if clip.image != nil || clip.text != "newer text" {
		t.Errorf("clipboard has the text %q and the image %q", clip.text, clip.image)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].Text != "newer text" {
		t.Errorf("history %+v", d.clipboard)
	}
}

// A text that a device copies while fluxd saves an older image keeps its
// job in the busy worker, and the image stays out of the history.
func TestClipTextDuringImageSave(t *testing.T) {
	d, clip := clipDaemon(t, true)
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	f := &clipFetch{cancel: func() {}}
	d.content.clipImages = map[string]*clipFetch{dev.ID: f}
	current := func() bool { return dev.Paired && !f.stale }

	// The worker runs an earlier job when the text comes.
	started, release := make(chan struct{}), make(chan struct{})
	d.runContent(&d.content.clipQ, 0, func() {
		close(started)
		<-release
	})
	<-started
	d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": "newer text"}))

	// These are the steps of receiveClipImage after its first check.
	if err := d.addClipImageIf(ClipEntry{Dir: "in", Device: dev.ID}, testPNG(1), "image/png", current); err != nil {
		t.Fatal(err)
	}
	if d.runContentIf(&d.content.clipQ, 0, current, func() { t.Error("the image job ran") }) {
		t.Error("the image replaced the job of the newer text")
	}
	close(release)
	waitIdle(t, d, &d.content.clipQ)
	if clip.image != nil || clip.text != "newer text" {
		t.Errorf("clipboard has the text %q and the image %q", clip.text, clip.image)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].Text != "newer text" {
		t.Errorf("history %+v", d.clipboard)
	}
	if n := clipFiles(t, d.clipDir); n != 0 {
		t.Errorf("folder has %d images, want 0", n)
	}
}

func TestCopyClipImage(t *testing.T) {
	d, clip := clipDaemon(t, true)
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}
	if err := d.CopyClipImage(d.clipboard[0].Image); err != nil {
		t.Fatal(err)
	}
	if clip.mime != "image/png" || !bytes.Equal(clip.image, testPNG(1)) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}

	// A path that is not in the history is refused.
	other := filepath.Join(t.TempDir(), "secret.png")
	if err := os.WriteFile(other, testPNG(2), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := d.CopyClipImage(other); err == nil {
		t.Error("copied a file that is not in the history")
	}
}

func TestRemoveClipImages(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"clip-a.png", "clip-b.jpg", "keep.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	removeClipImages(dir)
	if n := clipFiles(t, dir); n != 0 {
		t.Errorf("%d images stay", n)
	}
	if _, err := os.Stat(filepath.Join(dir, "keep.txt")); err != nil {
		t.Error("removed a file that is not a clipboard image")
	}
}

func TestClipPreview(t *testing.T) {
	d, clip := clipDaemon(t, true)
	long := strings.Repeat("é", maxClipPreview)
	d.addClipLocked(ClipEntry{Text: long, Dir: "out"})
	d.addClipLocked(ClipEntry{Text: "short", Dir: "out"})
	view := d.clipPreviewLocked()
	if view[0].Text != "short" || view[0].Truncated || view[0].Size != 0 {
		t.Errorf("short entry = %+v", view[0])
	}
	if !view[1].Truncated || view[1].Size != len(long) || len(view[1].Text) > maxClipPreview || !utf8.ValidString(view[1].Text) {
		t.Errorf("long entry: truncated %v, size %d, %d text bytes", view[1].Truncated, view[1].Size, len(view[1].Text))
	}
	if d.clipboard[1].Text != long {
		t.Error("the preview changed the history")
	}
	if view[0].ID == "" || view[0].ID == view[1].ID {
		t.Errorf("entry IDs %q and %q", view[0].ID, view[1].ID)
	}
	if err := d.CopyClip(view[1].ID); err != nil {
		t.Fatal(err)
	}
	if clip.text != long {
		t.Errorf("CopyClip put %d bytes on the clipboard, want %d", len(clip.text), len(long))
	}
	if err := d.CopyClip("missing"); err == nil {
		t.Error("CopyClip of a missing ID returned no error")
	}
}

// slowClipboard is a clipboard whose first Set waits for release.
type slowClipboard struct {
	memClipboard
	release chan struct{}
	started chan struct{}
	mu      sync.Mutex
	sets    []string
}

func (s *slowClipboard) Set(text string) error {
	s.mu.Lock()
	first := len(s.sets) == 0
	s.sets = append(s.sets, text)
	s.mu.Unlock()
	if first {
		close(s.started)
		<-s.release
	}
	return s.memClipboard.Set(text)
}

// TestClipboardWorkerKeepsNewest sends 3 texts while wl-copy runs. The
// clipboard ends with the newest text, and the text between is dropped.
func TestClipboardWorkerKeepsNewest(t *testing.T) {
	d, _ := clipDaemon(t, true)
	slow := &slowClipboard{release: make(chan struct{}), started: make(chan struct{})}
	d.clip = slow
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	for _, text := range []string{"A", "B", "C"} {
		d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": text}))
		if text == "A" {
			<-slow.started
		}
	}
	close(slow.release)
	waitIdle(t, d, &d.content.clipQ)
	if !slices.Equal(slow.sets, []string{"A", "C"}) || slow.text != "C" {
		t.Fatalf("sets %q, clipboard %q", slow.sets, slow.text)
	}
	if len(d.clipboard) != 3 || d.clipboard[0].Text != "C" {
		t.Fatalf("history %+v", d.clipboard)
	}
}

// TestClipboardWorkerChecksSwitch turns auto_clipboard off while a text
// waits. The text stays off the clipboard.
func TestClipboardWorkerChecksSwitch(t *testing.T) {
	d, _ := clipDaemon(t, true)
	slow := &slowClipboard{release: make(chan struct{}), started: make(chan struct{})}
	d.clip = slow
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": "A"}))
	<-slow.started
	d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": "B"}))
	d.mu.Lock()
	d.cfg.AutoClipboard = false
	d.mu.Unlock()
	close(slow.release)
	waitIdle(t, d, &d.content.clipQ)
	if !slices.Equal(slow.sets, []string{"A"}) {
		t.Fatalf("sets %q", slow.sets)
	}
}

func TestClipHistoryTextLimit(t *testing.T) {
	d, _ := clipDaemon(t, true)
	for i := range 40 {
		d.addClipLocked(ClipEntry{Text: strings.Repeat(string(rune('a'+i%26)), 1<<20) + fmt.Sprint(i), Dir: "in"})
	}
	total := 0
	for _, e := range d.clipboard {
		total += len(e.Text)
	}
	if total > maxClipText || len(d.clipboard) == 0 || !strings.HasSuffix(d.clipboard[0].Text, "39") {
		t.Fatalf("%d entries with %d bytes", len(d.clipboard), total)
	}
}

// TestConnectClipboardText checks that a device that connects gets only
// the text that Watch reported, and no text after an image copy.
func TestConnectClipboardText(t *testing.T) {
	d, _ := clipDaemon(t, false)
	d.onLocalClipboard("normal text")
	if d.content.lastClip != "normal text" {
		t.Fatalf("last text %q", d.content.lastClip)
	}
	d.onLocalImage(testPNG(1), "image/png")
	if d.content.lastClip != "" {
		t.Fatalf("last text after an image %q", d.content.lastClip)
	}
}

// TestLargeLocalText checks that a local copy above maxSentText stays in
// the history, and that a device that connects gets no text.
func TestLargeLocalText(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.onLocalClipboard("small text")
	large := strings.Repeat("a", maxSentText+1)
	d.onLocalClipboard(large)
	if d.content.lastClip != "" {
		t.Fatalf("last text has %d bytes", len(d.content.lastClip))
	}
	if len(d.clipboard) != 2 || d.clipboard[0].Text != large {
		t.Fatalf("history has %d entries", len(d.clipboard))
	}
}

// connectClip returns the flux.clipboard.connect packet of a device that
// copied text at the time at.
func connectClip(text string, at time.Time) *proto.Packet {
	return proto.New(proto.TypeClipboardConnect, map[string]any{"content": text, "timestamp": at.UnixMilli()})
}

// TestConnectClipboardTwoDevices checks that a device that connects with
// an older copy does not replace a newer text or image of another device,
// a newer shared text, or a newer desktop copy.
func TestConnectClipboardTwoDevices(t *testing.T) {
	d, clip := clipDaemon(t, true)
	phone := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	mac := &Device{ID: "mac", Name: "MacBook", Paired: true}
	older := time.Now().Add(-time.Minute)

	// The phone text comes after the copy on the Mac.
	d.handleClipboard(phone, proto.New(proto.TypeClipboard, map[string]any{"content": "phone text"}))
	d.handleClipboard(mac, connectClip("mac text", older))
	waitIdle(t, d, &d.content.clipQ)
	if clip.text != "phone text" {
		t.Errorf("clipboard has %q, want the phone text", clip.text)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].Device != phone.ID {
		t.Fatalf("history %+v", d.clipboard)
	}

	// The phone image comes after the copy on the Mac.
	at := time.Now()
	d.receiveClipImage(phone, &clipFetch{}, testPNG(1))
	d.handleClipboard(mac, connectClip("mac text", at))
	waitIdle(t, d, &d.content.clipQ)
	if clip.image == nil || clip.text != "phone text" {
		t.Errorf("clipboard has the text %q and the image %q", clip.text, clip.image)
	}
	if len(d.clipboard) != 2 || d.clipboard[0].Image == "" {
		t.Fatalf("history %+v", d.clipboard)
	}

	// A shared text or a desktop copy is newer than the copy on the Mac.
	// Each case starts with a new daemon, so that no other clipboard makes
	// the copy on the Mac stale.
	for _, c := range []struct {
		name  string
		newer func(d *Daemon)
		want  string
	}{
		{"shared text", func(d *Daemon) { d.receiveText(phone, "shared text") }, "shared text"},
		{"desktop text", func(d *Daemon) { d.onLocalClipboard("desktop text") }, ""},
		{"desktop image", func(d *Daemon) { d.onLocalImage(testPNG(2), "image/png") }, ""},
	} {
		d, clip := clipDaemon(t, true)
		d.ctx = t.Context()
		c.newer(d)
		d.handleClipboard(mac, connectClip("mac text", older))
		waitIdle(t, d, &d.content.clipQ)
		if clip.text != c.want || len(d.clipboard) != 1 || d.clipboard[0].Device == mac.ID {
			t.Errorf("%s: clipboard has %q, history %+v", c.name, clip.text, d.clipboard)
		}
	}
}

// TestConnectClipboardCopyTime checks that fluxd orders the copies that
// devices send when they connect by the time of each copy.
func TestConnectClipboardCopyTime(t *testing.T) {
	d, clip := clipDaemon(t, true)
	phone := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	mac := &Device{ID: "mac", Name: "MacBook", Paired: true}
	now := time.Now()

	// The phone copied after the Mac, so the phone text wins.
	d.handleClipboard(mac, connectClip("mac text", now.Add(-2*time.Minute)))
	d.handleClipboard(phone, connectClip("phone text", now.Add(-time.Minute)))
	waitIdle(t, d, &d.content.clipQ)
	if clip.text != "phone text" || len(d.clipboard) != 2 {
		t.Fatalf("clipboard has %q, history %+v", clip.text, d.clipboard)
	}

	// The same copy again after a reconnect changes nothing.
	d.handleClipboard(mac, connectClip("mac text", now.Add(-2*time.Minute)))
	waitIdle(t, d, &d.content.clipQ)
	if clip.text != "phone text" || len(d.clipboard) != 2 || d.clipboard[0].Text != "phone text" {
		t.Fatalf("clipboard has %q, history %+v", clip.text, d.clipboard)
	}

	// A copy time after now counts as now, so a device clock that is ahead
	// does not make the next copies stale.
	d.handleClipboard(mac, connectClip("mac text from the future", now.Add(time.Hour)))
	d.handleClipboard(phone, connectClip("new phone text", time.Now().Add(time.Second)))
	waitIdle(t, d, &d.content.clipQ)
	if clip.text != "new phone text" {
		t.Errorf("clipboard has %q, want the new phone text", clip.text)
	}
}

func TestDeleteClip(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.snippetsDir = t.TempDir()

	d.addClipLocked(ClipEntry{Text: "text 1", Dir: "out"})
	textID := d.clipboard[0].ID
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}
	imageID := d.clipboard[0].ID

	if len(d.clipboard) != 2 || clipFiles(t, d.clipDir) != 1 {
		t.Fatalf("expected 2 entries and 1 file, got %d entries, %d files", len(d.clipboard), clipFiles(t, d.clipDir))
	}

	// Delete image entry.
	if err := d.deleteClip(imageID); err != nil {
		t.Fatalf("deleteClip image: %v", err)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].ID != textID {
		t.Fatalf("expected 1 entry left, got %+v", d.clipboard)
	}
	if n := clipFiles(t, d.clipDir); n != 0 {
		t.Errorf("image file not deleted, count: %d", n)
	}

	// Delete text entry.
	if err := d.deleteClip(textID); err != nil {
		t.Fatalf("deleteClip text: %v", err)
	}
	if len(d.clipboard) != 0 {
		t.Fatalf("expected 0 entries left, got %+v", d.clipboard)
	}

	// Delete unknown ID returns not_found error.
	err := d.deleteClip("missing")
	var apiErr *Error
	if !errors.As(err, &apiErr) || apiErr.Code != "not_found" {
		t.Errorf("delete missing ID: want not_found error, got %v", err)
	}

	// Delete pinned entry.
	d.addClipLocked(ClipEntry{Text: "pinned text", Dir: "out"})
	pinnedID := d.clipboard[0].ID
	if _, err := d.pinClip(pinnedID, 0); err != nil {
		t.Fatal(err)
	}
	if len(d.snippets) != 1 {
		t.Fatalf("expected 1 snippet, got %d", len(d.snippets))
	}
	if err := d.deleteClip(pinnedID); err != nil {
		t.Fatalf("deleteClip pinned: %v", err)
	}
	if len(d.clipboard) != 0 || len(d.snippets) != 0 {
		t.Fatalf("expected 0 clips and 0 snippets, got %d clips, %d snippets", len(d.clipboard), len(d.snippets))
	}
}

func TestClearClips(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.snippetsDir = t.TempDir()

	d.addClipLocked(ClipEntry{Text: "clip 1", Dir: "out"})
	id1 := d.clipboard[0].ID
	d.addClipLocked(ClipEntry{Text: "clip 2", Dir: "out"})
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}

	// Pin clip 1 as snippet.
	if _, err := d.pinClip(id1, 0); err != nil {
		t.Fatal(err)
	}

	if len(d.clipboard) != 3 || len(d.snippets) != 1 || clipFiles(t, d.clipDir) != 1 {
		t.Fatalf("setup failed: %d clips, %d snippets, %d files", len(d.clipboard), len(d.snippets), clipFiles(t, d.clipDir))
	}

	// Clear unpinned clipboard history only.
	if err := d.clearClips(false); err != nil {
		t.Fatalf("clearClips(false): %v", err)
	}
	if len(d.clipboard) != 0 {
		t.Errorf("expected empty clipboard, got %d entries", len(d.clipboard))
	}
	if n := clipFiles(t, d.clipDir); n != 0 {
		t.Errorf("expected 0 clip files, got %d", n)
	}
	if len(d.snippets) != 1 {
		t.Errorf("expected snippets preserved, got %d", len(d.snippets))
	}

	// Clear all including snippets.
	if err := d.clearClips(true); err != nil {
		t.Fatalf("clearClips(true): %v", err)
	}
	if len(d.snippets) != 0 {
		t.Errorf("expected empty snippets, got %d", len(d.snippets))
	}

	// Test via Call API.
	d.addClipLocked(ClipEntry{Text: "call test", Dir: "out"})
	callID := d.clipboard[0].ID
	if _, err := d.Call(t.Context(), "clipboard.delete", []byte(fmt.Sprintf(`{"id":%q}`, callID))); err != nil {
		t.Fatalf("Call clipboard.delete: %v", err)
	}
	if len(d.clipboard) != 0 {
		t.Errorf("expected empty clipboard after API delete")
	}

	d.addClipLocked(ClipEntry{Text: "call test 2", Dir: "out"})
	if _, err := d.Call(t.Context(), "clipboard.clear", []byte(`{}`)); err != nil {
		t.Fatalf("Call clipboard.clear: %v", err)
	}
	if len(d.clipboard) != 0 {
		t.Errorf("expected empty clipboard after API clear")
	}
}

func TestClipboardLimitSetting(t *testing.T) {
	d, _ := clipDaemon(t, true)
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())

	// Default is 50.
	if d.cfg.ClipLimit() != config.DefaultClipboardLimit {
		t.Errorf("default limit %d, want %d", d.cfg.ClipLimit(), config.DefaultClipboardLimit)
	}

	// Change limit to 5.
	if err := d.setSetting("clipboardLimit", 5); err != nil {
		t.Fatalf("setSetting clipboardLimit 5: %v", err)
	}
	if d.cfg.ClipLimit() != 5 {
		t.Errorf("limit %d, want 5", d.cfg.ClipLimit())
	}

	// Add 8 entries.
	for i := range 8 {
		d.addClipLocked(ClipEntry{Text: fmt.Sprint("item ", i), Dir: "out"})
	}
	if len(d.clipboard) != 5 {
		t.Fatalf("expected 5 items kept, got %d", len(d.clipboard))
	}
	// The newest entry is "item 7".
	if d.clipboard[0].Text != "item 7" {
		t.Errorf("top item %q, want 'item 7'", d.clipboard[0].Text)
	}

	// Reduce limit to 3. It should trim immediately.
	if err := d.setSetting("clipboardLimit", 3); err != nil {
		t.Fatalf("setSetting clipboardLimit 3: %v", err)
	}
	if len(d.clipboard) != 3 {
		t.Fatalf("expected 3 items after trim, got %d", len(d.clipboard))
	}

	// Invalid limits.
	if err := d.setSetting("clipboardLimit", 0); err == nil {
		t.Errorf("limit 0 should fail")
	}
	if err := d.setSetting("clipboardLimit", 501); err == nil {
		t.Errorf("limit 501 should fail")
	}
	if err := d.setSetting("clipboardLimit", "not a number"); err == nil {
		t.Errorf("string limit should fail")
	}
}
