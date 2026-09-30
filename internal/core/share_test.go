package core

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

func TestDestDir(t *testing.T) {
	cfg := &config.Config{DownloadDir: "/tmp/dl", ScanDir: "/tmp/scan", PhotoDir: "/tmp/pics"}
	cases := map[fileDest]string{
		destDownload:   "/tmp/dl",
		destScan:       "/tmp/scan",
		destPhoto:      "/tmp/pics",
		destScreenshot: "/tmp/pics/screenshots",
		destSignature:  "/tmp/pics/signatures",
	}
	for kind, want := range cases {
		if got := destDir(cfg, kind); got != want {
			t.Errorf("kind %d: got %s, want %s", kind, got, want)
		}
	}
}

func TestCopyImage(t *testing.T) {
	dir := t.TempDir()
	clip := &memClipboard{}
	d := &Daemon{clip: clip}

	png := filepath.Join(dir, "signature.png")
	data := append([]byte("\x89PNG\r\n\x1a\n"), 1, 2, 3)
	if err := os.WriteFile(png, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := d.copyImage(png); err != nil {
		t.Fatal(err)
	}
	if clip.mime != "image/png" || string(clip.image) != string(data) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}

	// A file that is not a PNG stays off the clipboard.
	other := filepath.Join(dir, "signature.txt")
	if err := os.WriteFile(other, []byte("not an image"), 0o644); err != nil {
		t.Fatal(err)
	}
	clip.image, clip.mime = nil, ""
	if err := d.copyImage(other); err == nil {
		t.Error("copied a file that is not a PNG")
	}
	if clip.image != nil {
		t.Errorf("clipboard has %q", clip.image)
	}
}

func TestWriteScan(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "flux", "scanned")
	now := time.Date(2026, 9, 25, 11, 15, 30, 0, time.Local)
	first, err := writeScan(dir, "Gate B14\nBoarding 15:40", now)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(first) != "scan-2026-09-25-111530.txt" {
		t.Errorf("name %s", filepath.Base(first))
	}
	b, _ := os.ReadFile(first)
	if string(b) != "Gate B14\nBoarding 15:40\n" {
		t.Errorf("content %q", b)
	}
	second, err := writeScan(dir, "more", now)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(second) != "scan-2026-09-25-111530 (2).txt" {
		t.Errorf("second scan in the same second: %s", filepath.Base(second))
	}
}

func TestWebURL(t *testing.T) {
	open := map[string]string{
		"https://omarchy.org":            "https://omarchy.org",
		" HTTP://Example.com/a b?q=1 ":   "http://Example.com/a%20b?q=1",
		"https://user@host.example:8080": "https://user@host.example:8080",
	}
	for in, want := range open {
		if got, ok := webURL(in); !ok || got != want {
			t.Errorf("%q: got %q, %v, want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{
		"file:///etc/passwd", "/etc/passwd", "Downloads/x.odt", "ssh://x", "vnd.libreoffice.command:x",
		"ms-word:ofe|u|https://x", "claude-cli://x", "-x", "--help", "http:///etc/passwd", "https://:80",
		"http:example.com", "javascript:alert(1)", "mailto:a@b.c", "https://exa mple.com", "https://a\x00b",
	} {
		if got, ok := webURL(in); ok {
			t.Errorf("%q is a web URL: %q", in, got)
		}
	}
}

// TestHandleShareURL checks that only a web URL reaches xdg-open. Every
// other value arrives as shared text.
func TestHandleShareURL(t *testing.T) {
	var opened []string
	old := openWebLink
	openWebLink = func(u string) error { opened = append(opened, u); return nil }
	defer func() { openWebLink = old }()

	d := testDaemon()
	clip := d.clip.(*memClipboard)
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	values := []string{"file:///etc/passwd", "/etc/passwd", "Downloads/x.odt", "ssh://x", "vnd.libreoffice.command:x", "ms-word:ofe|u|https://x", "claude-cli://x", "-x"}
	for _, v := range values {
		d.handleShare(dev, nil, proto.New(proto.TypeShare, map[string]any{"url": v}))
	}
	waitIdle(t, d, &d.content.clipQ)
	if len(opened) != 0 {
		t.Fatalf("opened %q", opened)
	}
	if len(d.clipboard) != len(values) || d.clipboard[0].Text != "-x" || d.clipboard[0].Source != "share" {
		t.Fatalf("history %+v", d.clipboard)
	}
	if clip.text != "-x" {
		t.Fatalf("clipboard %q", clip.text)
	}
	d.handleShare(dev, nil, proto.New(proto.TypeShare, map[string]any{"url": "https://omarchy.org"}))
	if !slices.Equal(opened, []string{"https://omarchy.org"}) {
		t.Fatalf("opened %q", opened)
	}
}

// TestShareTextURL checks that only a web URL goes to a device as a URL.
func TestShareTextURL(t *testing.T) {
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	var e *Error
	for _, v := range []string{"file:///etc/passwd", "/etc/passwd", "ssh://host", "intent://x", "https://"} {
		if err := d.ShareText(dev, "url", v); !errors.As(err, &e) || e.Code != "bad_params" {
			t.Errorf("%q: %v", v, err)
		}
	}
	// A web URL and any text pass the check and need the link.
	for key, v := range map[string]string{"url": "https://omarchy.org", "text": "file:///etc/passwd"} {
		if err := d.ShareText(dev, key, v); !errors.As(err, &e) || e.Code != "offline" {
			t.Errorf("%s %q: %v", key, v, err)
		}
	}
}

// TestSentTextLimit checks that fluxd sends at most maxSentText of text
// to a device. Flux for Android from before this limit stops on a larger
// text.
func TestSentTextLimit(t *testing.T) {
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	var e *Error
	for _, n := range []int{maxSentText, maxSentText + 1} {
		want := "offline"
		if n > maxSentText {
			want = "too_large"
		}
		text := strings.Repeat("a", n)
		if err := d.ShareText(dev, "text", text); !errors.As(err, &e) || e.Code != want {
			t.Errorf("share %d bytes: %v, want %s", n, err, want)
		}
		if err := d.SendClipboard(dev, text); !errors.As(err, &e) || e.Code != want {
			t.Errorf("clipboard %d bytes: %v, want %s", n, err, want)
		}
	}
}

// TestSharedTextLimit checks that a shared text above the limit changes
// neither the clipboard nor the history.
func TestSharedTextLimit(t *testing.T) {
	d := testDaemon()
	clip := d.clip.(*memClipboard)
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	d.handleShare(dev, nil, proto.New(proto.TypeShare, map[string]any{"text": strings.Repeat("a", desktop.MaxClipboardText+1)}))
	d.handleClipboard(dev, proto.New(proto.TypeClipboard, map[string]any{"content": strings.Repeat("b", desktop.MaxClipboardText+1)}))
	waitIdle(t, d, &d.content.clipQ)
	if len(d.clipboard) != 0 || clip.text != "" {
		t.Fatalf("history has %d entries, clipboard has %d bytes", len(d.clipboard), len(clip.text))
	}
}

func TestPreviewText(t *testing.T) {
	if got := previewText(strings.Repeat("é", 400), maxSharePreview); utf8.RuneCountInString(got) != maxSharePreview+1 || !strings.HasSuffix(got, "…") {
		t.Errorf("preview has %d characters", utf8.RuneCountInString(got))
	}
	if got := previewText("short", maxSharePreview); got != "short" {
		t.Errorf("preview %q", got)
	}
}

func TestSafeName(t *testing.T) {
	cases := map[string]string{
		"photo.jpg":                 "photo.jpg",
		"../../.bashrc":             "_.bashrc",
		"..\\..\\x":                 "x",
		"/etc/passwd":               "passwd",
		"..":                        "received-file",
		".":                         "received-file",
		"":                          "received-file",
		"a/..":                      "received-file",
		"a\x00b.txt":                "ab.txt",
		"invoice\u202efdp.sh":       "invoicefdp.sh",
		"a\u2066b\u200fc\u061c.txt": "abc.txt",
		"-rf":                       "_-rf",
		".bash_login":               "_.bash_login",
		"line\nbreak\x1b[31m.txt":   "linebreak[31m.txt",
		" .hidden ":                 "_.hidden",
	}
	for in, want := range cases {
		if got := safeName(in); got != want {
			t.Errorf("safeName(%q) = %q, want %q", in, got, want)
		}
	}
	dir := t.TempDir()
	for in := range cases {
		if p := filepath.Join(dir, safeName(in)); filepath.Dir(p) != dir {
			t.Errorf("%q leaves the folder: %s", in, p)
		}
	}
	// A long name keeps its extension and fits NAME_MAX with a number.
	cjk := strings.Repeat("文", 90) + ".pdf"
	got := safeName(cjk)
	if len(got) > maxNameBytes || !strings.HasSuffix(got, ".pdf") || !utf8.ValidString(got) {
		t.Errorf("long name %q has %d bytes", got, len(got))
	}
	if got := safeName(strings.Repeat("a", 300) + "." + strings.Repeat("b", 100)); len(got) != maxNameBytes {
		t.Errorf("a name with a long extension has %d bytes", len(got))
	}
}

func TestUniquePath(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()
	// A 274-byte name from a phone fits after safeName.
	p, err := uniquePath(ctx, filepath.Join(dir, safeName(strings.Repeat("文", 90)+".pdf")))
	if err != nil {
		t.Fatal(err)
	}
	if again, err := uniquePath(ctx, p); err != nil || !strings.HasSuffix(again, " (2).pdf") {
		t.Fatalf("second name %q, %v", again, err)
	}
	// A name that does not fit returns an error and does not loop.
	if _, err := uniquePath(ctx, filepath.Join(dir, strings.Repeat("a", 300))); err == nil {
		t.Error("a 300-byte name returned no error")
	}
	long := filepath.Join(dir, strings.Repeat("b", 253))
	if err := os.WriteFile(long, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := uniquePath(ctx, long); err == nil {
		t.Error("a taken 253-byte name returned no error")
	}
	// A canceled transfer stops the search.
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := uniquePath(canceled, filepath.Join(dir, "c.txt")); !errors.Is(err, context.Canceled) {
		t.Errorf("canceled: %v", err)
	}
	// A folder without search permission returns an error.
	if os.Geteuid() != 0 {
		locked := filepath.Join(dir, "locked")
		if err := os.Mkdir(locked, 0o600); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(locked, 0o755)
		if _, err := uniquePath(ctx, filepath.Join(locked, "d.txt")); err == nil {
			t.Error("a folder without search permission returned no error")
		}
	}
}

// bigDisk makes the disk look large and empty for the test.
func bigDisk(t *testing.T) {
	old := freeSpace
	freeSpace = func(string) (uint64, uint64, error) { return 1 << 40, 1 << 41, nil }
	t.Cleanup(func() { freeSpace = old })
}

// payload returns a fetch function that gives data after release closes.
func payload(data string, release <-chan struct{}) func(context.Context) (io.ReadCloser, error) {
	return func(context.Context) (io.ReadCloser, error) {
		if release != nil {
			<-release
		}
		return io.NopCloser(strings.NewReader(data)), nil
	}
}

// TestConcurrentSameNameReceive runs 2 receives of 1 name. The first one
// finishes while the second one waits for its payload. Each gets its own
// file with its own content.
func TestConcurrentSameNameReceive(t *testing.T) {
	bigDisk(t)
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	dir := t.TempDir()
	first := d.newTransfer(dev, "IMG_0001.jpg", "", "in", 5)
	second := d.newTransfer(dev, "IMG_0001.jpg", "", "in", 6)
	release := make(chan struct{})
	var wg sync.WaitGroup
	errs := make([]error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		errs[1] = d.saveFile(context.Background(), dev, second, dir, payload("second", release))
	}()
	// The second receive reserves its name before the first one starts.
	deadline := time.Now().Add(5 * time.Second)
	for {
		d.mu.Lock()
		reserved := second.Path != ""
		d.mu.Unlock()
		if reserved || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	go func() {
		defer wg.Done()
		errs[0] = d.saveFile(context.Background(), dev, first, dir, payload("first", nil))
		close(release)
	}()
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("receive %d: %v", i, err)
		}
	}
	for tr, want := range map[*Transfer]string{first: "first", second: "second"} {
		b, err := os.ReadFile(tr.Path)
		if err != nil || string(b) != want {
			t.Errorf("%s has %q, %v, want %q", tr.Path, b, err, want)
		}
	}
	names, _ := os.ReadDir(dir)
	var got []string
	for _, e := range names {
		got = append(got, e.Name())
	}
	if !slices.Equal(got, []string{"IMG_0001 (2).jpg", "IMG_0001.jpg"}) {
		t.Errorf("folder has %q", got)
	}
}

// TestSaveFileFailureLeavesNoFile checks that a failed receive removes the
// reserved name and the temporary file.
func TestSaveFileFailureLeavesNoFile(t *testing.T) {
	bigDisk(t)
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	dir := t.TempDir()
	fail := func(context.Context) (io.ReadCloser, error) { return nil, errors.New("no payload") }
	if err := d.saveFile(context.Background(), dev, d.newTransfer(dev, "a.txt", "", "in", 5), dir, fail); err == nil {
		t.Error("a failed fetch returned no error")
	}
	if err := d.saveFile(context.Background(), dev, d.newTransfer(dev, "b.txt", "", "in", 50), dir, payload("short", nil)); err == nil {
		t.Error("a short payload returned no error")
	}
	// A device that is no longer paired stops the transfer.
	dev.Paired = false
	if err := d.saveFile(context.Background(), dev, d.newTransfer(dev, "c.txt", "", "in", 5), dir, payload("hello", nil)); !errors.Is(err, errReceiveUnpaired) {
		t.Errorf("unpaired: %v", err)
	}
	if names, _ := os.ReadDir(dir); len(names) != 0 {
		t.Errorf("folder has %d files", len(names))
	}
}

// TestSaveFileUsesUmask checks that a received file gets the mode of a
// file that the user creates, and not a fixed mode.
func TestSaveFileUsesUmask(t *testing.T) {
	bigDisk(t)
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	dir := t.TempDir()
	for _, c := range []struct {
		umask int
		want  os.FileMode
	}{{0o077, 0o600}, {0o022, 0o644}} {
		old := unix.Umask(c.umask)
		tr := d.newTransfer(dev, "a.txt", "", "in", 5)
		err := d.saveFile(context.Background(), dev, tr, dir, payload("hello", nil))
		unix.Umask(old)
		if err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(tr.Path)
		if err != nil {
			t.Fatal(err)
		}
		if got := info.Mode().Perm(); got != c.want {
			t.Errorf("umask %o: mode %o, want %o", c.umask, got, c.want)
		}
	}
}

func TestSaveFileNeedsSpace(t *testing.T) {
	old := freeSpace
	freeSpace = func(string) (uint64, uint64, error) { return 512 << 20, 100 << 30, nil }
	defer func() { freeSpace = old }()
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	dir := t.TempDir()
	// 1 GiB is the margin, so 512 MiB free is too little.
	if err := d.saveFile(context.Background(), dev, d.newTransfer(dev, "a.txt", "", "in", 5), dir, payload("hello", nil)); err == nil {
		t.Error("a nearly full disk took the file")
	}
	if names, _ := os.ReadDir(dir); len(names) != 0 {
		t.Errorf("folder has %d files", len(names))
	}
	if spaceMargin(100<<30) != 1<<30 || spaceMargin(10<<30) != 512<<20 {
		t.Error("margin")
	}
}

func TestIdleReader(t *testing.T) {
	r, w := io.Pipe()
	defer w.Close()
	idle := newIdleReader(r, 50*time.Millisecond)
	defer idle.stop()
	go func() { _, _ = w.Write([]byte("abc")) }()
	b := make([]byte, 8)
	if n, err := idle.Read(b); n != 3 || err != nil {
		t.Fatalf("read %d, %v", n, err)
	}
	if _, err := idle.Read(b); !errors.Is(err, errStalled) {
		t.Fatalf("stalled read: %v", err)
	}
}

func TestTrimTransfersKeepsRunning(t *testing.T) {
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	running := d.newTransfer(dev, "big.iso", "", "in", 1<<30)
	for range maxTransfers + 20 {
		d.finishTransfer(d.newTransfer(dev, "small.txt", "", "in", 1), nil)
	}
	if len(d.transfers) != maxTransfers {
		t.Fatalf("%d transfers", len(d.transfers))
	}
	if !slices.Contains(d.transfers, running) || d.Busy() == "" {
		t.Fatal("a running transfer left the list")
	}
}

func TestReceiveLimit(t *testing.T) {
	d := testDaemon()
	dev := &Device{ID: "p1"}
	for i := range maxReceives {
		if !d.startReceive(dev) {
			t.Fatalf("receive %d refused", i)
		}
	}
	if d.startReceive(dev) {
		t.Fatal("more than maxReceives receives run")
	}
	if !d.startReceive(&Device{ID: "p2"}) {
		t.Fatal("the limit of 1 device stopped another device")
	}
	d.endReceive(dev)
	if !d.startReceive(dev) {
		t.Fatal("a finished receive did not free its place")
	}
}

func TestRemoveStaleParts(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	for name, age := range map[string]time.Duration{".flux-1.part": 48 * time.Hour, ".flux-2.part": time.Hour, "report.pdf.part": 48 * time.Hour} {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, now.Add(-age), now.Add(-age)); err != nil {
			t.Fatal(err)
		}
	}
	removeStaleParts(dir, now)
	names, _ := os.ReadDir(dir)
	var got []string
	for _, e := range names {
		got = append(got, e.Name())
	}
	if !slices.Equal(got, []string{".flux-2.part", "report.pdf.part"}) {
		t.Errorf("folder has %q", got)
	}
}

func TestSpaceWriterStops(t *testing.T) {
	old := freeSpace
	free := uint64(10 << 30)
	freeSpace = func(string) (uint64, uint64, error) { return free, 20 << 30, nil }
	defer func() { freeSpace = old }()
	var buf bytes.Buffer
	w := &spaceWriter{w: &buf, dir: "/", left: 2 * spaceCheck, since: spaceCheck}
	if _, err := w.Write([]byte("a")); err != nil {
		t.Fatal(err)
	}
	// Another program fills the disk during the transfer.
	free = 1 << 30
	w.since = spaceCheck
	if _, err := w.Write([]byte("b")); err == nil {
		t.Fatal("the transfer went on with a nearly full disk")
	}
}

// TestSendFilesNeedsAbsolutePaths checks that share.files refuses a path
// that is not absolute, because the folder of fluxd is not the folder of
// the client.
func TestSendFilesNeedsAbsolutePaths(t *testing.T) {
	d, _ := approveDaemon()
	for _, paths := range []string{`["photo.jpg"]`, `["/tmp/a.jpg","../b.jpg"]`, `[]`} {
		_, err := d.Call(context.Background(), "share.files", []byte(`{"device":"phone1","paths":`+paths+`}`))
		if errCode(err) != "bad_params" {
			t.Errorf("%s: %v", paths, err)
		}
	}
	// An absolute path passes the check and needs the link.
	_, err := d.Call(context.Background(), "share.files", []byte(`{"device":"phone1","paths":["/tmp/a.jpg"]}`))
	if errCode(err) != "offline" {
		t.Errorf("an absolute path: %v", err)
	}
}

// TestSendFilesNeedsPairing checks that files and clipboard images do not
// go on the link of a device that is not paired. A device that sends a
// pair request again loses its trust and keeps its link.
func TestSendFilesNeedsPairing(t *testing.T) {
	d := testDaemon()
	dev := &Device{ID: "p1", Name: "Pixel 8", link: &lan.Link{}, Incoming: []string{proto.TypeFluxClipboardImage}}
	if _, err := d.SendFiles(dev, []string{"/tmp/a.jpg"}); errCode(err) != "not_paired" {
		t.Errorf("SendFiles: %v", err)
	}
	d.clip.(*memClipboard).image = []byte("\x89PNG\r\n\x1a\n")
	if err := d.SendClipboard(dev, ""); errCode(err) != "not_paired" {
		t.Errorf("SendClipboard with an image: %v", err)
	}
}
