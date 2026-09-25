package core

import (
	"time"

	"flux/internal/proto"
)

// maxClipboard is the number of clipboard entries that fluxd keeps. The
// history lives in memory only.
const maxClipboard = 50

// ClipEntry is one clipboard history entry.
type ClipEntry struct {
	Text       string `json:"text"`
	Dir        string `json:"dir"` // "in" or "out"
	Device     string `json:"device"`
	DeviceName string `json:"deviceName"`
	// Source is "scan" for camera text, "share" for shared text, and empty
	// for clipboard sync.
	Source string `json:"source,omitempty"`
	Time   int64  `json:"time"`
}

func (d *Daemon) addClipLocked(e ClipEntry) {
	if len(d.clipboard) > 0 && d.clipboard[0].Text == e.Text && d.clipboard[0].Dir == e.Dir {
		d.clipboard[0].Time = e.Time
		return
	}
	d.clipboard = append([]ClipEntry{e}, d.clipboard...)
	if len(d.clipboard) > maxClipboard {
		d.clipboard = d.clipboard[:maxClipboard]
	}
}

// onLocalClipboard sends a local clipboard change to every paired device.
func (d *Daemon) onLocalClipboard(text string) {
	d.mu.Lock()
	d.lastLocalClip = time.Now()
	auto := d.cfg.AutoClipboard
	if auto {
		d.addClipLocked(ClipEntry{Text: text, Dir: "out", DeviceName: "this pc", Time: time.Now().Unix()})
	}
	d.mu.Unlock()
	if !auto {
		return
	}
	for _, l := range d.pairedLinks() {
		_ = l.Send(proto.New(proto.TypeClipboard, map[string]any{"content": text}))
	}
	d.markDirty()
}

// handleClipboard stores a clipboard from a device. With automatic sync on,
// it also sets the local clipboard.
func (d *Daemon) handleClipboard(dev *Device, p *proto.Packet) {
	var body struct {
		Content   string `json:"content"`
		Timestamp int64  `json:"timestamp"`
	}
	if p.Decode(&body) != nil || body.Content == "" {
		return
	}
	d.mu.Lock()
	auto := d.cfg.AutoClipboard
	// A clipboard.connect packet is older than a local change.
	stale := p.Type == proto.TypeClipboardConnect && body.Timestamp > 0 && body.Timestamp <= d.lastLocalClip.UnixMilli()
	if !stale {
		d.addClipLocked(ClipEntry{Text: body.Content, Dir: "in", Device: dev.ID, DeviceName: dev.Name, Time: time.Now().Unix()})
	}
	d.mu.Unlock()
	if auto && !stale {
		// Run the desktop call outside the read loop of the link, so a slow
		// clipboard tool cannot block the next packets from the phone.
		go func() {
			if err := d.clip.Set(body.Content); err != nil {
				d.logf("set clipboard: %v", err)
			}
		}()
	}
	d.markDirty()
}

// SendClipboard sends text to a device. Empty text sends the local
// clipboard.
func (d *Daemon) SendClipboard(dev *Device, text string) error {
	if text == "" {
		var err error
		if text, err = d.clip.Get(); err != nil || text == "" {
			return apiErr("empty", "The clipboard is empty")
		}
	}
	if err := d.send(dev, proto.New(proto.TypeClipboard, map[string]any{"content": text})); err != nil {
		return err
	}
	d.mu.Lock()
	d.addClipLocked(ClipEntry{Text: text, Dir: "out", Device: dev.ID, DeviceName: "this pc", Time: time.Now().Unix()})
	d.mu.Unlock()
	d.markDirty()
	return nil
}
