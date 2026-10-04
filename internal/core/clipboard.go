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

// maxClipText is the number of text bytes that the clipboard history keeps
// in total. The history drops the oldest entries first.
const maxClipText = 16 << 20

// ClipEntry is one clipboard history entry.
type ClipEntry struct {
	Pinned  bool  `json:"pinned,omitempty"`
	Expires int64 `json:"expires,omitempty"`
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
	images, texts := 0, 0
	limit := d.cfg.ClipLimit()
	for i, c := range all {
		drop := i >= limit
		if c.Image != "" {
			images++
			drop = drop || images > maxClipImages
		}
		// The newest entry always stays. Its text is at most
		// desktop.MaxClipboardText.
		if i > 0 && texts+len(c.Text) > maxClipText {
			drop = true
		}
		if !drop {
			texts += len(c.Text)
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

// trimClipboardLocked trims the clipboard history to the configured limit.
func (d *Daemon) trimClipboardLocked() {
	limit := d.cfg.ClipLimit()
	if len(d.clipboard) <= limit {
		return
	}
	kept := d.clipboard[:limit]
	for _, c := range d.clipboard[limit:] {
		if c.Image != "" {
			os.Remove(c.Image)
		}
	}
	d.clipboard = kept
	d.markDirty()
}

// addClipImage saves an image in the runtime folder and adds it to the
// clipboard history as the entry e.
func (d *Daemon) addClipImage(e ClipEntry, data []byte, mime string) error {
	return d.addClipImageIf(e, data, mime, nil)
}

// addClipImageIf is addClipImage with the condition ok, which runs under
// d.mu after the save. When ok returns false, addClipImageIf removes the
// saved file and the history does not change. A nil ok is always true.
func (d *Daemon) addClipImageIf(e ClipEntry, data []byte, mime string, ok func() bool) error {
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
	if ok != nil && !ok() {
		d.mu.Unlock()
		os.Remove(path)
		return nil
	}
	d.addClipLocked(e)
	d.mu.Unlock()
	d.markDirty()
	return nil
}

// clipPreviewLocked returns the clipboard history for the state. A long text
// holds only its first maxClipPreview bytes.
func (d *Daemon) clipPreviewLocked() []ClipEntry {
	out := d.clipEntriesLocked()
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
// A text above maxSentText goes only to the clipboard history.
func (d *Daemon) onLocalClipboard(text string) {
	fits := len(text) <= maxSentText
	d.mu.Lock()
	d.lastLocalClip = time.Now()
	d.lastClipAt = d.lastLocalClip
	// A device that connects later gets no older text in place of a text
	// that is too large.
	d.content.lastClip = ""
	if fits {
		d.content.lastClip = text
	}
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
	links := d.featureLinks("clipboard")
	switch {
	case !fits && len(links) > 0:
		d.logf("clipboard: did not sync a text of %d bytes", len(text))
		d.toast("The copied text is larger than %d KiB. Flux did not sync it", maxSentText>>10)
	case fits:
		for _, l := range links {
			_ = l.Send(proto.New(proto.TypeClipboard, map[string]any{"content": text}))
		}
	}
	d.markDirty()
}

// onLocalImage sends a local image copy to every paired device that
// accepts clipboard images. A newer copy, an unpair, a dropped link, and
// auto_clipboard off stop the transfer.
func (d *Daemon) onLocalImage(data []byte, mime string) {
	type target struct {
		dev *Device
		l   *lan.Link
	}
	d.mu.Lock()
	d.lastLocalClip = time.Now()
	d.lastClipAt = d.lastLocalClip
	// A device that connects later gets no older text in place of the
	// image.
	d.content.lastClip = ""
	auto := d.cfg.AutoClipboard
	var targets []target
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxClipboardImage) && d.permittedLocked(dev.ID, "clipboard") {
			targets = append(targets, target{dev, dev.link})
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
		for _, t := range targets {
			d.mu.Lock()
			ok := t.dev.Paired && t.dev.link == t.l && d.cfg.AutoClipboard && d.permittedLocked(t.dev.ID, "clipboard")
			d.mu.Unlock()
			if !ok || ctx.Err() != nil {
				continue
			}
			lctx, lcancel := context.WithCancel(ctx)
			cancelOnLinkDown(lctx, t.l, lcancel)
			err := sendClipImage(lctx, t.l, data, mime)
			lcancel()
			if err != nil && ctx.Err() == nil {
				d.logf("send clipboard image to %s: %v", t.l.Identity.DeviceName, err)
			}
		}
	}()
}

// sendConnectClipboard sends the last text that Watch reported to a device
// that connects, with the time of the last local copy. The device keeps
// its own clipboard when that is newer.
func (d *Daemon) sendConnectClipboard(l *lan.Link) {
	d.mu.Lock()
	text, ts, auto := d.content.lastClip, d.lastLocalClip.UnixMilli(), d.cfg.AutoClipboard
	auto = auto && d.permittedLocked(l.DeviceID(), "clipboard")
	d.mu.Unlock()
	if !auto || text == "" || ts <= 0 {
		return
	}
	_ = l.Send(proto.New(proto.TypeClipboardConnect, map[string]any{"content": text, "timestamp": ts}))
}

// setClipboard puts text from a device on the local clipboard. 1 worker
// runs wl-copy, and only the newest waiting text runs, so a burst of
// copies ends with the newest text on the clipboard. With needAuto, the
// text is a clipboard sync, which also needs auto_clipboard when the
// worker runs it. The device must still be paired.
func (d *Daemon) setClipboard(dev *Device, text string, needAuto bool) {
	d.runContent(&d.content.clipQ, 0, func() {
		d.mu.Lock()
		ok := dev.Paired && (!needAuto || (d.cfg.AutoClipboard && d.permittedLocked(dev.ID, "clipboard")))
		d.mu.Unlock()
		if !ok {
			return
		}
		if err := d.clip.Set(text); err != nil {
			d.logf("set clipboard: %v", err)
		}
	})
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
	if len(body.Content) > desktop.MaxClipboardText {
		name := d.nameOf(dev)
		d.logf("%s: ignored a clipboard text of %d bytes", name, len(body.Content))
		d.toast("%s copied a text that is larger than %d MiB. Flux did not sync it", name, desktop.MaxClipboardText>>20)
		return
	}
	d.mu.Lock()
	auto := d.cfg.AutoClipboard
	// A clipboard.connect packet is older than the newest clipboard from
	// the desktop or from any device.
	connect := p.Type == proto.TypeClipboardConnect && body.Timestamp > 0
	stale := connect && body.Timestamp <= d.lastClipAt.UnixMilli()
	if !stale {
		// A clipboard.connect packet holds the time of the copy on the
		// device. A time after now counts as now, so that a device clock
		// that is ahead does not make the next copies stale.
		d.lastClipAt = time.Now()
		if connect && body.Timestamp < d.lastClipAt.UnixMilli() {
			d.lastClipAt = time.UnixMilli(body.Timestamp)
		}
		// The text is newer than an image of the device that is still on
		// its way.
		if f := d.content.clipImages[dev.ID]; f != nil {
			f.cancel()
			f.stale = true
		}
		d.addClipLocked(ClipEntry{Text: body.Content, Dir: "in", Device: dev.ID, DeviceName: dev.Name, Time: time.Now().Unix()})
	}
	d.mu.Unlock()
	if auto && !stale {
		// Run the desktop call outside the read loop of the link, so a slow
		// clipboard tool cannot block the next packets from the phone.
		d.setClipboard(dev, body.Content, true)
	}
	d.markDirty()
}

// handleClipboardImage receives an image that a device copied. It adds the
// image to the history. With automatic sync on, it also puts the image on
// the local clipboard. Each device sends 1 image at a time. A newer image
// stops the older one.
func (d *Daemon) handleClipboardImage(dev *Device, l *lan.Link, p *proto.Packet) {
	if !p.HasPayload() || p.PayloadSize <= 0 || p.PayloadSize > desktop.MaxClipboardImage {
		d.logf("%s: ignored a clipboard image of %d bytes", d.nameOf(dev), p.PayloadSize)
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, clipImageTimeout)
	fetch := &clipFetch{cancel: cancel}
	d.mu.Lock()
	if d.content.clipImages == nil {
		d.content.clipImages = map[string]*clipFetch{}
	}
	if old := d.content.clipImages[dev.ID]; old != nil {
		old.cancel()
		old.stale = true
	}
	d.content.clipImages[dev.ID] = fetch
	d.mu.Unlock()
	cancelOnLinkDown(ctx, l, cancel)
	go func() {
		defer func() {
			cancel()
			d.mu.Lock()
			if d.content.clipImages[dev.ID] == fetch {
				delete(d.content.clipImages, dev.ID)
			}
			d.mu.Unlock()
		}()
		data, err := fetchAll(ctx, l, p)
		if err != nil {
			d.logf("%s: receive clipboard image: %v", d.nameOf(dev), err)
			return
		}
		d.receiveClipImage(dev, fetch, data)
	}()
}

// receiveClipImage adds an image from a device to the history and, with
// automatic sync on, puts it on the local clipboard. An image that arrives
// after an unpair is dropped. So is an image of the fetch f after a newer
// text or image of the device. The worker of the texts from the devices
// sets the image, so that a text that comes later stays on the clipboard.
// The history and the worker check f again under d.mu, because a text can
// come while fluxd saves the image.
func (d *Daemon) receiveClipImage(dev *Device, f *clipFetch, data []byte) {
	d.mu.Lock()
	paired, name, stale := dev.Paired && d.permittedLocked(dev.ID, "clipboard"), dev.Name, f.stale
	d.mu.Unlock()
	mime := clipImageType(data)
	if mime == "" {
		d.logf("%s: the clipboard image is not a PNG, JPEG, GIF, or WebP image", name)
		return
	}
	if !paired || stale {
		return
	}
	// current runs under d.mu. It is false after an unpair or after a newer
	// text or image of the device. The image then stays out of the history
	// and does not replace the job of the newer text in the worker.
	current := func() bool { return dev.Paired && !f.stale && d.permittedLocked(dev.ID, "clipboard") }
	d.mu.Lock()
	if current() {
		d.lastClipAt = time.Now()
	}
	d.mu.Unlock()
	if err := d.addClipImageIf(ClipEntry{Dir: "in", Device: dev.ID, DeviceName: name, Time: time.Now().Unix()}, data, mime, current); err != nil {
		d.logf("save clipboard image: %v", err)
	}
	d.runContentIf(&d.content.clipQ, 0, current, func() {
		d.mu.Lock()
		ok := dev.Paired && d.cfg.AutoClipboard && !f.stale
		d.mu.Unlock()
		if !ok {
			return
		}
		if err := d.clip.SetImage(data, mime); err != nil {
			d.logf("set clipboard image: %v", err)
		}
	})
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
	if !d.permitted(dev.ID, "clipboard") {
		return apiErr("disabled", "Clipboard access is off for this device")
	}
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
	if err := textLimit(text); err != nil {
		return err
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
	var err error
	switch {
	case l == nil:
		err = offline(dev)
	case !dev.Paired:
		err = apiErr("not_paired", "%s is not paired", dev.Name)
	case !dev.accepts(proto.TypeFluxClipboardImage):
		err = apiErr("unsupported", "%s does not accept clipboard images. Flux for Android accepts them while Sync clipboard is on", dev.Name)
	}
	d.mu.Unlock()
	if err != nil {
		return err
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
	for _, c := range d.clipEntriesLocked() {
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
	for _, e := range d.clipEntriesLocked() {
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

// deleteClip removes an entry from the clipboard history and from saved
// snippets.
func (d *Daemon) deleteClip(id string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if id == "" {
		return apiErr("bad_params", "id is empty")
	}
	found := false

	var keptClip []ClipEntry
	for _, e := range d.clipboard {
		if e.ID == id {
			found = true
			if e.Image != "" {
				os.Remove(e.Image)
			}
		} else {
			keptClip = append(keptClip, e)
		}
	}
	d.clipboard = keptClip

	var keptSnippets []ClipEntry
	var snippetImage string
	snippetFound := false
	for _, e := range d.snippets {
		if e.ID == id {
			found = true
			snippetFound = true
			snippetImage = e.Image
		} else {
			keptSnippets = append(keptSnippets, e)
		}
	}
	if snippetFound {
		if keptSnippets == nil {
			keptSnippets = []ClipEntry{}
		}
		if err := saveJSON(filepath.Join(d.snippetsDir, "index.json"), keptSnippets); err != nil {
			return err
		}
		d.snippets = keptSnippets
		if snippetImage != "" {
			os.Remove(snippetImage)
		}
	}

	if !found {
		return apiErr("not_found", "No clipboard entry with ID %s", id)
	}
	d.markDirty()
	return nil
}

// clearClips removes all unpinned clipboard entries. When all is true, it
// also removes all saved snippets.
func (d *Daemon) clearClips(all bool) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	for _, e := range d.clipboard {
		if e.Image != "" {
			os.Remove(e.Image)
		}
	}
	d.clipboard = nil
	removeClipImages(d.clipDir)

	if all {
		for _, e := range d.snippets {
			if e.Image != "" {
				os.Remove(e.Image)
			}
		}
		d.snippets = nil
		if d.snippetsDir != "" {
			if err := saveJSON(filepath.Join(d.snippetsDir, "index.json"), []ClipEntry{}); err != nil {
				return err
			}
		}
	}

	d.markDirty()
	return nil
}
