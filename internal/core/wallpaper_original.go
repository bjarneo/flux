package core

import (
	"context"
	"encoding/json"
	"errors"
	"flux/internal/lan"
	"flux/internal/omarchytheme"
	"flux/internal/proto"
	"flux/internal/wallpaper"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"
)

// Originals have an independent capability/state, leaving the strict existing
// v1 palette catalog and its consent/selection contract unchanged.
type wallpaperCoordinator struct {
	mu       sync.Mutex
	sessions map[*lan.Link]*wallpaperPeer
	reader   *omarchytheme.Reader // nil uses the fixed native roots
	notify   func(string) error   // isolated compositor seam
}
type wallpaperPeer struct {
	sending             sync.Mutex
	dev                 *Device
	book                *ohmThemeRequestBook
	receiver            wallpaper.Receiver
	operation, revision string
	next                time.Time
	galleryGeneration   atomic.Uint64
	galleryCancel       context.CancelFunc
}

func (d *Daemon) wallpaperReader() omarchytheme.Reader {
	if d.wallpapers.reader != nil {
		return *d.wallpapers.reader
	}
	home, _ := os.UserHomeDir()
	return omarchytheme.Reader{Home: home, SystemThemes: "/usr/share/omarchy/themes"}
}

// Caller holds wallpapers.mu. A revocation replaces the authorization book,
// so an old partial receive can never survive unpair/re-pair on one socket.
func (d *Daemon) wallpaperPeer(dev *Device, l *lan.Link) *wallpaperPeer {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.currentOhmThemeLinkLocked(dev, l) || !dev.accepts(wallpaper.Type) || !dev.supports(wallpaper.Type) {
		return nil
	}
	if d.ohmThemeRequests == nil {
		d.ohmThemeRequests = map[*lan.Link]*ohmThemeRequestBook{}
	}
	book := d.ohmThemeRequests[l]
	if book == nil {
		book = &ohmThemeRequestBook{ids: map[string]bool{}}
		d.ohmThemeRequests[l] = book
	}
	if d.wallpapers.sessions == nil {
		d.wallpapers.sessions = map[*lan.Link]*wallpaperPeer{}
	}
	for link, peer := range d.wallpapers.sessions {
		if !d.currentOhmThemeLinkLocked(peer.dev, link) || d.ohmThemeRequests[link] != peer.book {
			delete(d.wallpapers.sessions, link)
		}
	}
	peer := d.wallpapers.sessions[l]
	if peer == nil {
		peer = &wallpaperPeer{dev: dev, book: book}
		d.wallpapers.sessions[l] = peer
	}
	return peer
}
func (d *Daemon) wallpaperAllowed(peer *wallpaperPeer, l *lan.Link) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return peer != nil && d.currentOhmThemeLinkLocked(peer.dev, l) && d.ohmThemeRequests[l] == peer.book && peer.dev.accepts(wallpaper.Type) && peer.dev.supports(wallpaper.Type)
}
func (d *Daemon) sendOriginalPacket(ctx context.Context, peer *wallpaperPeer, l *lan.Link, body any) error {
	return l.SendWithinCurrent(ctx, proto.New(wallpaper.Type, body), func() bool { return d.wallpaperAllowed(peer, l) })
}
func (d *Daemon) handleOriginalWallpaper(dev *Device, l *lan.Link, p *proto.Packet) {
	if len(p.Body) > wallpaper.MaxMessage || p.PayloadSize != 0 || p.PayloadTransferInfo != nil {
		return
	}
	if d.handleWallpaperGallery(dev, l, p) {
		return
	}
	d.wallpapers.mu.Lock()
	defer d.wallpapers.mu.Unlock()
	peer := d.wallpaperPeer(dev, l)
	if peer == nil {
		return
	}
	var envelope struct {
		Kind, Operation, Revision string
		OK                        bool
	}
	if json.Unmarshal(p.Body, &envelope) != nil {
		return
	}
	if envelope.Kind == "ack" {
		if envelope.Operation == peer.operation && envelope.OK && envelope.Revision == peer.revision {
			peer.next = time.Time{}
		}
		return
	}
	reader := d.wallpaperReader()
	ack := peer.receiver.Feed(p.Body, dev.ID, "", func(m wallpaper.Meta, data []byte) (string, error) {
		// Serialize with the current palette setter as well as its filesystem flock.
		if !d.themeMu.TryLock() {
			return "", errors.New("busy")
		}
		defer d.themeMu.Unlock()
		return reader.CommitOriginal(m, data, func() bool { return d.wallpaperAllowed(peer, l) }, func(path string) error {
			if d.wallpapers.notify != nil {
				return d.wallpapers.notify(path)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			return exec.CommandContext(ctx, "omarchy-shell", "-q", "background", "set", path).Run()
		})
	})
	if ack != nil && d.wallpaperAllowed(peer, l) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := d.sendOriginalPacket(ctx, peer, l, ack); err == nil && ack.OK {
			// A successful incoming original is already present on its source phone.
			// Publish only new CAS state to that peer; other peers receive the image.
			c, ok := reader.ReadRevision()
			if ok && c.Revision == ack.Revision {
				if d.sendOriginalPacket(ctx, peer, l, map[string]string{"kind": "state", "theme": c.Current, "revision": c.Revision}) == nil {
					peer.revision = c.Revision
					peer.next = time.Time{}
				}
			}
		}
	}
}
func (d *Daemon) wallpaperLoop(ctx context.Context) {
	if d.opts.Headless {
		return
	}
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		d.wallpapers.mu.Lock()
		for link, peer := range d.wallpapers.sessions {
			if !d.wallpaperAllowed(peer, link) {
				delete(d.wallpapers.sessions, link)
			} else {
				peer.receiver.Expire()
			}
		}
		d.wallpapers.mu.Unlock()
		reader := d.wallpaperReader()
		catalog, ok := reader.ReadRevision()
		if !ok {
			continue
		}
		type target struct {
			dev  *Device
			link *lan.Link
		}
		var targets []target
		d.mu.Lock()
		for _, dev := range d.devices {
			if dev.Paired && dev.link != nil && dev.accepts(wallpaper.Type) && dev.supports(wallpaper.Type) {
				targets = append(targets, target{dev, dev.link})
			}
		}
		d.mu.Unlock()
		for _, t := range targets {
			d.sendOriginalSnapshot(ctx, t.dev, t.link, catalog)
		}
	}
}
func (d *Daemon) sendOriginalSnapshot(parent context.Context, dev *Device, l *lan.Link, c omarchytheme.Catalog) {
	d.wallpapers.mu.Lock()
	peer := d.wallpaperPeer(dev, l)
	if peer == nil || (peer.revision == c.Revision && (peer.next.IsZero() || time.Now().Before(peer.next))) {
		d.wallpapers.mu.Unlock()
		return
	}
	if !peer.sending.TryLock() {
		d.wallpapers.mu.Unlock()
		return
	}
	d.wallpapers.mu.Unlock()
	defer peer.sending.Unlock()
	data, err := d.wallpaperReader().Original(c)
	if err != nil {
		return
	}
	mime, w, h, err := wallpaper.Inspect(data)
	if err != nil {
		return
	}
	digest := wallpaper.Digest(data)
	m := wallpaper.Meta{Operation: wallpaper.Digest([]byte(c.Revision + digest))[:32], Origin: d.selfID, Revision: c.Revision, Theme: c.Current, SHA256: digest, MIME: mime, Size: len(data), Width: w, Height: h}
	d.wallpapers.mu.Lock()
	peer.operation = m.Operation
	peer.revision = m.Revision
	peer.next = time.Now().Add(30 * time.Second)
	d.wallpapers.mu.Unlock()
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()
	if err = d.sendOriginalPacket(ctx, peer, l, map[string]string{"kind": "state", "theme": c.Current, "revision": c.Revision}); err != nil {
		return
	}
	err = wallpaper.Send(m, data, func(message wallpaper.Message) error { return d.sendOriginalPacket(ctx, peer, l, message) })
	if err != nil {
		l.Abort()
		return
	}
}
