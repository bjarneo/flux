package desktop

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/BurntSushi/toml"
	"golang.org/x/sys/unix"

	"flux/internal/proto"
)

// maxThemeFile is the largest colors.toml file that fluxd reads. The files
// of Omarchy have less than 2 KiB.
const maxThemeFile = 64 << 10

// maxThemeName is the longest theme name that fluxd sends.
const maxThemeName = 64

// maxBorderColors is the largest number of colors in a Hyprland border
// gradient.
const maxBorderColors = 10

// themePoll is the time between 2 reads of the theme file when no change
// event comes. The poll is a last check for a change that the watch misses,
// as in the desktop window.
const themePoll = 30 * time.Second

// themeSettle is the quiet time after the last change event before fluxd
// reads the theme again. A theme switch removes the theme folder, moves the
// new folder into its place, and then writes theme.name.
const themeSettle = 500 * time.Millisecond

// themeEvents are the inotify events that can change the theme file.
const themeEvents = unix.IN_CLOSE_WRITE | unix.IN_CREATE | unix.IN_DELETE |
	unix.IN_MOVED_FROM | unix.IN_MOVED_TO | unix.IN_DELETE_SELF | unix.IN_MOVE_SELF

// themeColorKeys are the keys of colors.toml that fluxd sends. The file
// of a current Omarchy theme has the named colors. A theme that Omarchy
// made from an Alacritty file also has color0 to color15.
var themeColorKeys = []string{
	"accent", "selection", "muted", "cursor",
	"background", "dark_background", "darker_background", "lighter_background",
	"foreground", "dark_foreground", "light_foreground", "bright_foreground",
	"selection_foreground", "selection_background",
	"red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown",
	"bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta",
	"color0", "color1", "color2", "color3", "color4", "color5", "color6", "color7",
	"color8", "color9", "color10", "color11", "color12", "color13", "color14", "color15",
}

// Theme is the active Omarchy theme. It is the body of a flux.theme packet.
type Theme struct {
	// Name is the theme name from theme.name, such as "tokyo-night", or ""
	// when the file is missing.
	Name string `json:"name"`
	// Mode is "dark" or "light".
	Mode string `json:"mode"`
	// Colors maps each key of themeColorKeys that the file sets to a
	// "#rrggbb" value. background and foreground are always set.
	Colors map[string]string `json:"colors"`
	// Border is the active window border of Hyprland. It is nil when the
	// file has no hyprland_active_border, or when the value does not parse.
	Border *ThemeBorder `json:"border,omitempty"`
}

// ThemeBorder is a Hyprland border gradient.
type ThemeBorder struct {
	// Colors has 1 to 10 "#rrggbbaa" values.
	Colors []string `json:"colors"`
	// Angle is the angle of the gradient in degrees, from 0 up to but not
	// including 360. A border without an angle has 0.
	Angle float64 `json:"angle"`
}

// ThemePath returns the colors.toml file of the active Omarchy theme. The
// desktop window reads the same file.
func ThemePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "omarchy", "current", "theme", "colors.toml")
}

// LoadTheme reads the colors.toml file at path, and the theme name from
// theme.name next to the theme folder. It returns an error when the file
// is missing or does not parse.
func LoadTheme(path string) (*Theme, error) {
	data, err := readLimited(path, maxThemeFile)
	if err != nil {
		return nil, err
	}
	name, _ := readLimited(filepath.Join(filepath.Dir(filepath.Dir(path)), "theme.name"), 1024)
	return ParseTheme(data, string(name))
}

// readLimited reads the file at path. It returns an error when the file
// has more than max bytes.
func readLimited(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("%s has more than %d bytes", path, max)
	}
	return data, nil
}

// ParseTheme parses the text of a colors.toml file. name is the content of
// theme.name. When the text is not valid TOML, ParseTheme reads it line by
// line, as Omarchy does. ParseTheme returns an error when background or
// foreground is not a "#rrggbb" color. It drops each other color that is
// not a "#rrggbb" color.
func ParseTheme(data []byte, name string) (*Theme, error) {
	raw, tomlErr := themeValues(data)
	t := &Theme{Name: themeName(name), Colors: map[string]string{}}
	for _, k := range themeColorKeys {
		if c, ok := hexColor(raw[k]); ok {
			t.Colors[k] = c
		}
	}
	bg, fg := t.Colors["background"], t.Colors["foreground"]
	if bg == "" || fg == "" {
		if tomlErr != nil {
			return nil, fmt.Errorf("colors.toml: %w", tomlErr)
		}
		return nil, errors.New("colors.toml has no valid background and foreground")
	}
	switch m := strings.ToLower(strings.TrimSpace(raw["mode"])); m {
	case "dark", "light":
		t.Mode = m
	default:
		// A theme without a mode is light when its background is lighter
		// than its text.
		t.Mode = "dark"
		if luminance(bg) > luminance(fg) {
			t.Mode = "light"
		}
	}
	if s, ok := raw["hyprland_active_border"]; ok {
		t.Border = parseBorder(s, t.Colors)
	}
	return t, nil
}

// themeValues returns the top-level string values of a colors.toml file.
// When the text is not valid TOML, themeValues returns the values of
// themeLines and the TOML error.
func themeValues(data []byte) (map[string]string, error) {
	var raw map[string]any
	if _, err := toml.Decode(string(data), &raw); err != nil {
		return themeLines(data), err
	}
	values := make(map[string]string, len(raw))
	for k, v := range raw {
		if s, ok := v.(string); ok {
			values[k] = s
		}
	}
	return values, nil
}

var (
	// themeKeyRe and themeValueRe are the characters that
	// omarchy-theme-color accepts in a key and in a value.
	themeKeyRe   = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)
	themeValueRe = regexp.MustCompile(`^[A-Za-z0-9#(),._+/% -]*$`)
)

// themeLines reads a colors.toml file line by line, as omarchy-theme-color
// does. The phone then gets the theme that Omarchy applies to the desktop,
// also from a file that is not valid TOML. Examples are a file with a key
// 2 times and a file with a value without quotes.
//
// Each line is "key = value". The key loses its quotes and its spaces. A
// value with a quote is the text between its first 2 quotes. A value
// without quotes loses the spaces at its ends. The last value of a key
// wins. themeLines skips a line without "=", a comment, and a line with a
// key or a value that has other characters.
func themeLines(data []byte) map[string]string {
	values := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.Map(func(r rune) rune {
			if r == '"' || r == '\'' || unicode.IsSpace(r) {
				return -1
			}
			return r
		}, key)
		if !themeKeyRe.MatchString(key) {
			continue
		}
		if i := strings.IndexAny(value, `"'`); i >= 0 {
			value = value[i+1:]
			if j := strings.IndexAny(value, `"'`); j >= 0 {
				value = value[:j]
			}
		} else {
			value = strings.TrimSpace(value)
		}
		if !themeValueRe.MatchString(value) {
			continue
		}
		values[key] = value
	}
	return values
}

// themeName returns the first line of theme.name without control
// characters, limited to maxThemeName characters.
func themeName(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return proto.CleanText(line, maxThemeName)
}

var (
	hexColorRe = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
	angleRe    = regexp.MustCompile(`^-?[0-9]{1,6}(\.[0-9]{1,6})?deg$`)
	// hyprHexRe matches rgba(rrggbbaa), rgba(rrggbb), rgb(rrggbb), and
	// rgb(rrggbbaa), as the Omarchy theme templates do.
	hyprHexRe = regexp.MustCompile(`(?i)^rgba?\(([0-9a-f]{6})([0-9a-f]{2})?\)$`)
	// hyprDecRe matches rgb(r,g,b) and rgba(r,g,b,a) with an alpha from 0
	// to 1.
	hyprDecRe = regexp.MustCompile(`(?i)^rgba?\(([0-9]{1,3}),([0-9]{1,3}),([0-9]{1,3})(?:,([0-9]*\.?[0-9]+))?\)$`)
	// hashHexRe matches #rrggbb and #rrggbbaa.
	hashHexRe = regexp.MustCompile(`^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$`)
	// legacyHexRe matches the Hyprland legacy form 0xaarrggbb.
	legacyHexRe = regexp.MustCompile(`^0x([0-9a-fA-F]{2})([0-9a-fA-F]{6})$`)
)

// hexColor returns s as a lowercase "#rrggbb" color. ok is false when s
// is not a "#rrggbb" color.
func hexColor(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if !hexColorRe.MatchString(s) {
		return "", false
	}
	return strings.ToLower(s), true
}

// parseBorder parses a hyprland_active_border value, such as
// "rgba(33ccffee) rgba(00ff99ee) 45deg". A part can also name a color of
// the theme, such as "accent". parseBorder returns nil when a part does
// not parse, or when the value has no color or more than 10 colors.
func parseBorder(spec string, colors map[string]string) *ThemeBorder {
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return nil
	}
	b := &ThemeBorder{Colors: []string{}}
	// Only the last part can be the angle.
	if a, ok := parseAngle(parts[len(parts)-1]); ok {
		b.Angle = a
		parts = parts[:len(parts)-1]
	}
	if len(parts) == 0 || len(parts) > maxBorderColors {
		return nil
	}
	for _, p := range parts {
		c, ok := borderColor(p, colors)
		if !ok {
			return nil
		}
		b.Colors = append(b.Colors, c)
	}
	return b
}

// parseAngle parses an angle such as "45deg" and returns it from 0 up to
// but not including 360.
func parseAngle(s string) (float64, bool) {
	if !angleRe.MatchString(s) {
		return 0, false
	}
	a, err := strconv.ParseFloat(strings.TrimSuffix(s, "deg"), 64)
	if err != nil {
		return 0, false
	}
	a = math.Mod(a, 360)
	if a < 0 {
		a += 360
	}
	if a == 0 {
		// The JSON of -0 is "-0".
		a = 0
	}
	return a, true
}

// borderColor returns 1 color of a border gradient as a lowercase
// "#rrggbbaa" color.
func borderColor(s string, colors map[string]string) (string, bool) {
	if m := hyprHexRe.FindStringSubmatch(s); m != nil {
		return "#" + strings.ToLower(m[1]+alphaOr(m[2])), true
	}
	if m := hashHexRe.FindStringSubmatch(s); m != nil {
		return "#" + strings.ToLower(m[1]+alphaOr(m[2])), true
	}
	if m := legacyHexRe.FindStringSubmatch(s); m != nil {
		return "#" + strings.ToLower(m[2]+m[1]), true
	}
	if m := hyprDecRe.FindStringSubmatch(s); m != nil {
		var rgb [3]int
		for i := range rgb {
			n, err := strconv.Atoi(m[i+1])
			if err != nil || n > 255 {
				return "", false
			}
			rgb[i] = n
		}
		alpha := 255
		if m[4] != "" {
			a, err := strconv.ParseFloat(m[4], 64)
			if err != nil || a > 1 {
				return "", false
			}
			alpha = int(math.Round(a * 255))
		}
		return fmt.Sprintf("#%02x%02x%02x%02x", rgb[0], rgb[1], rgb[2], alpha), true
	}
	if c, ok := colors[s]; ok {
		return c + "ff", true
	}
	return "", false
}

// alphaOr returns a, or "ff" when a is empty.
func alphaOr(a string) string {
	if a == "" {
		return "ff"
	}
	return a
}

// luminance returns the relative luminance of a "#rrggbb" color, as WCAG
// defines it.
func luminance(c string) float64 {
	channel := func(h string) float64 {
		n, _ := strconv.ParseUint(h, 16, 8)
		v := float64(n) / 255
		if v <= 0.03928 {
			return v / 12.92
		}
		return math.Pow((v+0.055)/1.055, 2.4)
	}
	return 0.2126*channel(c[1:3]) + 0.7152*channel(c[3:5]) + 0.0722*channel(c[5:7])
}

// WatchTheme calls changed when the theme file at path can have changed:
// after a change in the theme folder or in its parent folder, and at each
// poll. A burst of changes gives 1 call. WatchTheme returns when ctx ends.
// changed runs on the goroutine of WatchTheme.
func WatchTheme(ctx context.Context, path string, changed func()) {
	watchTheme(ctx, path, themePoll, themeSettle, changed)
}

func watchTheme(ctx context.Context, path string, poll, settle time.Duration, changed func()) {
	// The watch on the parent folder catches a theme switch, which replaces
	// the theme folder.
	dirs := []string{filepath.Dir(path), filepath.Dir(filepath.Dir(path))}
	events := make(chan struct{}, 1)
	// Without inotify, w is nil, and only the poll finds a change.
	w, _ := newDirWatch(events)
	defer w.close()
	w.add(dirs)
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	timer := time.NewTimer(settle)
	timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-events:
			timer.Reset(settle)
			continue
		case <-timer.C:
		case <-ticker.C:
		}
		// A theme switch gives a new theme folder, so add the watches again.
		w.add(dirs)
		changed()
	}
}

// dirWatch is an inotify watch on folders.
type dirWatch struct {
	f *os.File
}

// newDirWatch starts an inotify watch. Each read of events puts a value on
// events, without a wait.
func newDirWatch(events chan<- struct{}) (*dirWatch, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	// The file is non-blocking, so a read waits in the Go poller, and close
	// stops the read.
	w := &dirWatch{f: os.NewFile(uintptr(fd), "inotify")}
	go func() {
		buf := make([]byte, 4096)
		for {
			if _, err := w.f.Read(buf); err != nil {
				return
			}
			select {
			case events <- struct{}{}:
			default:
			}
		}
	}()
	return w, nil
}

// add watches each folder that exists. A folder that the watch has already
// keeps its watch. A nil watch adds nothing.
func (w *dirWatch) add(dirs []string) {
	if w == nil {
		return
	}
	rc, err := w.f.SyscallConn()
	if err != nil {
		return
	}
	_ = rc.Control(func(fd uintptr) {
		for _, d := range dirs {
			_, _ = unix.InotifyAddWatch(int(fd), d, themeEvents)
		}
	})
}

func (w *dirWatch) close() {
	if w != nil {
		_ = w.f.Close()
	}
}
