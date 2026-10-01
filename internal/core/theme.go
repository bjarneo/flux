package core

import (
	"bytes"
	"context"
	"encoding/json"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// themeLoop watches the theme file and sends each new theme to the phones.
// A headless daemon has no theme path and does not watch.
func (d *Daemon) themeLoop(ctx context.Context) {
	if d.themePath == "" {
		return
	}
	desktop.WatchTheme(ctx, d.themePath, d.reloadTheme)
}

// reloadTheme reads the theme file again. When the theme changed and
// parses, fluxd sends it to each paired phone that accepts flux.theme. A
// missing file or a file that does not parse sends nothing, and the phones
// keep the last theme that they got.
func (d *Daemon) reloadTheme() {
	if d.themePath == "" {
		return
	}
	d.themeSend.Lock()
	defer d.themeSend.Unlock()
	theme, err := desktop.LoadTheme(d.themePath)
	var body json.RawMessage
	if err == nil {
		body, err = json.Marshal(theme)
	}
	errText := ""
	if err != nil {
		body, errText = nil, err.Error()
	}
	d.mu.Lock()
	same := bytes.Equal(body, d.themeBody)
	d.themeBody = body
	newErr := errText != d.themeErr
	d.themeErr = errText
	var links []*lan.Link
	if !same && body != nil {
		links = d.themeLinksLocked()
	}
	d.mu.Unlock()
	if newErr && err != nil {
		d.logf("theme sync: %v", err)
	}
	if same || body == nil {
		return
	}
	if len(links) == 0 {
		d.logf("theme sync: Omarchy theme %q, %s", theme.Name, theme.Mode)
		return
	}
	d.logf("theme sync: Omarchy theme %q, %s, sent to %d devices", theme.Name, theme.Mode, len(links))
	for _, l := range links {
		_ = l.Send(proto.New(proto.TypeFluxTheme, body))
	}
}

// themeLinksLocked returns the links of the connected paired devices that
// accept flux.theme. The caller holds d.mu.
func (d *Daemon) themeLinksLocked() []*lan.Link {
	var out []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxTheme) {
			out = append(out, dev.link)
		}
	}
	return out
}

// sendThemeTo sends the last theme that parsed on the link l of dev. It
// sends nothing when there is no such theme, when l is not the link of
// dev, or when dev is not paired or does not accept flux.theme.
func (d *Daemon) sendThemeTo(dev *Device, l *lan.Link) {
	d.themeSend.Lock()
	defer d.themeSend.Unlock()
	d.mu.Lock()
	body := d.themeBody
	ok := body != nil && dev.Paired && dev.link == l && dev.accepts(proto.TypeFluxTheme)
	d.mu.Unlock()
	if ok {
		_ = l.Send(proto.New(proto.TypeFluxTheme, body))
	}
}
