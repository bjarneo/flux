package omarchytheme

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"math/rand"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func backgroundFixture(t *testing.T) (Reader, Catalog, string) {
	t.Helper()
	root := t.TempDir()
	r := Reader{Home: filepath.Join(root, "home"), SystemThemes: filepath.Join(root, "system"), RuntimeDir: root}
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	put(t, filepath.Join(state, "theme.name"), "omalaunch-dusk\n")
	put(t, filepath.Join(state, "theme/colors.toml"), "background = \"#162437\"\nforeground = \"#eeeeee\"\naccent = \"#68c4ee\"\n")
	path := filepath.Join(state, "theme/backgrounds/dusk.png")
	writeBackground(t, path, image.NewUniform(color.RGBA{R: 22, G: 36, B: 55, A: 255}))
	if err := os.Symlink(path, filepath.Join(state, "background")); err != nil {
		t.Fatal(err)
	}
	c, ok := r.ReadRevision()
	if !ok {
		t.Fatal("fixture catalog missing")
	}
	return r, c, path
}

func writeBackground(t *testing.T, path string, source image.Image) {
	t.Helper()
	if _, uniform := source.(*image.Uniform); uniform {
		im := image.NewRGBA(image.Rect(0, 0, 160, 90))
		for y := 0; y < 90; y++ {
			for x := 0; x < 160; x++ {
				im.Set(x, y, source.At(x, y))
			}
		}
		source = im
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	var data bytes.Buffer
	if err := png.Encode(&data, source); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestBackgroundCurrentProjectionHasBoundedCorrelatedJPEG(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	b, ok := r.Background(c, c.Revision)
	if !ok || b.Kind != "background" || b.Version != 1 || b.ThemeID != c.Current || b.Revision != c.Revision {
		t.Fatalf("background: %+v %v", b, ok)
	}
	data, err := base64.StdEncoding.DecodeString(b.Data)
	if err != nil || len(data) > MaxBackgroundBytes {
		t.Fatal("invalid/big JPEG", err)
	}
	sum := sha256.Sum256(data)
	if b.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatal("incorrect SHA256")
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width != 160 || config.Height != 90 || b.Width != config.Width || b.Height != config.Height {
		t.Fatal("incorrect dimensions", config, err)
	}
	encoded, _ := json.Marshal(b)
	if len(encoded) > MaxBody {
		t.Fatal("body exceeds transport limit")
	}
	if bytes.Contains(encoded, []byte(r.Home)) || bytes.Contains(encoded, []byte("dusk.png")) {
		t.Fatal("source path escaped projection")
	}
}

func TestBackgroundPermitsOnlyCurrentThemeRoots(t *testing.T) {
	for _, kind := range []string{"active", "user-background", "user-theme", "system-theme", "external", "other-theme", "symlink-file", "symlink-directory"} {
		t.Run(kind, func(t *testing.T) {
			r, c, path := backgroundFixture(t)
			state := filepath.Join(r.Home, ".local/state/omarchy/current")
			allowed := true
			switch kind {
			case "active":
			case "user-background":
				path = filepath.Join(r.Home, ".config/omarchy/backgrounds", c.Current, "dusk.png")
			case "user-theme":
				path = filepath.Join(r.Home, ".config/omarchy/themes", c.Current, "backgrounds/dusk.png")
			case "system-theme":
				path = filepath.Join(r.SystemThemes, c.Current, "backgrounds/dusk.png")
			case "external":
				path = filepath.Join(t.TempDir(), "private.png")
				allowed = false
			case "other-theme":
				path = filepath.Join(r.Home, ".config/omarchy/backgrounds/other-theme/dusk.png")
				allowed = false
			case "symlink-file":
				outside := filepath.Join(t.TempDir(), "outside.png")
				writeBackground(t, outside, image.NewUniform(color.White))
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, path); err != nil {
					t.Fatal(err)
				}
				allowed = false
			case "symlink-directory":
				outside := t.TempDir()
				writeBackground(t, filepath.Join(outside, "dusk.png"), image.NewUniform(color.White))
				if err := os.RemoveAll(filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
				allowed = false
			}
			if kind != "symlink-file" && kind != "symlink-directory" {
				writeBackground(t, path, image.NewUniform(color.White))
			}
			if err := os.Remove(filepath.Join(state, "background")); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(path, filepath.Join(state, "background")); err != nil {
				t.Fatal(err)
			}
			c, _ = r.ReadRevision()
			if _, ok := r.Background(c, c.Revision); ok != allowed {
				t.Fatalf("accepted=%v expected=%v", ok, allowed)
			}
		})
	}
}

func TestBackgroundRejectsStalePaletteNameRevisionAndSwitchLock(t *testing.T) {
	r, c, _ := backgroundFixture(t)
	for _, bad := range []string{"", "12345678-1234-4123-8123-123456789abC", "../../bad", "12345678-1234-1123-8123-123456789abc"} {
		if _, ok := r.Background(c, bad); ok {
			t.Fatal("accepted invalid revision", bad)
		}
	}
	c.Themes[0].Palette.Colors["background"] = "#000000"
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("accepted stale palette")
	}
	c, _ = r.ReadRevision()
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "other\n")
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("accepted stale name")
	}
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), c.Current+"\n")
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("accepted a revision after the same theme was rewritten")
	}
	c, _ = r.ReadRevision()
	fd, err := unix.Open(filepath.Join(r.RuntimeDir, "omarchy-theme-set.lock"), unix.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	if err := unix.Flock(fd, unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("published during theme switch")
	}
}

func TestBackgroundProjectionShrinksNoisyImageAndPreservesAspect(t *testing.T) {
	source := image.NewRGBA(image.Rect(0, 0, 1920, 1080))
	rng := rand.New(rand.NewSource(13))
	for i := 0; i < len(source.Pix); i += 4 {
		source.Pix[i] = byte(rng.Intn(256))
		source.Pix[i+1] = byte(rng.Intn(256))
		source.Pix[i+2] = byte(rng.Intn(256))
		source.Pix[i+3] = 255
	}
	var input bytes.Buffer
	if err := png.Encode(&input, source); err != nil {
		t.Fatal(err)
	}
	data, width, height, ok := projectBackground(input.Bytes())
	if !ok || len(data) > MaxBackgroundBytes || width > MaxBackgroundSide || height > MaxBackgroundSide || width*height > MaxBackgroundPixels {
		t.Fatal("unbounded projection", len(data), width, height, ok)
	}
	if abs(width*1080-height*1920) > 1920 {
		t.Fatal("aspect ratio changed", width, height)
	}
	if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
		t.Fatal(err)
	}
}

func TestBackgroundProjectionRejectsDecodeBombsAndUnsupportedData(t *testing.T) {
	var pngHeader bytes.Buffer
	pngHeader.Write([]byte("\x89PNG\r\n\x1a\n"))
	chunk := make([]byte, 17)
	copy(chunk, "IHDR")
	binary.BigEndian.PutUint32(chunk[4:8], 65536)
	binary.BigEndian.PutUint32(chunk[8:12], 65536)
	chunk[12], chunk[13] = 8, 2
	binary.Write(&pngHeader, binary.BigEndian, uint32(13))
	pngHeader.Write(chunk)
	binary.Write(&pngHeader, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	for _, data := range [][]byte{[]byte("not an image"), make([]byte, maxBackgroundInputBytes+1), pngHeader.Bytes()} {
		if _, _, _, ok := projectBackground(data); ok {
			t.Fatal("accepted invalid or oversized input")
		}
	}
	var small bytes.Buffer
	if err := gif.Encode(&small, image.NewPaletted(image.Rect(0, 0, 2, 2), color.Palette{color.Black}), nil); err != nil {
		t.Fatal(err)
	}
	if _, w, h, ok := projectBackground(small.Bytes()); !ok || w != 2 || h != 2 {
		t.Fatal("first-frame GIF missing")
	}
}

func TestBackgroundProjectsLossyAndLosslessWebP(t *testing.T) {
	for _, fixture := range []struct {
		name          string
		width, height int
	}{
		{"blue-purple-pink.lossy.webp", 150, 100}, {"background-lossless.webp", 1, 1},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			source, err := os.ReadFile(filepath.Join("testdata", fixture.name))
			if err != nil {
				t.Fatal(err)
			}
			config, format, err := image.DecodeConfig(bytes.NewReader(source))
			if err != nil || format != "webp" || config.Width != fixture.width || config.Height != fixture.height {
				t.Fatalf("fixture config: %+v %s %v", config, format, err)
			}
			data, width, height, ok := projectBackground(source)
			if !ok || width != fixture.width || height != fixture.height || len(data) > MaxBackgroundBytes {
				t.Fatal("WebP projection missing", width, height, len(data), ok)
			}
			if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
				t.Fatal(err)
			}
			// The same current-state/path/revision checks apply to WebP input.
			r, _, path := backgroundFixture(t)
			if err := os.WriteFile(path, source, 0600); err != nil {
				t.Fatal(err)
			}
			catalog, valid := r.ReadRevision()
			if !valid {
				t.Fatal("current revision missing")
			}
			if b, valid := r.Background(catalog, catalog.Revision); !valid || b.Width != fixture.width || b.Height != fixture.height {
				t.Fatal("current WebP sidepacket missing")
			}
		})
	}
}

func TestBackgroundRejectsMalformedAndOversizedWebPHeaders(t *testing.T) {
	valid, err := os.ReadFile(filepath.Join("testdata", "background-lossless.webp"))
	if err != nil {
		t.Fatal(err)
	}
	huge := bytes.Clone(valid)
	// VP8L stores width-1 and height-1 in two 14-bit fields. DecodeConfig
	// must reject this 16384x16384 canvas before allocating decoded pixels.
	binary.LittleEndian.PutUint32(huge[21:25], (16384-1)|((16384-1)<<14))
	// A small VP8X canvas followed by the huge VP8L header must also fail.
	// The pinned decoder checks inner dimensions before its full allocation.
	var mismatched bytes.Buffer
	mismatched.WriteString("RIFF")
	binary.Write(&mismatched, binary.LittleEndian, uint32(len(huge)-8+18))
	mismatched.WriteString("WEBPVP8X")
	binary.Write(&mismatched, binary.LittleEndian, uint32(10))
	mismatched.Write(make([]byte, 10))
	mismatched.Write(huge[12:])
	for _, source := range [][]byte{valid[:12], valid[:len(valid)-3], huge, mismatched.Bytes(), []byte("RIFF\x00\x00\x00\x00WEBPinvalid")} {
		if _, _, _, ok := projectBackground(source); ok {
			t.Fatal("accepted malformed or oversized WebP")
		}
	}
}

// Opt-in validation against the actual installed stock formats, without
// changing desktop state or copying theme assets into the repository.
func TestBackgroundInstalledWebPProbe(t *testing.T) {
	root := os.Getenv("FLUX_THEME_WEBP_PROBE_ROOT")
	if root == "" {
		t.Skip("set FLUX_THEME_WEBP_PROBE_ROOT for installed WebP validation")
	}
	for _, relative := range []string{"catppuccin/backgrounds/1-totoro.webp", "catppuccin/backgrounds/2-waves.webp", "catppuccin/backgrounds/3-blue-eye.webp", "catppuccin/backgrounds/omarchy.webp", "gruvbox/backgrounds/omarchy.webp"} {
		source, err := readRegular(filepath.Join(root, relative), maxBackgroundInputBytes)
		if err != nil {
			t.Fatal("installed stock WebP unavailable", relative)
		}
		data, width, height, ok := projectBackground(source)
		if !ok || len(data) > MaxBackgroundBytes || width > MaxBackgroundSide || height > MaxBackgroundSide || width*height > MaxBackgroundPixels {
			t.Fatal("installed WebP projection failed", relative)
		}
		if _, err := jpeg.Decode(bytes.NewReader(data)); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		t.Logf("%s: JPEG %dx%d %d bytes sha256=%s", relative, width, height, len(data), hex.EncodeToString(digest[:]))
	}
}

func TestBackgroundRejectsTargetGenerationChangesAndOversizedFiles(t *testing.T) {
	r, c, path := backgroundFixture(t)
	writeBackground(t, path, image.NewUniform(color.White))
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("accepted old revision after in-place background edit")
	}
	c, _ = r.ReadRevision()
	if _, ok := r.Background(c, c.Revision); !ok {
		t.Fatal("did not project newly correlated background")
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(maxBackgroundInputBytes + 1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	c, _ = r.ReadRevision()
	if _, ok := r.Background(c, c.Revision); ok {
		t.Fatal("accepted oversized file")
	}
}

// Opt-in physical validation: prints only bounded metadata, never pixels or
// source paths. The supplied roots are trusted local test configuration.
func TestBackgroundCurrentHostProbe(t *testing.T) {
	home := os.Getenv("FLUX_THEME_ASSET_PROBE_HOME")
	if home == "" {
		t.Skip("set FLUX_THEME_ASSET_PROBE_HOME for physical validation")
	}
	system := os.Getenv("FLUX_THEME_ASSET_PROBE_SYSTEM")
	if system == "" {
		system = filepath.Join(home, ".local/share/omarchy/themes")
	}
	r := Reader{Home: home, SystemThemes: system, RuntimeDir: os.Getenv("FLUX_THEME_ASSET_PROBE_RUNTIME")}
	c, ok := r.ReadRevision()
	if !ok {
		t.Fatal("current theme revision unavailable")
	}
	b, ok := r.Background(c, c.Revision)
	if !ok {
		t.Fatal("current theme background unavailable")
	}
	data, err := base64.StdEncoding.DecodeString(b.Data)
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	var geometry *Geometry
	for _, theme := range c.Themes {
		if theme.ID == c.Current {
			geometry = theme.Palette.Geometry
		}
	}
	metadata, err := json.Marshal(struct {
		ThemeID    string    `json:"themeId"`
		Revision   string    `json:"revision"`
		SHA256     string    `json:"sha256"`
		Width      int       `json:"width"`
		Height     int       `json:"height"`
		ImageBytes int       `json:"imageBytes"`
		BodyBytes  int       `json:"bodyBytes"`
		Geometry   *Geometry `json:"geometry,omitempty"`
	}{b.ThemeID, b.Revision, b.SHA256, b.Width, b.Height, len(data), len(body), geometry})
	if err != nil {
		t.Fatal(err)
	}
	t.Log(string(metadata))
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}
