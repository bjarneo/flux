package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flux/internal/lan"
	"flux/internal/omarchytheme"
	"flux/internal/proto"
	"flux/internal/wallpaper"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

var wallpaperGalleryOperation = regexp.MustCompile(`^[0-9a-f]{32}$`)

type wallpaperGalleryRequest struct {
	Kind, Operation, Theme, Revision, ID string
}

func decodeWallpaperGallery(p *proto.Packet) (wallpaperGalleryRequest, bool) {
	var request wallpaperGalleryRequest
	if p.Type != wallpaper.Type || p.ID < 0 || len(p.Body) > 4096 || p.PayloadSize != 0 || p.PayloadTransferInfo != nil {
		return request, false
	}
	fields, err := ohmThemeBodyFields(p.Body)
	if err != nil || json.Unmarshal(p.Body, &request) != nil || !wallpaperGalleryOperation.MatchString(request.Operation) {
		return request, false
	}
	switch request.Kind {
	case "gallery_request":
		return request, len(fields) == 2 && fields["kind"] != nil && fields["operation"] != nil
	case "gallery_select":
		return request, len(fields) == 5 && fields["kind"] != nil && fields["operation"] != nil && fields["theme"] != nil && fields["revision"] != nil && fields["id"] != nil && omarchytheme.ValidSelectionID(request.Theme) && omarchytheme.ValidRevision(request.Revision) && omarchytheme.ValidRevision(request.ID)
	}
	return request, false
}

// Dispatch before the original receiver's mutex/Feed: catalog traffic must
// neither cancel a partial original nor perform filesystem IO under that mutex.
func (d *Daemon) handleWallpaperGallery(dev *Device, l *lan.Link, p *proto.Packet) bool {
	var envelope struct{ Kind string }
	if json.Unmarshal(p.Body, &envelope) != nil || !strings.HasPrefix(envelope.Kind, "gallery_") {
		return false
	}
	request, ok := decodeWallpaperGallery(p)
	if !ok {
		return true
	}
	parent := d.ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 30*time.Second)
	d.wallpapers.mu.Lock()
	peer := d.wallpaperPeer(dev, l)
	if peer == nil {
		d.wallpapers.mu.Unlock()
		cancel()
		return true
	}
	if peer.galleryCancel != nil {
		peer.galleryCancel()
	}
	epoch := peer.galleryGeneration.Add(1)
	peer.galleryCancel = cancel
	d.wallpapers.mu.Unlock()
	go func() {
		defer cancel()
		defer func() {
			d.wallpapers.mu.Lock()
			if peer.galleryGeneration.Load() == epoch {
				peer.galleryCancel = nil
			}
			d.wallpapers.mu.Unlock()
		}()
		go func() {
			tick := time.NewTicker(50 * time.Millisecond)
			defer tick.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-l.Done():
					cancel()
					return
				case <-tick.C:
					if !d.currentWallpaperGallery(peer, l, epoch) {
						cancel()
						return
					}
				}
			}
		}()
		for !peer.sending.TryLock() {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
		defer peer.sending.Unlock()
		if ctx.Err() != nil || !d.currentWallpaperGallery(peer, l, epoch) {
			return
		}
		if request.Kind == "gallery_select" {
			d.selectWallpaperGallery(ctx, peer, l, epoch, request)
		} else {
			d.sendWallpaperGallery(ctx, peer, l, epoch, request.Operation)
		}
	}()
	return true
}

func (d *Daemon) currentWallpaperGallery(peer *wallpaperPeer, l *lan.Link, epoch uint64) bool {
	return peer != nil && peer.galleryGeneration.Load() == epoch && d.wallpaperAllowed(peer, l)
}

func (d *Daemon) sendWallpaperGalleryPacket(ctx context.Context, peer *wallpaperPeer, l *lan.Link, epoch uint64, body any, expected *omarchytheme.Gallery) error {
	// Filesystem CAS reads precede serializer admission. Its final guard must
	// stay short so the write deadline also bounds a stalled control writer.
	if expected != nil {
		c, ok := d.wallpaperReader().ReadRevision()
		if !ok || c.Current != expected.Theme || c.Revision != expected.Revision {
			return context.Canceled
		}
	}
	write, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return l.SendWithinCurrent(write, proto.New(wallpaper.Type, body), func() bool {
		return ctx.Err() == nil && d.currentWallpaperGallery(peer, l, epoch)
	})
}

func (d *Daemon) sendWallpaperGallery(ctx context.Context, peer *wallpaperPeer, l *lan.Link, epoch uint64, operation string) {
	gallery, err := d.wallpaperReader().Gallery(ctx)
	if err != nil {
		d.sendWallpaperGalleryPacket(ctx, peer, l, epoch, map[string]any{"kind": "gallery_error", "operation": operation}, nil)
		return
	}
	if d.sendWallpaperGalleryPacket(ctx, peer, l, epoch, map[string]any{"kind": "gallery_begin", "operation": operation, "theme": gallery.Theme, "revision": gallery.Revision, "current": gallery.Current, "count": len(gallery.Choices)}, &gallery) != nil {
		return
	}
	for _, choice := range gallery.Choices {
		if d.sendWallpaperGalleryPacket(ctx, peer, l, epoch, map[string]any{"kind": "gallery_item", "operation": operation, "id": choice.ID, "label": choice.Label, "preview": base64.StdEncoding.EncodeToString(choice.Preview)}, &gallery) != nil {
			return
		}
	}
	d.sendWallpaperGalleryPacket(ctx, peer, l, epoch, map[string]any{"kind": "gallery_end", "operation": operation}, &gallery)
}

func (d *Daemon) selectWallpaperGallery(ctx context.Context, peer *wallpaperPeer, l *lan.Link, epoch uint64, request wallpaperGalleryRequest) {
	reader := d.wallpaperReader()
	meta, data, err := reader.GalleryOriginal(ctx, request.Theme, request.Revision, request.ID)
	if err == nil {
		for !d.themeMu.TryLock() {
			select {
			case <-ctx.Done():
				err = ctx.Err()
			case <-time.After(5 * time.Millisecond):
			}
			if err != nil {
				break
			}
		}
		if err == nil {
			meta.Operation, meta.Origin = request.Operation, peer.dev.ID
			_, err = reader.CommitOriginal(meta, data, func() bool { return ctx.Err() == nil && d.currentWallpaperGallery(peer, l, epoch) }, func(path string) error {
				if d.wallpapers.notify != nil {
					return d.wallpapers.notify(path)
				}
				notify, cancel := context.WithTimeout(ctx, 3*time.Second)
				defer cancel()
				return exec.CommandContext(notify, "omarchy-shell", "-q", "background", "set", path).Run()
			})
			d.themeMu.Unlock()
		}
	}
	if err == nil && (ctx.Err() != nil || !d.currentWallpaperGallery(peer, l, epoch)) {
		err = errors.New("revoked")
	}
	if err == nil {
		// A gallery selection carries no original to the phone. Even selecting
		// the same pixels must schedule the normal watcher snapshot to its source.
		d.wallpapers.mu.Lock()
		if peer.galleryGeneration.Load() == epoch {
			peer.revision = ""
			peer.next = time.Time{}
		}
		d.wallpapers.mu.Unlock()
	}
	d.sendWallpaperGalleryPacket(ctx, peer, l, epoch, map[string]any{"kind": "gallery_selected", "operation": request.Operation, "ok": err == nil}, nil)
}
