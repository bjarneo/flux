package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"flux/internal/lan"
	"flux/internal/omarchytheme"
	"flux/internal/proto"
	"flux/internal/wallpaper"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type galleryTestRig struct {
	d           *Daemon
	dev         *Device
	desk, phone *lan.Link
	reader      omarchytheme.Reader
	packets     chan *proto.Packet
	ctx         context.Context
}

func newGalleryTestRig(t *testing.T) *galleryTestRig {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	desk, phone, deskID, phoneID := linkPair(t, ctx)
	t.Cleanup(func() { cancel(); desk.Close(); phone.Close() })
	d, dev, _, _ := ohmThemeTestDaemon()
	d.ctx, d.selfID = ctx, deskID
	dev.ID, dev.link, dev.Cert = phoneID, desk, desk.Cert
	dev.Incoming = append(dev.Incoming, wallpaper.Type)
	dev.Outgoing = append(dev.Outgoing, wallpaper.Type)
	d.devices = map[string]*Device{phoneID: dev}
	root := t.TempDir()
	reader := omarchytheme.Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "themes"), RuntimeDir: root}
	d.wallpapers.reader = &reader
	d.wallpapers.notify = func(string) error { return nil }
	state := filepath.Join(reader.Home, ".local/state/omarchy/current")
	if err := os.MkdirAll(filepath.Join(state, "theme/backgrounds"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "theme.name"), []byte("gallery-theme\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "theme/colors.toml"), []byte("background=\"#101010\"\nforeground=\"#eeeeee\"\naccent=\"#123456\"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for i, name := range []string{"a.png", "b.png"} {
		im := image.NewRGBA(image.Rect(0, 0, 160, 90))
		shade := color.White
		if i == 1 {
			shade = color.Black
		}
		for y := 0; y < 90; y++ {
			for x := 0; x < 160; x++ {
				im.Set(x, y, shade)
			}
		}
		var encoded bytes.Buffer
		if err := png.Encode(&encoded, im); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(state, "theme/backgrounds", name), encoded.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(state, "theme/backgrounds/a.png"), filepath.Join(state, "background")); err != nil {
		t.Fatal(err)
	}
	rig := &galleryTestRig{d: d, dev: dev, desk: desk, phone: phone, reader: reader, packets: make(chan *proto.Packet, 64), ctx: ctx}
	go phone.Receive(func(p *proto.Packet) {
		select {
		case rig.packets <- p:
		case <-ctx.Done():
		}
	})
	go desk.Receive(func(p *proto.Packet) { d.handlePacket(dev, desk, p) })
	return rig
}

func (r *galleryTestRig) next(t *testing.T) (*proto.Packet, map[string]any) {
	t.Helper()
	select {
	case p := <-r.packets:
		var body map[string]any
		if json.Unmarshal(p.Body, &body) != nil || p.Type != wallpaper.Type {
			t.Fatal("invalid wallpaper packet")
		}
		return p, body
	case <-time.After(5 * time.Second):
		t.Fatal("gallery packet timeout")
		return nil, nil
	}
}

func (r *galleryTestRig) waitSender() {
	r.d.wallpapers.mu.Lock()
	peer := r.d.wallpaperPeer(r.dev, r.desk)
	r.d.wallpapers.mu.Unlock()
	peer.sending.Lock()
	peer.sending.Unlock()
}

func TestWallpaperGalleryTLSSelectionSendsOriginalToSource(t *testing.T) {
	r := newGalleryTestRig(t)
	request := strings.Repeat("a", 32)
	if err := r.phone.Send(proto.New(wallpaper.Type, map[string]string{"kind": "gallery_request", "operation": request})); err != nil {
		t.Fatal(err)
	}
	_, begin := r.next(t)
	if begin["kind"] != "gallery_begin" || begin["operation"] != request || begin["count"] != float64(2) {
		t.Fatal("missing full gallery header", begin)
	}
	ids := []string{}
	for range 2 {
		_, item := r.next(t)
		if item["kind"] != "gallery_item" || item["operation"] != request {
			t.Fatal("invalid gallery item")
		}
		preview, err := base64.StdEncoding.DecodeString(item["preview"].(string))
		config, decodeErr := jpeg.DecodeConfig(bytes.NewReader(preview))
		if err != nil || decodeErr != nil || len(preview) > 16<<10 || config.Width > 320 || config.Height > 180 {
			t.Fatal("invalid wire preview")
		}
		ids = append(ids, item["id"].(string))
	}
	_, end := r.next(t)
	if end["kind"] != "gallery_end" || end["operation"] != request || ids[0] == ids[1] {
		t.Fatal("incomplete/duplicate gallery")
	}
	op := strings.Repeat("b", 32)
	if err := r.phone.Send(proto.New(wallpaper.Type, map[string]string{"kind": "gallery_select", "operation": op, "theme": begin["theme"].(string), "revision": begin["revision"].(string), "id": ids[1]})); err != nil {
		t.Fatal(err)
	}
	_, selected := r.next(t)
	if selected["kind"] != "gallery_selected" || selected["operation"] != op || selected["ok"] != true {
		t.Fatal("gallery selection failed", selected)
	}
	r.waitSender()
	c, ok := r.reader.ReadRevision()
	if !ok || c.Current != begin["theme"] {
		t.Fatal("selection changed theme")
	}
	go r.d.sendOriginalSnapshot(r.ctx, r.dev, r.desk, c)
	_, state := r.next(t)
	if state["kind"] != "state" || state["revision"] != c.Revision {
		t.Fatal("source phone did not receive original state")
	}
	wanted, err := os.ReadFile(filepath.Join(r.reader.Home, ".local/state/omarchy/current/theme/backgrounds/b.png"))
	if err != nil {
		t.Fatal(err)
	}
	var receiver wallpaper.Receiver
	complete := false
	for !complete {
		packet, _ := r.next(t)
		ack := receiver.Feed(packet.Body, r.d.selfID, "", func(meta wallpaper.Meta, data []byte) (string, error) {
			if !bytes.Equal(data, wanted) {
				t.Error("gallery source received preview instead of original")
			}
			complete = true
			return meta.Revision, nil
		})
		if ack != nil && !ack.OK {
			t.Fatal("original transfer failed", ack.Error)
		}
	}
	// A fresh selection of already active pixels must still deliver an original
	// to its source phone; an ACK cannot stand in for the image.
	r.waitSender()
	r.d.wallpapers.mu.Lock()
	peer := r.d.wallpaperPeer(r.dev, r.desk)
	peer.revision, peer.next = c.Revision, time.Time{}
	r.d.wallpapers.mu.Unlock()
	op = strings.Repeat("c", 32)
	r.phone.Send(proto.New(wallpaper.Type, map[string]string{"kind": "gallery_select", "operation": op, "theme": c.Current, "revision": c.Revision, "id": ids[1]}))
	_, selected = r.next(t)
	if selected["ok"] != true {
		t.Fatal("same image selection failed", selected)
	}
	r.waitSender()
	go r.d.sendOriginalSnapshot(r.ctx, r.dev, r.desk, c)
	_, state = r.next(t)
	if state["kind"] != "state" {
		t.Fatal("same-pixel selection suppressed its source original")
	}
}

func TestWallpaperGalleryQueuedRequestCannotSurviveBookRevocation(t *testing.T) {
	r := newGalleryTestRig(t)
	r.d.wallpapers.mu.Lock()
	peer := r.d.wallpaperPeer(r.dev, r.desk)
	peer.sending.Lock()
	r.d.wallpapers.mu.Unlock()
	r.d.handleOriginalWallpaper(r.dev, r.desk, proto.New(wallpaper.Type, map[string]string{"kind": "gallery_request", "operation": strings.Repeat("a", 32)}))
	r.d.mu.Lock()
	r.d.revokeOhmThemesLocked(r.dev)
	r.d.mu.Unlock()
	peer.sending.Unlock()
	select {
	case p := <-r.packets:
		t.Fatal("revoked gallery request sent data", p.Type)
	case <-time.After(120 * time.Millisecond):
	}
}

func TestWallpaperGalleryStrictRequestsAndFalseResult(t *testing.T) {
	for _, body := range []string{
		`{"kind":"gallery_request","operation":"` + strings.Repeat("a", 32) + `","extra":1}`,
		`{"kind":"gallery_request","kind":"gallery_request","operation":"` + strings.Repeat("a", 32) + `"}`,
		`{"kind":"gallery_request","operation":true}`,
		`{"kind":"gallery_select","operation":"` + strings.Repeat("a", 32) + `","theme":"../other","revision":"` + strings.Repeat("b", 64) + `","id":"` + strings.Repeat("c", 64) + `"}`,
	} {
		p := proto.New(wallpaper.Type, nil)
		p.Body = json.RawMessage(body)
		if _, ok := decodeWallpaperGallery(p); ok {
			t.Fatal("invalid gallery request was accepted")
		}
	}
	r := newGalleryTestRig(t)
	c, ok := r.reader.ReadRevision()
	if !ok {
		t.Fatal("revision")
	}
	r.phone.Send(proto.New(wallpaper.Type, map[string]string{"kind": "gallery_select", "operation": strings.Repeat("a", 32), "theme": c.Current, "revision": c.Revision, "id": strings.Repeat("f", 64)}))
	_, result := r.next(t)
	if result["kind"] != "gallery_selected" || result["ok"] != false {
		t.Fatal("false result omitted or foreign ID accepted", result)
	}
}
