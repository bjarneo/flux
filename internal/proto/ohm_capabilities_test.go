package proto

import (
	"slices"
	"testing"
)

func TestOhmExtensionsPreserveOfficialPaletteContract(t *testing.T) {
	if slices.Contains(Incoming, TypeFluxTheme) || !slices.Contains(Outgoing, TypeFluxTheme) {
		t.Fatal("official flux.theme palette contract changed")
	}
	for _, typ := range []string{TypeWallpaperOriginal, TypeOmarchyThemeSelect, TypeFluxInputRequestV2} {
		if !slices.Contains(Incoming, typ) {
			t.Fatalf("missing incoming extension: %s", typ)
		}
	}
	for _, typ := range []string{TypeWallpaperOriginal, TypeOmarchyTheme, TypeOmarchyThemeSelected} {
		if !slices.Contains(Outgoing, typ) {
			t.Fatalf("missing outgoing extension: %s", typ)
		}
	}
}
