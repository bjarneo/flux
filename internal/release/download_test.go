package release

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const apkName = "flux-android-0.7.0.apk"

func sumLine(body []byte, name string) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:]) + "  " + name + "\n"
}

// fileServer serves the files in files. A path in slow sends its file in
// parts over 300 ms. gets counts the requests of each path.
type fileServer struct {
	mu    sync.Mutex
	files map[string][]byte
	slow  map[string]bool
	gets  map[string]int
}

func newFileServer(t *testing.T, files map[string][]byte) (*fileServer, *httptest.Server) {
	t.Helper()
	fs := &fileServer{files: files, slow: map[string]bool{}, gets: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fs.mu.Lock()
		body, ok := fs.files[r.URL.Path]
		slow := fs.slow[r.URL.Path]
		fs.gets[r.URL.Path]++
		fs.mu.Unlock()
		if !ok {
			http.NotFound(w, r)
			return
		}
		if !slow {
			w.Write(body)
			return
		}
		// Parts with a flush give a chunked answer without Content-Length.
		for i := 0; i < 6; i++ {
			w.Write(body[i*len(body)/6 : (i+1)*len(body)/6])
			w.(http.Flusher).Flush()
			time.Sleep(50 * time.Millisecond)
		}
	}))
	t.Cleanup(srv.Close)
	return fs, srv
}

func (fs *fileServer) setSlow(path string) {
	fs.mu.Lock()
	fs.slow[path] = true
	fs.mu.Unlock()
}

func (fs *fileServer) set(path string, body []byte) {
	fs.mu.Lock()
	fs.files[path] = body
	fs.mu.Unlock()
}

func (fs *fileServer) count(path string) int {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	return fs.gets[path]
}

// leftovers returns the temporary files in dir.
func leftovers(t *testing.T, dir string) []string {
	t.Helper()
	parts, err := filepath.Glob(filepath.Join(dir, "*.part"))
	if err != nil {
		t.Fatal(err)
	}
	return parts
}

// withKey makes Fetch check signatures with a new key, and returns its
// seed.
func withKey(t *testing.T) string {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	old := releaseKey
	releaseKey = base64.StdEncoding.EncodeToString(pub)
	t.Cleanup(func() { releaseKey = old })
	return base64.StdEncoding.EncodeToString(priv.Seed())
}

func TestSumOf(t *testing.T) {
	body := []byte("package")
	sums := []byte(sumLine(body, "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst") + "abc  " + apkName + "\n" + sumLine(body, "*star.zip"))
	want := sumLine(body, "")[:64]
	if got, err := sumOf(sums, "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst"); err != nil || got != want {
		t.Errorf("a matching line: %q, %v", got, err)
	}
	if got, err := sumOf(sums, "star.zip"); err != nil || got != want {
		t.Errorf("a binary mode line: %q, %v", got, err)
	}
	if _, err := sumOf(sums, apkName); err == nil {
		t.Error("no error for a checksum that is not SHA-256")
	}
	if _, err := sumOf(sums, "flux-macos-0.7.0.zip"); err == nil {
		t.Error("no error for a missing line")
	}
}

func TestValidName(t *testing.T) {
	for _, name := range []string{apkName, "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst", "a+b_c"} {
		if !validName(name) {
			t.Errorf("%q is not valid", name)
		}
	}
	for _, name := range []string{"", ".", "..", "../apk", "a/b", ".hidden", "-rf", "a b", "a\nb", strings.Repeat("a", 201)} {
		if validName(name) {
			t.Errorf("%q is valid", name)
		}
	}
}

// TestFetch downloads a file, checks it, and reuses a complete file. A
// file with a wrong checksum goes away.
func TestFetch(t *testing.T) {
	body := []byte("apk")
	fs, srv := newFileServer(t, map[string][]byte{
		"/" + apkName: body,
		"/SHA256SUMS": []byte(sumLine(body, apkName)),
	})
	dir := filepath.Join(t.TempDir(), "update")
	a := Asset{Name: apkName, URL: srv.URL + "/" + apkName, Size: int64(len(body))}
	for i := 0; i < 2; i++ {
		path, sum, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", "", dir, "0.6.0")
		if err != nil {
			t.Fatal(err)
		}
		if path != filepath.Join(dir, apkName) || sum != sumLine(body, "")[:64] {
			t.Fatalf("path %s, sum %s", path, sum)
		}
		if b, _ := os.ReadFile(path); string(b) != "apk" {
			t.Fatalf("the file has %q", b)
		}
	}
	if n := fs.count("/" + apkName); n != 1 {
		t.Errorf("%d downloads, want 1", n)
	}
	if st, err := os.Stat(dir); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("the update folder: %v, %v", st.Mode(), err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 {
		t.Errorf("the update folder has %d files, want 1", len(entries))
	}

	fs.set("/SHA256SUMS", []byte("0000000000000000000000000000000000000000000000000000000000000000  "+apkName+"\n"))
	if _, _, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", "", dir, "0.6.0"); err == nil {
		t.Fatal("no error for a wrong checksum")
	}
	if _, err := os.Stat(filepath.Join(dir, apkName)); err != nil {
		t.Errorf("the earlier checked file went away: %v", err)
	}
	if parts := leftovers(t, dir); len(parts) != 0 {
		t.Errorf("temporary files stay: %v", parts)
	}
}

// TestFetchMissing checks that a release without SHA256SUMS or with a bad
// file name gives an error before a download.
func TestFetchMissing(t *testing.T) {
	fs, srv := newFileServer(t, map[string][]byte{"/" + apkName: []byte("apk")})
	dir := t.TempDir()
	a := Asset{Name: apkName, URL: srv.URL + "/" + apkName}
	if _, _, err := Fetch(context.Background(), a, "", "", dir, "0.6.0"); err == nil {
		t.Error("no error without SHA256SUMS")
	}
	if _, _, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", "", dir, "0.6.0"); err == nil {
		t.Error("no error for a SHA256SUMS that is not found")
	}
	a.Name = "../" + apkName
	if _, _, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", "", dir, "0.6.0"); err == nil {
		t.Error("no error for a name with a folder")
	}
	if n := fs.count("/" + apkName); n != 0 {
		t.Errorf("%d downloads, want 0", n)
	}
}

// TestFetchParallel runs 2 downloads of the same file at the same time.
// Each has its own temporary file, so both succeed.
func TestFetchParallel(t *testing.T) {
	body := bytes.Repeat([]byte("flux"), 64<<10)
	fs, srv := newFileServer(t, map[string][]byte{
		"/" + apkName: body,
		"/SHA256SUMS": []byte(sumLine(body, apkName)),
	})
	fs.setSlow("/" + apkName)
	dir := t.TempDir()
	a := Asset{Name: apkName, URL: srv.URL + "/" + apkName, Size: int64(len(body))}
	var wg sync.WaitGroup
	var fails atomic.Int32
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			path, _, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", "", dir, "0.6.0")
			if err != nil {
				t.Errorf("download: %v", err)
				fails.Add(1)
				return
			}
			if b, err := os.ReadFile(path); err != nil || !bytes.Equal(b, body) {
				t.Errorf("the file has %d bytes: %v", len(b), err)
			}
		}()
		time.Sleep(100 * time.Millisecond)
	}
	wg.Wait()
	if fails.Load() == 0 && fs.count("/"+apkName) != 2 {
		t.Errorf("%d downloads, want 2", fs.count("/"+apkName))
	}
	if parts := leftovers(t, dir); len(parts) != 0 {
		t.Errorf("temporary files stay: %v", parts)
	}
}

// TestFetchSize checks the size limits. A file that is larger than the
// release gives, or larger than the limit, does not stay on disk.
func TestFetchSize(t *testing.T) {
	body := []byte("a longer apk than the release gives")
	fs, srv := newFileServer(t, map[string][]byte{
		"/" + apkName: body,
		"/slow.apk":   body,
		"/SHA256SUMS": []byte(sumLine(body, apkName) + sumLine(body, "slow.apk")),
		"/BIGSUMS":    bytes.Repeat([]byte("x"), maxSums+1),
	})
	fs.setSlow("/slow.apk")
	dir := t.TempDir()
	sums := srv.URL + "/SHA256SUMS"

	// The answer has a Content-Length that differs from the size.
	a := Asset{Name: apkName, URL: srv.URL + "/" + apkName, Size: 10}
	if _, _, err := Fetch(context.Background(), a, sums, "", dir, "0.6.0"); err == nil || !strings.Contains(err.Error(), "release gives") {
		t.Errorf("a larger file with Content-Length: %v", err)
	}
	// A chunked answer has no Content-Length, so the copy stops it.
	a = Asset{Name: "slow.apk", URL: srv.URL + "/slow.apk", Size: 10}
	if _, _, err := Fetch(context.Background(), a, sums, "", dir, "0.6.0"); err == nil || !strings.Contains(err.Error(), "release gives") {
		t.Errorf("a larger chunked file: %v", err)
	}
	a = Asset{Name: apkName, URL: srv.URL + "/" + apkName, Size: maxAsset + 1}
	if _, _, err := Fetch(context.Background(), a, sums, "", dir, "0.6.0"); err == nil {
		t.Error("no error for a file above the limit")
	}
	a = Asset{Name: apkName, URL: srv.URL + "/" + apkName}
	if _, _, err := Fetch(context.Background(), a, srv.URL+"/BIGSUMS", "", dir, "0.6.0"); err == nil {
		t.Error("no error for a SHA256SUMS above the limit")
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("files stay after the errors: %v", entries)
	}
	// Without a size from the release, the checksum decides.
	if _, _, err := Fetch(context.Background(), a, sums, "", dir, "0.6.0"); err != nil {
		t.Errorf("a file without a size: %v", err)
	}
}

// TestFetchSignature checks SHA256SUMS.sig when the build has a release
// key. Fetch refuses a release without a valid signature before it
// downloads the file.
func TestFetchSignature(t *testing.T) {
	seed := withKey(t)
	body := []byte("apk")
	sums := []byte(sumLine(body, apkName))
	sig, err := Sign(sums, seed)
	if err != nil {
		t.Fatal(err)
	}
	fs, srv := newFileServer(t, map[string][]byte{
		"/" + apkName:     body,
		"/SHA256SUMS":     sums,
		"/SHA256SUMS.sig": sig,
	})
	dir := t.TempDir()
	a := Asset{Name: apkName, URL: srv.URL + "/" + apkName, Size: int64(len(body))}
	fetch := func(sigURL string) error {
		_, _, err := Fetch(context.Background(), a, srv.URL+"/SHA256SUMS", sigURL, dir, "0.6.0")
		return err
	}

	if err := fetch(""); err == nil {
		t.Error("no error for a release without SHA256SUMS.sig")
	}
	if err := fetch(srv.URL + "/missing.sig"); err == nil {
		t.Error("no error for a SHA256SUMS.sig that is not found")
	}
	other, _ := Sign([]byte("other"), seed)
	fs.set("/SHA256SUMS.sig", other)
	if err := fetch(srv.URL + "/SHA256SUMS.sig"); err == nil {
		t.Error("no error for a signature of other data")
	}
	fs.set("/SHA256SUMS.sig", []byte("not base64\n"))
	if err := fetch(srv.URL + "/SHA256SUMS.sig"); err == nil {
		t.Error("no error for a signature that is not base64")
	}
	// A changed SHA256SUMS with the signature of the real one.
	fs.set("/SHA256SUMS.sig", sig)
	fs.set("/SHA256SUMS", []byte(sumLine([]byte("evil"), apkName)))
	if err := fetch(srv.URL + "/SHA256SUMS.sig"); err == nil {
		t.Error("no error for a changed SHA256SUMS")
	}
	if n := fs.count("/" + apkName); n != 0 {
		t.Errorf("%d downloads before a valid signature, want 0", n)
	}

	fs.set("/SHA256SUMS", sums)
	if err := fetch(srv.URL + "/SHA256SUMS.sig"); err != nil {
		t.Errorf("a valid signature: %v", err)
	}
}

func TestSign(t *testing.T) {
	seed := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, ed25519.SeedSize))
	key, err := KeyOf(seed)
	if err != nil {
		t.Fatal(err)
	}
	sums := []byte("abc  flux-android-0.7.0.apk\n")
	sig, err := Sign(sums, seed+"\n")
	if err != nil {
		t.Fatal(err)
	}
	if err := CheckSignature(sums, sig, key); err != nil {
		t.Errorf("a valid signature: %v", err)
	}
	if err := CheckSignature(append(sums, '\n'), sig, key); err == nil {
		t.Error("no error for changed data")
	}
	if err := CheckSignature(sums, sig, "short"); err == nil {
		t.Error("no error for a key that is not valid")
	}
	if _, err := Sign(sums, base64.StdEncoding.EncodeToString([]byte("short"))); err == nil {
		t.Error("no error for a seed that is not 32 bytes")
	}
	if Signed() != (PublicKey != "") {
		t.Errorf("Signed() is %v with the key %q", Signed(), PublicKey)
	}
}
