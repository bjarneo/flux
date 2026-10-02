package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/BurntSushi/toml"
)

const (
	maxOhmThemes    = 64
	maxOhmColors    = 48
	maxOhmThemeFile = 64 * 1024
	// Leave room for the outer Flux packet in Ohm's 64 KiB reader.
	maxOhmThemeCatalog = 60 * 1024
)

var (
	ohmColorRole  = regexp.MustCompile(`^[a-z][a-z0-9_]{0,39}$`)
	ohmColorValue = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
)

// OhmThemeCatalog is the bounded v1 data-only theme catalog used by Ohm.
// flux.theme remains available for the original Flux Android client.
type OhmThemeCatalog struct {
	Kind    string     `json:"kind"`
	Version int        `json:"version"`
	Current string     `json:"current"`
	Themes  []OhmTheme `json:"themes"`
}

type OhmTheme struct {
	ID      string          `json:"id"`
	Label   string          `json:"label"`
	Palette OhmThemePalette `json:"palette"`
}

type OhmThemePalette struct {
	Name   string            `json:"name"`
	Mode   string            `json:"mode"`
	Source string            `json:"source"`
	Colors map[string]string `json:"colors"`
}

// OhmCatalog reads palettes without applying themes or executing theme code.
func (t Themes) OhmCatalog() (OhmThemeCatalog, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return OhmThemeCatalog{}, err
	}
	// Read the current ID and palette under the setter's staging lock. A
	// snapshot taken between its directory swap and theme.name write could
	// otherwise associate the new colors with the previous theme ID.
	runtime := os.Getenv("XDG_RUNTIME_DIR")
	if runtime == "" {
		runtime = "/tmp"
	}
	lock, err := os.OpenFile(filepath.Join(runtime, "omarchy-theme-set.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return OhmThemeCatalog{}, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		return OhmThemeCatalog{}, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	return ohmThemeCatalog(t.Active(), t.Colors(),
		filepath.Join(omarchyPath(), "themes"), filepath.Join(home, ".config", "omarchy", "themes"))
}

func ohmThemeCatalog(active, currentColors string, roots ...string) (OhmThemeCatalog, error) {
	ids, err := themeCatalog(roots...)
	if err != nil {
		return OhmThemeCatalog{}, err
	}
	if !containsTheme(ids, active) {
		return OhmThemeCatalog{}, errors.New("active Omarchy theme is not installed")
	}
	catalog := OhmThemeCatalog{Kind: "catalog", Version: 1, Current: active, Themes: []OhmTheme{}}
	// Keep the active theme even when a large installed catalog must be capped.
	ordered := append([]string{active}, ids...)
	for _, id := range ordered {
		if id == active && len(catalog.Themes) > 0 {
			continue
		}
		if len(id) > 64 {
			continue
		}
		var colors []byte
		if id == active && currentColors != "" {
			colors = []byte(currentColors)
		} else {
			// Omarchy overlays the per-user theme over the packaged theme.
			for _, root := range roots {
				b, readErr := readOhmThemeColors(filepath.Join(root, id, "colors.toml"))
				if readErr == nil {
					colors = b
				}
			}
		}
		label := ohmThemeLabel(id)
		palette, parseErr := ohmThemePalette(id, colors)
		if parseErr != nil {
			if id == active {
				return OhmThemeCatalog{}, fmt.Errorf("active Omarchy palette: %w", parseErr)
			}
			continue
		}
		candidate := OhmTheme{ID: id, Label: label, Palette: palette}
		catalog.Themes = append(catalog.Themes, candidate)
		encoded, encodeErr := json.Marshal(catalog)
		if encodeErr != nil {
			return OhmThemeCatalog{}, encodeErr
		}
		if len(catalog.Themes) > maxOhmThemes || len(encoded) > maxOhmThemeCatalog {
			catalog.Themes = catalog.Themes[:len(catalog.Themes)-1]
			break
		}
	}
	if len(catalog.Themes) == 0 {
		return OhmThemeCatalog{}, errors.New("no readable Omarchy palettes")
	}
	sort.Slice(catalog.Themes, func(i, j int) bool { return catalog.Themes[i].ID < catalog.Themes[j].ID })
	return catalog, nil
}

// Theme palettes are local color data. Refuse symlinks for colors.toml so an
// installed theme cannot use the catalog to disclose another readable file.
func readOhmThemeColors(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxOhmThemeFile {
		return nil, errors.New("invalid palette file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !os.SameFile(info, opened) {
		return nil, errors.New("palette file changed")
	}
	b, err := io.ReadAll(io.LimitReader(f, maxOhmThemeFile+1))
	if len(b) > maxOhmThemeFile {
		return nil, errors.New("palette is too large")
	}
	return b, err
}

func ohmThemePalette(name string, b []byte) (OhmThemePalette, error) {
	if len(b) == 0 || len(b) > maxOhmThemeFile {
		return OhmThemePalette{}, errors.New("missing or oversized colors.toml")
	}
	var raw map[string]any
	if err := toml.Unmarshal(b, &raw); err != nil {
		return OhmThemePalette{}, err
	}
	colors := map[string]string{}
	for role, value := range raw {
		color, ok := value.(string)
		if ok && ohmColorRole.MatchString(role) && ohmColorValue.MatchString(color) {
			colors[role] = color
		}
	}
	if len(colors) == 0 || len(colors) > maxOhmColors {
		return OhmThemePalette{}, errors.New("invalid palette colors")
	}
	mode, _ := raw["mode"].(string)
	if mode != "dark" && mode != "light" {
		mode = "dark"
		if background, ok := colors["background"]; ok {
			n, _ := strconv.ParseUint(background[1:], 16, 32)
			// Infer only for older themes which do not declare a mode.
			if 299*((n>>16)&255)+587*((n>>8)&255)+114*(n&255) >= 128000 {
				mode = "light"
			}
		}
	}
	return OhmThemePalette{Name: name, Mode: mode, Source: "omarchy", Colors: colors}, nil
}

func ohmThemeLabel(id string) string {
	words := strings.Split(id, "-")
	for i, word := range words {
		if word != "" {
			words[i] = strings.ToUpper(word[:1]) + word[1:]
		}
	}
	return strings.Join(words, " ")
}

// ApplyContext uses the canonical Omarchy setter, bounded by the
// authenticated request's lifetime. It never passes through a shell.
func (t Themes) ApplyContext(ctx context.Context, id string) error {
	ids, err := t.Catalog()
	if err != nil {
		return err
	}
	if !containsTheme(ids, id) {
		return os.ErrNotExist
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return runOhmThemeSetter(ctx, "/usr/bin/omarchy-theme-set", id)
}

func runOhmThemeSetter(ctx context.Context, setter, id string) error {
	cmd := exec.CommandContext(ctx, setter, id)
	cmd.Env = append(withoutEnv(os.Environ(), "OMARCHY_PATH"), "OMARCHY_PATH="+omarchyPath())
	// The setter starts children. Cancel the complete request process group
	// so they cannot continue applying a theme after this link is revoked.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if err == syscall.ESRCH {
			return os.ErrProcessDone
		}
		return err
	}
	cmd.WaitDelay = 2 * time.Second
	return cmd.Run()
}
