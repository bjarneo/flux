// Package config holds the Flux paths, the user configuration file, and the
// store of trusted devices.
package config

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/BurntSushi/toml"
)

// Command is a desktop command that a paired phone can run.
type Command struct {
	ID      string `toml:"id" json:"id"`
	Name    string `toml:"name" json:"name"`
	Command string `toml:"command" json:"command"`
}

// Config is the content of ~/.config/flux/config.toml.
type Config struct {
	Name        string `toml:"name"`
	DownloadDir string `toml:"download_dir"`
	// ScanDir is the folder for text that Flux for Android scans with the
	// camera. Empty means <Documents>/flux/scanned.
	ScanDir string `toml:"scan_dir,omitempty"`
	// PhotoDir is the folder for photos that Flux for Android takes with
	// the camera. Empty means <Pictures>/flux.
	PhotoDir      string `toml:"photo_dir,omitempty"`
	AutoClipboard bool   `toml:"auto_clipboard"`
	Notifications bool   `toml:"notifications"`
	ShareHome     bool   `toml:"share_home"`
	// PauseMediaOnCall pauses the players on this computer while the
	// phone rings or has a call, and plays them again after the call.
	PauseMediaOnCall bool `toml:"pause_media_on_call"`
	// GUI selects the window: "plugin" for the omarchy-shell plugin, "app"
	// for flux-gui, or empty for the plugin when it is enabled.
	GUI      string    `toml:"gui,omitempty"`
	Commands []Command `toml:"commands"`
}

// ConfigDir returns ~/.config/flux, or $XDG_CONFIG_HOME/flux.
func ConfigDir() string { return filepath.Join(xdg("XDG_CONFIG_HOME", ".config"), "flux") }

// DataDir returns ~/.local/share/flux, or $XDG_DATA_HOME/flux.
func DataDir() string { return filepath.Join(xdg("XDG_DATA_HOME", ".local/share"), "flux") }

// RuntimeDir returns $XDG_RUNTIME_DIR/flux.
func RuntimeDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "flux")
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("flux-%d", os.Getuid()))
}

// SocketPath returns the path of the fluxd IPC socket.
func SocketPath() string {
	if p := os.Getenv("FLUX_SOCKET"); p != "" {
		return p
	}
	return filepath.Join(RuntimeDir(), "fluxd.sock")
}

func xdg(env, fallback string) string {
	if d := os.Getenv(env); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, fallback)
}

// Path returns the path of config.toml.
func Path() string { return filepath.Join(ConfigDir(), "config.toml") }

var mu sync.Mutex

// Load reads config.toml. It writes a default file when none exists.
func Load() (*Config, error) {
	mu.Lock()
	defer mu.Unlock()
	c := &Config{AutoClipboard: true, Notifications: true, ShareHome: true, PauseMediaOnCall: true}
	data, err := os.ReadFile(Path())
	if errors.Is(err, os.ErrNotExist) {
		c.Commands = []Command{}
		return c, save(c)
	}
	if err != nil {
		return nil, err
	}
	if _, err := toml.Decode(string(data), c); err != nil {
		return nil, fmt.Errorf("%s: %w", Path(), err)
	}
	for i := range c.Commands {
		if c.Commands[i].ID == "" {
			c.Commands[i].ID = NewID(4)
		}
	}
	return c, nil
}

// Save writes config.toml.
func Save(c *Config) error {
	mu.Lock()
	defer mu.Unlock()
	return save(c)
}

func save(c *Config) error {
	if err := os.MkdirAll(ConfigDir(), 0o755); err != nil {
		return err
	}
	var b strings.Builder
	b.WriteString("# Flux configuration. fluxd reloads this file on SIGHUP.\n\n")
	if err := toml.NewEncoder(&b).Encode(c); err != nil {
		return err
	}
	return writeAtomic(Path(), []byte(b.String()), 0o644)
}

// DownloadPath returns the directory for received files. It uses the
// download_dir setting, then XDG_DOWNLOAD_DIR, then ~/Downloads.
func (c *Config) DownloadPath() string {
	home, _ := os.UserHomeDir()
	if c.DownloadDir != "" {
		return expand(c.DownloadDir, home)
	}
	if d := userDir("XDG_DOWNLOAD_DIR", home); d != "" {
		return d
	}
	return filepath.Join(home, "Downloads")
}

// ScanPath returns the folder for scanned text. It uses the scan_dir
// setting, then XDG_DOCUMENTS_DIR, then ~/Documents, with flux/scanned
// inside.
func (c *Config) ScanPath() string {
	home, _ := os.UserHomeDir()
	if c.ScanDir != "" {
		return expand(c.ScanDir, home)
	}
	docs := userDir("XDG_DOCUMENTS_DIR", home)
	if docs == "" {
		docs = filepath.Join(home, "Documents")
	}
	return filepath.Join(docs, "flux", "scanned")
}

// PhotoPath returns the folder for photos from the phone camera. It uses
// the photo_dir setting, then XDG_PICTURES_DIR, then ~/Pictures, with flux
// inside.
func (c *Config) PhotoPath() string {
	home, _ := os.UserHomeDir()
	if c.PhotoDir != "" {
		return expand(c.PhotoDir, home)
	}
	pics := userDir("XDG_PICTURES_DIR", home)
	if pics == "" {
		pics = filepath.Join(home, "Pictures")
	}
	return filepath.Join(pics, "flux")
}

func expand(p, home string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

// userDir reads one entry of ~/.config/user-dirs.dirs.
func userDir(key, home string) string {
	f, err := os.Open(filepath.Join(xdg("XDG_CONFIG_HOME", ".config"), "user-dirs.dirs"))
	if err != nil {
		return ""
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(s.Text()), "=")
		if !ok || k != key {
			continue
		}
		v = strings.Trim(v, `"`)
		return strings.ReplaceAll(v, "$HOME", home)
	}
	return ""
}

// NewID returns a random hex string of n bytes.
func NewID(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
