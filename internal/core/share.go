package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"

	"golang.org/x/sys/unix"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxTransfers is the number of transfers that the history keeps. A
// queued or active transfer stays in the history also above this number.
const maxTransfers = 100

// maxReceives is the number of files that 1 device can send to this
// computer at the same time.
const maxReceives = 4

// receiveIdle ends an incoming transfer when the device sends no data for
// this time.
const receiveIdle = time.Minute

// maxSharePreview is the number of characters of a shared text that the
// desktop notification shows.
const maxSharePreview = 300

// maxNameBytes is the longest name of a received file. The name then fits
// in the 255 bytes of NAME_MAX also with a number such as " (10000)".
const maxNameBytes = 200

// maxUnique is the number of names that uniquePath tries.
const maxUnique = 10000

// spaceCheck is the number of bytes between 2 checks of the free disk
// space during an incoming transfer.
const spaceCheck = 64 << 20

// partPrefix and partSuffix name the temporary file of an incoming
// transfer, such as .flux-123456.part.
const (
	partPrefix = ".flux-"
	partSuffix = ".part"
)

// errStalled ends a transfer that got no data for receiveIdle.
var errStalled = errors.New("the device stopped sending")

// errReceiveUnpaired ends a transfer of a device that is no longer paired.
var errReceiveUnpaired = errors.New("the device is not paired")

// openWebLink opens a web link on the desktop. Tests replace it.
var openWebLink = desktop.Open

// Transfer is one file that moves between this computer and a device.
type Transfer struct {
	ID         string `json:"id"`
	Device     string `json:"device"`
	DeviceName string `json:"deviceName"`
	Name       string `json:"name"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	Done       int64  `json:"done"`
	Dir        string `json:"dir"`   // "in" or "out"
	State      string `json:"state"` // queued, active, done, failed, canceled
	Rate       int64  `json:"rate"`  // bytes per second
	Error      string `json:"error,omitempty"`
	Time       int64  `json:"time"`

	cancel   context.CancelFunc
	mu       sync.Mutex
	lastTick time.Time
	lastDone int64
}

// copyLocked returns a copy of the public fields of t for the state. The
// caller holds d.mu.
func (t *Transfer) copyLocked() *Transfer {
	return &Transfer{
		ID: t.ID, Device: t.Device, DeviceName: t.DeviceName, Name: t.Name, Path: t.Path,
		Size: t.Size, Done: t.Done, Dir: t.Dir, State: t.State, Rate: t.Rate, Error: t.Error, Time: t.Time,
	}
}

// running reports whether the transfer is queued or active.
func (t *Transfer) running() bool { return t.State == "queued" || t.State == "active" }

// newTransfer adds a transfer to the history. path can be empty until the
// transfer knows it.
func (d *Daemon) newTransfer(dev *Device, name, path, dir string, size int64) *Transfer {
	d.mu.Lock()
	t := &Transfer{
		ID: config.NewID(6), Device: dev.ID, DeviceName: dev.Name, Name: name, Path: path,
		Size: size, Dir: dir, State: "queued", Time: time.Now().Unix(),
	}
	d.transfers = trimTransfers(append([]*Transfer{t}, d.transfers...))
	d.mu.Unlock()
	d.markDirty()
	return t
}

// trimTransfers drops the oldest finished transfers until the list has at
// most maxTransfers entries. A queued or active transfer stays, so that
// Busy and CancelTransfer still find it.
func trimTransfers(list []*Transfer) []*Transfer {
	extra := len(list) - maxTransfers
	if extra <= 0 {
		return list
	}
	drop := make(map[*Transfer]bool, extra)
	for i := len(list) - 1; i >= 0 && len(drop) < extra; i-- {
		if !list[i].running() {
			drop[list[i]] = true
		}
	}
	out := list[:0]
	for _, t := range list {
		if !drop[t] {
			out = append(out, t)
		}
	}
	return out
}

// progress updates the byte count and the rate. It publishes at most 4
// updates per second.
func (d *Daemon) progress(t *Transfer) func(int64) {
	return func(n int64) {
		now := time.Now()
		rate := int64(-1)
		t.mu.Lock()
		if t.lastTick.IsZero() {
			t.lastTick = now
		}
		if elapsed := now.Sub(t.lastTick); elapsed >= 250*time.Millisecond {
			rate = int64(float64(n-t.lastDone) / elapsed.Seconds())
			t.lastTick, t.lastDone = now, n
		}
		t.mu.Unlock()
		d.mu.Lock()
		t.Done = n
		if t.State != "canceled" {
			t.State = "active"
		}
		if rate >= 0 {
			if t.Rate == 0 {
				t.Rate = rate
			} else {
				t.Rate = (t.Rate*3 + rate) / 4
			}
		}
		d.mu.Unlock()
		if rate >= 0 {
			d.markDirty()
		}
	}
}

func (d *Daemon) finishTransfer(t *Transfer, err error) {
	d.mu.Lock()
	switch {
	case err == nil:
		t.State, t.Done = "done", t.Size
	case t.State == "canceled" || strings.Contains(err.Error(), "context canceled"):
		t.State = "canceled"
	default:
		t.State, t.Error = "failed", err.Error()
	}
	t.Rate = 0
	d.mu.Unlock()
	d.markDirty()
}

// CancelTransfer stops a running transfer.
func (d *Daemon) CancelTransfer(id string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, t := range d.transfers {
		if t.ID == id {
			if t.cancel != nil && t.running() {
				t.State = "canceled"
				t.cancel()
			}
			return nil
		}
	}
	return apiErr("not_found", "No transfer with ID %s", id)
}

// handleShare receives a file, a text, or a URL.
func (d *Daemon) handleShare(dev *Device, l *lan.Link, p *proto.Packet) {
	var body struct {
		Filename string `json:"filename"`
		Text     string `json:"text"`
		URL      string `json:"url"`
		// Scan marks text or a PDF that the phone camera scanned. Photo marks
		// a photo from the phone camera. Screenshot marks a new screenshot
		// that the phone sends by itself, together with Photo, so that an
		// older fluxd saves it as a photo. Signature marks a PNG of a
		// signature that the phone cut out of a photo. All come from Flux
		// for Android.
		Scan       bool `json:"scan"`
		Photo      bool `json:"photo"`
		Screenshot bool `json:"screenshot"`
		Signature  bool `json:"signature"`
	}
	if p.Decode(&body) != nil {
		return
	}
	name := d.nameOf(dev)
	switch {
	case body.URL != "":
		if link, ok := webURL(body.URL); ok {
			d.openLink(dev, link)
			return
		}
		// A path, a file: URL, or another scheme would start a local
		// program through xdg-open, so the value arrives as text.
		d.logf("%s: shared a value that is not an http or https URL, received it as text", name)
		d.receiveText(dev, body.URL)
	case body.Text != "" && body.Scan:
		d.saveScan(dev, body.Text)
	case body.Text != "":
		d.receiveText(dev, body.Text)
	case p.HasPayload():
		if p.PayloadSize <= 0 {
			d.logf("%s: ignored a file share with a payload size of %d", name, p.PayloadSize)
			return
		}
		kind := destDownload
		switch {
		case body.Signature:
			kind = destSignature
		case body.Scan:
			kind = destScan
		case body.Screenshot:
			kind = destScreenshot
		case body.Photo:
			kind = destPhoto
		}
		if !d.startReceive(dev) {
			d.logf("%s: refused %q, because %d files arrive from the device", name, body.Filename, maxReceives)
			t := d.newTransfer(dev, safeName(body.Filename), "", "in", p.PayloadSize)
			d.finishTransfer(t, fmt.Errorf("the device sends more than %d files at the same time", maxReceives))
			return
		}
		go func() {
			defer d.endReceive(dev)
			d.receiveFile(dev, l, p, body.Filename, kind)
		}()
	}
}

// webURL returns s as a URL when s is an http or https URL with a host.
// fluxd opens only such URLs. xdg-open opens a path or a file: URL with
// the default program for the file, and another scheme with the program
// for that scheme.
func webURL(s string) (string, bool) {
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return "", false
	}
	return u.String(), true
}

// openLink opens a web link from a device in the browser.
func (d *Daemon) openLink(dev *Device, link string) {
	name := d.nameOf(dev)
	if err := openWebLink(link); err != nil {
		d.logf("open %s: %v", link, err)
		d.toast("Could not open %s from %s: %v", link, name, err)
		return
	}
	d.toast("%s opened %s", name, link)
}

// receiveText puts shared text on the clipboard and in the clipboard
// history, and shows the start of the text in a desktop notification.
func (d *Daemon) receiveText(dev *Device, text string) {
	if len(text) > desktop.MaxClipboardText {
		name := d.nameOf(dev)
		d.logf("%s: ignored a shared text of %d bytes", name, len(text))
		d.toast("%s shared a text that is larger than %d MiB", name, desktop.MaxClipboardText>>20)
		return
	}
	d.setClipboard(dev, text, false)
	d.mu.Lock()
	name := dev.Name
	d.addClipLocked(ClipEntry{Text: text, Dir: "in", Device: dev.ID, DeviceName: name, Source: "share", Time: time.Now().Unix()})
	d.mu.Unlock()
	d.notifyAsync(desktop.Notification{AppName: "Flux", Title: "Text from " + name, Body: previewText(text, maxSharePreview)})
	d.markDirty()
}

// previewText returns the first max characters of s. A longer text ends
// with an ellipsis.
func previewText(s string, max int) string {
	n := 0
	for i := range s {
		if n == max {
			return s[:i] + "…"
		}
		n++
	}
	return s
}

// fileDest selects the folder for a received file.
type fileDest int

const (
	destDownload   fileDest = iota // the download folder
	destScan                       // the scan folder, for scanned PDFs
	destPhoto                      // the photo folder
	destScreenshot                 // the screenshots folder in the photo folder
	destSignature                  // the signatures folder in the photo folder
)

// maxClipboardImage is the largest signature that fluxd puts on the clipboard.
const maxClipboardImage = 16 << 20

// pngMagic starts every PNG file.
var pngMagic = []byte("\x89PNG\r\n\x1a\n")

// destDir returns the folder for a received file of the kind.
func destDir(cfg *config.Config, kind fileDest) string {
	switch kind {
	case destScan:
		return cfg.ScanPath()
	case destPhoto:
		return cfg.PhotoPath()
	case destScreenshot:
		return filepath.Join(cfg.PhotoPath(), "screenshots")
	case destSignature:
		return filepath.Join(cfg.PhotoPath(), "signatures")
	}
	return cfg.DownloadPath()
}

// startReceive counts a new incoming transfer of dev. It returns false when
// dev already sends maxReceives files.
func (d *Daemon) startReceive(dev *Device) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.content.receives[dev.ID] >= maxReceives {
		return false
	}
	if d.content.receives == nil {
		d.content.receives = map[string]int{}
	}
	d.content.receives[dev.ID]++
	return true
}

// endReceive counts the end of an incoming transfer of dev.
func (d *Daemon) endReceive(dev *Device) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if n := d.content.receives[dev.ID] - 1; n > 0 {
		d.content.receives[dev.ID] = n
	} else {
		delete(d.content.receives, dev.ID)
	}
}

func (d *Daemon) receiveFile(dev *Device, l *lan.Link, p *proto.Packet, name string, kind fileDest) {
	name = safeName(name)
	t := d.newTransfer(dev, name, "", "in", p.PayloadSize)
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	// A dropped link ends the transfer at once. Without it, a dead peer
	// holds the socket until TCP gives up.
	cancelOnLinkDown(ctx, l, cancel)
	d.mu.Lock()
	t.cancel = cancel
	dir := destDir(d.cfg, kind)
	d.mu.Unlock()

	err := d.saveFile(ctx, dev, t, dir, func(ctx context.Context) (io.ReadCloser, error) { return l.FetchPayload(ctx, p) })
	d.finishTransfer(t, err)
	if err != nil {
		d.toast("Could not receive %s: %v", name, err)
		return
	}
	title := "Received " + t.Name
	body := "Saved as " + t.Path
	from := d.nameOf(dev)
	switch kind {
	case destScan:
		title = "Scanned document from " + from
	case destPhoto:
		title = "Photo from " + from
	case destScreenshot:
		title = "Screenshot from " + from
	case destSignature:
		title = "Signature from " + from
		if err := d.copyImage(t.Path); err != nil {
			d.logf("copy signature %s: %v", t.Path, err)
		} else {
			body = "Copied to the clipboard. Saved as " + t.Path
		}
	}
	d.notify(desktop.Notification{
		AppName: "Flux", Title: title, Body: body,
		Actions: []desktop.Action{{Key: "open:" + t.Path, Label: "Open"}, {Key: "reveal:" + t.Path, Label: "Show in folder"}},
	})
}

// saveFile writes the payload of the incoming transfer t to a new file in
// dir. It reserves the final name first with an empty file. It then
// writes to a hidden temporary file and renames that file over the
// reserved name. 2 transfers with the same name then give 2 files, and a
// failed transfer leaves no file. fetch opens the payload.
func (d *Daemon) saveFile(ctx context.Context, dev *Device, t *Transfer, dir string, fetch func(context.Context) (io.ReadCloser, error)) (err error) {
	d.mu.Lock()
	name, size := t.Name, t.Size
	d.mu.Unlock()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := checkSpace(dir, size); err != nil {
		return err
	}
	d.cleanParts(dir)
	dest, err := uniquePath(ctx, filepath.Join(dir, name))
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.Remove(dest)
		}
	}()
	d.mu.Lock()
	t.Path, t.Name = dest, filepath.Base(dest)
	d.mu.Unlock()

	rc, err := fetch(ctx)
	if err != nil {
		return err
	}
	defer rc.Close()
	stop := context.AfterFunc(ctx, func() { rc.Close() })
	defer stop()
	f, err := os.CreateTemp(dir, partPrefix+"*"+partSuffix)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			os.Remove(f.Name())
		}
	}()
	idle := newIdleReader(rc, receiveIdle)
	defer idle.stop()
	src := &countingReader{r: idle, fn: d.progress(t), check: func() error {
		if !d.stillPaired(dev) {
			return errReceiveUnpaired
		}
		return nil
	}}
	n, err := io.Copy(&spaceWriter{w: f, dir: dir, left: size}, src)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n != size {
		err = fmt.Errorf("received %d of %d bytes", n, size)
	}
	if err != nil {
		return err
	}
	// os.CreateTemp makes a file that only the user can read. A received
	// file gets the mode of the reserved file, which uniquePath made with
	// the umask of fluxd.
	mode := fs.FileMode(0o600)
	if info, err := os.Stat(dest); err == nil {
		mode = info.Mode().Perm()
	}
	if err := os.Chmod(f.Name(), mode); err != nil {
		return err
	}
	return os.Rename(f.Name(), dest)
}

// freeSpace returns the bytes that the user can write in dir and the size
// of its file system. Tests replace it.
var freeSpace = func(dir string) (free, total uint64, err error) {
	var st unix.Statfs_t
	if err := unix.Statfs(dir, &st); err != nil {
		return 0, 0, err
	}
	return st.Bavail * uint64(st.Bsize), st.Blocks * uint64(st.Bsize), nil
}

// spaceMargin returns the free space that an incoming transfer leaves on
// a file system of total bytes: 1 GiB, or 5% of a file system that is
// smaller than 20 GiB.
func spaceMargin(total uint64) uint64 { return min(1<<30, total/20) }

// checkSpace returns an error when dir has no room for size more bytes and
// the margin. A file system that reports no size, such as some FUSE file
// systems, passes.
func checkSpace(dir string, size int64) error {
	free, total, err := freeSpace(dir)
	if err != nil {
		return err
	}
	if total == 0 {
		return nil
	}
	if free < uint64(max(size, 0))+spaceMargin(total) {
		return fmt.Errorf("the disk of %s is almost full", dir)
	}
	return nil
}

// spaceWriter writes to w and checks the free space of dir after each
// spaceCheck bytes. It stops the transfer before the disk is full.
type spaceWriter struct {
	w     io.Writer
	dir   string
	left  int64 // the bytes that the transfer still writes
	since int64 // the bytes since the last check
}

func (s *spaceWriter) Write(b []byte) (int, error) {
	if s.since >= spaceCheck {
		s.since = 0
		if err := checkSpace(s.dir, s.left); err != nil {
			return 0, err
		}
	}
	n, err := s.w.Write(b)
	s.since += int64(n)
	s.left -= int64(n)
	return n, err
}

// idleReader closes the stream when no data comes for the time wait. A
// read then fails with errStalled.
type idleReader struct {
	r     io.Reader
	wait  time.Duration
	timer *time.Timer
	fired atomic.Bool
}

func newIdleReader(rc io.ReadCloser, wait time.Duration) *idleReader {
	r := &idleReader{r: rc, wait: wait}
	r.timer = time.AfterFunc(wait, func() {
		r.fired.Store(true)
		rc.Close()
	})
	return r
}

func (r *idleReader) Read(b []byte) (int, error) {
	n, err := r.r.Read(b)
	if n > 0 {
		r.timer.Reset(r.wait)
	}
	if err != nil && r.fired.Load() {
		err = errStalled
	}
	return n, err
}

func (r *idleReader) stop() { r.timer.Stop() }

// cleanParts runs removeStaleParts once for each folder.
func (d *Daemon) cleanParts(dir string) {
	d.mu.Lock()
	done := d.content.cleaned[dir]
	if d.content.cleaned == nil {
		d.content.cleaned = map[string]bool{}
	}
	d.content.cleaned[dir] = true
	d.mu.Unlock()
	if !done {
		removeStaleParts(dir, time.Now())
	}
}

// removeStaleParts removes the temporary files of incoming transfers that
// stopped more than 1 day ago. Only a crash of fluxd or a power loss
// leaves such a file.
func removeStaleParts(dir string, now time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !e.Type().IsRegular() || !strings.HasPrefix(name, partPrefix) || !strings.HasSuffix(name, partSuffix) {
			continue
		}
		if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) > 24*time.Hour {
			os.Remove(filepath.Join(dir, name))
		}
	}
}

// copyImage puts the PNG file at path on the clipboard, so that the user
// can paste it at once. The file must be a PNG of at most
// maxClipboardImage bytes.
func (d *Daemon) copyImage(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxClipboardImage+1))
	if err != nil {
		return err
	}
	if len(data) > maxClipboardImage {
		return fmt.Errorf("the image is larger than %d MiB", maxClipboardImage>>20)
	}
	if !bytes.HasPrefix(data, pngMagic) {
		return errors.New("the file is not a PNG image")
	}
	return d.clip.SetImage(data, "image/png")
}

// saveScan writes text that the phone camera read into a new file in the
// scan folder. The file shows in the Files tab as a received file.
func (d *Daemon) saveScan(dev *Device, text string) {
	d.mu.Lock()
	dir, from := d.cfg.ScanPath(), dev.Name
	d.mu.Unlock()
	if len(text) > desktop.MaxClipboardText {
		d.logf("%s: ignored a scanned text of %d bytes", from, len(text))
		return
	}
	path, err := "", os.MkdirAll(dir, 0o755)
	if err == nil {
		err = checkSpace(dir, int64(len(text)))
	}
	if err == nil {
		path, err = writeScan(dir, text, time.Now())
	}
	name := filepath.Base(path)
	if path == "" {
		name = "scan.txt"
	}
	t := d.newTransfer(dev, name, path, "in", int64(len(text)))
	d.finishTransfer(t, err)
	if err != nil {
		d.logf("save scan: %v", err)
		d.notifyAsync(desktop.Notification{AppName: "Flux", Title: "Could not save scanned text", Body: err.Error(), Urgency: 2})
		return
	}
	d.notifyAsync(desktop.Notification{
		AppName: "Flux", Title: "Scanned text from " + from, Body: "Saved as " + path,
		Actions: []desktop.Action{{Key: "open:" + path, Label: "Open"}, {Key: "reveal:" + path, Label: "Show in folder"}},
	})
}

// writeScan writes text to dir/scan-<date>-<time>.txt and returns the path.
func writeScan(dir, text string, now time.Time) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path, err := uniquePath(context.Background(), filepath.Join(dir, "scan-"+now.Format("2006-01-02-150405")+".txt"))
	if err != nil {
		return "", err
	}
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

// SendFiles sends files to a device one after the other. Each path must
// be absolute, because the folder of fluxd is not the folder of the
// client.
func (d *Daemon) SendFiles(dev *Device, paths []string) ([]*Transfer, error) {
	if len(paths) == 0 {
		return nil, apiErr("bad_params", "Give at least 1 file")
	}
	for _, p := range paths {
		if !filepath.IsAbs(p) {
			return nil, apiErr("bad_params", "%s is not an absolute path. Give the full path of each file", p)
		}
	}
	d.mu.Lock()
	l := dev.link
	var err error
	switch {
	case l == nil:
		err = offline(dev)
	case !dev.Paired:
		err = apiErr("not_paired", "%s is not paired", dev.Name)
	}
	d.mu.Unlock()
	if err != nil {
		return nil, err
	}
	type item struct {
		path string
		info os.FileInfo
		t    *Transfer
	}
	var items []item
	var total int64
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, apiErr("not_found", "%s: %v", p, err)
		}
		if info.IsDir() {
			return nil, apiErr("is_dir", "%s is a folder. Send the files inside it", p)
		}
		total += info.Size()
		items = append(items, item{path: p, info: info})
	}
	var out []*Transfer
	for i := range items {
		items[i].t = d.newTransfer(dev, filepath.Base(items[i].path), items[i].path, "out", items[i].info.Size())
		out = append(out, items[i].t)
	}
	go func() {
		_ = l.Send(proto.New(proto.TypeShareUpdate, map[string]any{"numberOfFiles": len(items), "totalPayloadSize": total}))
		for _, it := range items {
			d.mu.Lock()
			canceled := it.t.State == "canceled"
			d.mu.Unlock()
			if canceled {
				continue
			}
			err := d.sendFile(l, it.t, it.path, it.info, len(items), total)
			d.finishTransfer(it.t, err)
			if err != nil {
				d.toast("Could not send %s: %v", it.t.Name, err)
			}
		}
	}()
	return out, nil
}

// sendFile sends 1 file. SendWithPayload uses a tunnel when the phone opens
// one, so the file passes a firewall that blocks incoming traffic.
func (d *Daemon) sendFile(l *lan.Link, t *Transfer, path string, info os.FileInfo, count int, total int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	cancelOnLinkDown(ctx, l, cancel)
	d.mu.Lock()
	t.cancel = cancel
	d.mu.Unlock()
	p := proto.New(proto.TypeShare, map[string]any{
		"filename":         filepath.Base(path),
		"lastModified":     info.ModTime().UnixMilli(),
		"numberOfFiles":    count,
		"totalPayloadSize": total,
	})
	return l.SendWithPayload(ctx, p, f, info.Size(), d.progress(t))
}

// ShareText sends text or a URL to a device. The key is "text" or "url". A
// text above maxSentText returns an error. A URL must be an http or https
// URL with a host, because the device opens only such a URL.
func (d *Daemon) ShareText(dev *Device, key, value string) error {
	if err := textLimit(value); err != nil {
		return err
	}
	if key == "url" {
		u, ok := webURL(value)
		if !ok {
			return apiErr("bad_params", "Give an http or https URL with a host")
		}
		value = u
	}
	return d.send(dev, proto.New(proto.TypeShare, map[string]any{key: value}))
}

// maxSentText is the largest clipboard text and shared text that fluxd
// sends to a device. Flux for Android from before this limit stops when it
// gets a text above the binder limit of Android, at about 500,000
// characters. Text from a device keeps the limit desktop.MaxClipboardText.
const maxSentText = 256 << 10

// textLimit returns an API error when text is too large to send to a
// device.
func textLimit(text string) error {
	if len(text) > maxSentText {
		return apiErr("too_large", "The text has %d bytes. Flux sends at most %d KiB of text to a device", len(text), maxSentText>>10)
	}
	return nil
}

// safeName returns the name for a received file. It keeps only the last
// element of the name. It removes control characters and the characters
// that change the direction of text, so that a name cannot hide its real
// extension. It puts "_" before a name that starts with a dot or a dash,
// so that the file is not hidden and does not look like an option. It
// cuts a long name to maxNameBytes and keeps the extension.
func safeName(name string) string {
	name = filepath.Base(strings.ReplaceAll(strings.ToValidUTF8(name, "_"), "\\", "/"))
	name = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || bidiControl(r) {
			return -1
		}
		return r
	}, name))
	if name == "" || name == "." || name == ".." || name == "/" {
		return "received-file"
	}
	if name[0] == '.' || name[0] == '-' {
		name = "_" + name
	}
	return cutName(name, maxNameBytes)
}

// bidiControl reports whether r changes the direction of the text around
// it, such as U+202E RIGHT-TO-LEFT OVERRIDE.
func bidiControl(r rune) bool {
	switch {
	case r == 0x061c, r == 0x200e, r == 0x200f:
		return true
	case r >= 0x202a && r <= 0x202e:
		return true
	case r >= 0x2066 && r <= 0x2069:
		return true
	}
	return false
}

// cutName cuts a file name to at most max bytes at the start of a UTF-8
// character. It keeps an extension of up to a quarter of max.
func cutName(name string, max int) string {
	if len(name) <= max {
		return name
	}
	ext := filepath.Ext(name)
	if len(ext) > max/4 {
		ext = ""
	}
	return cutText(name[:len(name)-len(ext)], max-len(ext)) + ext
}

// uniquePath creates an empty file at p, or at p with " (2)", " (3)", and
// so on when the name is taken. It returns the path of the new file. The
// file reserves the name, so a second transfer with the same name gets the
// next number, also while the first transfer runs. O_EXCL also refuses a
// symbolic link at the name. uniquePath stops at an error other than a
// taken name, after maxUnique names, and when ctx ends.
func uniquePath(ctx context.Context, p string) (string, error) {
	ext := filepath.Ext(p)
	base := strings.TrimSuffix(p, ext)
	for i := 1; i <= maxUnique; i++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		c := p
		if i > 1 {
			c = fmt.Sprintf("%s (%d)%s", base, i, ext)
		}
		f, err := os.OpenFile(c, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err == nil {
			f.Close()
			return c, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return "", err
		}
	}
	return "", fmt.Errorf("%d names like %s are taken", maxUnique, filepath.Base(p))
}

type countingReader struct {
	r  io.Reader
	n  int64
	fn func(int64)

	// check can stop the read with an error after each read. It can be nil.
	check func() error
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n += int64(n)
	if n > 0 {
		c.fn(c.n)
	}
	if err == nil && c.check != nil {
		err = c.check()
	}
	return n, err
}
