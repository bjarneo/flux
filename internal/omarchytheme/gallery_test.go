package omarchytheme

import (
	"bytes"
	"context"
	"flux/internal/wallpaper"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGalleryUsesCurrentAlbumsAndBoundedJPEGPreviews(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	writeBackground(t, filepath.Join(state, "theme/backgrounds/dawn.png"), image.NewUniform(color.White))
	writeBackground(t, filepath.Join(r.Home, ".config/omarchy/backgrounds", c.Current, "00-custom.png"), image.NewUniform(color.Black))
	for _, excluded := range []string{"Wallpapers/Images/private.png", ".config/omarchy/backgrounds/other-theme/foreign.png", ".local/state/omarchy/flux-wallpapers/cached.png"} {
		writeBackground(t, filepath.Join(r.Home, excluded), image.NewUniform(color.White))
	}
	gallery, err := r.Gallery(context.Background())
	if err != nil || gallery.Theme != c.Current || gallery.Revision != c.Revision || len(gallery.Choices) != 3 {
		t.Fatal("unexpected current album", gallery, err)
	}
	for i, label := range []string{"00-custom", "dawn", "dusk"} {
		choice := gallery.Choices[i]
		if choice.Label != label || !ValidRevision(choice.ID) || len(choice.Preview) > MaxGalleryPreview {
			t.Fatal("invalid gallery choice", choice.Label)
		}
		config, err := jpeg.DecodeConfig(bytes.NewReader(choice.Preview))
		if err != nil || config.Width > 320 || config.Height > 180 {
			t.Fatal("unbounded/non-JPEG preview", config, err)
		}
	}
	if gallery.Current != gallery.Choices[2].ID {
		t.Fatal("active album image was not highlighted")
	}
	again, err := r.Gallery(context.Background())
	if err != nil || again.Choices[0].ID != gallery.Choices[0].ID {
		t.Fatal("unchanged choice IDs are unstable", err)
	}
}

func TestGalleryRejectsUnsafeInvalidAndOversizedSources(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	dir := filepath.Join(r.Home, ".local/state/omarchy/current/theme/backgrounds")
	outside := filepath.Join(t.TempDir(), "outside.png")
	writeBackground(t, outside, image.NewUniform(color.White))
	if err := os.Symlink(outside, filepath.Join(dir, "linked.png")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "invalid.jpg"), []byte("not an image"), 0600); err != nil {
		t.Fatal(err)
	}
	oversized := filepath.Join(dir, "oversized.png")
	if err := os.WriteFile(oversized, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(oversized, wallpaper.MaxBytes+1); err != nil {
		t.Fatal(err)
	}
	album := filepath.Join(r.Home, ".config/omarchy/backgrounds", c.Current)
	if err := os.MkdirAll(filepath.Dir(album), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(outside), album); err != nil {
		t.Fatal(err)
	}
	gallery, err := r.Gallery(context.Background())
	if err != nil || len(gallery.Choices) != 1 || gallery.Choices[0].Label != "dusk" {
		t.Fatal("unsafe source entered gallery", err, len(gallery.Choices))
	}
}

func TestGallerySelectionPreservesPaletteAndRejectsStaleOrForeignChoice(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	path := filepath.Join(state, "theme/backgrounds/day.png")
	writeBackground(t, path, image.NewUniform(color.White))
	gallery, err := r.Gallery(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	id := gallery.Choices[0].ID
	for _, values := range [][3]string{{c.Current, strings.Repeat("f", 64), id}, {"other-theme", c.Revision, id}, {c.Current, c.Revision, strings.Repeat("e", 64)}} {
		if _, _, err := r.GalleryOriginal(context.Background(), values[0], values[1], values[2]); err == nil {
			t.Fatal("stale/foreign choice accepted")
		}
	}
	meta, data, err := r.GalleryOriginal(context.Background(), c.Current, c.Revision, id)
	if err != nil {
		t.Fatal(err)
	}
	colors, _ := os.ReadFile(filepath.Join(state, "theme/colors.toml"))
	name, _ := os.ReadFile(filepath.Join(state, "theme.name"))
	meta.Operation, meta.Origin = strings.Repeat("b", 32), "phone"
	if _, err := r.CommitOriginal(meta, data, func() bool { return true }, func(string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	afterColors, _ := os.ReadFile(filepath.Join(state, "theme/colors.toml"))
	afterName, _ := os.ReadFile(filepath.Join(state, "theme.name"))
	if !bytes.Equal(colors, afterColors) || !bytes.Equal(name, afterName) {
		t.Fatal("background selection changed the palette")
	}
	current, ok := r.ReadRevision()
	selected, err := r.Original(current)
	if !ok || err != nil || !bytes.Equal(data, selected) {
		t.Fatal("selected original differs", err)
	}
	again, err := r.Gallery(context.Background())
	if err != nil || again.Current != id {
		t.Fatal("copied album image lost selection highlight", err)
	}
	writeBackground(t, path, image.NewUniform(color.Black))
	if _, _, err := r.GalleryOriginal(context.Background(), again.Theme, again.Revision, id); err == nil {
		t.Fatal("old content ID selected a modified album file")
	}
}

func TestGalleryCancelledRequestAndPortraitBounds(t *testing.T) {
	r, _, _ := backgroundFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := r.Gallery(ctx); err == nil {
		t.Fatal("cancelled request continued")
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, image.NewRGBA(image.Rect(0, 0, 160, 640)), nil); err != nil {
		t.Fatal(err)
	}
	preview, err := galleryPreview(b.Bytes())
	config, decodeErr := jpeg.DecodeConfig(bytes.NewReader(preview))
	if err != nil || decodeErr != nil || config.Width > 320 || config.Height > 180 {
		t.Fatal("portrait preview exceeded bounds", err, decodeErr, config)
	}
}

func TestGalleryBoundsEnumerationBeforeReadingSources(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	dir := filepath.Join(r.Home, ".local/state/omarchy/current/theme/backgrounds")
	for i := range MaxGalleryChoices {
		name := filepath.Join(dir, fmt.Sprintf("%04d.png", i))
		if err := os.WriteFile(name, nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := r.Gallery(context.Background()); err == nil {
		t.Fatal("unbounded candidate enumeration was accepted")
	}
	if _, _, err := r.GalleryOriginal(context.Background(), c.Current, c.Revision, strings.Repeat("e", 64)); err == nil {
		t.Fatal("selection enumerated an oversized album")
	}
}
