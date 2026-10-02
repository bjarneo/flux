package core

import (
	"bytes"
	"context"
	"encoding/json"
	"flux/internal/omarchytheme"
	"flux/internal/proto"
	"flux/internal/wallpaper"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestIntegratedOriginalsTLSAndNoEcho(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk, phone, deskID, phoneID := linkPair(t, ctx)
	defer desk.Close()
	defer phone.Close()
	d, dev, _, _ := ohmThemeTestDaemon()
	d.selfID = deskID
	dev.ID = phoneID
	dev.link = desk
	dev.Cert = desk.Cert
	d.devices = map[string]*Device{phoneID: dev}
	dev.Incoming = append(dev.Incoming, wallpaper.Type)
	dev.Outgoing = append(dev.Outgoing, wallpaper.Type)
	root := t.TempDir()
	reader := omarchytheme.Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "themes"), RuntimeDir: root}
	d.wallpapers.reader = &reader
	state := filepath.Join(reader.Home, ".local/state/omarchy/current")
	put := func(path string, data []byte) {
		t.Helper()
		if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(path, data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	put(filepath.Join(state, "theme.name"), []byte("tokyo-night\n"))
	put(filepath.Join(state, "theme/colors.toml"), []byte("background = \"#222222\"\nforeground = \"#eeeeee\"\naccent = \"#123456\"\n"))
	var imageBytes bytes.Buffer
	jpeg.Encode(&imageBytes, image.NewRGBA(image.Rect(0, 0, 3840, 2160)), &jpeg.Options{Quality: 95})
	original := imageBytes.Bytes()
	path := filepath.Join(state, "theme/backgrounds/original.jpg")
	put(path, original)
	if e := os.Symlink(path, filepath.Join(state, "background")); e != nil {
		t.Fatal(e)
	}
	var commits atomic.Int32
	d.wallpapers.notify = func(string) error { commits.Add(1); return nil }
	incoming := make(chan *proto.Packet, 64)
	go phone.Receive(func(p *proto.Packet) {
		select {
		case incoming <- p:
		case <-ctx.Done():
		}
	})
	go desk.Receive(func(p *proto.Packet) { d.handlePacket(dev, desk, p) })
	next := func() *proto.Packet {
		t.Helper()
		select {
		case p := <-incoming:
			return p
		case <-time.After(5 * time.Second):
			t.Fatal("packet timeout")
			return nil
		}
	}
	c, ok := reader.ReadRevision()
	if !ok {
		t.Fatal("revision")
	}
	done := make(chan struct{})
	go func() { d.sendOriginalSnapshot(ctx, dev, desk, c); close(done) }()
	first := next()
	var header map[string]any
	json.Unmarshal(first.Body, &header)
	if header["kind"] != "state" || header["revision"] != c.Revision {
		t.Fatal("missing original state", header)
	}
	var receiver wallpaper.Receiver
	complete := false
	for !complete {
		p := next()
		if p.Type != wallpaper.Type {
			t.Fatal("wrong capability")
		}
		ack := receiver.Feed(p.Body, deskID, "", func(m wallpaper.Meta, b []byte) (string, error) {
			if !bytes.Equal(b, original) || m.Width != 3840 || m.Height != 2160 {
				t.Error("original changed")
			}
			complete = true
			return m.Revision, nil
		})
		if ack != nil {
			phone.Send(proto.New(wallpaper.Type, ack))
		}
	}
	<-done
	// Reverse direction and retry: one native commit, correlated ACK, state only.
	m := wallpaper.Meta{Operation: strings.Repeat("a", 32), Origin: phoneID, Revision: c.Revision, Theme: c.Current, SHA256: wallpaper.Digest(original), MIME: "image/jpeg", Size: len(original), Width: 3840, Height: 2160}
	for attempt := 0; attempt < 2; attempt++ {
		if e := wallpaper.Send(m, original, func(msg wallpaper.Message) error { return phone.Send(proto.New(wallpaper.Type, msg)) }); e != nil {
			t.Fatal(e)
		}
		p := next()
		var ack wallpaper.Message
		json.Unmarshal(p.Body, &ack)
		if !ack.OK || ack.Operation != m.Operation {
			t.Fatal("missing ACK", string(p.Body))
		}
		p = next()
		json.Unmarshal(p.Body, &header)
		if header["kind"] != "state" {
			t.Fatal("image echo instead of state", string(p.Body))
		}
	}
	if commits.Load() != 1 {
		t.Fatal("retry reapplied", commits.Load())
	}
	current, ok := reader.ReadRevision()
	if !ok {
		t.Fatal("final revision")
	}
	got, e := reader.Original(current)
	if e != nil || !bytes.Equal(got, original) {
		t.Fatal("final bytes", e)
	}
	d.sendOriginalSnapshot(ctx, dev, desk, current)
	select {
	case p := <-incoming:
		t.Fatal("echo", p.Type)
	case <-time.After(100 * time.Millisecond):
	}
	// The exact live link book is revoked even before a socket is closed.
	d.wallpapers.mu.Lock()
	peer := d.wallpaperPeer(dev, desk)
	d.wallpapers.mu.Unlock()
	d.mu.Lock()
	d.revokeOhmThemesLocked(dev)
	d.mu.Unlock()
	if d.wallpaperAllowed(peer, desk) {
		t.Fatal("revoked original authority survived")
	}
}
