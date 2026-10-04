package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

const transferChunk = 1 << 20

var transferID = regexp.MustCompile(`^[a-f0-9]{12}$`)
var transferHash = regexp.MustCompile(`^[a-f0-9]{64}$`)

type resumeMessage struct {
	Action string `json:"action"`
	ID     string `json:"id"`
	Name   string `json:"name,omitempty"`
	Size   int64  `json:"size,omitempty"`
	Hash   string `json:"hash,omitempty"`
	Offset int64  `json:"offset"`
	Error  string `json:"error,omitempty"`
}

type incomingRecord struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	Hash string `json:"hash"`
	Path string `json:"path,omitempty"`
}

func (d *Daemon) sendResumable(ctx context.Context, l *lan.Link, t *Transfer, j outboxJob, path string) error {
	ch := make(chan resumeMessage, 2)
	key := l.DeviceID() + ":" + j.ID
	d.mu.Lock()
	d.resumeReplies[key] = ch
	d.mu.Unlock()
	defer func() { d.mu.Lock(); delete(d.resumeReplies, key); d.mu.Unlock() }()
	wait := func() (resumeMessage, error) {
		select {
		case b := <-ch:
			if b.Action == "error" {
				return b, errors.New(b.Error)
			}
			return b, nil
		case <-ctx.Done():
			return resumeMessage{}, ctx.Err()
		case <-time.After(time.Minute):
			return resumeMessage{}, errors.New("the device did not acknowledge the transfer")
		}
	}
	b := resumeMessage{Action: "offer", ID: j.ID, Name: j.Name, Size: j.Size, Hash: j.Hash}
	if err := l.Send(proto.New(proto.TypeFluxTransfer, b)); err != nil {
		return err
	}
	ack, err := wait()
	if err != nil {
		return err
	}
	if ack.Action == "done" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	for ack.Action == "offset" && ack.Offset >= 0 && ack.Offset < j.Size {
		offset := ack.Offset
		length := min(int64(transferChunk), j.Size-offset)
		b.Action, b.Offset = "chunk", offset
		progress := d.progress(t)
		if err := l.SendWithPayload(ctx, proto.New(proto.TypeFluxTransfer, b), io.NewSectionReader(f, offset, length), length,
			func(n int64) { progress(offset + n) }); err != nil {
			return err
		}
		ack, err = wait()
		if err != nil {
			return err
		}
		if ack.Action == "done" {
			return nil
		}
		if ack.Offset != offset+length {
			return errors.New("the device acknowledged an unexpected transfer offset")
		}
	}
	return errors.New("the device returned an invalid transfer offset")
}

func (d *Daemon) handleResumable(dev *Device, l *lan.Link, p *proto.Packet) {
	var b resumeMessage
	if p.Decode(&b) != nil || !transferID.MatchString(b.ID) {
		return
	}
	if b.Action == "offset" || b.Action == "done" || b.Action == "error" {
		d.mu.Lock()
		ch := d.resumeReplies[dev.ID+":"+b.ID]
		current := dev.link == l
		d.mu.Unlock()
		if current && ch != nil {
			select {
			case ch <- b:
			default:
			}
		}
		return
	}
	if b.Action != "offer" && b.Action != "chunk" {
		return
	}
	go func() {
		d.resumeMu.Lock()
		defer d.resumeMu.Unlock()
		if b.Action == "offer" {
			pruneIncoming(d.resumeDir, time.Now().Add(-7*24*time.Hour))
		}
		reply, err := d.receiveResumable(dev, l, p, b)
		if err != nil {
			reply = resumeMessage{Action: "error", ID: b.ID, Error: err.Error()}
		}
		_ = l.Send(proto.New(proto.TypeFluxTransfer, reply))
	}()
}

func pruneIncoming(dir string, before time.Time) {
	entries, _ := os.ReadDir(dir)
	for _, entry := range entries {
		if !entry.IsDir() || !transferHash.MatchString(entry.Name()) {
			continue
		}
		if info, err := entry.Info(); err == nil && info.ModTime().Before(before) {
			_ = os.RemoveAll(filepath.Join(dir, entry.Name()))
		}
	}
}

func (d *Daemon) receiveResumable(dev *Device, l *lan.Link, p *proto.Packet, b resumeMessage) (resumeMessage, error) {
	ack := resumeMessage{Action: "offset", ID: b.ID}
	if !transferHash.MatchString(b.Hash) || b.Size < 0 || b.Size > 1<<40 || safeName(b.Name) != b.Name || b.Name == "" {
		return ack, errors.New("invalid transfer metadata")
	}
	key := sha256.Sum256([]byte(dev.ID + ":" + b.ID))
	dir := filepath.Join(d.resumeDir, hex.EncodeToString(key[:]))
	metaPath, part := filepath.Join(dir, "state.json"), filepath.Join(dir, "data")
	defer func() { _ = os.Chtimes(dir, time.Now(), time.Now()) }()
	r := incomingRecord{Name: b.Name, Size: b.Size, Hash: b.Hash}
	if data, err := os.ReadFile(metaPath); err == nil {
		var old incomingRecord
		if json.Unmarshal(data, &old) != nil || old.Name != r.Name || old.Size != r.Size || old.Hash != r.Hash {
			return ack, errors.New("transfer metadata changed")
		}
		r = old
		if r.Path != "" {
			ack.Action, ack.Offset = "done", r.Size
			return ack, nil
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return ack, err
	} else if err := saveJSON(metaPath, r); err != nil {
		return ack, err
	}
	f, err := os.OpenFile(part, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return ack, err
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return ack, err
	}
	offset := stat.Size()
	if offset > b.Size {
		return ack, errors.New("partial file exceeds the transfer size")
	}
	if b.Action == "chunk" {
		if b.Offset != offset || p.PayloadSize <= 0 || p.PayloadSize > transferChunk || p.PayloadSize > b.Size-offset {
			return ack, errors.New("invalid transfer chunk")
		}
		ctx, cancel := context.WithTimeout(d.ctx, time.Minute)
		defer cancel()
		cancelOnLinkDown(ctx, l, cancel)
		rc, err := l.FetchPayload(ctx, p)
		if err != nil {
			return ack, err
		}
		defer rc.Close()
		defer context.AfterFunc(ctx, func() { rc.Close() })()
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return ack, err
		}
		n, err := io.CopyN(f, rc, p.PayloadSize)
		if syncErr := f.Sync(); err == nil {
			err = syncErr
		}
		if err != nil {
			return ack, err
		}
		offset += n
	}
	ack.Offset = offset
	if offset != b.Size {
		return ack, nil
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return ack, err
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ack, err
	}
	if hex.EncodeToString(h.Sum(nil)) != b.Hash {
		_ = f.Truncate(0)
		return ack, errors.New("the file checksum does not match")
	}
	d.mu.Lock()
	destDir := d.cfg.DownloadPath()
	d.mu.Unlock()
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return ack, err
	}
	f.Seek(0, io.SeekStart)
	dest, err := os.CreateTemp(destDir, ".flux-received-*")
	if err != nil {
		return ack, err
	}
	defer os.Remove(dest.Name())
	_, err = io.Copy(dest, f)
	if err == nil {
		err = dest.Sync()
	}
	if e := dest.Close(); err == nil {
		err = e
	}
	if err != nil {
		os.Remove(dest.Name())
		return ack, err
	}
	r.Path, err = uniquePath(d.ctx, filepath.Join(destDir, b.Name))
	if err != nil {
		return ack, err
	}
	if err = os.Rename(dest.Name(), r.Path); err != nil {
		os.Remove(r.Path)
		return ack, err
	}
	if err := saveJSON(metaPath, r); err != nil {
		os.Remove(r.Path)
		return ack, err
	}
	os.Remove(part)
	t := d.newTransfer(dev, b.Name, r.Path, "in", b.Size)
	d.mu.Lock()
	t.Path = r.Path
	d.mu.Unlock()
	d.finishTransfer(t, nil)
	d.notify(desktop.Notification{AppName: "Flux", Title: "Received " + b.Name, Body: "Saved as " + r.Path,
		Actions: []desktop.Action{{Key: "open:" + r.Path, Label: "Open"}}})
	ack.Action = "done"
	return ack, nil
}
