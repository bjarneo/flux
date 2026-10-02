package omarchytheme

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const CapabilityV2 = "flux.omarchy_theme.v2"

var revisionPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var roundingPattern = regexp.MustCompile(`(?m)^\s*(?:rounding|corner_radius)\s*=\s*([0-9]+)(?:\s*[,;]?\s*(?:#.*|--.*)?)$`)

func ValidRevision(s string) bool { return revisionPattern.MatchString(s) }

type Geometry struct {
	CornerRadius int `json:"cornerRadius"`
}
type fileGeneration struct {
	Path         string
	Dev, Ino     uint64
	Mtime, Ctime unix.Timespec
	Target       string
}

func (r Reader) runtimePath() string {
	if r.RuntimeDir != "" {
		return r.RuntimeDir
	}
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return dir
	}
	return "/tmp"
}

// ReadRevision projects v2 while keeping Read's strict legacy wire untouched.
// The canonical setter holds this same lock through its filesystem commit.
func (r Reader) ReadRevision() (Catalog, bool) {
	fd, err := openSafe(filepath.Join(r.runtimePath(), "omarchy-theme-set.lock"), unix.O_RDWR|unix.O_CREAT)
	if err != nil {
		return Catalog{}, false
	}
	defer unix.Close(fd)
	var s unix.Stat_t
	if unix.Fstat(fd, &s) != nil || s.Mode&unix.S_IFMT != unix.S_IFREG || s.Nlink != 1 || s.Uid != uint32(os.Geteuid()) {
		return Catalog{}, false
	}
	if unix.Flock(fd, unix.LOCK_SH|unix.LOCK_NB) != nil {
		return Catalog{}, false
	}
	return r.readRevision()
}

// ReadUnderHeldLock verifies inherited canonical fd9, retains its exclusive
// flock, then reads without reopening a competing shared lock. It is used by
// the fixed child CAS helper immediately before canonical theme staging.
func (r Reader) ReadUnderHeldLock(fd int) (Catalog, bool) {
	var held, expected unix.Stat_t
	if unix.Fstat(fd, &held) != nil || held.Mode&unix.S_IFMT != unix.S_IFREG || held.Nlink != 1 || held.Uid != uint32(os.Geteuid()) {
		return Catalog{}, false
	}
	check, err := openSafe(filepath.Join(r.runtimePath(), "omarchy-theme-set.lock"), unix.O_RDWR)
	if err != nil {
		return Catalog{}, false
	}
	defer unix.Close(check)
	if unix.Fstat(check, &expected) != nil || expected.Dev != held.Dev || expected.Ino != held.Ino || unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB) != nil {
		return Catalog{}, false
	}
	return r.readRevision()
}

func generation(path string, link bool) (fileGeneration, bool) {
	g := fileGeneration{Path: path}
	var s unix.Stat_t
	if link {
		if unix.Lstat(path, &s) != nil || s.Mode&unix.S_IFMT != unix.S_IFLNK {
			return g, false
		}
		target, err := os.Readlink(path)
		if err != nil || len(target) > 4096 {
			return g, false
		}
		g.Target = target
	} else {
		fd, err := openSafe(path, unix.O_RDONLY)
		if err != nil {
			return g, false
		}
		err = unix.Fstat(fd, &s)
		unix.Close(fd)
		if err != nil || s.Mode&unix.S_IFMT != unix.S_IFREG {
			return g, false
		}
	}
	g.Dev, g.Ino, g.Mtime, g.Ctime = s.Dev, s.Ino, s.Mtim, s.Ctim
	return g, true
}

func (r Reader) readRevision() (Catalog, bool) {
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	name, ok := generation(filepath.Join(state, "theme.name"), false)
	if !ok {
		return Catalog{}, false
	}
	c, ok := r.readCurrent()
	if !ok {
		return Catalog{}, false
	}
	var current Palette
	for _, t := range c.Themes {
		if t.ID == c.Current {
			current = t.Palette
		}
	}
	current.Geometry = &Geometry{CornerRadius: 0}
	color, ok := generation(filepath.Join(state, "theme/colors.toml"), false)
	if !ok {
		for _, root := range []string{r.SystemThemes, filepath.Join(r.Home, ".config/omarchy/themes")} {
			if g, found := generation(filepath.Join(root, c.Current, "colors.toml"), false); found {
				color, ok = g, true
			}
		}
	}
	if !ok {
		return Catalog{}, false
	}
	files := []fileGeneration{name, color}
	if background, found := generation(filepath.Join(state, "background"), true); found {
		files = append(files, background)
		path := background.Target
		if !filepath.IsAbs(path) {
			path = filepath.Join(state, path)
		}
		path = filepath.Clean(path)
		// A local manual selection may live outside the theme roots. Include
		// that exact canonical target's generation so in-place changes also
		// supersede old originals and pending remote CAS operations.
		if source, valid := generation(path, false); valid {
			files = append(files, source)
		}
	}
	// Only parse literal configuration; theme files never run to obtain geometry.
	for _, path := range []string{filepath.Join(state, "theme/hyprland.lua"), filepath.Join(state, "theme/hyprland.conf"), filepath.Join(r.Home, ".config/hypr/looknfeel.lua"), filepath.Join(r.Home, ".config/hypr/looknfeel.conf"), filepath.Join(r.Home, ".local/share/omarchy/default/hypr/looknfeel.lua"), filepath.Join(filepath.Dir(r.SystemThemes), "default/hypr/looknfeel.lua")} {
		raw, err := readRegular(path, 16<<10)
		if err != nil {
			continue
		}
		match := roundingPattern.FindSubmatch(raw)
		if len(match) == 2 {
			n, err := strconv.Atoi(string(match[1]))
			if err != nil || n > 128 {
				continue
			}
			current.Geometry = &Geometry{CornerRadius: n}
			if g, found := generation(path, false); found {
				files = append(files, g)
			}
			break
		}
	}
	// Observe generations twice to reject concurrent uncooperative edits too.
	for _, before := range files {
		after, valid := generation(before.Path, before.Target != "")
		if !valid || after != before {
			return Catalog{}, false
		}
	}
	for role, value := range current.Colors {
		current.Colors[role] = strings.ToLower(value)
	}
	canonical, err := json.Marshal(struct {
		Current string
		Palette Palette
		Files   []fileGeneration
	}{c.Current, current, files})
	if err != nil {
		return Catalog{}, false
	}
	hash := sha256.Sum256(canonical)
	c.Version, c.Revision = 2, hex.EncodeToString(hash[:])
	for i := range c.Themes {
		if c.Themes[i].ID == c.Current {
			c.Themes[i].Palette = current
		}
	}
	if raw, err := json.Marshal(c); err != nil || len(raw) > MaxBody {
		return Catalog{}, false
	}
	return c, true
}
