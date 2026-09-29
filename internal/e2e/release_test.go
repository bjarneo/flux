package e2e

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

type updateState struct {
	Update struct {
		Enabled   bool   `json:"enabled"`
		Latest    string `json:"latest"`
		Available bool   `json:"available"`
		Error     string `json:"error"`
	} `json:"update"`
}

func (n *node) update(t *testing.T) updateState {
	t.Helper()
	var s updateState
	n.call(t, "state", nil, &s)
	return s
}

func (n *node) waitUpdate(t *testing.T, what string, ok func(updateState) bool) updateState {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		s := n.update(t)
		if ok(s) {
			return s
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s: timed out waiting for %s: %+v\n%s", n.name, what, s.Update, n.log)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func offlineURL(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return "http://" + addr + "/latest"
}

// TestReleaseCheck runs fluxd against a fake GitHub API. fluxd reports the
// new release, keeps it after a restart without a network, reports a
// failed check without other effects, and asks nothing when the check is
// off.
func TestReleaseCheck(t *testing.T) {
	if testing.Short() {
		t.Skip("builds fluxd")
	}
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Write([]byte(`{"tag_name":"v1.1.0","html_url":"https://example.com/v1.1.0","assets":[]}`))
	}))
	defer srv.Close()
	bin := filepath.Join(t.TempDir(), "fluxd")
	buildVersion(t, bin, "v1.0.0")

	launch := func(n *node, url string) {
		n.env = []string{"FLUX_RELEASES_URL=" + url, "FLUX_RELEASE_DELAY=0s", "INVOCATION_ID="}
		n.udpPort = freePort(t, "udp")
		n.launch(t, bin, freePort(t, "tcp"))
	}

	online := newNode(t, "online")
	launch(online, srv.URL)
	online.waitUpdate(t, "the new release", func(s updateState) bool {
		return s.Update.Available && s.Update.Latest == "1.1.0"
	})

	// A restart without a network shows the release from the cache.
	online.stop()
	launch(online, offlineURL(t))
	s := online.update(t)
	if !s.Update.Available || s.Update.Latest != "1.1.0" {
		t.Fatalf("after a restart without a network: %+v", s.Update)
	}

	// Without a network and with no cache, the check reports an error,
	// and fluxd works as before.
	offline := newNode(t, "offline")
	launch(offline, offlineURL(t))
	offline.waitUpdate(t, "the error", func(s updateState) bool { return s.Update.Error != "" })
	if s := offline.update(t); s.Update.Available || s.Update.Latest != "" || !s.Update.Enabled {
		t.Fatalf("without a network: %+v", s.Update)
	}
	offline.call(t, "discover", nil, nil)

	// With check_updates = false, fluxd asks nothing.
	before := requests.Load()
	off := newNode(t, "off")
	cfg := filepath.Join(off.dir, "config", "flux", "config.toml")
	f, err := os.OpenFile(cfg, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("check_updates = false\n")
	f.Close()
	launch(off, srv.URL)
	time.Sleep(500 * time.Millisecond)
	if s := off.update(t); s.Update.Enabled || s.Update.Available {
		t.Fatalf("with the check off: %+v", s.Update)
	}
	if n := requests.Load(); n != before {
		t.Fatalf("fluxd sent %d requests with the check off", n-before)
	}
}
