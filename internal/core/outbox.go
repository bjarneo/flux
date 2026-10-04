package core

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

const maxFileOutbox = 100

type outboxJob struct {
	ID         string `json:"id"`
	Device     string `json:"device"`
	DeviceName string `json:"deviceName"`
	Name       string `json:"name"`
	Size       int64  `json:"size"`
	Hash       string `json:"hash"`
	Time       int64  `json:"time"`
	Attempts   int    `json:"attempts"`
	Next       int64  `json:"next"`
}

type outbox struct {
	mu        sync.Mutex
	dir       string
	jobs      map[string]outboxJob
	preparing int
}

func (d *Daemon) loadOutbox() error {
	o := &outbox{dir: filepath.Join(config.DataDir(), "outbox"), jobs: map[string]outboxJob{}}
	if err := os.MkdirAll(o.dir, 0o700); err != nil {
		return err
	}
	entries, err := os.ReadDir(o.dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".json" {
			continue
		}
		var j outboxJob
		b, err := os.ReadFile(filepath.Join(o.dir, e.Name()))
		if err != nil {
			return err
		}
		if json.Unmarshal(b, &j) != nil || !transferID.MatchString(j.ID) || e.Name() != j.ID+".json" {
			return fmt.Errorf("invalid outbox record %s", e.Name())
		}
		if dev := d.devices[j.Device]; dev == nil || !dev.Paired {
			os.Remove(filepath.Join(o.dir, j.ID+".data"))
			os.Remove(filepath.Join(o.dir, e.Name()))
			continue
		}
		o.jobs[j.ID] = j
		d.transfers = append(d.transfers, &Transfer{ID: j.ID, Device: j.Device, DeviceName: j.DeviceName,
			Name: j.Name, Size: j.Size, Time: j.Time, Dir: "out", State: "waiting"})
	}
	sort.Slice(d.transfers, func(i, j int) bool { return d.transfers[i].Time > d.transfers[j].Time })
	d.outbox = o
	return nil
}

// queueFiles snapshots each source. A later source edit cannot change a queued transfer.
func (d *Daemon) queueFiles(dev *Device, paths []string) ([]*Transfer, error) {
	o := d.outbox
	if o == nil {
		return d.sendFilesNow(dev, paths)
	}
	if len(paths) == 0 {
		return nil, apiErr("bad_params", "Select at least one file or folder")
	}
	o.mu.Lock()
	if len(o.jobs)+o.preparing+len(paths) > maxFileOutbox {
		o.mu.Unlock()
		return nil, apiErr("full", "The outbox holds at most %d files", maxFileOutbox)
	}
	o.preparing += len(paths)
	o.mu.Unlock()
	defer func() { o.mu.Lock(); o.preparing -= len(paths); o.mu.Unlock() }()
	var jobs []outboxJob
	committed := false
	defer func() {
		if !committed {
			for _, j := range jobs {
				os.Remove(filepath.Join(o.dir, j.ID+".data"))
				os.Remove(filepath.Join(o.dir, j.ID+".json"))
			}
		}
	}()
	for _, source := range paths {
		j := outboxJob{ID: config.NewID(6), Device: dev.ID, DeviceName: dev.Name, Name: safeName(filepath.Base(filepath.Clean(source))), Time: time.Now().Unix()}
		jobs = append(jobs, j)
		dest := filepath.Join(o.dir, j.ID+".data")
		info, err := os.Lstat(source)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() && !info.IsDir() {
			return nil, apiErr("unsupported", "Select a regular file or folder: %s", source)
		}
		f, err := os.OpenFile(dest, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return nil, err
		}
		hash := sha256.New()
		w := io.MultiWriter(f, hash)
		if info.IsDir() {
			j.Name += ".zip"
			err = zipFolder(d.ctx, source, w)
		} else {
			var src *os.File
			src, err = os.Open(source)
			if err == nil {
				_, err = io.Copy(w, src)
				src.Close()
			}
		}
		if err == nil {
			err = f.Sync()
		}
		stat, statErr := f.Stat()
		closeErr := f.Close()
		if err != nil {
			return nil, err
		}
		if statErr != nil {
			return nil, statErr
		}
		if closeErr != nil {
			return nil, closeErr
		}
		j.Size, j.Hash = stat.Size(), hex.EncodeToString(hash.Sum(nil))
		jobs[len(jobs)-1] = j
		if err := saveJSON(filepath.Join(o.dir, j.ID+".json"), j); err != nil {
			return nil, err
		}
	}
	var ts []*Transfer
	o.mu.Lock()
	defer o.mu.Unlock()
	d.mu.Lock()
	if !dev.Paired {
		d.mu.Unlock()
		return nil, apiErr("not_paired", "The destination is no longer paired")
	}
	for _, j := range jobs {
		o.jobs[j.ID] = j
		t := &Transfer{ID: j.ID, Device: j.Device, DeviceName: j.DeviceName, Name: j.Name, Size: j.Size, Time: j.Time, Dir: "out", State: "waiting"}
		d.transfers = append([]*Transfer{t}, d.transfers...)
		ts = append(ts, t)
	}
	d.mu.Unlock()
	committed = true
	d.markDirty()
	return ts, nil
}

func (d *Daemon) clearDeviceOutbox(device string) {
	if d.outbox == nil {
		return
	}
	d.outbox.mu.Lock()
	var ids []string
	for id, j := range d.outbox.jobs {
		if j.Device == device {
			ids = append(ids, id)
		}
	}
	d.outbox.mu.Unlock()
	for _, id := range ids {
		if _, err := d.cancelOutbox(id); err != nil {
			d.logf("cancel outbox %s: %v", id, err)
		}
	}
}

func zipFolder(ctx context.Context, root string, out io.Writer) error {
	z := zip.NewWriter(out)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if ctx != nil && ctx.Err() != nil {
			return ctx.Err()
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return fmt.Errorf("cannot archive a special file or symbolic link: %s", path)
		}
		rel, err := filepath.Rel(filepath.Dir(filepath.Clean(root)), path)
		if err != nil {
			return err
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		header.Name = filepath.ToSlash(rel)
		if info.IsDir() {
			header.Name += "/"
		} else {
			header.Method = zip.Deflate
		}
		w, err := z.CreateHeader(header)
		if err != nil || info.IsDir() {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(w, f)
		return err
	})
	closeErr := z.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func (d *Daemon) outboxLoop(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		o := d.outbox
		o.mu.Lock()
		jobs := make([]outboxJob, 0, len(o.jobs))
		for _, j := range o.jobs {
			jobs = append(jobs, j)
		}
		o.mu.Unlock()
		sort.Slice(jobs, func(i, j int) bool { return jobs[i].Time < jobs[j].Time })
		for _, j := range jobs {
			if ctx.Err() != nil {
				return
			}
			if j.Next > time.Now().Unix() {
				continue
			}
			d.sendOutbox(ctx, j)
		}
	}
}

func (d *Daemon) sendOutbox(parent context.Context, j outboxJob) {
	o := d.outbox
	o.mu.Lock()
	_, exists := o.jobs[j.ID]
	d.mu.Lock()
	dev := d.devices[j.Device]
	var t *Transfer
	for _, x := range d.transfers {
		if x.ID == j.ID {
			t = x
			break
		}
	}
	if !exists || t == nil || t.State == "canceled" || dev == nil || !dev.Paired || dev.link == nil {
		d.mu.Unlock()
		o.mu.Unlock()
		return
	}
	l := dev.link
	resume := dev.accepts(proto.TypeFluxTransfer)
	ctx, cancel := context.WithCancel(parent)
	t.cancel, t.State, t.Error = cancel, "active", ""
	d.mu.Unlock()
	o.mu.Unlock()
	defer cancel()
	cancelOnLinkDown(ctx, l, cancel)
	d.markDirty()
	err := func() error {
		path := filepath.Join(o.dir, j.ID+".data")
		if resume {
			return d.sendResumable(ctx, l, t, j, path)
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		p := proto.New(proto.TypeShare, map[string]any{"filename": j.Name, "open": false})
		return l.SendWithPayload(ctx, p, f, j.Size, d.progress(t))
	}()
	o.mu.Lock()
	defer o.mu.Unlock()
	if _, exists := o.jobs[j.ID]; !exists {
		return
	}
	if err == nil {
		delete(o.jobs, j.ID)
		os.Remove(filepath.Join(o.dir, j.ID+".json"))
		os.Remove(filepath.Join(o.dir, j.ID+".data"))
		d.finishTransfer(t, nil)
		return
	}
	j.Attempts++
	j.Next = time.Now().Add(time.Duration(min(300, 1<<min(j.Attempts, 8))) * time.Second).Unix()
	o.jobs[j.ID] = j
	if saveErr := saveJSON(filepath.Join(o.dir, j.ID+".json"), j); saveErr != nil {
		d.logf("save outbox: %v", saveErr)
	}
	d.mu.Lock()
	if t.State != "canceled" {
		t.State, t.Error, t.Rate = "waiting", err.Error(), 0
	}
	d.mu.Unlock()
	d.markDirty()
}

func (d *Daemon) cancelOutbox(id string) (bool, error) {
	if d.outbox == nil {
		return false, nil
	}
	o := d.outbox
	o.mu.Lock()
	defer o.mu.Unlock()
	if _, ok := o.jobs[id]; !ok {
		return false, nil
	}
	if err := os.Remove(filepath.Join(o.dir, id+".json")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return true, err
	}
	delete(o.jobs, id)
	d.mu.Lock()
	for _, t := range d.transfers {
		if t.ID == id {
			t.State, t.Rate = "canceled", 0
			if t.cancel != nil {
				t.cancel()
			}
			break
		}
	}
	d.mu.Unlock()
	os.Remove(filepath.Join(o.dir, id+".data"))
	d.markDirty()
	return true, nil
}

func (d *Daemon) retryTransfer(id string) error {
	if d.outbox == nil {
		return apiErr("not_found", "No queued transfer with ID %s", id)
	}
	o := d.outbox
	o.mu.Lock()
	defer o.mu.Unlock()
	j, ok := o.jobs[id]
	if !ok {
		return apiErr("not_found", "No queued transfer with ID %s", id)
	}
	j.Next = 0
	if err := saveJSON(filepath.Join(o.dir, id+".json"), j); err != nil {
		return err
	}
	o.jobs[id] = j
	return nil
}
