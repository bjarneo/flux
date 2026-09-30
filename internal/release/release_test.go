package release

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
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

// TestOfficial checks that a release from GitHub keeps only the files that
// GitHub serves from the release of the tag in the Flux repository, and
// that it records the names of the other files.
func TestOfficial(t *testing.T) {
	r := Release{Tag: "v0.7.0", Assets: []Asset{
		{Name: "flux-android-0.7.0.apk", URL: "https://github.com/bjarneo/flux/releases/download/v0.7.0/flux-android-0.7.0.apk"},
		{Name: "SHA256SUMS", URL: "http://github.com/bjarneo/flux/releases/download/v0.7.0/SHA256SUMS"},
		{Name: "SHA256SUMS.sig", URL: "https://example.com/bjarneo/flux/releases/download/v0.7.0/SHA256SUMS.sig"},
		{Name: "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst", URL: "https://github.com/bjarneo/flux/releases/download/v0.6.0/omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst"},
		{Name: "flux-macos-0.7.0.zip", URL: "https://github.com/bjarneo/flux/releases/download/v0.7.0/other.zip"},
	}}
	got, dropped := official(r)
	if len(got) != 1 || got[0].Name != "flux-android-0.7.0.apk" {
		t.Fatalf("official files %+v", got)
	}
	want := []string{"SHA256SUMS", "SHA256SUMS.sig", "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst", "flux-macos-0.7.0.zip"}
	if strings.Join(dropped, " ") != strings.Join(want, " ") {
		t.Errorf("dropped files %q, want %q", dropped, want)
	}
}

// TestURL checks that FLUX_RELEASES_URL counts only with https, or with
// http on the loopback interface.
func TestURL(t *testing.T) {
	cases := []struct {
		env, want string
	}{
		{"", DefaultURL},
		{"https://mirror.example.com/latest", "https://mirror.example.com/latest"},
		{"http://127.0.0.1:8080/latest", "http://127.0.0.1:8080/latest"},
		{"http://[::1]:8080/latest", "http://[::1]:8080/latest"},
		{"http://localhost/latest", "http://localhost/latest"},
		{"http://mirror.example.com/latest", DefaultURL},
		{"http://192.168.1.2/latest", DefaultURL},
		{"file:///tmp/latest.json", DefaultURL},
		{"https:///latest", DefaultURL},
	}
	for _, c := range cases {
		t.Setenv("FLUX_RELEASES_URL", c.env)
		if got := URL(); got != c.want {
			t.Errorf("FLUX_RELEASES_URL=%q: URL() = %q, want %q", c.env, got, c.want)
		}
	}
}
