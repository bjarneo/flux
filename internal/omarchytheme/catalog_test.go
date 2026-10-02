package omarchytheme

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

func put(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestCatalogReadsStockUserAndAppliedPalette(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.SystemThemes, "tokyo-night", "colors.toml"), "mode = \"dark\"\nbackground = \"#1A1B26\"\nforeground = \"#c0caf5\"\naccent = \"#7aa2f7\"\n")
	put(t, filepath.Join(r.Home, ".config/omarchy/themes/tokyo-night/colors.toml"), "mode = \"light\"\nbackground = \"#ffffff\"\nforeground = \"#000000\"\naccent = \"#123abc\"\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "tokyo-night\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme/colors.toml"), "mode = \"light\"\nbackground = \"#eeeeee\"\nforeground = \"#111111\"\naccent = \"#abcdef\"\n")
	c, ok := r.Read()
	if !ok || c.Kind != "catalog" || c.Current != "tokyo-night" || len(c.Themes) != 1 {
		t.Fatalf("catalog: %+v, %v", c, ok)
	}
	p := c.Themes[0].Palette
	if p.Name != "tokyo-night" || p.Mode != "light" || p.Source != "omarchy" || p.Colors["background"] != "#eeeeee" || p.Colors["accent"] != "#abcdef" {
		t.Fatalf("palette: %+v", p)
	}
}

func TestCatalogCurrentStagedLegacyPalette(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "legacy\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme/colors.toml"), "bg = \"#101010\"\nfg = \"#eeeeee\"\ncolor4 = \"#424242\"\n")
	c, ok := r.Read()
	if !ok || c.Current != "legacy" || len(c.Themes) != 1 || c.Themes[0].Palette.Colors["accent"] != "#424242" {
		t.Fatalf("staged legacy: %+v %v", c, ok)
	}
}

func TestCatalogLightMarkerAndUserNames(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "My Theme\n")
	dir := filepath.Join(r.Home, ".config/omarchy/themes/My Theme")
	put(t, filepath.Join(dir, "colors.toml"), "background = \"#ffffff\"\nforeground = \"#000000\"\naccent = \"#123456\"\n")
	put(t, filepath.Join(dir, "light.mode"), "")
	c, ok := r.Read()
	if !ok || c.Themes[0].Palette.Mode != "light" {
		t.Fatalf("marker: %+v %v", c, ok)
	}
}

func TestCatalogNoInstallOrInvalidCurrent(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	if _, ok := r.Read(); ok {
		t.Fatal("non-Omarchy host emitted catalog")
	}
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#000000\"\nforeground = \"#ffffff\"\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "../../etc/passwd\n")
	if _, ok := r.Read(); ok {
		t.Fatal("invalid current was accepted")
	}
}

func TestCatalogEntryLimitRetainsCurrent(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "zz-final\n")
	for i := 0; i < MaxThemes+10; i++ {
		id := fmt.Sprintf("theme-%02d", i)
		put(t, filepath.Join(r.SystemThemes, id, "colors.toml"), "background = \"#000000\"\nforeground = \"#ffffff\"\naccent = \"#123456\"\n")
	}
	put(t, filepath.Join(r.SystemThemes, "zz-final/colors.toml"), "background = \"#000000\"\nforeground = \"#ffffff\"\naccent = \"#123456\"\n")
	c, ok := r.Read()
	if !ok || len(c.Themes) != MaxThemes {
		t.Fatalf("bounded catalog: %+v %v", c, ok)
	}
	found := false
	for _, v := range c.Themes {
		if v.ID == c.Current {
			found = true
		}
	}
	if !found {
		t.Fatal("active theme truncated")
	}
}

func TestCatalogBoundsAndSymlinks(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#000000\"\nforeground = \"#ffffff\"\naccent = \"#123456\"\n")
	put(t, filepath.Join(root, "outside/colors.toml"), "background = \"#badbad\"\nforeground = \"#ffffff\"\n")
	if err := os.Symlink(filepath.Join(root, "outside"), filepath.Join(r.SystemThemes, "evil")); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Join(r.SystemThemes, "huge/colors.toml"), strings.Repeat("x", 17000))
	put(t, filepath.Join(r.SystemThemes, "invalid/colors.toml"), "background = \"#zzzzzz\"\nforeground = \"#ffffff\"\n")
	c, ok := r.Read()
	if !ok || len(c.Themes) != 1 || c.Themes[0].ID != "safe" {
		t.Fatalf("catalog: %+v, %v", c, ok)
	}
}

func TestCatalogRejectsSymlinkedAncestors(t *testing.T) {
	for _, part := range []string{"state", "system"} {
		t.Run(part, func(t *testing.T) {
			root := t.TempDir()
			r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
			palette := "background = \"#123456\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n"
			put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
			put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), palette)
			switch part {
			case "state":
				outside := filepath.Join(root, "outside-state")
				put(t, filepath.Join(outside, "theme.name"), "safe\n")
				if err := os.RemoveAll(filepath.Join(r.Home, ".local/state/omarchy/current")); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, filepath.Join(r.Home, ".local/state/omarchy/current")); err != nil {
					t.Fatal(err)
				}
			case "system":
				outside := filepath.Join(root, "outside-system")
				put(t, filepath.Join(outside, "safe/colors.toml"), palette)
				if err := os.RemoveAll(r.SystemThemes); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, r.SystemThemes); err != nil {
					t.Fatal(err)
				}
			}
			if c, ok := r.Read(); ok {
				t.Fatalf("followed symlinked %s ancestor: %+v", part, c)
			}
		})
	}
}

func TestCatalogRejectsSymlinkedAppliedPaletteAncestor(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	outside := filepath.Join(root, "outside")
	put(t, filepath.Join(outside, "colors.toml"), "background = \"#222222\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	if err := os.Symlink(outside, filepath.Join(r.Home, ".local/state/omarchy/current/theme")); err != nil {
		t.Fatal(err)
	}
	c, ok := r.Read()
	if !ok || len(c.Themes) != 1 || c.Themes[0].Palette.Colors["background"] != "#111111" {
		t.Fatalf("followed applied palette symlink: %+v %v", c, ok)
	}
}

func TestCatalogRejectsSymlinkedMarkerAncestor(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	outside := filepath.Join(root, "outside")
	put(t, filepath.Join(outside, "light.mode"), "")
	// A marker that is itself a symlink must not select light mode.
	if err := os.Symlink(filepath.Join(outside, "light.mode"), filepath.Join(r.SystemThemes, "safe/light.mode")); err != nil {
		t.Fatal(err)
	}
	c, ok := r.Read()
	if !ok || c.Themes[0].Palette.Mode != "dark" {
		t.Fatalf("followed marker symlink: %+v %v", c, ok)
	}
}

func TestCatalogTrimsWireBytesKeepingCurrent(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "zz-current\n")
	var palette strings.Builder
	for role := range colorRoles {
		fmt.Fprintf(&palette, "%s = \"#abcdef\"\n", role)
	}
	for i := 0; i < MaxThemes-1; i++ {
		put(t, filepath.Join(r.SystemThemes, fmt.Sprintf("theme-%02d", i), "colors.toml"), palette.String())
	}
	put(t, filepath.Join(r.SystemThemes, "zz-current/colors.toml"), palette.String())
	c, ok := r.Read()
	if !ok {
		t.Fatal("catalog missing")
	}
	b, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	if len(b) > MaxBody || len(c.Themes) == MaxThemes || len(c.Themes) < 2 {
		t.Fatalf("catalog not byte bounded: themes=%d bytes=%d", len(c.Themes), len(b))
	}
	found := false
	for _, theme := range c.Themes {
		if theme.ID == c.Current {
			found = true
		}
	}
	if !found {
		t.Fatal("current omitted")
	}
}

func TestCatalogStopsWhenThemeKeepsSwitching(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	name := filepath.Join(r.Home, ".local/state/omarchy/current/theme.name")
	put(t, name, "first\n")
	put(t, filepath.Join(r.SystemThemes, "first/colors.toml"), "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	put(t, filepath.Join(r.SystemThemes, "second/colors.toml"), "background = \"#222222\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	count := 0
	r.afterNameRead = func() {
		count++
		if count > 5 {
			t.Fatal("unbounded retries")
		}
		if count%2 == 1 {
			put(t, name, "second\n")
		} else {
			put(t, name, "first\n")
		}
	}
	if c, ok := r.Read(); ok || count != 3 {
		t.Fatalf("unstable snapshot emitted: %+v %v (reads=%d)", c, ok, count)
	}
}

func TestCatalogRetriesThemeSwitch(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	name := filepath.Join(r.Home, ".local/state/omarchy/current/theme.name")
	colors := filepath.Join(r.Home, ".local/state/omarchy/current/theme/colors.toml")
	put(t, name, "first\n")
	put(t, colors, "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	count := 0
	r.afterNameRead = func() {
		count++
		if count != 1 {
			return
		}
		put(t, colors, "background = \"#222222\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
		put(t, name, "second\n")
	}
	c, ok := r.Read()
	if !ok || c.Current != "second" || len(c.Themes) != 1 || c.Themes[0].Palette.Colors["background"] != "#222222" {
		t.Fatalf("mixed switch: %+v %v (reads=%d)", c, ok, count)
	}
}

func TestCatalogDoesNotPublishPaletteBeforeNameSwitch(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	name := filepath.Join(r.Home, ".local/state/omarchy/current/theme.name")
	colors := filepath.Join(r.Home, ".local/state/omarchy/current/theme/colors.toml")
	first := "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n"
	second := "background = \"#222222\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n"
	put(t, name, "first\n")
	put(t, colors, first)
	put(t, filepath.Join(r.SystemThemes, "first/colors.toml"), first)
	put(t, filepath.Join(r.SystemThemes, "second/colors.toml"), second)
	lock, err := os.OpenFile(filepath.Join(root, "omarchy-theme-set.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	put(t, colors, second) // Omarchy publishes the palette before the name.
	if c, ok := r.Read(); ok {
		t.Fatalf("published name from old theme with new applied colors: %+v", c)
	}
	put(t, name, "second\n")
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	c, ok := r.Read()
	if !ok || c.Current != "second" || len(c.Themes) != 2 {
		t.Fatalf("missing completed switch: %+v %v", c, ok)
	}
	for _, theme := range c.Themes {
		if theme.ID == c.Current && theme.Palette.Colors["background"] != "#222222" {
			t.Fatalf("incorrect applied colors after switch: %+v", theme)
		}
	}
}

func TestCatalogLockRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	outside := filepath.Join(root, "outside")
	put(t, outside, "untouched")
	if err := os.Symlink(outside, filepath.Join(root, "omarchy-theme-set.lock")); err != nil {
		t.Fatal(err)
	}
	if c, ok := r.Read(); ok {
		t.Fatalf("published through symlinked lock: %+v", c)
	}
	b, err := os.ReadFile(outside)
	if err != nil || string(b) != "untouched" {
		t.Fatalf("lock target changed: %q %v", b, err)
	}
}

func TestCatalogKeepsSharedLockUntilScanCompletes(t *testing.T) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "safe\n")
	put(t, filepath.Join(r.SystemThemes, "safe/colors.toml"), "background = \"#111111\"\nforeground = \"#ffffff\"\naccent = \"#abcdef\"\n")
	r.afterNameRead = func() {
		lock, err := os.OpenFile(filepath.Join(root, "omarchy-theme-set.lock"), os.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer lock.Close()
		if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != unix.EWOULDBLOCK {
			t.Fatalf("exclusive lock should fail during catalog scan: %v", err)
		}
	}
	if c, ok := r.Read(); !ok || c.Current != "safe" {
		t.Fatalf("shared lock blocked clean scan: %+v %v", c, ok)
	}
}
