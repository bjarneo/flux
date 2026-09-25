package core

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxTransfers is the number of transfers that the history keeps.
const maxTransfers = 100

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

func (d *Daemon) newTransfer(dev *Device, name, dir string, size int64) *Transfer {
	t := &Transfer{
		ID: config.NewID(6), Device: dev.ID, DeviceName: dev.Name, Name: name,
		Size: size, Dir: dir, State: "queued", Time: time.Now().Unix(),
	}
	d.mu.Lock()
	d.transfers = append([]*Transfer{t}, d.transfers...)
	if len(d.transfers) > maxTransfers {
		d.transfers = d.transfers[:maxTransfers]
	}
	d.mu.Unlock()
	d.markDirty()
	return t
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
			if t.cancel != nil && (t.State == "queued" || t.State == "active") {
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
		Open     bool   `json:"open"`
		// Scan marks text or a PDF that the phone camera scanned. Photo marks
		// a photo from the phone camera. Both come from Flux for Android.
		Scan  bool `json:"scan"`
		Photo bool `json:"photo"`
	}
	if p.Decode(&body) != nil {
		return
	}
	switch {
	case body.URL != "":
		if err := desktop.Open(body.URL); err != nil {
			d.logf("open %s: %v", body.URL, err)
		}
		d.toast("%s opened %s", dev.Name, body.URL)
	case body.Text != "" && body.Scan:
		d.saveScan(dev, body.Text)
	case body.Text != "":
		go func() { _ = d.clip.Set(body.Text) }()
		d.mu.Lock()
		d.addClipLocked(ClipEntry{Text: body.Text, Dir: "in", Device: dev.ID, DeviceName: dev.Name, Source: "share", Time: time.Now().Unix()})
		d.mu.Unlock()
		d.notify(desktop.Notification{AppName: "Flux", Title: "Text from " + dev.Name, Body: body.Text})
		d.markDirty()
	case p.HasPayload():
		kind := destDownload
		switch {
		case body.Scan:
			kind = destScan
		case body.Photo:
			kind = destPhoto
		}
		go d.receiveFile(dev, l, p, body.Filename, body.Open, kind)
	}
}

// fileDest selects the folder for a received file.
type fileDest int

const (
	destDownload fileDest = iota // the download folder
	destScan                     // the scan folder, for scanned PDFs
	destPhoto                    // the photo folder
)

func (d *Daemon) receiveFile(dev *Device, l *lan.Link, p *proto.Packet, name string, open bool, kind fileDest) {
	name = safeName(name)
	t := d.newTransfer(dev, name, "in", p.PayloadSize)
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	d.mu.Lock()
	t.cancel = cancel
	dir := d.cfg.DownloadPath()
	switch kind {
	case destScan:
		dir = d.cfg.ScanPath()
	case destPhoto:
		dir = d.cfg.PhotoPath()
	}
	d.mu.Unlock()

	err := func() error {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		dest := uniquePath(filepath.Join(dir, name))
		d.mu.Lock()
		t.Path, t.Name = dest, filepath.Base(dest)
		d.mu.Unlock()
		rc, err := l.FetchPayload(ctx, p)
		if err != nil {
			return err
		}
		defer rc.Close()
		stop := context.AfterFunc(ctx, func() { rc.Close() })
		defer stop()
		part := dest + ".part"
		f, err := os.Create(part)
		if err != nil {
			return err
		}
		n, err := io.Copy(f, &countingReader{r: rc, fn: d.progress(t)})
		if cerr := f.Close(); err == nil {
			err = cerr
		}
		if err == nil && p.PayloadSize > 0 && n != p.PayloadSize {
			err = fmt.Errorf("received %d of %d bytes", n, p.PayloadSize)
		}
		if err != nil {
			os.Remove(part)
			return err
		}
		return os.Rename(part, dest)
	}()
	d.finishTransfer(t, err)
	if err != nil {
		d.toast("Could not receive %s: %v", name, err)
		return
	}
	title := "Received " + t.Name
	switch kind {
	case destScan:
		title = "Scanned document from " + dev.Name
	case destPhoto:
		title = "Photo from " + dev.Name
	}
	d.notify(desktop.Notification{
		AppName: "Flux", Title: title, Body: "Saved as " + t.Path,
		Actions: []desktop.Action{{Key: "open:" + t.Path, Label: "Open"}, {Key: "reveal:" + t.Path, Label: "Show in folder"}},
	})
	if open {
		_ = desktop.Open(t.Path)
	}
}

// saveScan writes text that the phone camera read into a new file in the
// scan folder. The file shows in the Files tab as a received file.
func (d *Daemon) saveScan(dev *Device, text string) {
	d.mu.Lock()
	dir := d.cfg.ScanPath()
	d.mu.Unlock()
	path, err := writeScan(dir, text, time.Now())
	t := d.newTransfer(dev, filepath.Base(path), "in", int64(len(text)))
	d.mu.Lock()
	t.Path = path
	d.mu.Unlock()
	d.finishTransfer(t, err)
	if err != nil {
		d.logf("save scan: %v", err)
		d.notify(desktop.Notification{AppName: "Flux", Title: "Could not save scanned text", Body: err.Error(), Urgency: 2})
		return
	}
	d.notify(desktop.Notification{
		AppName: "Flux", Title: "Scanned text from " + dev.Name, Body: "Saved as " + path,
		Actions: []desktop.Action{{Key: "open:" + path, Label: "Open"}, {Key: "reveal:" + path, Label: "Show in folder"}},
	})
}

// writeScan writes text to dir/scan-<date>-<time>.txt and returns the path.
func writeScan(dir, text string, now time.Time) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := uniquePath(filepath.Join(dir, "scan-"+now.Format("2006-01-02-150405")+".txt"))
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	return path, os.WriteFile(path, []byte(text), 0o644)
}

// SendFiles sends files to a device one after the other.
func (d *Daemon) SendFiles(dev *Device, paths []string) ([]*Transfer, error) {
	d.mu.Lock()
	l := dev.link
	d.mu.Unlock()
	if l == nil {
		return nil, offline(dev)
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
		items[i].t = d.newTransfer(dev, filepath.Base(items[i].path), "out", items[i].info.Size())
		items[i].t.Path = items[i].path
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
	d.mu.Lock()
	t.cancel = cancel
	d.mu.Unlock()
	p := proto.New(proto.TypeShare, map[string]any{
		"filename":         filepath.Base(path),
		"lastModified":     info.ModTime().UnixMilli(),
		"open":             false,
		"numberOfFiles":    count,
		"totalPayloadSize": total,
	})
	return l.SendWithPayload(ctx, p, f, info.Size(), d.progress(t))
}

// ShareText sends text or a URL to a device.
func (d *Daemon) ShareText(dev *Device, key, value string) error {
	return d.send(dev, proto.New(proto.TypeShare, map[string]any{key: value}))
}

// safeName keeps only the last element of a received file name.
func safeName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	if name == "." || name == "/" || name == ".." || name == "" {
		name = "received-file"
	}
	return name
}

// uniquePath adds " (2)", " (3)", and so on when the file exists.
func uniquePath(p string) string {
	if _, err := os.Stat(p); os.IsNotExist(err) {
		return p
	}
	ext := filepath.Ext(p)
	base := strings.TrimSuffix(p, ext)
	for i := 2; ; i++ {
		c := fmt.Sprintf("%s (%d)%s", base, i, ext)
		if _, err := os.Stat(c); os.IsNotExist(err) {
			return c
		}
	}
}

type countingReader struct {
	r  io.Reader
	n  int64
	fn func(int64)
}

func (c *countingReader) Read(b []byte) (int, error) {
	n, err := c.r.Read(b)
	c.n += int64(n)
	if n > 0 {
		c.fn(c.n)
	}
	return n, err
}
