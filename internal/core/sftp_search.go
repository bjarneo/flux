package core

import (
	"cmp"
	"context"
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"flux/internal/proto"
)

// Search of Browse PC. While its session runs, the phone sends
// flux.sftp.request with a search body. fluxd reads the folders of the
// session and answers with flux.sftp. The search uses the rules of the
// session: it skips each name that starts with a dot and the Flux folders,
// and it does not go into a folder through a symlink. It also skips the
// node_modules folders, which hold many names that nobody looks for.

const (
	// maxSearchResults is the number of matches that 1 answer holds.
	maxSearchResults = 100
	// maxSearchEntries is the number of names that 1 search reads.
	maxSearchEntries = 2_000_000
	// maxSearchQuery is the longest query in bytes.
	maxSearchQuery = 200
)

// searchTime is the longest time that 1 search runs.
var searchTime = 10 * time.Second

// browseSearch is the search body of flux.sftp.request. The phone gives
// each search a new ID.
type browseSearch struct {
	ID    int64  `json:"id"`
	Query string `json:"query"`
	// Path is the folder that the search reads, with its subfolders. An
	// empty path reads each shared folder.
	Path string `json:"path"`
}

// browseMatch is 1 file or folder that a search found. Path is the path
// that the phone opens or downloads. Modified is in Unix seconds.
type browseMatch struct {
	Path     string `json:"path"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
}

// browseFound is the search body of flux.sftp. More tells that more names
// match than the answer holds. Partial tells that the search stopped at
// its time limit or its entry limit before it read each folder.
type browseFound struct {
	ID      int64         `json:"id"`
	Results []browseMatch `json:"results"`
	More    bool          `json:"more"`
	Partial bool          `json:"partial"`
	Error   string        `json:"error,omitempty"`
}

// searchBrowse answers a search of a device. The search runs in the Browse
// PC session of the device, so it reads only what the session can read. A
// new search of the device stops the search before it, and that search
// sends no answer.
func (d *Daemon) searchBrowse(dev *Device, l interface{ Send(*proto.Packet) error }, req browseSearch) {
	reply := func(f browseFound) {
		f.ID = req.ID
		if f.Results == nil {
			f.Results = []browseMatch{}
		}
		_ = l.Send(proto.New(proto.TypeSftp, map[string]any{"search": f}))
	}
	words := strings.Fields(strings.ToLower(req.Query))
	if len(words) == 0 || len(req.Query) > maxSearchQuery {
		reply(browseFound{Error: "Type 1 to 200 characters of the name"})
		return
	}
	d.mu.Lock()
	var s *browseSession
	for _, o := range d.sessions.browse {
		if o.dev.ID == dev.ID {
			s = o
		}
	}
	if s == nil || s.fsys == nil {
		d.mu.Unlock()
		reply(browseFound{Error: "Get files is not open. Open it again."})
		return
	}
	if s.stopSearch != nil {
		s.stopSearch()
	}
	ctx, cancel := context.WithTimeout(s.ctx, searchTime)
	s.stopSearch = cancel
	fsys := s.fsys
	d.mu.Unlock()

	go func() {
		defer cancel()
		found, more, partial, err := fsys.search(ctx, req.Path, words)
		if errors.Is(ctx.Err(), context.Canceled) {
			return
		}
		if err != nil {
			reply(browseFound{Error: "Cannot search: " + err.Error()})
			return
		}
		reply(browseFound{Results: found, More: more, Partial: partial})
	}()
}

// searchDir is 1 folder that a search reads. Path is the path that the
// phone uses. Rel is the path in the root without symlinks.
type searchDir struct {
	root *browseRoot
	path string
	rel  string
}

// search finds the files and the folders whose names hold each word. The
// words are in lower case. It reads the folders breadth first, so that a
// match near the top comes first. It reads from, or each root when from is
// empty.
func (fsys *browseFS) search(ctx context.Context, from string, words []string) (found []browseMatch, more, partial bool, err error) {
	var queue []searchDir
	if from == "" {
		for i := range fsys.roots {
			r := &fsys.roots[i]
			if !fsys.nested(i) && fsys.visible(r, r.real) {
				queue = append(queue, searchDir{root: r, path: r.path, rel: "."})
			}
		}
	} else {
		r, rel, err := fsys.resolve(from)
		if err != nil {
			return nil, false, false, err
		}
		f, real, err := fsys.openIn(r, rel)
		if err != nil {
			return nil, false, false, err
		}
		fi, err := f.Stat()
		f.Close()
		if err != nil || !fi.IsDir() {
			return nil, false, false, errBrowseDenied
		}
		inner := strings.TrimPrefix(strings.TrimPrefix(real, r.real), "/")
		if inner == "" {
			inner = "."
		}
		queue = append(queue, searchDir{root: r, path: path.Clean(from), rel: inner})
	}
	read := 0
	for len(queue) > 0 && !more {
		if ctx.Err() != nil || read >= maxSearchEntries {
			partial = true
			break
		}
		if fsys.allowed != nil && !fsys.allowed() {
			return nil, false, false, errBrowseDenied
		}
		dir := queue[0]
		queue = queue[1:]
		entries, err := fsys.readSearchDir(dir)
		if err != nil {
			continue
		}
		read += len(entries)
		for _, e := range entries {
			name := e.Name()
			if strings.HasPrefix(name, ".") {
				continue
			}
			rel := path.Join(dir.rel, name)
			match := nameMatches(name, words)
			var fi fs.FileInfo
			switch {
			case e.Type()&fs.ModeSymlink != 0:
				// A symlink shows as its target when the target is visible
				// in the same root, as in a folder list. The search does not
				// go into it.
				if !match {
					continue
				}
				t, _, err := fsys.openIn(dir.root, rel)
				if err != nil {
					continue
				}
				fi, err = t.Stat()
				t.Close()
				if err != nil {
					continue
				}
			case e.IsDir():
				if name == "node_modules" || !fsys.visible(dir.root, filepath.Join(dir.root.real, rel)) {
					continue
				}
				queue = append(queue, searchDir{root: dir.root, path: path.Join(dir.path, name), rel: rel})
				if !match {
					continue
				}
				if fi, err = e.Info(); err != nil {
					continue
				}
			case e.Type().IsRegular():
				if !match {
					continue
				}
				if fi, err = e.Info(); err != nil {
					continue
				}
			default:
				continue
			}
			if len(found) == maxSearchResults {
				more = true
				break
			}
			found = append(found, browseMatch{
				Path: path.Join(dir.path, name), Dir: fi.IsDir(), Size: fi.Size(), Modified: fi.ModTime().Unix(),
			})
		}
	}
	sortMatches(found, words)
	return found, more, partial, nil
}

// readSearchDir lists 1 folder of a search. A folder can change into a
// symlink after its parent was read, so readSearchDir checks the real path
// of the folder that it opened.
func (fsys *browseFS) readSearchDir(dir searchDir) ([]os.DirEntry, error) {
	f, err := dir.root.root.Open(dir.rel)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	real, err := fdPath(f)
	if err != nil {
		return nil, err
	}
	if want := filepath.Join(dir.root.real, dir.rel); real != want || !fsys.visible(dir.root, real) {
		return nil, errBrowseDenied
	}
	return f.ReadDir(-1)
}

// nested reports whether the search of another root reads root i, so that
// a search of each root reads a folder once. That root holds root i
// without a symlink between them. Of 2 equal roots, the first one stays.
func (fsys *browseFS) nested(i int) bool {
	r := &fsys.roots[i]
	for j := range fsys.roots {
		o := &fsys.roots[j]
		if j == i || !within(o.path, r.path) {
			continue
		}
		if o.path == r.path {
			if j < i {
				return true
			}
			continue
		}
		rel := strings.TrimPrefix(r.path, strings.TrimSuffix(o.path, "/"))
		if !hiddenName(rel) && r.real == strings.TrimSuffix(o.real, "/")+rel {
			return true
		}
	}
	return false
}

// nameMatches reports whether a name holds each word, in any case.
func nameMatches(name string, words []string) bool {
	lower := strings.ToLower(name)
	for _, w := range words {
		if !strings.Contains(lower, w) {
			return false
		}
	}
	return true
}

// sortMatches puts the best matches first: a name that is the query, then
// a name that starts with the first word, then the others. In each group,
// a match near the top comes first, then the name in alphabetical order.
func sortMatches(found []browseMatch, words []string) {
	query := strings.Join(words, " ")
	rank := func(m browseMatch) int {
		name := strings.ToLower(path.Base(m.Path))
		switch {
		case name == query || strings.TrimSuffix(name, path.Ext(name)) == query:
			return 0
		case strings.HasPrefix(name, words[0]):
			return 1
		}
		return 2
	}
	slices.SortStableFunc(found, func(a, b browseMatch) int {
		return cmp.Or(
			cmp.Compare(rank(a), rank(b)),
			cmp.Compare(strings.Count(a.Path, "/"), strings.Count(b.Path, "/")),
			strings.Compare(strings.ToLower(path.Base(a.Path)), strings.ToLower(path.Base(b.Path))),
			strings.Compare(a.Path, b.Path),
		)
	})
}
