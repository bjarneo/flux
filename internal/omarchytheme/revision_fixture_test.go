package omarchytheme

import (
	"path/filepath"
	"testing"
)

func selectionFixture(t *testing.T) (Reader, string) {
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "themes"), RuntimeDir: root}
	put(t, filepath.Join(r.SystemThemes, "gruvbox/colors.toml"), "background = \"#111111\"\nforeground = \"#eeeeee\"\naccent = \"#123456\"\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "tokyo-night\n")
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme/colors.toml"), "background = \"#222222\"\nforeground = \"#eeeeee\"\naccent = \"#123456\"\n")
	return r, ""
}
