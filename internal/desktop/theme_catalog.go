package desktop

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Themes is the Omarchy theme catalog and its canonical setter. It accepts
// only IDs that name an installed theme, then invokes omarchy-theme-set without
// a shell so a paired phone cannot turn a theme selection into a command.
type Themes struct{}

// NewThemes returns the desktop theme backend used by fluxd.
func NewThemes() Themes { return Themes{} }

// Catalog lists the safe, installed Omarchy theme IDs from the packaged and
// per-user theme directories.
func (Themes) Catalog() ([]string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return themeCatalog(filepath.Join(omarchyPath(), "themes"), filepath.Join(home, ".config", "omarchy", "themes"))
}

// Apply validates id against the current catalog before using Omarchy's
// canonical setter. The setter owns staging, locking, and active-theme state.
func (t Themes) Apply(id string) error {
	ids, err := t.Catalog()
	if err != nil {
		return err
	}
	if !containsTheme(ids, id) {
		return os.ErrNotExist
	}
	cmd := exec.Command("/usr/bin/omarchy-theme-set", id)
	cmd.Env = append(withoutEnv(os.Environ(), "OMARCHY_PATH"), "OMARCHY_PATH="+omarchyPath())
	return cmd.Run()
}

// Active returns the canonical ID saved by omarchy-theme-set, or an empty
// string when Omarchy has not selected a valid theme yet.
func (Themes) Active() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(home, ".local", "state", "omarchy", "current", "theme.name"))
	if err != nil {
		return ""
	}
	id := strings.TrimSpace(string(b))
	if !validThemeID(id) {
		return ""
	}
	return id
}

// Colors returns the desktop-resolved palette after a successful selection.
// It is bounded so a malformed local file cannot create an oversized packet.
func (Themes) Colors() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(home, ".local", "state", "omarchy", "current", "theme", "colors.toml"))
	if err != nil || len(b) > 64*1024 {
		return ""
	}
	return string(b)
}

func themeCatalog(roots ...string) ([]string, error) {
	seen := map[string]bool{}
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, err
		}
		for _, entry := range entries {
			info, err := os.Stat(filepath.Join(root, entry.Name()))
			if err == nil && info.IsDir() && validThemeID(entry.Name()) {
				seen[entry.Name()] = true
			}
		}
	}
	ids := make([]string, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids, nil
}

func omarchyPath() string {
	if path := os.Getenv("OMARCHY_PATH"); path != "" {
		return path
	}
	return "/usr/share/omarchy"
}

func withoutEnv(env []string, key string) []string {
	prefix := key + "="
	out := make([]string, 0, len(env))
	for _, value := range env {
		if !strings.HasPrefix(value, prefix) {
			out = append(out, value)
		}
	}
	return out
}

func validThemeID(id string) bool {
	if id == "" || id[0] == '-' || id[0] == '.' {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

func containsTheme(ids []string, id string) bool {
	if !validThemeID(id) {
		return false
	}
	for _, candidate := range ids {
		if candidate == id {
			return true
		}
	}
	return false
}
