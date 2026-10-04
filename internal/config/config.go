// Package config holds the Flux paths, the user configuration file, and the
// store of trusted devices.
package config

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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
	// SyncDnd syncs Do Not Disturb between this computer and the phone.
	SyncDnd bool `toml:"sync_dnd"`
	// Herdr shows the herdr agents of this computer on the phone.
	Herdr bool `toml:"herdr"`
	// HerdrControl lets every paired device send keys and prompts to the
	// herdr agents, and start and close agents. An agent runs the commands
	// that a prompt asks for, so each paired device can then run any
	// command on this computer through an agent. It is off by default.
	HerdrControl bool `toml:"herdr_control"`
	// HerdrTerminals lets the phone open herdr terminals, read them, and
	// type commands in them. It is off by default, because it gives the
	// phone a shell. It needs HerdrControl.
	HerdrTerminals bool `toml:"herdr_terminals"`
	// RemoteInput lets the phone move the pointer and type on this
	// computer. It is off by default, because the phone can then type in
	// any window, such as a terminal.
	RemoteInput bool `toml:"remote_input"`
	// RemoteDesktop lets the phone show the screen of this computer. It is
	// off by default. The touches on the screen also need RemoteInput.
	RemoteDesktop bool `toml:"remote_desktop"`
	// CheckUpdates lets fluxd ask GitHub once a day for the latest
	// release. It is on by default. Without a network, the check fails
	// and Flux works as before.
	CheckUpdates bool `toml:"check_updates"`
	// GUI selects the window: "plugin" for the omarchy-shell plugin, "app"
	// for flux-gui, or empty for the plugin when it is enabled.
	GUI string `toml:"gui,omitempty"`
	// ApproveTimeout is how long an approval waits for the phone, in
	// seconds, from 5 to 120. Zero means 20.
	ApproveTimeout    int                        `toml:"approve_timeout,omitempty"`
	Commands          []Command                  `toml:"commands"`
	Devices           map[string]map[string]bool `toml:"devices,omitempty"`
	NotificationRules []NotificationRule         `toml:"notification_rules,omitempty"`
	AutomationRules   []AutomationRule           `toml:"automation_rules,omitempty"`
}

// ConfigDir returns ~/.config/flux, or $XDG_CONFIG_HOME/flux.
func ConfigDir() string { return filepath.Join(xdg("XDG_CONFIG_HOME", ".config"), "flux") }

// OffPath returns the marker file that `flux-cli off` writes. While it exists,
// a fluxd that systemd starts exits at once, also when the service is
// enabled for all users.
func OffPath() string { return filepath.Join(ConfigDir(), "off") }

// IsOff reports whether the user turned fluxd off with `flux-cli off`.
func IsOff() bool {
	_, err := os.Stat(OffPath())
	return err == nil
}

// DataDir returns ~/.local/share/flux, or $XDG_DATA_HOME/flux.
func DataDir() string { return filepath.Join(xdg("XDG_DATA_HOME", ".local/share"), "flux") }

// CacheDir returns ~/.cache/flux, or $XDG_CACHE_HOME/flux.
func CacheDir() string { return filepath.Join(xdg("XDG_CACHE_HOME", ".cache"), "flux") }

// RuntimeDir returns $XDG_RUNTIME_DIR/flux, or /run/user/<uid>/flux when
// XDG_RUNTIME_DIR is not set. The folder is in memory and private to the
// user. Flux never uses the shared temporary folder for it.
func RuntimeDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "flux")
	}
	return filepath.Join("/run/user", strconv.Itoa(os.Getuid()), "flux")
}

// SocketPath returns the path of the fluxd IPC socket: $FLUX_SOCKET, else
// fluxd.sock in RuntimeDir. fluxd, flux-cli, and the 2 desktop hosts use
// the same rule.
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
	c := &Config{AutoClipboard: true, Notifications: true, ShareHome: true, PauseMediaOnCall: true, SyncDnd: true, Herdr: true, CheckUpdates: true}
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
	if err := c.ValidateRules(); err != nil {
		return nil, err
	}
	setCommandIDs(c.Commands)
	return c, nil
}

// setCommandIDs gives each command without an ID an ID from its name and
// its command. So a command that the user added to config.toml by hand
// keeps its ID after each reload and restart, and `flux-cli run ID` works.
func setCommandIDs(cmds []Command) {
	used := map[string]bool{}
	for _, c := range cmds {
		used[c.ID] = true
	}
	for i := range cmds {
		if cmds[i].ID != "" {
			continue
		}
		for n := 0; ; n++ {
			sum := sha256.Sum256([]byte(fmt.Sprintf("%s\x00%s\x00%d", cmds[i].Name, cmds[i].Command, n)))
			if id := hex.EncodeToString(sum[:4]); !used[id] {
				cmds[i].ID = id
				used[id] = true
				break
			}
		}
	}
}

// Check reads config.toml and returns its parse error. Unlike Load, it
// writes no file. A missing file is not an error.
func Check() error {
	data, err := os.ReadFile(Path())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var c Config
	if _, err := toml.Decode(string(data), &c); err != nil {
		return fmt.Errorf("%s: %w", Path(), err)
	}
	return nil
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

// writeAtomic replaces path with data in 1 step. It syncs the file and
// the folder, so that a power loss leaves the old file or the new file,
// never an empty file.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
