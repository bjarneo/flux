package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxClipboard is the number of clipboard entries that fluxd keeps. The
// history lives in memory only.
const maxClipboard = 50

// maxClipImages is the number of images that the clipboard history keeps.
// The images live in the runtime folder, which is in memory.
const maxClipImages = 10

// clipImageTimeout limits the transfer of 1 clipboard image.
const clipImageTimeout = time.Minute

// maxClipPreview is the number of text bytes that each state event holds for
// one clipboard entry. A copy by ID gives the full text.
const maxClipPreview = 1024

// ClipEntry is one clipboard history entry.
type ClipEntry struct {
	// ID identifies the entry for clipboard.copy.
	ID   string `json:"id"`
	Text string `json:"text"`
	// Truncated is true when the state holds only the start of Text. Size
	// is then the full length of Text in bytes.
	Truncated bool `json:"truncated,omitempty"`
	Size      int  `json:"size,omitempty"`
	// Image is the path of a copied image. Text is empty for an image.
	Image      string `json:"image,omitempty"`
	Dir        string `json:"dir"` // "in" or "out"
	Device     string `json:"device"`
	DeviceName string `json:"deviceName"`
	// Source is "scan" for camera text, "share" for shared text, and empty
	// for clipboard sync.
	Source string `json:"source,omitempty"`
	Time   int64  `json:"time"`

	// sum identifies the image, so that a repeat of the same image makes
	// no new entry.
	sum string
}

func (d *Daemon) addClipLocked(e ClipEntry) {
	if len(d.clipboard) > 0 {
		top := &d.clipboard[0]
		if top.Text == e.Text && top.sum == e.sum && top.Dir == e.Dir {
			top.Time = e.Time
			if e.Image != "" && e.Image != top.Image {
				os.Remove(e.Image)
			}
			return
		}
	}
	e.ID = config.NewID(6)
	all := append([]ClipEntry{e}, d.clipboard...)
	kept := all[:0]
	images := 0
	for i, c := range all {
		drop := i >= maxClipboard
		if c.Image != "" {
			images++
			drop = drop || images > maxClipImages
		}
		if drop {
			if c.Image != "" {
				os.Remove(c.Image)
			}
			continue
		}
		kept = append(kept, c)
	}
	d.clipboard = kept
}

// addClipImage saves an image in the runtime folder and adds it to the
// clipboard history as the entry e.
func (d *Daemon) addClipImage(e ClipEntry, data []byte, mime string) error {
	d.mu.Lock()
	dir := d.clipDir
	d.mu.Unlock()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, "clip-"+config.NewID(6)+imageExt(mime))
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	e.Text, e.Image, e.sum = "", path, hex.EncodeToString(sum[:])
	d.mu.Lock()
	d.addClipLocked(e)
	d.mu.Unlock()
	d.markDirty()
	return nil
}

// clipPreviewLocked returns the clipboard history for the state. A long text
// holds only its first maxClipPreview bytes.
func (d *Daemon) clipPreviewLocked() []ClipEntry {
	out := make([]ClipEntry, len(d.clipboard))
	copy(out, d.clipboard)
	for i := range out {
		if len(out[i].Text) > maxClipPreview {
			out[i].Size = len(out[i].Text)
			out[i].Text = strings.ToValidUTF8(out[i].Text[:maxClipPreview], "")
			out[i].Truncated = true
		}
	}
	return out
}

// removeClipImages removes the images that an earlier fluxd left in dir.
func removeClipImages(dir string) {
	names, _ := filepath.Glob(filepath.Join(dir, "clip-*"))
	for _, n := range names {
		os.Remove(n)
	}
}

// clipImageType returns the MIME type of an image that Flux puts on the
// clipboard. It returns an empty string for other data.
func clipImageType(data []byte) string {
	switch t := http.DetectContentType(data); t {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return t
	}
	return ""
}

func imageExt(mime string) string {
	switch mime {
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	}
	return ".png"
}

// newClipSend stops the clipboard image that fluxd sends, and returns the
// context for the next one.
func (d *Daemon) newClipSend() (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithTimeout(d.ctx, clipImageTimeout)
	d.mu.Lock()
	if d.clipSend != nil {
		d.clipSend()
	}
	d.clipSend = cancel
	d.mu.Unlock()
	return ctx, cancel
}

// stopClipSend stops the clipboard image that fluxd sends.
func (d *Daemon) stopClipSend() {
	d.mu.Lock()
	if d.clipSend != nil {
		d.clipSend()
		d.clipSend = nil
	}
	d.mu.Unlock()
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
	// The text replaces an image that is still on its way.
	d.stopClipSend()
	for _, l := range d.pairedLinks() {
		_ = l.Send(proto.New(proto.TypeClipboard, map[string]any{"content": text}))
	}
	d.markDirty()
}

// onLocalImage sends a local image copy to every paired device that
// accepts clipboard images. A newer copy stops the transfer.
func (d *Daemon) onLocalImage(data []byte, mime string) {
	d.mu.Lock()
	d.lastLocalClip = time.Now()
	auto := d.cfg.AutoClipboard
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxClipboardImage) {
			links = append(links, dev.link)
		}
	}
	d.mu.Unlock()
	if !auto {
		return
	}
	if err := d.addClipImage(ClipEntry{Dir: "out", DeviceName: "this pc", Time: time.Now().Unix()}, data, mime); err != nil {
		d.logf("save clipboard image: %v", err)
	}
	ctx, cancel := d.newClipSend()
	go func() {
		defer cancel()
		for _, l := range links {
			if err := sendClipImage(ctx, l, data, mime); err != nil && ctx.Err() == nil {
				d.logf("send clipboard image to %s: %v", l.Identity.DeviceName, err)
			}
		}
	}()
}

func sendClipImage(ctx context.Context, l *lan.Link, data []byte, mime string) error {
	p := proto.New(proto.TypeFluxClipboardImage, map[string]any{"mime": mime})
	return l.SendWithPayload(ctx, p, bytes.NewReader(data), int64(len(data)), nil)
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

// handleClipboardImage receives an image that a device copied. It adds the
// image to the history. With automatic sync on, it also puts the image on
// the local clipboard.
func (d *Daemon) handleClipboardImage(dev *Device, l *lan.Link, p *proto.Packet) {
	if !p.HasPayload() || p.PayloadSize <= 0 || p.PayloadSize > desktop.MaxClipboardImage {
		d.logf("%s: ignored a clipboard image of %d bytes", dev.Name, p.PayloadSize)
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(d.ctx, clipImageTimeout)
		defer cancel()
		data, err := fetchAll(ctx, l, p)
		if err != nil {
			d.logf("%s: receive clipboard image: %v", dev.Name, err)
			return
		}
		d.receiveClipImage(dev, data)
	}()
}

// receiveClipImage adds an image from a device to the history and, with
// automatic sync on, puts it on the local clipboard.
func (d *Daemon) receiveClipImage(dev *Device, data []byte) {
	mime := clipImageType(data)
	if mime == "" {
		d.logf("%s: the clipboard image is not a PNG, JPEG, GIF, or WebP image", dev.Name)
		return
	}
	d.mu.Lock()
	auto := d.cfg.AutoClipboard
	d.mu.Unlock()
	if err := d.addClipImage(ClipEntry{Dir: "in", Device: dev.ID, DeviceName: dev.Name, Time: time.Now().Unix()}, data, mime); err != nil {
		d.logf("save clipboard image: %v", err)
	}
	if auto {
		if err := d.clip.SetImage(data, mime); err != nil {
			d.logf("set clipboard image: %v", err)
		}
	}
}

// fetchAll reads the whole payload of p.
func fetchAll(ctx context.Context, l *lan.Link, p *proto.Packet) ([]byte, error) {
	rc, err := l.FetchPayload(ctx, p)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	stop := context.AfterFunc(ctx, func() { rc.Close() })
	defer stop()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != p.PayloadSize {
		return nil, fmt.Errorf("received %d of %d bytes", len(data), p.PayloadSize)
	}
	return data, nil
}

// SendClipboard sends text to a device. Empty text sends the local
// clipboard: its image, or else its text.
func (d *Daemon) SendClipboard(dev *Device, text string) error {
	if text == "" {
		img, err := d.clip.GetImage()
		if err != nil {
			return apiErr("clipboard", "%v", err)
		}
		if img != nil {
			return d.sendImageTo(dev, img)
		}
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

// sendImageTo sends a PNG image from the local clipboard to a device and
// waits until the device has it.
func (d *Daemon) sendImageTo(dev *Device, data []byte) error {
	d.mu.Lock()
	l := dev.link
	accepts := dev.accepts(proto.TypeFluxClipboardImage)
	d.mu.Unlock()
	if l == nil {
		return offline(dev)
	}
	if !accepts {
		return apiErr("unsupported", "%s does not accept clipboard images. Flux for Android accepts them while Sync clipboard is on", dev.Name)
	}
	ctx, cancel := d.newClipSend()
	defer cancel()
	if err := sendClipImage(ctx, l, data, desktop.ImageType); err != nil {
		return err
	}
	return d.addClipImage(ClipEntry{Dir: "out", Device: dev.ID, DeviceName: "this pc", Time: time.Now().Unix()}, data, desktop.ImageType)
}

// CopyClip puts the full text or the image of a history entry on the local
// clipboard.
func (d *Daemon) CopyClip(id string) error {
	d.mu.Lock()
	var e ClipEntry
	found := false
	for _, c := range d.clipboard {
		if c.ID == id {
			e, found = c, true
			break
		}
	}
	d.mu.Unlock()
	if !found {
		return apiErr("not_found", "The clipboard history has no entry %s", id)
	}
	if e.Image != "" {
		return d.CopyClipImage(e.Image)
	}
	return d.clip.Set(e.Text)
}

// CopyClipImage puts an image from the clipboard history on the local
// clipboard. path must be the image of a history entry.
func (d *Daemon) CopyClipImage(path string) error {
	d.mu.Lock()
	found := false
	for _, e := range d.clipboard {
		if e.Image != "" && e.Image == path {
			found = true
			break
		}
	}
	d.mu.Unlock()
	if !found {
		return apiErr("not_found", "The clipboard history has no image %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	mime := clipImageType(data)
	if mime == "" {
		return errors.New("the file is not an image")
	}
	return d.clip.SetImage(data, mime)
}
