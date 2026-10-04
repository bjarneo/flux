package core

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"
)

// searchPaths runs a search and returns the paths that it found.
func searchPaths(t *testing.T, fsys *browseFS, from string, words ...string) []string {
	t.Helper()
	found, more, partial, err := fsys.search(context.Background(), from, words)
	if err != nil || more || partial {
		t.Fatalf("search %q in %q: more %v, partial %v, %v", words, from, more, partial, err)
	}
	paths := make([]string, 0, len(found))
	for _, m := range found {
		paths = append(paths, m.Path)
	}
	return paths
}

// The search finds names in each root and through a symlink that stays in
// its root. It does not find a hidden name, a Flux folder, or a symlink out
// of its root.
func TestBrowseSearchFindsNames(t *testing.T) {
	home, _ := browseTree(t)
	fsys := testBrowseFS(t, home)
	defer fsys.Close()

	got := searchPaths(t, fsys, "", "txt")
	want := []string{
		filepath.Join(home, "a-link.txt"),
		filepath.Join(home, "notes", "a.txt"),
		filepath.Join(home, "Documents", "doc.txt"),
	}
	if !slices.Equal(got, want) {
		t.Fatalf("search txt = %q, want %q", got, want)
	}
	for _, word := range []string{"secret", "id_ed25519", "privatekey", "env", "key", "pipe", "escape"} {
		if got := searchPaths(t, fsys, "", word); len(got) != 0 {
			t.Fatalf("search %s = %q", word, got)
		}
	}
	found, _, _, err := fsys.search(context.Background(), "", []string{"notes"})
	if err != nil || len(found) != 1 || !found[0].Dir {
		t.Fatalf("the folder notes is not a folder: %+v, %v", found, err)
	}
	found, _, _, err = fsys.search(context.Background(), "", []string{"doc.txt"})
	if err != nil || len(found) != 1 || found[0].Dir || found[0].Size != 3 || found[0].Modified <= 0 {
		t.Fatalf("doc.txt = %+v, %v", found, err)
	}
}

// Each word of the query must be in the name. The search skips the
// node_modules folders.
func TestBrowseSearchNeedsEachWord(t *testing.T) {
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "app", "node_modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Invoice 2024.pdf", "invoice-2025.pdf", "2024 photos", filepath.Join("app", "node_modules", "invoice 2024.js")} {
		if err := os.WriteFile(filepath.Join(home, name), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	fsys, err := openBrowseFS([][2]string{{"Home", home}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer fsys.Close()
	if got := searchPaths(t, fsys, "", "2024", "invoice"); !slices.Equal(got, []string{filepath.Join(home, "Invoice 2024.pdf")}) {
		t.Fatalf("search 2024 invoice = %q", got)
	}
}

// A search in a folder reads only that folder and its subfolders. A
// search in a path outside the roots fails.
func TestBrowseSearchInAFolder(t *testing.T) {
	home, outside := browseTree(t)
	if err := os.WriteFile(filepath.Join(home, "b.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	fsys := testBrowseFS(t, home)
	defer fsys.Close()
	if got := searchPaths(t, fsys, filepath.Join(home, "notes"), "txt"); !slices.Equal(got, []string{filepath.Join(home, "notes", "a.txt")}) {
		t.Fatalf("search in notes = %q", got)
	}
	for _, from := range []string{outside, filepath.Join(home, ".ssh"), filepath.Join(home, "escape"), filepath.Join(home, "notes", "a.txt"), "notes"} {
		if _, _, _, err := fsys.search(context.Background(), from, []string{"txt"}); err == nil {
			t.Fatalf("search in %q works", from)
		}
	}
}

// A root in another root without a symlink between them is read once.
func TestBrowseSearchReadsANestedRootOnce(t *testing.T) {
	home := t.TempDir()
	docs := filepath.Join(home, "Documents")
	if err := os.MkdirAll(docs, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(docs, "plan.md"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	fsys, err := openBrowseFS(browseRoots(home, home), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer fsys.Close()
	if len(fsys.roots) != 3 {
		t.Fatalf("roots %d, want Home, Downloads, and Documents", len(fsys.roots))
	}
	if got := searchPaths(t, fsys, "", "plan"); !slices.Equal(got, []string{filepath.Join(docs, "plan.md")}) {
		t.Fatalf("search plan = %q", got)
	}
}

// An answer holds at most maxSearchResults matches. The best matches come
// first: the name that is the query, then a name that starts with the
// query, then a match near the top.
func TestBrowseSearchLimitAndOrder(t *testing.T) {
	home := t.TempDir()
	deep := filepath.Join(home, "a", "b")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := range maxSearchResults + 20 {
		if err := os.WriteFile(filepath.Join(home, "my report "+strconv.Itoa(i)), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(deep, "report.pdf"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	fsys, err := openBrowseFS([][2]string{{"Home", home}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer fsys.Close()
	found, more, _, err := fsys.search(context.Background(), "", []string{"report"})
	if err != nil || !more || len(found) != maxSearchResults {
		t.Fatalf("found %d, more %v, %v", len(found), more, err)
	}

	if err := os.WriteFile(filepath.Join(home, "a", "report-old.pdf"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	got := searchPaths(t, fsys, filepath.Join(home, "a"), "report")
	want := []string{filepath.Join(deep, "report.pdf"), filepath.Join(home, "a", "report-old.pdf")}
	if !slices.Equal(got, want) {
		t.Fatalf("order %q, want %q", got, want)
	}
}

// A search that runs out of time answers with the matches that it has and
// tells that it is partial.
func TestBrowseSearchStopsAtTheTimeLimit(t *testing.T) {
	home, _ := browseTree(t)
	fsys := testBrowseFS(t, home)
	defer fsys.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 0)
	defer cancel()
	found, _, partial, err := fsys.search(ctx, "", []string{"txt"})
	if err != nil || !partial || len(found) != 0 {
		t.Fatalf("found %d, partial %v, %v", len(found), partial, err)
	}
}

// waitSearch returns the search answer with the ID that the link sent.
func waitSearch(t *testing.T, l *fakeStreamLink, id int64) map[string]any {
	t.Helper()
	var answer map[string]any
	waitFor(t, "the search answer", func() bool {
		l.mu.Lock()
		defer l.mu.Unlock()
		for _, b := range l.sent {
			if s, ok := b["search"].(map[string]any); ok && s["id"] == float64(id) {
				answer = s
				return true
			}
		}
		return false
	})
	return answer
}

// The phone searches in its Browse PC session. Without a session, and
// after share_home turns off, the search fails.
func TestBrowseSearchInTheSession(t *testing.T) {
	d, dev, ctx, _, file := browseSessionDaemon(t)
	l := newFakeStreamLink()
	d.searchBrowse(dev, l, browseSearch{ID: 1, Query: "a.TXT"})
	answer := waitSearch(t, l, 1)
	results, _ := answer["results"].([]any)
	if len(results) != 1 || results[0].(map[string]any)["path"] != file || answer["more"] != false || answer["partial"] != false {
		t.Fatalf("answer %+v", answer)
	}

	d.searchBrowse(dev, l, browseSearch{ID: 2, Query: "  "})
	if answer := waitSearch(t, l, 2); answer["error"] == nil || len(answer["results"].([]any)) != 0 {
		t.Fatalf("answer to an empty query %+v", answer)
	}

	if err := d.setSetting("shareHome", false); err != nil {
		t.Fatal(err)
	}
	waitDone(t, ctx, "the Browse PC session")
	waitFor(t, "the session ends", func() bool { return d.Busy() == "" })
	d.searchBrowse(dev, l, browseSearch{ID: 3, Query: "a.txt"})
	if answer := waitSearch(t, l, 3); answer["error"] == nil || len(answer["results"].([]any)) != 0 {
		t.Fatalf("answer without a session %+v", answer)
	}
}

// A new search stops the search before it, which sends no answer.
func TestBrowseSearchStopsTheOldSearch(t *testing.T) {
	d, dev, _, _, _ := browseSessionDaemon(t)
	old := searchTime
	searchTime = time.Hour
	t.Cleanup(func() { searchTime = old })
	d.mu.Lock()
	var s *browseSession
	for _, o := range d.sessions.browse {
		s = o
	}
	d.mu.Unlock()
	stopped := make(chan struct{})
	l := newFakeStreamLink()
	d.mu.Lock()
	s.stopSearch = func() { close(stopped) }
	d.mu.Unlock()
	d.searchBrowse(dev, l, browseSearch{ID: 5, Query: "a"})
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("the old search did not stop")
	}
	waitSearch(t, l, 5)
}
