package desktop

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeOhmTheme(t *testing.T, root, id, colors string) {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "colors.toml"), []byte(colors), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestOhmCatalogIncludesResolvedActiveAndUserPalette(t *testing.T) {
	official, user := t.TempDir(), t.TempDir()
	writeOhmTheme(t, official, "tokyo-night", "background = '#101010'\nforeground = '#ededed'\n")
	writeOhmTheme(t, official, "nord", "accent = '#000000'\n")
	writeOhmTheme(t, user, "nord", "mode = 'light'\naccent = '#aabbcc'\nbackground = '#ffffff'\n")
	writeOhmTheme(t, official, "broken", "background = 'not a color'\n")
	catalog, err := ohmThemeCatalog("tokyo-night", "mode = 'dark'\nbackground = '#123456'\naccent = '#a1b2c3'\n", official, user)
	if err != nil {
		t.Fatal(err)
	}
	if catalog.Kind != "catalog" || catalog.Version != 1 || catalog.Current != "tokyo-night" || len(catalog.Themes) != 2 {
		t.Fatalf("unexpected catalog: %+v", catalog)
	}
	if catalog.Themes[0].ID != "nord" || catalog.Themes[0].Palette.Mode != "light" || catalog.Themes[0].Palette.Colors["accent"] != "#aabbcc" {
		t.Fatalf("user override not used: %+v", catalog.Themes[0])
	}
	if catalog.Themes[1].Label != "Tokyo Night" || catalog.Themes[1].Palette.Name != "tokyo-night" || catalog.Themes[1].Palette.Source != "omarchy" || catalog.Themes[1].Palette.Colors["background"] != "#123456" {
		t.Fatalf("active palette not resolved: %+v", catalog.Themes[1])
	}
	encoded, err := json.Marshal(catalog)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 4 || body["kind"] == nil || body["version"] == nil || body["current"] == nil || body["themes"] == nil {
		t.Fatalf("wrong v1 fields: %s", encoded)
	}
}

func TestOhmCatalogCapsThemesWithoutDroppingActive(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 80; i++ {
		writeOhmTheme(t, root, fmt.Sprintf("theme-%02d", i), "background = '#111111'\n")
	}
	catalog, err := ohmThemeCatalog("theme-79", "", root)
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog.Themes) != maxOhmThemes {
		t.Fatalf("themes = %d", len(catalog.Themes))
	}
	found := false
	for _, theme := range catalog.Themes {
		if theme.ID == catalog.Current {
			found = true
		}
	}
	encoded, _ := json.Marshal(catalog)
	if !found || len(encoded) > maxOhmThemeCatalog {
		t.Fatalf("active missing or catalog too large: %d", len(encoded))
	}
}

func TestOhmPaletteRejectsOversizedAndColorlessData(t *testing.T) {
	for _, body := range []string{"", "mode = 'dark'", strings.Repeat(" ", maxOhmThemeFile+1), "background = '#fff'"} {
		if _, err := ohmThemePalette("Test", []byte(body)); err == nil {
			t.Errorf("accepted invalid palette of %d bytes", len(body))
		}
	}
	palette, err := ohmThemePalette("Light", []byte("background = '#eeeeee'\nlaunch = 'rm -rf /'\n"))
	if err != nil {
		t.Fatal(err)
	}
	if palette.Mode != "light" || len(palette.Colors) != 1 {
		t.Fatalf("bad inferred palette: %+v", palette)
	}
}

func TestOhmPaletteRefusesSymlinkAndOversizedFiles(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "real.toml")
	if err := os.WriteFile(file, []byte("accent = '#123456'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "colors.toml")
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readOhmThemeColors(link); err == nil {
		t.Fatal("symlink palette accepted")
	}
	if err := os.WriteFile(file, []byte(strings.Repeat(" ", maxOhmThemeFile+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readOhmThemeColors(file); err == nil {
		t.Fatal("oversized palette accepted")
	}
}

func TestOhmSetterCancellationStopsChildren(t *testing.T) {
	root := t.TempDir()
	setter := filepath.Join(root, "setter")
	marker := filepath.Join(root, "child-result")
	script := "#!/bin/sh\nprintf ready > \"$1.ready\"\n(sleep 0.4; printf done > \"$1\") &\nwait\n"
	if err := os.WriteFile(setter, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runOhmThemeSetter(ctx, setter, marker) }()
	deadline := time.Now().Add(time.Second)
	for {
		if _, err := os.Stat(marker + ".ready"); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("setter did not start")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err == nil {
		t.Fatal("canceled setter succeeded")
	}
	time.Sleep(500 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("setter child continued after cancellation: %v", err)
	}
}
