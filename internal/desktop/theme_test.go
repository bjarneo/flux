package desktop

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// realTheme is a colors.toml file of a current Omarchy theme with a border
// gradient.
const realTheme = `mode = "dark"

accent = "#d563fe"
selection = "#441e5d"
muted = "#665a8c"

background = "#0c031f"
dark_background = "#090217"
darker_background = "#060210"
lighter_background = "#190f2e"

foreground = "#e8e6ef"
dark_foreground = "#9b97a6"
light_foreground = "#cbc9d4"
bright_foreground = "#faf9fd"

hyprland_active_border = "rgba(21e4f8ee) rgba(d563feee) 45deg"
hyprland_inactive_border = "rgba(665a8caa)"

red = "#fe288f"
yellow = "#fde3c9"
orange = "#fe9f8b"
green = "#fc9afe"
cyan = "#21e4f8"
blue = "#bdff6d"
magenta = "#d563fe"
brown = "#7f5046"

bright_red = "#fe83af"
bright_yellow = "#fdf7f2"
bright_green = "#fed5fe"
bright_cyan = "#c1f6fe"
bright_blue = "#9698fd"
bright_magenta = "#e39efe"
`

// lightTheme is the colors.toml file of Flexoki Light. It has uppercase
// colors and no border.
const lightTheme = `mode = "light"

accent = "#205EA6"
selection = "#CECDC3"
muted = "#B7B5AC"

background = "#FFFCF0"
dark_background = "#f2efe4"
darker_background = "#e5e2d8"
lighter_background = "#E6E4D9"

foreground = "#100F0F"
dark_foreground = "#878580"
light_foreground = "#403E3C"
bright_foreground = "#100F0F"

red = "#D14D41"
yellow = "#D0A215"
blue = "#205EA6"
`

func TestParseThemeReal(t *testing.T) {
	th, err := ParseTheme([]byte(realTheme), "synthwave-aether-studio-2\n")
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "synthwave-aether-studio-2" || th.Mode != "dark" {
		t.Fatalf("name %q, mode %q", th.Name, th.Mode)
	}
	want := map[string]string{
		"accent": "#d563fe", "selection": "#441e5d", "muted": "#665a8c",
		"background": "#0c031f", "dark_background": "#090217", "darker_background": "#060210",
		"lighter_background": "#190f2e", "foreground": "#e8e6ef", "dark_foreground": "#9b97a6",
		"light_foreground": "#cbc9d4", "bright_foreground": "#faf9fd",
		"red": "#fe288f", "yellow": "#fde3c9", "orange": "#fe9f8b", "green": "#fc9afe",
		"cyan": "#21e4f8", "blue": "#bdff6d", "magenta": "#d563fe", "brown": "#7f5046",
		"bright_red": "#fe83af", "bright_yellow": "#fdf7f2", "bright_green": "#fed5fe",
		"bright_cyan": "#c1f6fe", "bright_blue": "#9698fd", "bright_magenta": "#e39efe",
	}
	if !reflect.DeepEqual(th.Colors, want) {
		t.Fatalf("colors %v", th.Colors)
	}
	wantBorder := &ThemeBorder{Colors: []string{"#21e4f8ee", "#d563feee"}, Angle: 45}
	if !reflect.DeepEqual(th.Border, wantBorder) {
		t.Fatalf("border %+v", th.Border)
	}
	// The JSON is the body of the flux.theme packet.
	b, err := json.Marshal(th)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	if err := json.Unmarshal(b, &body); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"name", "mode", "colors", "border"} {
		if _, ok := body[k]; !ok {
			t.Errorf("the body has no %q: %s", k, b)
		}
	}
	if !strings.Contains(string(b), `"border":{"colors":["#21e4f8ee","#d563feee"],"angle":45}`) {
		t.Errorf("border JSON: %s", b)
	}
}

func TestParseThemeLight(t *testing.T) {
	th, err := ParseTheme([]byte(lightTheme), "")
	if err != nil {
		t.Fatal(err)
	}
	if th.Mode != "light" || th.Name != "" {
		t.Fatalf("mode %q, name %q", th.Mode, th.Name)
	}
	if th.Colors["background"] != "#fffcf0" || th.Colors["accent"] != "#205ea6" {
		t.Fatalf("colors must be lowercase: %v", th.Colors)
	}
	if th.Border != nil {
		t.Fatalf("a theme without hyprland_active_border has no border: %+v", th.Border)
	}
	b, _ := json.Marshal(th)
	if strings.Contains(string(b), "border") {
		t.Fatalf("the body must leave out the border: %s", b)
	}
}

// A theme without a mode gets the mode from its background and its text.
func TestParseThemeModeFromColors(t *testing.T) {
	for _, tc := range []struct{ text, want string }{
		{"background = \"#fafafa\"\nforeground = \"#202020\"\n", "light"},
		{"background = \"#1a1b26\"\nforeground = \"#c0caf5\"\n", "dark"},
		{"mode = \"purple\"\nbackground = \"#ffffff\"\nforeground = \"#000000\"\n", "light"},
		{"mode = \"Dark\"\nbackground = \"#ffffff\"\nforeground = \"#000000\"\n", "dark"},
	} {
		th, err := ParseTheme([]byte(tc.text), "")
		if err != nil {
			t.Fatal(err)
		}
		if th.Mode != tc.want {
			t.Errorf("%q: mode %q, want %q", tc.text, th.Mode, tc.want)
		}
	}
}

func TestParseThemeBroken(t *testing.T) {
	for _, text := range []string{
		"",
		"\x00\x01\x02\xff",
		"background = \"#1a1b26\n",   // the string does not end
		"foreground = \"#c0caf5\"\n", // no background
		"background = \"#1a1b26\"\n", // no foreground
		"background = \"#1a1b2\"\nforeground = \"#c0caf5\"\n",       // 5 digits
		"background = \"#1a1b26ff\"\nforeground = \"#c0caf5\"\n",    // 8 digits
		"background = \"1a1b26\"\nforeground = \"#c0caf5\"\n",       // no #
		"background = 26\nforeground = \"#c0caf5\"\n",               // a number
		"background #1a1b26\nforeground #c0caf5\n",                  // no =
		"background = #1a1b26 # dark\nforeground = #c0caf5\n",       // a comment after a value without quotes
		"background = \"#1a1b26\"\nforeground = \"#c0caf5;\"\nx\n",  // a character that Omarchy does not accept
		"# background = \"#1a1b26\"\nforeground = \"#c0caf5\"\nx\n", // a comment
		"background = \"#1a1b26\"\nfore ground! = \"#c0caf5\"\nx\n", // a key that Omarchy does not accept
	} {
		if th, err := ParseTheme([]byte(text), ""); err == nil {
			t.Errorf("%q parsed: %+v", text, th)
		}
	}
}

// A file that is not valid TOML parses line by line, as in
// omarchy-theme-color. The last value of a key wins.
func TestParseThemeLines(t *testing.T) {
	// A key 2 times. The last value wins.
	text := realTheme + "accent = \"#123456\"\nbackground = \"#000000\"\n"
	if _, err := themeValues([]byte(text)); err == nil {
		t.Fatal("a key 2 times must not be valid TOML")
	}
	th, err := ParseTheme([]byte(text), "")
	if err != nil {
		t.Fatal(err)
	}
	if th.Colors["accent"] != "#123456" || th.Colors["background"] != "#000000" || th.Colors["red"] != "#fe288f" {
		t.Fatalf("colors %v", th.Colors)
	}
	wantBorder := &ThemeBorder{Colors: []string{"#21e4f8ee", "#d563feee"}, Angle: 45}
	if th.Mode != "dark" || !reflect.DeepEqual(th.Border, wantBorder) {
		t.Fatalf("mode %q, border %+v", th.Mode, th.Border)
	}

	// Values without quotes, quoted keys, comments, and lines that are
	// not "key = value".
	text = `mode = light
background = #FAFAFA
foreground = #202020
accent = '#7aa2f7' # a comment
"red" = "#ff0000"
# green = "#00ff00"
[colors]
x
blue = "#0000ff;"
cyan = "#00ffff"
cyan = "#00ffff;"
hyprland_active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
`
	th, err = ParseTheme([]byte(text), "")
	if err != nil {
		t.Fatal(err)
	}
	// A value that Omarchy does not accept drops out, and an earlier value
	// of the key stays.
	want := map[string]string{
		"background": "#fafafa", "foreground": "#202020", "accent": "#7aa2f7",
		"red": "#ff0000", "cyan": "#00ffff",
	}
	if !reflect.DeepEqual(th.Colors, want) {
		t.Fatalf("colors %v", th.Colors)
	}
	wantBorder = &ThemeBorder{Colors: []string{"#33ccffee", "#00ff99ee"}, Angle: 45}
	if th.Mode != "light" || !reflect.DeepEqual(th.Border, wantBorder) {
		t.Fatalf("mode %q, border %+v", th.Mode, th.Border)
	}

	// The line parser reads a valid file the same way as the TOML parser.
	for _, text := range []string{realTheme, lightTheme} {
		values, err := themeValues([]byte(text))
		if err != nil {
			t.Fatal(err)
		}
		if lines := themeLines([]byte(text)); !reflect.DeepEqual(lines, values) {
			t.Errorf("lines %v, TOML %v", lines, values)
		}
	}
}

// A color that is not well formed drops out. The rest of the theme stays.
func TestParseThemeDropsBadColors(t *testing.T) {
	text := `background = "#1a1b26"
foreground = "#c0caf5"
accent = "blue"
red = "#f7768e80"
green = " #9ece6a "
cyan = "#7dcfff"
unknown = "#123456"
hyprland_active_border = "rgba(nothex) 45deg"
`
	th, err := ParseTheme([]byte(text), "")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"background": "#1a1b26", "foreground": "#c0caf5", "green": "#9ece6a", "cyan": "#7dcfff"}
	if !reflect.DeepEqual(th.Colors, want) {
		t.Fatalf("colors %v", th.Colors)
	}
	if th.Border != nil {
		t.Fatalf("a border that does not parse must drop out: %+v", th.Border)
	}
}

func TestParseThemeName(t *testing.T) {
	text := "background = \"#1a1b26\"\nforeground = \"#c0caf5\"\n"
	th, err := ParseTheme([]byte(text), "tokyo\x1b[31m-night\nsecond line\n")
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "tokyo[31m-night" {
		t.Fatalf("name %q", th.Name)
	}
	th, _ = ParseTheme([]byte(text), strings.Repeat("a", 200))
	if len(th.Name) != maxThemeName {
		t.Fatalf("name has %d characters", len(th.Name))
	}
}

func TestParseBorder(t *testing.T) {
	colors := map[string]string{"accent": "#7aa2f7"}
	for _, tc := range []struct {
		spec   string
		colors []string
		angle  float64
	}{
		// 1 color, as in a theme with a plain border.
		{"rgba(33ccffee)", []string{"#33ccffee"}, 0},
		// 2 colors without an angle, as in Solitude.
		{"rgba(798186ee) rgba(caccccee)", []string{"#798186ee", "#caccccee"}, 0},
		// 2 colors with an angle, as in Hackerman.
		{"rgba(26a269ee) rgba(2ec27eee) 45deg", []string{"#26a269ee", "#2ec27eee"}, 45},
		// 3 colors in 3 forms.
		{"rgb(FF0000) #00ff00 0xee0000ff 90deg", []string{"#ff0000ff", "#00ff00ff", "#0000ffee"}, 90},
		// A color of the theme, and the decimal form.
		{"accent rgba(255,0,0,0.5) rgb(0,128,255)", []string{"#7aa2f7ff", "#ff000080", "#0080ffff"}, 0},
		{"#11223344 rgba(aabbcc)", []string{"#11223344", "#aabbccff"}, 0},
		{"  rgba(33ccffee)   rgba(00ff99ee)  -90deg ", []string{"#33ccffee", "#00ff99ee"}, 270},
		{"rgba(33ccffee) 450deg", []string{"#33ccffee"}, 90},
		{"rgba(33ccffee) 22.5deg", []string{"#33ccffee"}, 22.5},
		{"rgba(33ccffee) -0deg", []string{"#33ccffee"}, 0},
	} {
		b := parseBorder(tc.spec, colors)
		if b == nil {
			t.Errorf("%q did not parse", tc.spec)
			continue
		}
		if !reflect.DeepEqual(b.Colors, tc.colors) || b.Angle != tc.angle {
			t.Errorf("%q: colors %v, angle %v", tc.spec, b.Colors, b.Angle)
		}
	}
}

func TestParseBorderBroken(t *testing.T) {
	colors := map[string]string{"accent": "#7aa2f7"}
	for _, spec := range []string{
		"",
		"   ",
		"45deg",
		"rgba(33ccffee) 45deg rgba(00ff99ee)", // the angle is not last
		"rgba(33ccffee) 45deg 90deg",
		"rgba(33ccffe)",
		"rgba(33ccffeeff)",
		"rgba(gggggggg)",
		"rgb(256,0,0)",
		"rgba(255,0,0,1.5)",
		"rgba(255, 0, 0, 0.5)", // spaces split the color
		"0x33ccff",
		"#33ccf",
		"nocolor",
		"red",                         // red is not a color of this theme map
		"rgba(33ccffee) 45.deg",       // not a number
		"rgba(33ccffee) 1234567deg",   // too long
		"rgba(33ccffee) 45 deg",       // the unit is a separate part
		"url(x) rgba(33ccffee) 45deg", // an unknown form
		strings.Repeat("rgba(33ccffee) ", 11),
	} {
		if b := parseBorder(spec, colors); b != nil {
			t.Errorf("%q parsed: %+v", spec, b)
		}
	}
	// 10 colors is the limit of Hyprland.
	if b := parseBorder(strings.Repeat("rgba(33ccffee) ", 10)+"10deg", colors); b == nil || len(b.Colors) != 10 {
		t.Errorf("10 colors must parse: %+v", b)
	}
}

// themeDirs makes the Omarchy state folder in a temporary folder and
// returns the path of colors.toml.
func themeDirs(t *testing.T) string {
	t.Helper()
	current := filepath.Join(t.TempDir(), "current")
	if err := os.MkdirAll(filepath.Join(current, "theme"), 0o755); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(current, "theme", "colors.toml")
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadTheme(t *testing.T) {
	path := themeDirs(t)
	if _, err := LoadTheme(path); err == nil {
		t.Fatal("a missing file must give an error")
	}
	writeFile(t, path, realTheme)
	th, err := LoadTheme(path)
	if err != nil {
		t.Fatal(err)
	}
	if th.Name != "" {
		t.Fatalf("without theme.name the name is empty, not %q", th.Name)
	}
	writeFile(t, filepath.Join(filepath.Dir(filepath.Dir(path)), "theme.name"), "synthwave-aether-studio-2\n")
	if th, err = LoadTheme(path); err != nil || th.Name != "synthwave-aether-studio-2" {
		t.Fatalf("name %q, err %v", th.Name, err)
	}
	writeFile(t, path, realTheme+strings.Repeat("# padding\n", maxThemeFile/10+1))
	if _, err := LoadTheme(path); err == nil {
		t.Fatal("a file larger than the limit must give an error")
	}
}

// waitCalls waits until n reaches at least want.
func waitCalls(t *testing.T, n *atomic.Int32, want int32, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for n.Load() < want {
		if time.Now().After(deadline) {
			t.Fatalf("no call after %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestWatchTheme changes the theme the way omarchy-theme-set does, and
// writes the file in place the way a theme editor does. Each change gives
// a call, and the poll is too slow to give one.
func TestWatchTheme(t *testing.T) {
	path := themeDirs(t)
	writeFile(t, path, realTheme)
	current := filepath.Dir(filepath.Dir(path))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int32
	done := make(chan struct{})
	go func() {
		watchTheme(ctx, path, time.Hour, 50*time.Millisecond, func() { calls.Add(1) })
		close(done)
	}()
	// The watch starts on the goroutine. A short wait lets it add the folders.
	time.Sleep(100 * time.Millisecond)

	// A theme switch: a new folder, the removal of the old one, the move,
	// and the name.
	next := filepath.Join(current, "next-theme")
	if err := os.MkdirAll(next, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(next, "colors.toml"), lightTheme)
	if err := os.RemoveAll(filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(next, filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(current, "theme.name"), "flexoki-light\n")
	waitCalls(t, &calls, 1, "a theme switch")
	time.Sleep(200 * time.Millisecond)
	if n := calls.Load(); n > 2 {
		t.Errorf("a theme switch gave %d calls", n)
	}

	// The new theme folder has a watch too.
	before := calls.Load()
	writeFile(t, path, realTheme)
	waitCalls(t, &calls, before+1, "a write in the new theme folder")

	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the watch did not stop")
	}
}

// Without a folder to watch, the poll still finds the theme.
func TestWatchThemePoll(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing", "current", "theme", "colors.toml")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var calls atomic.Int32
	go watchTheme(ctx, path, 20*time.Millisecond, time.Hour, func() { calls.Add(1) })
	waitCalls(t, &calls, 2, "2 polls")
}
