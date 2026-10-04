package core

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maxSnippets = 100

func (d *Daemon) loadSnippets() error {
	data, err := os.ReadFile(filepath.Join(d.snippetsDir, "index.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &d.snippets); err != nil {
		return err
	}
	for i := range d.snippets {
		e := &d.snippets[i]
		e.Pinned = true
		if e.Image != "" {
			e.Image = filepath.Join(d.snippetsDir, filepath.Base(e.Image))
		}
	}
	return d.expireSnippetsLocked(time.Now().Unix())
}

func (d *Daemon) pinClip(id string, expires int64) (ClipEntry, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if expires < 0 || (expires != 0 && expires <= time.Now().Unix()) {
		return ClipEntry{}, apiErr("bad_params", "The expiry must be in the future")
	}
	if len(d.snippets) >= maxSnippets {
		return ClipEntry{}, apiErr("full", "At most %d snippets can be saved", maxSnippets)
	}
	var e ClipEntry
	for _, item := range d.clipboard {
		if item.ID == id {
			e = item
			break
		}
	}
	if e.ID == "" {
		return e, apiErr("not_found", "No clipboard entry with ID %s", id)
	}
	for _, item := range d.snippets {
		if item.ID == id {
			return item, nil
		}
	}
	if len(e.Text) > 1<<20 {
		return e, apiErr("too_large", "A saved text snippet must be at most 1 MiB")
	}
	e.Pinned, e.Expires = true, expires
	if e.Image != "" {
		data, err := os.ReadFile(e.Image)
		if err != nil {
			return e, err
		}
		if len(data) > maxClipboardImage {
			return e, apiErr("too_large", "A saved image must be at most 16 MiB")
		}
		if err := os.MkdirAll(d.snippetsDir, 0o700); err != nil {
			return e, err
		}
		e.Image = filepath.Join(d.snippetsDir, e.ID+filepath.Ext(e.Image))
		if err := os.WriteFile(e.Image, data, 0o600); err != nil {
			return e, err
		}
	}
	all := append([]ClipEntry{e}, d.snippets...)
	if err := saveJSON(filepath.Join(d.snippetsDir, "index.json"), all); err != nil {
		if e.Image != "" {
			os.Remove(e.Image)
		}
		return e, err
	}
	d.snippets = all
	d.markDirty()
	return e, nil
}

func (d *Daemon) unpinClip(id string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	var all []ClipEntry
	var image string
	found := false
	for _, e := range d.snippets {
		if e.ID == id {
			found, image = true, e.Image
		} else {
			all = append(all, e)
		}
	}
	if !found {
		return apiErr("not_found", "No saved snippet with ID %s", id)
	}
	if err := saveJSON(filepath.Join(d.snippetsDir, "index.json"), all); err != nil {
		return err
	}
	d.snippets = all
	if image != "" {
		os.Remove(image)
	}
	d.markDirty()
	return nil
}

func (d *Daemon) clipEntriesLocked() []ClipEntry {
	all := make([]ClipEntry, 0, len(d.snippets)+len(d.clipboard))
	ids := map[string]bool{}
	for _, e := range d.snippets {
		if e.Expires != 0 && e.Expires <= time.Now().Unix() {
			continue
		}
		all = append(all, e)
		ids[e.ID] = true
	}
	for _, e := range d.clipboard {
		if !ids[e.ID] {
			all = append(all, e)
		}
	}
	return all
}

func (d *Daemon) searchClips(query string) []ClipEntry {
	d.mu.Lock()
	defer d.mu.Unlock()
	query = strings.ToLower(query)
	out := []ClipEntry{}
	for _, e := range d.clipEntriesLocked() {
		if strings.Contains(strings.ToLower(e.Text+" "+e.DeviceName), query) {
			out = append(out, e)
		}
	}
	return out
}

func (d *Daemon) expireSnippetsLocked(now int64) error {
	var kept, removed []ClipEntry
	for _, e := range d.snippets {
		if e.Expires > 0 && e.Expires <= now {
			removed = append(removed, e)
		} else {
			kept = append(kept, e)
		}
	}
	if len(removed) == 0 {
		return nil
	}
	if err := saveJSON(filepath.Join(d.snippetsDir, "index.json"), kept); err != nil {
		return err
	}
	d.snippets = kept
	for _, e := range removed {
		if e.Image != "" {
			os.Remove(e.Image)
		}
	}
	d.markDirty()
	return nil
}

func (d *Daemon) snippetLoop(ctx context.Context) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		d.mu.Lock()
		err := d.expireSnippetsLocked(time.Now().Unix())
		d.mu.Unlock()
		if err != nil {
			d.logf("expire snippets: %v", err)
		}
	}
}
