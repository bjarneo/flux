package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

var ohmThemeRequestID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

type ohmThemeBackend interface {
	OhmCatalog() (desktop.OhmThemeCatalog, error)
	ApplyContext(context.Context, string) error
}

type ohmThemeSelection struct {
	Version   int    `json:"version"`
	RequestID string `json:"requestId"`
	ID        string `json:"id"`
}

// A book's identity is an authorization epoch. Removing it on unpairing
// invalidates queued work even if the same TLS link is paired again quickly.
type ohmThemeRequestBook struct{ ids map[string]bool }

func decodeOhmThemeSelection(p *proto.Packet) (ohmThemeSelection, bool) {
	var body ohmThemeSelection
	if p.Type != proto.TypeOmarchyThemeSelect || p.ID < 0 || len(p.Body) > 4096 ||
		p.PayloadSize != 0 || p.PayloadTransferInfo != nil {
		return body, false
	}
	fields, err := ohmThemeBodyFields(p.Body)
	if err != nil || len(fields) != 3 || fields["version"] == nil ||
		fields["requestId"] == nil || fields["id"] == nil || p.Decode(&body) != nil {
		return body, false
	}
	return body, body.Version == 1 && ohmThemeRequestID.MatchString(body.RequestID) &&
		validThemeID(body.ID) && len(body.ID) <= 64
}

func ohmThemeBodyFields(raw []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return nil, errors.New("invalid theme selection body")
	}
	fields := map[string]json.RawMessage{}
	for decoder.More() {
		token, tokenErr := decoder.Token()
		key, ok := token.(string)
		if tokenErr != nil || !ok || fields[key] != nil {
			return nil, errors.New("duplicate or invalid theme selection field")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, err
		}
		fields[key] = value
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("trailing theme selection data")
	}
	return fields, nil
}

// All async theme work remains attached to the exact paired control link.
// A replaced link cannot apply a queued selection or receive its result.
func (d *Daemon) currentOhmThemeLink(dev *Device, l *lan.Link) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.currentOhmThemeLinkLocked(dev, l)
}

func (d *Daemon) currentOhmThemeLinkLocked(dev *Device, l *lan.Link) bool {
	if d.opts.Headless || dev == nil || l == nil || d.devices[dev.ID] != dev || !dev.Paired || dev.link != l || dev.Cert != l.Cert {
		return false
	}
	select {
	case <-l.Done():
		return false
	default:
	}
	return true
}

func (d *Daemon) rememberOhmThemeRequest(dev *Device, l *lan.Link, id string) bool {
	return d.beginOhmThemeRequest(dev, l, id) != nil
}

func (d *Daemon) beginOhmThemeRequest(dev *Device, l *lan.Link, id string) *ohmThemeRequestBook {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.currentOhmThemeLinkLocked(dev, l) ||
		!dev.supports(proto.TypeOmarchyThemeSelect) || !dev.accepts(proto.TypeOmarchyThemeSelected) {
		return nil
	}
	if d.ohmThemeRequests == nil {
		d.ohmThemeRequests = map[*lan.Link]*ohmThemeRequestBook{}
	}
	for link := range d.ohmThemeRequests {
		live := false
		for _, peer := range d.devices {
			if peer.Paired && peer.link == link {
				live = true
				break
			}
		}
		if !live {
			delete(d.ohmThemeRequests, link)
		}
	}
	book := d.ohmThemeRequests[l]
	if book == nil {
		book = &ohmThemeRequestBook{ids: map[string]bool{}}
		d.ohmThemeRequests[l] = book
	}
	// Retain every seen ID, refusing further requests rather than forgetting
	// replay protection on a very long-lived session.
	if book.ids[id] || len(book.ids) >= 256 {
		return nil
	}
	book.ids[id] = true
	return book
}

func (d *Daemon) currentOhmThemeRequest(dev *Device, l *lan.Link, book *ohmThemeRequestBook) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.currentOhmThemeLinkLocked(dev, l) && (book == nil || d.ohmThemeRequests[l] == book)
}

// Caller holds d.mu. Revocation occurs before any network notice is sent.
func (d *Daemon) revokeOhmThemesLocked(dev *Device) {
	delete(d.ohmThemeRequests, dev.link)
}

func (d *Daemon) handleOhmTheme(dev *Device, l *lan.Link, p *proto.Packet) {
	received := time.Now()
	body, ok := decodeOhmThemeSelection(p)
	if !ok {
		return
	}
	book := d.beginOhmThemeRequest(dev, l, body.RequestID)
	if book == nil {
		return
	}
	backend, ok := d.themes.(ohmThemeBackend)
	if !ok {
		return
	}
	parent := d.ctx
	if parent == nil {
		parent = context.Background()
	}
	// The deadline includes waiting for a previous theme setter. Expired
	// queued requests must not change the desktop after Ohm has timed out.
	ctx, cancel := context.WithDeadline(parent, received.Add(12*time.Second))
	go func() {
		defer cancel()
		err := d.selectOhmTheme(ctx, dev, l, backend, body.ID, book)
		if !d.currentOhmThemeRequest(dev, l, book) {
			return
		}
		current := d.themes.Active()
		if !validThemeID(current) || len(current) > 64 {
			return
		}
		d.sendOhmThemePacket(dev, l, book, proto.New(proto.TypeOmarchyThemeSelected, map[string]any{
			"version": 1, "requestId": body.RequestID, "ok": err == nil && current == body.ID, "current": current,
		}))
		if err != nil {
			d.logf("Omarchy theme selection failed: %v", err)
		}
		d.sendOhmThemeCatalog(dev, l)
	}()
}

func (d *Daemon) selectOhmTheme(ctx context.Context, dev *Device, l *lan.Link, backend ohmThemeBackend, id string, book *ohmThemeRequestBook) error {
	// This dedicated lock serializes canonical theme staging, without holding
	// the global device mutex through palette reads or process execution.
	for !d.themeMu.TryLock() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
	defer d.themeMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if !d.currentOhmThemeRequest(dev, l, book) {
		return errors.New("theme request link is no longer paired")
	}
	catalog, err := backend.OhmCatalog()
	if err != nil {
		return err
	}
	installed := false
	for _, theme := range catalog.Themes {
		if theme.ID == id {
			installed = true
			break
		}
	}
	if !installed {
		return errors.New("theme is not in the advertised palette catalog")
	}
	if !d.currentOhmThemeRequest(dev, l, book) {
		return errors.New("theme request link is no longer paired")
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// A disconnected, replaced or unpaired link cancels an in-flight setter.
	// The recheck immediately before Apply also excludes queued stale work.
	go func() {
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-l.Done():
				cancel()
				return
			case <-ticker.C:
				if !d.currentOhmThemeRequest(dev, l, book) {
					cancel()
					return
				}
			}
		}
	}()
	return backend.ApplyContext(ctx, id)
}

func (d *Daemon) sendOhmThemeCatalog(dev *Device, l *lan.Link) {
	backend, ok := d.themes.(ohmThemeBackend)
	if !ok || !d.currentOhmThemeLink(dev, l) {
		return
	}
	d.mu.Lock()
	accepts := dev.accepts(proto.TypeOmarchyTheme)
	d.mu.Unlock()
	if !accepts {
		return
	}
	catalog, err := backend.OhmCatalog()
	if err != nil {
		d.logf("read Omarchy palette catalog: %v", err)
		return
	}
	if !d.currentOhmThemeLink(dev, l) {
		return
	}
	d.sendOhmThemePacket(dev, l, nil, proto.New(proto.TypeOmarchyTheme, catalog))
}

// Both serializer admission and the TLS write are bounded. Authorization is
// rechecked inside the serializer, without holding device state during IO.
func (d *Daemon) sendOhmThemePacket(dev *Device, l *lan.Link, book *ohmThemeRequestBook, p *proto.Packet) {
	parent := d.ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	allowed := func() bool { return d.currentOhmThemeRequest(dev, l, book) }
	if err := l.SendWithinCurrent(ctx, p, allowed); err != nil {
		l.Abort()
	}
}

// ohmThemeLoop also notices selections made on the computer and installed
// palette changes. The Qt theme watcher cannot update network state in fluxd.
func (d *Daemon) ohmThemeLoop(ctx context.Context) {
	backend, ok := d.themes.(ohmThemeBackend)
	if !ok || d.opts.Headless {
		return
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	var previous [32]byte
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		catalog, err := backend.OhmCatalog()
		if err != nil {
			continue
		}
		encoded, err := json.Marshal(catalog)
		if err != nil {
			continue
		}
		current := sha256.Sum256(encoded)
		if current == previous {
			continue
		}
		previous = current
		type target struct {
			dev  *Device
			link *lan.Link
		}
		d.mu.Lock()
		var targets []target
		for _, dev := range d.devices {
			if dev.Paired && dev.link != nil && dev.accepts(proto.TypeOmarchyTheme) {
				targets = append(targets, target{dev, dev.link})
			}
		}
		d.mu.Unlock()
		packet := proto.New(proto.TypeOmarchyTheme, catalog)
		for _, target := range targets {
			if d.currentOhmThemeLink(target.dev, target.link) {
				d.sendOhmThemePacket(target.dev, target.link, nil, packet)
			}
		}
	}
}

var _ ohmThemeBackend = desktop.NewThemes()
