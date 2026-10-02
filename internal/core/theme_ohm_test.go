package core

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

type fakeOhmThemes struct {
	fakeThemes
	mu      sync.Mutex
	onApply func(context.Context, string) error
}

func (f *fakeOhmThemes) OhmCatalog() (desktop.OhmThemeCatalog, error) {
	return desktop.OhmThemeCatalog{Kind: "catalog", Version: 1, Current: f.Active(), Themes: []desktop.OhmTheme{
		{ID: "tokyo-night", Label: "Tokyo Night", Palette: desktop.OhmThemePalette{Name: "tokyo-night", Mode: "dark", Source: "omarchy", Colors: map[string]string{"background": "#1a1b26"}}},
		{ID: "catppuccin", Label: "Catppuccin", Palette: desktop.OhmThemePalette{Name: "catppuccin", Mode: "dark", Source: "omarchy", Colors: map[string]string{"background": "#1e1e2e"}}},
	}}, f.err
}

func (f *fakeOhmThemes) Active() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.applied != "" {
		return f.applied
	}
	return "tokyo-night"
}

func (f *fakeOhmThemes) ApplyContext(ctx context.Context, id string) error {
	if f.onApply != nil {
		return f.onApply(ctx, id)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.Apply(id)
}

func ohmThemeTestDaemon() (*Daemon, *Device, *lan.Link, *fakeOhmThemes) {
	l := &lan.Link{}
	dev := &Device{ID: "phone", Paired: true, link: l, Outgoing: []string{proto.TypeOmarchyThemeSelect}, Incoming: []string{proto.TypeOmarchyThemeSelected, proto.TypeOmarchyTheme}}
	backend := &fakeOhmThemes{fakeThemes: fakeThemes{catalog: []string{"catppuccin", "tokyo-night"}}}
	d := &Daemon{cfg: &config.Config{}, logger: log.New(io.Discard, "", 0), themes: backend, devices: map[string]*Device{dev.ID: dev}, ctx: context.Background()}
	return d, dev, l, backend
}

func TestOhmThemeSelectionRequiresExactVersionedUUIDBody(t *testing.T) {
	valid := `{"version":1,"requestId":"5da63e00-8c22-4bc8-b615-290e4248e3fd","id":"catppuccin"}`
	cases := []struct {
		body string
		want bool
	}{
		{valid, true},
		{`{"version":1,"requestId":"not-a-uuid","id":"catppuccin"}`, false},
		{`{"version":1,"requestId":"5da63e00-8c22-4bc8-b615-290e4248e3fd","id":"../escape"}`, false},
		{`{"version":1,"requestId":"5da63e00-8c22-4bc8-b615-290e4248e3fd","id":"catppuccin","command":"x"}`, false},
		{`{"version":1,"version":1,"requestId":"5da63e00-8c22-4bc8-b615-290e4248e3fd","id":"catppuccin"}`, false},
		{`{"version":1.0,"requestId":"5da63e00-8c22-4bc8-b615-290e4248e3fd","id":"catppuccin"}`, false},
		{valid + `{}`, false},
	}
	for _, c := range cases {
		_, ok := decodeOhmThemeSelection(&proto.Packet{Type: proto.TypeOmarchyThemeSelect, ID: 1, Body: json.RawMessage(c.body)})
		if ok != c.want {
			t.Errorf("decode(%s) = %v, want %v", c.body, ok, c.want)
		}
	}
}

func TestOhmThemeSelectionAppliesOnlyAdvertisedPaletteIDs(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	if err := d.selectOhmTheme(context.Background(), dev, l, backend, "catppuccin", nil); err != nil {
		t.Fatal(err)
	}
	if backend.applied != "catppuccin" {
		t.Fatalf("applied %q", backend.applied)
	}
	backend.applied = ""
	if err := d.selectOhmTheme(context.Background(), dev, l, backend, "nord", nil); err == nil || backend.applied != "" {
		t.Fatal("unadvertised theme was applied")
	}
}

func TestOhmQueuedSelectionDoesNotApplyAfterLinkReplacement(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	d.themeMu.Lock()
	done := make(chan error, 1)
	go func() { done <- d.selectOhmTheme(context.Background(), dev, l, backend, "catppuccin", nil) }()
	d.mu.Lock()
	dev.link = &lan.Link{}
	d.mu.Unlock()
	d.themeMu.Unlock()
	if err := <-done; err == nil || backend.applied != "" {
		t.Fatal("replaced link applied a queued selection")
	}
}

func TestOhmInFlightSetterCancelsWhenTrustIsRevoked(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	started := make(chan struct{})
	backend.onApply = func(ctx context.Context, _ string) error { close(started); <-ctx.Done(); return ctx.Err() }
	done := make(chan error, 1)
	go func() { done <- d.selectOhmTheme(context.Background(), dev, l, backend, "catppuccin", nil) }()
	<-started
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("revoked link completed selection")
		}
	case <-time.After(time.Second):
		t.Fatal("revoked link did not cancel its setter")
	}
}

func TestOhmThemeRequestCannotBeReplayedOrMovedToReplacementLink(t *testing.T) {
	d, dev, l, _ := ohmThemeTestDaemon()
	id := "5da63e00-8c22-4bc8-b615-290e4248e3fd"
	if !d.rememberOhmThemeRequest(dev, l, id) || d.rememberOhmThemeRequest(dev, l, id) {
		t.Fatal("theme replay policy failed")
	}
	d.mu.Lock()
	dev.link = &lan.Link{}
	d.mu.Unlock()
	if d.rememberOhmThemeRequest(dev, l, "595a5001-0ae2-44dc-9f70-a246df8f0d4f") {
		t.Fatal("stale link registered theme request")
	}
}

func TestOhmQueuedSelectionCannotReviveAfterRepairOnSameLink(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	id := "5da63e00-8c22-4bc8-b615-290e4248e3fd"
	book := d.beginOhmThemeRequest(dev, l, id)
	if book == nil {
		t.Fatal("theme request rejected")
	}
	d.themeMu.Lock()
	done := make(chan error, 1)
	go func() { done <- d.selectOhmTheme(context.Background(), dev, l, backend, "catppuccin", book) }()
	d.mu.Lock()
	dev.Paired = false
	d.revokeOhmThemesLocked(dev)
	dev.Paired = true
	d.mu.Unlock()
	// A fresh request on renewed trust has its own authorization epoch,
	// including when a malicious peer reuses the old wire request ID.
	if next := d.beginOhmThemeRequest(dev, l, id); next == nil || next == book {
		t.Fatal("renewed trust did not create a new request epoch")
	}
	d.themeMu.Unlock()
	if err := <-done; err == nil || backend.applied != "" {
		t.Fatal("old request revived after re-pairing")
	}
}

func TestOhmQueuedSelectionExpiresWithoutApplyingAfterLockWait(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	d.themeMu.Lock()
	defer d.themeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- d.selectOhmTheme(ctx, dev, l, backend, "catppuccin", nil) }()
	select {
	case err := <-done:
		if err == nil || backend.applied != "" {
			t.Fatal("expired request applied a theme")
		}
	case <-time.After(time.Second):
		t.Fatal("expired request remained blocked on theme staging lock")
	}
}

// Validate the catalog, local-change watcher and correlated success/failure
// replies over real TLS control links, without running a desktop setter.
func TestOhmThemeCatalogAndSelectionOverLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk, phone, _, phoneID := linkPair(t, ctx)
	defer desk.Close()
	defer phone.Close()
	d, dev, _, backend := ohmThemeTestDaemon()
	d.ctx = ctx
	d.devices = map[string]*Device{phoneID: dev}
	dev.ID, dev.link, dev.Cert = phoneID, desk, desk.Cert
	packets := make(chan *proto.Packet, 16)
	go phone.Receive(func(p *proto.Packet) { packets <- p })
	wait := func(typ string, current string) *proto.Packet {
		t.Helper()
		timer := time.NewTimer(4 * time.Second)
		defer timer.Stop()
		for {
			select {
			case p := <-packets:
				if p.Type == typ && p.Fields()["current"] == current {
					return p
				}
			case <-timer.C:
				t.Fatalf("no %s with current %s", typ, current)
				return nil
			}
		}
	}
	d.sendOhmThemeCatalog(dev, desk)
	first := wait(proto.TypeOmarchyTheme, "tokyo-night")
	if first.Fields()["version"] != float64(1) {
		t.Fatal("wrong catalog version")
	}
	go d.ohmThemeLoop(ctx)
	wait(proto.TypeOmarchyTheme, "tokyo-night") // watcher's baseline snapshot
	if err := backend.ApplyContext(ctx, "catppuccin"); err != nil {
		t.Fatal(err)
	}
	wait(proto.TypeOmarchyTheme, "catppuccin") // a local desktop change
	requestID := "5da63e00-8c22-4bc8-b615-290e4248e3fd"
	d.handleOhmTheme(dev, desk, proto.New(proto.TypeOmarchyThemeSelect, map[string]any{"version": 1, "requestId": requestID, "id": "tokyo-night"}))
	ack := wait(proto.TypeOmarchyThemeSelected, "tokyo-night")
	fields := ack.Fields()
	if len(fields) != 4 || fields["requestId"] != requestID || fields["ok"] != true || fields["version"] != float64(1) {
		t.Fatalf("invalid success response: %s", ack.Body)
	}
	d.handleOhmTheme(dev, desk, proto.New(proto.TypeOmarchyThemeSelect, map[string]any{"version": 1, "requestId": "595a5001-0ae2-44dc-9f70-a246df8f0d4f", "id": "nord"}))
	ack = wait(proto.TypeOmarchyThemeSelected, "tokyo-night")
	if ack.Fields()["ok"] != false {
		t.Fatalf("unknown theme accepted: %s", ack.Body)
	}
}

func TestHeadlessRejectsThemeAndWallpaperExtensionsBeforeAdmission(t *testing.T) {
	d, dev, l, backend := ohmThemeTestDaemon()
	d.opts.Headless = true
	dev.Incoming = append(dev.Incoming, proto.TypeWallpaperOriginal)
	dev.Outgoing = append(dev.Outgoing, proto.TypeWallpaperOriginal)
	backend.onApply = func(context.Context, string) error { t.Error("headless theme setter ran"); return nil }
	if d.currentOhmThemeLink(dev, l) {
		t.Fatal("headless desktop authority admitted")
	}
	d.handleOhmTheme(dev, l, proto.New(proto.TypeOmarchyThemeSelect, map[string]any{
		"version": 1, "requestId": "5da63e00-8c22-4bc8-b615-290e4248e3fd", "id": "catppuccin",
	}))
	d.sendOhmThemeCatalog(dev, l)
	for _, kind := range []string{"gallery_request", "begin"} {
		d.handleOriginalWallpaper(dev, l, proto.New(proto.TypeWallpaperOriginal, map[string]any{
			"kind": kind, "operation": "0123456789abcdef0123456789abcdef",
		}))
	}
	d.mu.Lock()
	requests := len(d.ohmThemeRequests)
	d.mu.Unlock()
	d.wallpapers.mu.Lock()
	sessions := len(d.wallpapers.sessions)
	d.wallpapers.mu.Unlock()
	if requests != 0 || sessions != 0 || backend.applied != "" {
		t.Fatal("headless desktop operation reached admission")
	}
}

func TestHeadlessDoesNotInitializeThemeSetter(t *testing.T) {
	for _, name := range []string{"XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"} {
		t.Setenv(name, t.TempDir())
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, err := New(ctx, log.New(io.Discard, "", 0), Options{Headless: true})
	if err != nil {
		t.Fatal(err)
	}
	if d.themes != nil || d.input != nil || d.themePath != "" {
		t.Fatal("headless initialized desktop effects")
	}
}
