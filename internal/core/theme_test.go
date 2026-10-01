package core

import (
	"context"
	"io"
	"log"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

const (
	darkColors  = "mode = \"dark\"\nbackground = \"#1a1b26\"\nforeground = \"#c0caf5\"\nhyprland_active_border = \"rgba(33ccffee) rgba(00ff99ee) 45deg\"\n"
	lightColors = "mode = \"light\"\nbackground = \"#fffcf0\"\nforeground = \"#100f0f\"\n"
)

// themeDaemon returns a daemon that reads the theme from a temporary
// folder, and the path of colors.toml.
func themeDaemon(t *testing.T) (*Daemon, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "current", "theme")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return &Daemon{
		cfg:       &config.Config{},
		devices:   map[string]*Device{},
		dirty:     make(chan struct{}, 1),
		logger:    log.New(io.Discard, "", 0),
		themePath: filepath.Join(dir, "colors.toml"),
	}, filepath.Join(dir, "colors.toml")
}

func setColors(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// nextTheme returns the body of the next packet from ch. A ping is the
// marker that the test sends after a step that must send nothing, so
// nextTheme returns nil for it.
func nextTheme(t *testing.T, ch chan *proto.Packet) map[string]any {
	t.Helper()
	select {
	case p := <-ch:
		switch p.Type {
		case proto.TypeFluxTheme:
			return p.Fields()
		case proto.TypePing:
			return nil
		}
		t.Fatalf("unexpected packet %s", p.Type)
	case <-time.After(5 * time.Second):
		t.Fatal("no packet within 5 seconds")
	}
	return nil
}

// noTheme checks that no theme waits on the link: the marker comes first.
func noTheme(t *testing.T, onDesk *lan.Link, ch chan *proto.Packet, what string) {
	t.Helper()
	if err := onDesk.Send(proto.New(proto.TypePing, nil)); err != nil {
		t.Fatal(err)
	}
	if body := nextTheme(t, ch); body != nil {
		t.Fatalf("%s sent a theme: %v", what, body)
	}
}

// TestThemeLinks checks the send rule: only a connected paired device that
// accepts flux.theme gets the theme.
func TestThemeLinks(t *testing.T) {
	d, _ := themeDaemon(t)
	want := &lan.Link{}
	theme := []string{proto.TypeFluxTheme}
	d.devices["a"] = &Device{ID: "a", Paired: true, link: want, Incoming: theme}
	d.devices["b"] = &Device{ID: "b", Paired: true, link: &lan.Link{}, Incoming: []string{proto.TypeFluxDnd}}
	d.devices["c"] = &Device{ID: "c", Paired: false, link: &lan.Link{}, Incoming: theme}
	d.devices["e"] = &Device{ID: "e", Paired: true, Incoming: theme}
	d.mu.Lock()
	got := d.themeLinksLocked()
	d.mu.Unlock()
	if !slices.Equal(got, []*lan.Link{want}) {
		t.Fatalf("links %v", got)
	}
}

// TestThemeSends follows the theme file through a change, a broken file,
// and the same file again, on a real link.
func TestThemeSends(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	ch := packets(onPhone)
	d, path := themeDaemon(t)
	dev := &Device{ID: phoneID, Name: "phone", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxTheme}}
	d.devices[phoneID] = dev

	// No file: the link gets nothing.
	d.reloadTheme()
	d.sendThemeTo(dev, onDesk)
	noTheme(t, onDesk, ch, "a missing file")

	// The first theme goes out.
	setColors(t, path, darkColors)
	d.reloadTheme()
	body := nextTheme(t, ch)
	if body == nil || body["mode"] != "dark" || body["border"] == nil {
		t.Fatalf("theme %v", body)
	}
	if c := body["colors"].(map[string]any); c["background"] != "#1a1b26" {
		t.Fatalf("colors %v", c)
	}

	// The same theme does not go out again.
	d.reloadTheme()
	noTheme(t, onDesk, ch, "an unchanged file")

	// A new theme goes out.
	setColors(t, path, lightColors)
	d.reloadTheme()
	if body := nextTheme(t, ch); body == nil || body["mode"] != "light" {
		t.Fatalf("theme %v", body)
	}

	// A file that does not parse sends nothing, and a new link gets nothing.
	setColors(t, path, "background = \"#1a1b26\n")
	d.reloadTheme()
	d.sendThemeTo(dev, onDesk)
	noTheme(t, onDesk, ch, "a broken file")

	// The file parses again. The theme goes out again, also when it is
	// the theme from before the broken file.
	setColors(t, path, lightColors)
	d.reloadTheme()
	if body := nextTheme(t, ch); body == nil || body["mode"] != "light" {
		t.Fatalf("theme %v", body)
	}

	// The link start sends the current theme.
	d.sendThemeTo(dev, onDesk)
	if body := nextTheme(t, ch); body == nil || body["mode"] != "light" {
		t.Fatalf("theme %v", body)
	}
}

// TestThemeNeedsIncoming checks that a phone that does not list flux.theme
// gets no theme, and gets it at once when a new identity lists it.
func TestThemeNeedsIncoming(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	ch := packets(onPhone)
	d, path := themeDaemon(t)
	setColors(t, path, darkColors)
	dev := &Device{ID: phoneID, Name: "phone", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxDnd}}
	d.devices[phoneID] = dev

	d.reloadTheme()
	d.sendThemeTo(dev, onDesk)
	noTheme(t, onDesk, ch, "a phone without flux.theme")

	id := proto.NewIdentity(phoneID, "phone", 0)
	id.IncomingCapabilities = []string{proto.TypeFluxDnd, proto.TypeFluxTheme}
	d.handlePacket(dev, onDesk, proto.New(proto.TypeIdentity, id))
	if body := nextTheme(t, ch); body == nil || body["mode"] != "dark" {
		t.Fatalf("theme %v", body)
	}

	// The same identity again sends nothing.
	d.handlePacket(dev, onDesk, proto.New(proto.TypeIdentity, id))
	time.Sleep(50 * time.Millisecond)
	noTheme(t, onDesk, ch, "the same identity")
}

// TestThemeHeadless checks that a daemon without a theme path sends
// nothing.
func TestThemeHeadless(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	ch := packets(onPhone)
	d, path := themeDaemon(t)
	setColors(t, path, darkColors)
	d.themePath = ""
	dev := &Device{ID: phoneID, Name: "phone", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxTheme}}
	d.devices[phoneID] = dev

	d.reloadTheme()
	d.sendThemeTo(dev, onDesk)
	done := make(chan struct{})
	go func() {
		d.themeLoop(ctx)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the theme loop of a headless daemon must return at once")
	}
	noTheme(t, onDesk, ch, "a headless daemon")
}
