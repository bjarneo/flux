// Package omarchytheme reads a bounded, read-only projection of an installed
// Omarchy theme catalog. It never substitutes a palette on a non-Omarchy host.
package omarchytheme

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

const MaxThemes = 64
const MaxBody = 60 << 10
const maxColorsFile = 16 << 10

var idPattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._ -]{0,62}[A-Za-z0-9])?$`)
var hexPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

// ValidSelectionID matches the opaque wire ID and the canonical setter's
// normalization. Never silently select another directory after normalization.
func ValidSelectionID(id string) bool {
	return idPattern.MatchString(id) && !strings.Contains(id, "..") &&
		id == strings.ToLower(strings.ReplaceAll(id, " ", "-"))
}

// Installed excludes the materialized active-theme fallback used by Read.
// Selection authority requires a valid palette in an installed theme root.
func (r Reader) Installed(id string) bool {
	if !ValidSelectionID(id) {
		return false
	}
	for _, root := range []string{r.SystemThemes, filepath.Join(r.Home, ".config/omarchy/themes")} {
		if _, ok := readPalette(filepath.Join(root, id, "colors.toml"), id); ok {
			return true
		}
	}
	return false
}

// Reader's roots are fixed by the daemon; exported paths permit isolated tests.
type Reader struct {
	Home, SystemThemes string
	// RuntimeDir overrides XDG_RUNTIME_DIR for isolated readers/tests.
	RuntimeDir string
	// afterNameRead is a test seam for an Omarchy switch during a scan.
	afterNameRead func()
}
type Catalog struct {
	Kind     string  `json:"kind"`
	Version  int     `json:"version"`
	Current  string  `json:"current"`
	Themes   []Theme `json:"themes"`
	Revision string  `json:"revision,omitempty"`
}
type Theme struct {
	ID      string  `json:"id"`
	Label   string  `json:"label"`
	Palette Palette `json:"palette"`
}
type Palette struct {
	Name     string            `json:"name"`
	Mode     string            `json:"mode"`
	Source   string            `json:"source"`
	Colors   map[string]string `json:"colors"`
	Geometry *Geometry         `json:"geometry,omitempty"`
}

// Read returns false when there is no valid installed/current theme. An empty
// or malformed state cannot trigger a Tokyo Night or other fallback packet.
func (r Reader) Read() (Catalog, bool) {
	var empty Catalog
	if r.Home == "" || r.SystemThemes == "" {
		return empty, false
	}
	// Omarchy holds an exclusive flock through the palette-first, name-last
	// switch. Hold a shared lock over the entire scan, not just theme.name.
	runtimeDir := r.RuntimeDir
	if runtimeDir == "" {
		runtimeDir = os.Getenv("XDG_RUNTIME_DIR")
	}
	if runtimeDir == "" {
		runtimeDir = "/tmp"
	}
	fd, err := openSafe(filepath.Join(runtimeDir, "omarchy-theme-set.lock"), unix.O_RDWR|unix.O_CREAT)
	if err != nil {
		return empty, false
	}
	defer unix.Close(fd)
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil || stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Nlink != 1 || stat.Uid != uint32(os.Geteuid()) {
		return empty, false
	}
	if err := unix.Flock(fd, unix.LOCK_SH|unix.LOCK_NB); err != nil {
		return empty, false
	}
	return r.readCurrent()
}

func (r Reader) readCurrent() (Catalog, bool) {
	var empty Catalog
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	namePath := filepath.Join(state, "theme.name")
	// A switch can replace theme.name while the catalog and applied palette
	// are being read. Never publish a snapshot labeled with the old name.
	for attempt := 0; attempt < 3; attempt++ {
		raw, err := readRegular(namePath, 128)
		if err != nil {
			return empty, false
		}
		id := strings.TrimSpace(string(raw))
		if !idPattern.MatchString(id) || string(raw) != id && string(raw) != id+"\n" {
			return empty, false
		}
		if r.afterNameRead != nil {
			r.afterNameRead()
		}
		c, ok := r.readNamed(state, id)
		again, err := readRegular(namePath, 128)
		if err != nil {
			return empty, false
		}
		if !bytes.Equal(raw, again) {
			continue
		}
		return c, ok
	}
	return empty, false
}

func (r Reader) readNamed(state, id string) (Catalog, bool) {
	var empty Catalog
	roots := []string{r.SystemThemes, filepath.Join(r.Home, ".config/omarchy/themes")}
	themes := make(map[string]Theme)
	for _, root := range roots {
		// ReadDir on the pinned, no-symlink directory, not on a pathname
		// that could be redirected between validation and enumeration.
		fd, err := openSafe(root, unix.O_RDONLY|unix.O_DIRECTORY)
		if err != nil {
			continue
		}
		f := os.NewFile(uintptr(fd), root)
		entries, err := f.ReadDir(-1)
		f.Close()
		if err != nil {
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if !idPattern.MatchString(name) || !entry.IsDir() {
				continue
			}
			palette, ok := readPalette(filepath.Join(root, name, "colors.toml"), name)
			if !ok {
				continue
			}
			themes[name] = Theme{ID: name, Label: label(name), Palette: palette}
		}
	}
	current, ok := themes[id]
	// Omarchy materializes the selected theme in current/theme. Prefer its
	// effective colors when available (user overrides can differ from catalog).
	activeDir := filepath.Join(state, "theme")
	if fd, err := openSafe(activeDir, unix.O_RDONLY|unix.O_DIRECTORY); err == nil {
		unix.Close(fd)
		if p, valid := readPalette(filepath.Join(activeDir, "colors.toml"), id); valid {
			current.Palette = p
			current.ID, current.Label = id, label(id)
			themes[id] = current
			ok = true
		}
	}
	if !ok {
		return empty, false
	}
	ids := make([]string, 0, len(themes))
	for name := range themes {
		ids = append(ids, name)
	}
	sort.Strings(ids)
	// Start with the current theme, then add sorted candidates only when
	// their exact JSON encoding fits the transport body limit.
	c := Catalog{Kind: "catalog", Version: 1, Current: id, Themes: []Theme{themes[id]}}
	if b, err := json.Marshal(c); err != nil || len(b) > MaxBody {
		return empty, false
	}
	for _, name := range ids {
		if name == id || len(c.Themes) == MaxThemes {
			continue
		}
		c.Themes = append(c.Themes, themes[name])
		b, err := json.Marshal(c)
		if err != nil || len(b) > MaxBody {
			c.Themes = c.Themes[:len(c.Themes)-1]
		}
	}
	sort.Slice(c.Themes, func(i, j int) bool { return c.Themes[i].ID < c.Themes[j].ID })
	return c, true
}

func label(id string) string { return strings.ReplaceAll(strings.ReplaceAll(id, "-", " "), "_", " ") }

// openSafe resolves every component without following symlinks, atomically
// with open. O_NOFOLLOW alone only protects the final path component.
func openSafe(path string, flags int) (int, error) {
	var mode uint64
	if flags&unix.O_CREAT != 0 {
		mode = 0600
	}
	return unix.Openat2(unix.AT_FDCWD, path, &unix.OpenHow{
		Flags:   uint64(flags | unix.O_NOFOLLOW | unix.O_CLOEXEC | unix.O_NONBLOCK),
		Mode:    mode,
		Resolve: unix.RESOLVE_NO_SYMLINKS,
	})
}

// readRegular rejects symlinks, directories, and oversized files on the
// opened descriptor. Local theme names are never used as arbitrary paths.
func readRegular(path string, limit int) ([]byte, error) {
	fd, err := openSafe(path, unix.O_RDONLY)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || opened.Size() > int64(limit) {
		return nil, os.ErrInvalid
	}
	b, err := io.ReadAll(io.LimitReader(f, int64(limit)+1))
	if err != nil || len(b) > limit {
		return nil, os.ErrInvalid
	}
	return b, nil
}

var colorRoles = map[string]bool{"background": true, "foreground": true, "accent": true, "black": true, "red": true, "green": true, "yellow": true, "blue": true, "magenta": true, "cyan": true, "white": true, "orange": true, "brown": true, "bright_red": true, "bright_yellow": true, "bright_green": true, "bright_cyan": true, "bright_blue": true, "bright_magenta": true, "dark_background": true, "darker_background": true, "lighter_background": true, "dark_foreground": true, "light_foreground": true, "bright_foreground": true, "muted": true, "selection": true, "cursor": true, "selection_background": true, "selection_foreground": true, "color0": true, "color1": true, "color2": true, "color3": true, "color4": true, "color5": true, "color6": true, "color7": true, "color8": true, "color9": true, "color10": true, "color11": true, "color12": true, "color13": true, "color14": true, "color15": true}

var legacyRoles = map[string]string{"bg": "background", "fg": "foreground", "dark_bg": "dark_background", "darker_bg": "darker_background", "lighter_bg": "lighter_background", "dark_fg": "dark_foreground", "light_fg": "light_foreground", "bright_fg": "bright_foreground"}

func readPalette(path, id string) (Palette, bool) {
	var empty Palette
	b, err := readRegular(path, maxColorsFile)
	if err != nil || !utf8.Valid(b) {
		return empty, false
	}
	colors := map[string]string{}
	mode := "dark"
	// A marker is used by older themes that do not specify mode in TOML.
	if fd, err := openSafe(filepath.Join(filepath.Dir(path), "light.mode"), unix.O_RDONLY); err == nil {
		f := os.NewFile(uintptr(fd), "light.mode")
		if fi, err := f.Stat(); err == nil && fi.Mode().IsRegular() {
			mode = "light"
		}
		f.Close()
	}
	s := bufio.NewScanner(bytes.NewReader(b))
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, raw, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		raw = strings.TrimSpace(raw)
		// Accept only bare quoted hex values, not comments or interpolated strings.
		if len(raw) < 2 || raw[0] != '"' || raw[len(raw)-1] != '"' {
			continue
		}
		val := raw[1 : len(raw)-1]
		if key == "mode" {
			if val == "light" || val == "dark" {
				mode = val
			}
			continue
		}
		if colorRoles[key] && hexPattern.MatchString(val) {
			colors[key] = strings.ToLower(val)
		}
		if canonical := legacyRoles[key]; canonical != "" && hexPattern.MatchString(val) && colors[canonical] == "" {
			colors[canonical] = strings.ToLower(val)
		}
	}
	if s.Err() != nil || colors["background"] == "" || colors["foreground"] == "" {
		return empty, false
	}
	if colors["accent"] == "" {
		colors["accent"] = colors["blue"]
	}
	if colors["accent"] == "" {
		colors["accent"] = colors["color4"]
	}
	if colors["accent"] == "" {
		return empty, false
	}
	return Palette{Name: id, Mode: mode, Source: "omarchy", Colors: colors}, true
}
