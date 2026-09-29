package release

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"v0.7.0", "0.6.0", true},
		{"0.7.0", "v0.7.0", false},
		{"0.6.0", "0.7.0", false},
		{"v0.10.0", "v0.9.9", true},
		{"v1.0.0", "v0.99.0", true},
		// A checkout build counts as its last tag.
		{"0.7.0", "0.6.0.r3.g1a2b3c4", true},
		{"0.6.0", "0.6.0.r3.g1a2b3c4", false},
		{"v0.6.0", "v0.6.0-3-g1a2b3c4-dirty", false},
		// A dev build or a commit hash has no version to compare.
		{"0.7.0", "dev", false},
		{"0.7.0", "8407611", false},
		{"0.7.0", "0.7", false},
		{"0.7.01", "0.6.0", false},
	}
	for _, c := range cases {
		if got := Newer(c.a, c.b); got != c.want {
			t.Errorf("Newer(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestLatest(t *testing.T) {
	var agent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		agent = r.Header.Get("User-Agent")
		w.Write([]byte(`{"tag_name":"v0.7.0","html_url":"https://example.com/v0.7.0","assets":[
			{"name":"omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst","browser_download_url":"https://example.com/pkg","size":10},
			{"name":"flux-android-0.7.0.apk","browser_download_url":"https://example.com/apk","size":20}]}`))
	}))
	defer srv.Close()

	r, err := Latest(context.Background(), srv.URL, "0.6.0")
	if err != nil {
		t.Fatal(err)
	}
	if r.Version() != "0.7.0" || r.Page != "https://example.com/v0.7.0" {
		t.Fatalf("release %+v", r)
	}
	if agent != "flux/0.6.0" {
		t.Errorf("User-Agent %q", agent)
	}
	apk, ok := r.Find(func(n string) bool { return strings.HasSuffix(n, ".apk") })
	if !ok || apk.URL != "https://example.com/apk" {
		t.Errorf("apk %+v, %v", apk, ok)
	}
}

func TestLatestErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/limit":
			http.Error(w, "rate limit", http.StatusForbidden)
		case "/tag":
			w.Write([]byte(`{"tag_name":"nightly"}`))
		default:
			w.Write([]byte(`not json`))
		}
	}))
	defer srv.Close()
	for _, path := range []string{"/limit", "/tag", "/json"} {
		if _, err := Latest(context.Background(), srv.URL+path, "0.6.0"); err == nil {
			t.Errorf("%s: no error", path)
		}
	}
}

// TestOffline checks that a check without a network fails at once with an
// error, and does not wait for the timeout.
func TestOffline(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	if _, err := Latest(context.Background(), "http://"+addr+"/latest", "0.6.0"); err == nil {
		t.Fatal("no error for a closed port")
	}
}

func TestVerify(t *testing.T) {
	dir := t.TempDir()
	pkg := filepath.Join(dir, "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst")
	if err := os.WriteFile(pkg, []byte("package"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("package"))
	sums := filepath.Join(dir, "SHA256SUMS")
	write := func(text string) {
		if err := os.WriteFile(sums, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write(hex.EncodeToString(sum[:]) + "  omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst\nabc  flux-android-0.7.0.apk\n")
	if err := Verify(pkg, sums); err != nil {
		t.Errorf("a matching checksum: %v", err)
	}
	write("0000  omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst\n")
	if err := Verify(pkg, sums); err == nil {
		t.Error("no error for a wrong checksum")
	}
	write("abc  flux-android-0.7.0.apk\n")
	if err := Verify(pkg, sums); err == nil {
		t.Error("no error for a missing line")
	}
}

// TestFetch downloads a file, checks it, and reuses a complete file. A
// file with a wrong checksum goes away.
func TestFetch(t *testing.T) {
	body := []byte("apk")
	sum := sha256.Sum256(body)
	var gets int
	sums := hex.EncodeToString(sum[:]) + "  flux-android-0.7.0.apk\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/SHA256SUMS":
			w.Write([]byte(sums))
		case "/flux-android-0.7.0.apk":
			gets++
			w.Write(body)
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	for i := 0; i < 2; i++ {
		path, err := Fetch(context.Background(), srv.URL+"/flux-android-0.7.0.apk", srv.URL+"/SHA256SUMS", dir, "0.6.0")
		if err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(path); string(b) != "apk" {
			t.Fatalf("the file has %q", b)
		}
	}
	if gets != 1 {
		t.Errorf("%d downloads, want 1", gets)
	}
	if _, err := os.Stat(filepath.Join(dir, "SHA256SUMS")); !os.IsNotExist(err) {
		t.Errorf("SHA256SUMS stays: %v", err)
	}

	sums = "0000  flux-android-0.7.0.apk\n"
	if _, err := Fetch(context.Background(), srv.URL+"/flux-android-0.7.0.apk", srv.URL+"/SHA256SUMS", dir, "0.6.0"); err == nil {
		t.Fatal("no error for a wrong checksum")
	}
	if _, err := os.Stat(filepath.Join(dir, "flux-android-0.7.0.apk")); !os.IsNotExist(err) {
		t.Errorf("the file stays after a wrong checksum: %v", err)
	}
}
