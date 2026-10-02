package desktop

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestThemeCatalogListsOnlySafeInstalledThemeIDs(t *testing.T) {
	official := filepath.Join(t.TempDir(), "themes")
	user := filepath.Join(t.TempDir(), "user-themes")
	for _, root := range []string{official, user} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"tokyo-night", "gruvbox", "../escape", "two words", ".hidden"} {
		if err := os.Mkdir(filepath.Join(official, name), 0o755); err != nil && !os.IsExist(err) {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(user, "catppuccin"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := themeCatalog(official, user)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"catppuccin", "gruvbox", "tokyo-night"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("themeCatalog() = %v, want %v", got, want)
	}
}

func TestThemeIDRejectsPathsAndNonCanonicalNames(t *testing.T) {
	for _, id := range []string{"", ".hidden", "../escape", "two words", "Tokyo-Night", "theme/child"} {
		if validThemeID(id) {
			t.Errorf("validThemeID(%q) = true", id)
		}
	}
	for _, id := range []string{"tokyo-night", "catppuccin", "nord2"} {
		if !validThemeID(id) {
			t.Errorf("validThemeID(%q) = false", id)
		}
	}
}
