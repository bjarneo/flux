package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"flux/internal/nativemsg"
)

// TestExtensionMatchesID checks that the extension ID in the Chromium
// manifest is the one that `flux-cli browser install` writes in the host
// manifest. Chromium derives the ID of an unpacked extension from the key
// in its manifest, and a host manifest with another ID starts for nobody.
func TestExtensionMatchesID(t *testing.T) {
	var m struct {
		Key string `json:"key"`
	}
	read(t, "../../browser/extension/manifest.json", &m)
	der, err := base64.StdEncoding.DecodeString(m.Key)
	if err != nil {
		t.Fatal(err)
	}
	// Chromium takes the first 16 bytes of the SHA-256 of the public key
	// and writes every nibble as a letter from a to p.
	sum := sha256.Sum256(der)
	id := make([]byte, 32)
	for i, c := range []byte(hex.EncodeToString(sum[:16])) {
		nibble := c - '0'
		if c >= 'a' {
			nibble = c - 'a' + 10
		}
		id[i] = 'a' + nibble
	}
	if string(id) != extensionID {
		t.Errorf("the manifest key gives the ID %s, and the code says %s", id, extensionID)
	}
}

// TestExtensionDirFindsUserCopy checks that the CLI points at the copy
// `make install-user` wrote, and not at the checkout, when both could
// answer. A user without root only has that one.
func TestExtensionDirFindsUserCopy(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, userExtension)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, ok := extensionDir()
	if !ok || got != dir {
		t.Errorf("extensionDir() gave %q, %t, and the test wants %q", got, ok, dir)
	}
}

// TestExtensionUsesHostName checks that the extension starts the host that
// Flux installs.
func TestExtensionUsesHostName(t *testing.T) {
	if body := read(t, "../../browser/extension/host.js", nil); !strings.Contains(body, `"`+nativemsg.Host+`"`) {
		t.Errorf("host.js does not use the host name %s", nativemsg.Host)
	}
}

// TestGeckoIDMatchesManifest checks the add-on ID that `flux-cli browser
// install` looks for in prefs.js.
func TestGeckoIDMatchesManifest(t *testing.T) {
	var m struct {
		Settings struct {
			Gecko struct {
				ID string `json:"id"`
			} `json:"gecko"`
		} `json:"browser_specific_settings"`
	}
	read(t, "../../browser/extension/manifest.firefox.json", &m)
	if m.Settings.Gecko.ID != geckoID {
		t.Errorf("the manifest says %q, and the code says %q", m.Settings.Gecko.ID, geckoID)
	}
}

// TestBrowserInstallChromium checks the manifest that a Chromium browser
// reads. The extension starts only when the name, the path, and the origin
// all match.
func TestBrowserInstallChromium(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".config", "chromium"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	var m hostManifest
	path := filepath.Join(home, ".config", "chromium", "NativeMessagingHosts", nativemsg.Host+".json")
	read(t, path, &m)
	if m.Name != nativemsg.Host {
		t.Errorf("name is %q, want %q", m.Name, nativemsg.Host)
	}
	if m.Type != "stdio" {
		t.Errorf("type is %q, want stdio", m.Type)
	}
	if !filepath.IsAbs(m.Path) || filepath.Base(m.Path) != hostBinary {
		t.Errorf("path is %q, want the whole path of %s", m.Path, hostBinary)
	}
	if len(m.AllowedOrigins) != 1 || m.AllowedOrigins[0] != "chrome-extension://"+extensionID+"/" {
		t.Errorf("origins are %v", m.AllowedOrigins)
	}
}

// TestBrowserInstallLeavesOtherBrowsers checks that Flux does not create a
// profile directory for a browser that this user does not have.
func TestBrowserInstallLeavesOtherBrowsers(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".config", "chromium"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	if isDir(filepath.Join(home, ".config", "vivaldi")) {
		t.Error("Flux created a directory for a browser that is not installed")
	}
}

// TestBrowserInstallXDG checks that the manifest also lands in
// XDG_CONFIG_HOME, because a Chromium browser follows it.
func TestBrowserInstallXDG(t *testing.T) {
	home := installable(t)
	xdg := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", xdg)
	mkdir(t, filepath.Join(home, ".config", "chromium"))
	mkdir(t, filepath.Join(xdg, "BraveSoftware", "Brave-Browser"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	read(t, filepath.Join(home, ".config", "chromium", "NativeMessagingHosts", nativemsg.Host+".json"), &hostManifest{})
	read(t, filepath.Join(xdg, "BraveSoftware", "Brave-Browser", "NativeMessagingHosts", nativemsg.Host+".json"), &hostManifest{})
}

// TestBrowserInstallGecko checks the manifest that Firefox and Zen read.
// They name the caller by its add-on ID, in allowed_extensions, and they
// have never heard of allowed_origins.
func TestBrowserInstallGecko(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".zen"))
	mkdir(t, filepath.Join(home, ".mozilla", "firefox"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{filepath.Join(home, ".zen", "native-messaging-hosts"), filepath.Join(home, ".mozilla", "native-messaging-hosts")} {
		var m hostManifest
		read(t, filepath.Join(dir, nativemsg.Host+".json"), &m)
		if len(m.AllowedExtensions) != 1 || m.AllowedExtensions[0] != geckoID {
			t.Errorf("%s names %v, want [%s]", dir, m.AllowedExtensions, geckoID)
		}
		if len(m.AllowedOrigins) != 0 {
			t.Errorf("%s has origins %v, which Firefox does not read", dir, m.AllowedOrigins)
		}
	}
}

// TestBrowserInstallGeckoNeedsNoLoadedAddon checks that the manifest is
// written the first time, before the add-on has ever been loaded. Firefox
// matches the add-on ID, not the UUID a profile would have given it, so
// waiting for a profile would only delay a manifest that is already right.
func TestBrowserInstallGeckoNeedsNoLoadedAddon(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".zen"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	var m hostManifest
	read(t, filepath.Join(home, ".zen", "native-messaging-hosts", nativemsg.Host+".json"), &m)
	if m.AllowedExtensions[0] != geckoID {
		t.Errorf("extensions are %v, want [%s]", m.AllowedExtensions, geckoID)
	}
}

// TestBrowserInstallCustomID checks --id, which is what a user needs after
// signing the extension with their own key.
func TestBrowserInstallCustomID(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".config", "google-chrome"))
	if err := browser([]string{"install", "--id", "aaaabbbbccccddddeeeeffffgggghhhh"}); err != nil {
		t.Fatal(err)
	}
	var m hostManifest
	read(t, filepath.Join(home, ".config", "google-chrome", "NativeMessagingHosts", nativemsg.Host+".json"), &m)
	if m.AllowedOrigins[0] != "chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/" {
		t.Errorf("origins are %v", m.AllowedOrigins)
	}
}

// TestBrowserInstallDryRun checks that --dry-run writes nothing.
func TestBrowserInstallDryRun(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".config", "chromium"))
	if err := browser([]string{"install", "--dry-run"}); err != nil {
		t.Fatal(err)
	}
	if isDir(filepath.Join(home, ".config", "chromium", "NativeMessagingHosts")) {
		t.Error("--dry-run created a directory")
	}
}

// TestBrowserInstallBadOption checks that a mistyped option is refused
// instead of ignored.
func TestBrowserInstallBadOption(t *testing.T) {
	installable(t)
	if err := browser([]string{"install", "--all"}); err == nil {
		t.Error("an unknown option was accepted")
	}
}

// TestBrowserRemove checks that the removal takes the Flux manifest and
// leaves a file of another program alone, even with the same name.
func TestBrowserRemove(t *testing.T) {
	home := installable(t)
	mkdir(t, filepath.Join(home, ".config", "chromium"))
	if err := browser([]string{"install"}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, ".config", "chromium", "NativeMessagingHosts")
	foreign := filepath.Join(dir, "org.omarchy.flux.json")
	write(t, foreign, `{"name":"org.example.other","path":"/usr/bin/other"}`)
	if err := browser([]string{"remove"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Error("Flux removed a manifest of another program")
	}
	if err := browser([]string{"remove"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Error("Flux removed a manifest of another program")
	}
}

// installable gives the test a home directory with a flux-native that
// hostPath can find, so that the install runs without an installed Flux.
func installable(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	write(t, filepath.Join(home, ".local", "bin", hostBinary), "#!/bin/sh\n")
	return home
}

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string, into any) string {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if into != nil {
		if err := json.Unmarshal(body, into); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
	}
	return string(body)
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
