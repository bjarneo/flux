package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/sys/unix"

	"flux/internal/config"
)

// browseTree makes a home folder for Browse PC. It returns the home folder
// and a folder outside it.
func browseTree(t *testing.T) (home, outside string) {
	t.Helper()
	base := t.TempDir()
	home = filepath.Join(base, "home")
	outside = filepath.Join(base, "outside")
	drive := filepath.Join(base, "drive", "Documents")
	for _, dir := range []string{home, outside, drive, filepath.Join(home, ".ssh"), filepath.Join(home, "notes"), filepath.Join(home, "fluxdata")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		filepath.Join(home, "notes", "a.txt"):             "notes",
		filepath.Join(home, ".ssh", "id_ed25519"):         "ssh key",
		filepath.Join(home, ".env"):                       "token",
		filepath.Join(home, "fluxdata", "privateKey.pem"): "flux key",
		filepath.Join(outside, "secret.txt"):              "outside",
		filepath.Join(drive, "doc.txt"):                   "doc",
	}
	for p, text := range files {
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	links := map[string]string{
		filepath.Join(home, "escape"):     outside,
		filepath.Join(home, "escape.txt"): filepath.Join(outside, "secret.txt"),
		filepath.Join(home, "key"):        filepath.Join(home, ".ssh", "id_ed25519"),
		filepath.Join(home, "a-link.txt"): filepath.Join(home, "notes", "a.txt"),
		// Documents is on another drive.
		filepath.Join(home, "Documents"): drive,
	}
	for link, target := range links {
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}
	if err := unix.Mkfifo(filepath.Join(home, "pipe"), 0o644); err != nil {
		t.Fatal(err)
	}
	return home, outside
}

// testBrowseFS opens the roots of a home folder from browseTree.
func testBrowseFS(t *testing.T, home string) *browseFS {
	t.Helper()
	fsys, err := openBrowseFS(browseRoots(home, filepath.Join(home, "Downloads")), []string{filepath.Join(home, "fluxdata")})
	if err != nil {
		t.Fatal(err)
	}
	return fsys
}

// browseClient opens an SFTP client over SSH on conn, as the phone does.
func browseClient(t *testing.T, conn net.Conn, password string) *sftp.Client {
	t.Helper()
	sc, chans, reqs, err := ssh.NewClientConn(conn, "flux", &ssh.ClientConfig{
		User:            "flux",
		Auth:            []ssh.AuthMethod{ssh.Password(password)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         5 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	client := ssh.NewClient(sc, chans, reqs)
	t.Cleanup(func() { client.Close() })
	c, err := sftp.NewClient(client)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

// connPair returns 2 ends of a TCP connection on the loopback. A net.Pipe
// does not work, because both SSH ends write their version first.
func connPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		c, _ := ln.Accept()
		accepted <- c
	}()
	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	server := <-accepted
	if server == nil {
		t.Fatal("no connection")
	}
	t.Cleanup(func() { client.Close(); server.Close() })
	return server, client
}

// serveBrowse serves fsys on a connection and returns a client for it.
func serveBrowse(t *testing.T, fsys *browseFS) *sftp.Client {
	t.Helper()
	cfg, password, err := browseConfig()
	if err != nil {
		t.Fatal(err)
	}
	server, client := connPair(t)
	go serveSSH(server, cfg, fsys, func(string, ...any) {})
	return browseClient(t, client, password)
}

func readRemote(c *sftp.Client, p string) (string, error) {
	f, err := c.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	return string(b), err
}

// Browse PC reads the files of the roots, also through a symlink that stays
// in its root and through a root that is a symlink to another drive.
func TestBrowseReadsTheRoots(t *testing.T) {
	home, _ := browseTree(t)
	c := serveBrowse(t, testBrowseFS(t, home))
	for p, want := range map[string]string{
		filepath.Join(home, "notes", "a.txt"):    "notes",
		filepath.Join(home, "a-link.txt"):        "notes",
		filepath.Join(home, "Documents/doc.txt"): "doc",
		home + "/notes/../a-link.txt":            "notes",
	} {
		got, err := readRemote(c, p)
		if err != nil || got != want {
			t.Errorf("read %s = %q, %v, want %q", p, got, err, want)
		}
	}
	wd, err := c.Getwd()
	if err != nil || wd != home {
		t.Fatalf("the start folder is %q, %v, want %q", wd, err, home)
	}
	entries, err := c.ReadDir(home)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	slices.Sort(names)
	if want := []string{"a-link.txt", "notes"}; !slices.Equal(names, want) {
		t.Fatalf("home lists %q, want %q", names, want)
	}
	if entries, err := c.ReadDir(filepath.Join(home, "Documents")); err != nil || len(entries) != 1 {
		t.Fatalf("Documents lists %v, %v", entries, err)
	}
}

// A path outside the roots, a ".." path, a symlink out of a root, a dot
// name, and a Flux folder all fail.
func TestBrowseRefusesPathsOutsideTheRoots(t *testing.T) {
	home, outside := browseTree(t)
	c := serveBrowse(t, testBrowseFS(t, home))
	for _, p := range []string{
		"/etc/hostname",
		"/proc/self/environ",
		filepath.Join(outside, "secret.txt"),
		home + "/../outside/secret.txt",
		"../outside/secret.txt",
		"../../../../../../etc/hostname",
		filepath.Join(home, "escape", "secret.txt"),
		filepath.Join(home, "escape.txt"),
		filepath.Join(home, ".ssh", "id_ed25519"),
		filepath.Join(home, ".env"),
		home + "/notes/../.env",
		filepath.Join(home, "key"),
		filepath.Join(home, "fluxdata", "privateKey.pem"),
		filepath.Join(home, "pipe"),
	} {
		if got, err := readRemote(c, p); err == nil {
			t.Errorf("read %s = %q, want an error", p, got)
		}
		if _, err := c.Stat(p); err == nil {
			t.Errorf("stat %s works, want an error", p)
		}
	}
	for _, p := range []string{"/", "/etc", filepath.Dir(home), filepath.Join(home, ".ssh"), filepath.Join(home, "escape"), filepath.Join(home, "fluxdata")} {
		if _, err := c.ReadDir(p); err == nil {
			t.Errorf("list %s works, want an error", p)
		}
	}
	if p, err := c.RealPath("/"); err == nil {
		t.Errorf("RealPath(/) = %q, want an error", p)
	}
	if _, err := c.ReadLink(filepath.Join(home, "escape")); err == nil {
		t.Error("readlink shows a target outside the roots")
	}
}

// Browse PC changes nothing, also with the hard link extension of OpenSSH.
func TestBrowseRefusesWrites(t *testing.T) {
	home, _ := browseTree(t)
	c := serveBrowse(t, testBrowseFS(t, home))
	file := filepath.Join(home, "notes", "a.txt")
	copyPath := filepath.Join(home, "notes", "b.txt")
	if f, err := c.Create(copyPath); err == nil {
		f.Close()
		t.Error("create works")
	}
	if f, err := c.OpenFile(file, os.O_RDWR); err == nil {
		f.Close()
		t.Error("open for writing works")
	}
	checks := map[string]error{
		"mkdir":    c.Mkdir(filepath.Join(home, "new")),
		"remove":   c.Remove(file),
		"rename":   c.Rename(file, copyPath),
		"hardlink": c.Link(file, copyPath),
		"symlink":  c.Symlink(file, copyPath),
		"chmod":    c.Chmod(file, 0o777),
	}
	for name, err := range checks {
		if err == nil {
			t.Errorf("%s works", name)
		}
	}
	if _, err := os.Lstat(copyPath); err == nil {
		t.Fatal("a new file exists")
	}
	if b, err := os.ReadFile(file); err != nil || string(b) != "notes" {
		t.Fatalf("the file changed: %q, %v", b, err)
	}
}

// A download_dir that holds the home folder is not a root, and a folder
// with a dot name is not a root.
func TestBrowseRoots(t *testing.T) {
	home, _ := browseTree(t)
	roots := browseRoots(home, "/")
	for _, r := range roots {
		if r[0] == "Downloads" {
			t.Fatalf("/ is a root: %q", roots)
		}
	}
	dot := filepath.Join(home, ".cache", "downloads")
	if err := os.MkdirAll(dot, 0o755); err != nil {
		t.Fatal(err)
	}
	fsys, err := openBrowseFS(browseRoots(home, dot), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer fsys.Close()
	for _, r := range fsys.roots {
		if r.path == dot {
			t.Fatalf("a folder with a dot name is a root: %q", r.path)
		}
	}
}

// browseSessionDaemon returns a daemon with share_home on, a paired device,
// and a Browse PC session of that device with a client.
func browseSessionDaemon(t *testing.T) (*Daemon, *Device, context.Context, *sftp.Client, string) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	check := sessionCheck
	sessionCheck = 10 * time.Millisecond
	t.Cleanup(func() { sessionCheck = check })
	d, dev := sessionDaemon(t, &config.Config{ShareHome: true})
	home, _ := browseTree(t)
	cfg, password, err := browseConfig()
	if err != nil {
		t.Fatal(err)
	}
	server, client := connPair(t)
	ctx := d.startBrowse(dev, newFakeStreamLink(), testBrowseFS(t, home), cfg, func(context.Context) (net.Conn, error) {
		return server, nil
	})
	c := browseClient(t, client, password)
	file := filepath.Join(home, "notes", "a.txt")
	if got, err := readRemote(c, file); err != nil || got != "notes" {
		t.Fatalf("read = %q, %v", got, err)
	}
	if busy := d.Busy(); busy != "Browse PC" {
		t.Fatalf("Busy = %q", busy)
	}
	return d, dev, ctx, c, file
}

// Turning share_home off ends the Browse PC session at once.
func TestShareHomeOffEndsBrowse(t *testing.T) {
	d, _, ctx, c, file := browseSessionDaemon(t)
	if err := d.setSetting("shareHome", false); err != nil {
		t.Fatal(err)
	}
	waitDone(t, ctx, "the Browse PC session")
	if _, err := readRemote(c, file); err == nil {
		t.Fatal("the phone reads after share_home turned off")
	}
	waitFor(t, "the session ends", func() bool { return d.Busy() == "" })
}

// A reload of config.toml with share_home off ends the session too.
func TestReloadEndsBrowse(t *testing.T) {
	d, _, ctx, _, _ := browseSessionDaemon(t)
	cfg := *d.cfg
	cfg.ShareHome = false
	if err := config.Save(&cfg); err != nil {
		t.Fatal(err)
	}
	if err := d.Reload(); err != nil {
		t.Fatal(err)
	}
	waitDone(t, ctx, "the Browse PC session")
}

// The session ends when the device is no longer paired, and each read
// fails at once.
func TestUnpairEndsBrowse(t *testing.T) {
	d, dev, ctx, c, file := browseSessionDaemon(t)
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	if _, err := readRemote(c, file); err == nil {
		t.Fatal("the phone reads after the unpair")
	}
	waitDone(t, ctx, "the Browse PC session")
}

// The Stop button of the notification ends the session.
func TestBrowseStopButton(t *testing.T) {
	d, _, ctx, _, _ := browseSessionDaemon(t)
	d.mu.Lock()
	var key string
	for n := range d.sessions.browse {
		key = "browse-stop:" + strconv.FormatUint(n, 10)
	}
	d.mu.Unlock()
	d.onNotificationAction(0, key)
	waitDone(t, ctx, "the Browse PC session")
}

// The state lists each Browse PC session, and browse.stop ends it.
func TestBrowseStateAndStop(t *testing.T) {
	d, dev, ctx, _, _ := browseSessionDaemon(t)
	var state struct {
		Browse []BrowseView `json:"browse"`
	}
	if err := json.Unmarshal(d.Snapshot(), &state); err != nil {
		t.Fatal(err)
	}
	if len(state.Browse) != 1 || state.Browse[0].Device != dev.ID || state.Browse[0].Name != dev.Name || state.Browse[0].Since <= 0 {
		t.Fatalf("browse state %+v", state.Browse)
	}
	var e *Error
	if _, err := d.Call(context.Background(), "browse.stop", json.RawMessage(`{"device":"other"}`)); !errors.As(err, &e) || e.Code != "not_found" {
		t.Fatalf("stop of an unknown device: %v", err)
	}
	if _, err := d.Call(context.Background(), "browse.stop", json.RawMessage(`{"device":"`+dev.ID+`"}`)); err != nil {
		t.Fatal(err)
	}
	waitDone(t, ctx, "the Browse PC session")
	if _, err := d.Call(context.Background(), "browse.stop", nil); !errors.As(err, &e) || e.Code != "not_active" {
		t.Fatalf("stop without a session: %v", err)
	}
	if err := json.Unmarshal(d.Snapshot(), &state); err != nil || len(state.Browse) != 0 {
		t.Fatalf("browse state after the stop %+v, %v", state.Browse, err)
	}
}
