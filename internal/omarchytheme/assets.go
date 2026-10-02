package omarchytheme

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	_ "golang.org/x/image/webp"
	"golang.org/x/sys/unix"
)

const BackgroundType = "flux.omarchy_theme_background"
const MaxBackgroundBytes = 44 << 10
const MaxBackgroundSide = 1280
const MaxBackgroundPixels = MaxBackgroundSide * MaxBackgroundSide
const maxBackgroundInputBytes = 16 << 20
const maxBackgroundInputPixels = 16 << 20

// Background is a read-only, current-state projection, not a background choice.
// Neither paths nor source filenames leave the desktop. Revision is the v2
// catalog token; peers must bind both it and ThemeID before applying the image.
type Background struct {
	Kind     string `json:"kind"`
	Version  int    `json:"version"`
	ThemeID  string `json:"themeId"`
	Revision string `json:"revision"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	SHA256   string `json:"sha256"`
	Data     string `json:"data"`
}

// Background rechecks the supplied catalog's current palette under Omarchy's
// shared switch lock. A palette/name/link change drops the image instead of
// labeling another theme's pixels with a stale revision. The caller still
// fences the captured revision and paired session immediately before sending.
func (r Reader) Background(c Catalog, revision string) (Background, bool) {
	var empty Background
	if r.Home == "" || r.SystemThemes == "" || c.Version != 2 || c.Revision != revision || !ValidSelectionID(c.Current) || !ValidRevision(revision) {
		return empty, false
	}
	runtimeDir := r.RuntimeDir
	if runtimeDir == "" {
		runtimeDir = os.Getenv("XDG_RUNTIME_DIR")
	}
	if runtimeDir == "" {
		runtimeDir = "/tmp"
	}
	fd, err := openSafe(filepath.Join(runtimeDir, "omarchy-theme-set.lock"), unix.O_RDWR|unix.O_CREAT)
	if err != nil {
		return empty, false
	}
	defer unix.Close(fd)
	var stat unix.Stat_t
	if unix.Fstat(fd, &stat) != nil || stat.Mode&unix.S_IFMT != unix.S_IFREG || stat.Nlink != 1 || stat.Uid != uint32(os.Geteuid()) || unix.Flock(fd, unix.LOCK_SH|unix.LOCK_NB) != nil {
		return empty, false
	}
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	actual, ok := r.readRevision()
	if !ok || actual.Current != c.Current || actual.Revision != revision || !backgroundPaletteMatches(actual, c) {
		return empty, false
	}
	namePath := filepath.Join(state, "theme.name")
	name, err := readRegular(namePath, 128)
	if err != nil || string(name) != c.Current && string(name) != c.Current+"\n" {
		return empty, false
	}
	stateFD, err := openSafe(state, unix.O_RDONLY|unix.O_DIRECTORY)
	if err != nil {
		return empty, false
	}
	defer unix.Close(stateFD)
	target, err := backgroundLink(stateFD)
	if err != nil {
		return empty, false
	}
	path := target
	if !filepath.IsAbs(path) {
		path = filepath.Join(state, path)
	}
	path = filepath.Clean(path)
	if !r.backgroundPathAllowed(state, c.Current, path) {
		return empty, false
	}
	sourceGeneration, valid := generation(path, false)
	if !valid {
		return empty, false
	}
	// The single canonical current/background link is permitted; the opened
	// target and every ancestor must be ordinary files/directories, never links.
	source, err := readRegular(path, maxBackgroundInputBytes)
	if err != nil {
		return empty, false
	}
	jpegBytes, width, height, ok := projectBackground(source)
	if !ok {
		return empty, false
	}
	again, err := readRegular(namePath, 128)
	linkAgain, linkErr := backgroundLink(stateFD)
	currentGeneration, generationOK := generation(path, false)
	current, revisionOK := r.readRevision()
	if err != nil || linkErr != nil || !bytes.Equal(name, again) || target != linkAgain ||
		!generationOK || currentGeneration != sourceGeneration || !revisionOK || current.Current != c.Current || current.Revision != revision {
		return empty, false
	}
	digest := sha256.Sum256(jpegBytes)
	b := Background{Kind: "background", Version: 1, ThemeID: c.Current, Revision: revision,
		Width: width, Height: height, SHA256: hex.EncodeToString(digest[:]), Data: base64.StdEncoding.EncodeToString(jpegBytes)}
	encoded, err := json.Marshal(b)
	if err != nil || len(encoded) > MaxBody {
		return empty, false
	}
	return b, true
}

func backgroundPaletteMatches(actual, expected Catalog) bool {
	for _, wanted := range expected.Themes {
		if wanted.ID != expected.Current {
			continue
		}
		for _, got := range actual.Themes {
			if got.ID == expected.Current {
				return reflect.DeepEqual(wanted.Palette, got.Palette)
			}
		}
	}
	return false
}

func backgroundLink(dirFD int) (string, error) {
	buf := make([]byte, 4096)
	n, err := unix.Readlinkat(dirFD, "background", buf)
	if err != nil || n == 0 || n == len(buf) {
		return "", os.ErrInvalid
	}
	return string(buf[:n]), nil
}

func (r Reader) backgroundPathAllowed(state, id, path string) bool {
	for _, root := range []string{filepath.Join(state, "theme/backgrounds"),
		filepath.Join(r.Home, ".config/omarchy/backgrounds", id),
		filepath.Join(r.Home, ".config/omarchy/themes", id, "backgrounds"),
		filepath.Join(r.SystemThemes, id, "backgrounds")} {
		rel, err := filepath.Rel(root, path)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel) {
			return true
		}
	}
	return false
}

var errBackgroundLimit = errors.New("background encoding limit")

type boundedJPEG struct{ bytes.Buffer }

func (b *boundedJPEG) Write(p []byte) (int, error) {
	if len(p) > MaxBackgroundBytes-b.Len() {
		return 0, errBackgroundLimit
	}
	return b.Buffer.Write(p)
}

// DecodeConfig bounds allocations before image.Decode. Only registered Go
// JPEG, PNG, WebP and first-frame GIF decoders are used; no external transcoder runs.
func projectBackground(source []byte) ([]byte, int, int, bool) {
	if len(source) == 0 || len(source) > maxBackgroundInputBytes {
		return nil, 0, 0, false
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(source))
	if err != nil || format != "jpeg" && format != "png" && format != "gif" && format != "webp" || config.Width < 1 || config.Height < 1 ||
		int64(config.Width)*int64(config.Height) > maxBackgroundInputPixels {
		return nil, 0, 0, false
	}
	original, _, err := image.Decode(bytes.NewReader(source))
	if err != nil || original.Bounds().Dx() != config.Width || original.Bounds().Dy() != config.Height {
		return nil, 0, 0, false
	}
	side := min(MaxBackgroundSide, max(config.Width, config.Height))
	for {
		width, height := projectionSize(config.Width, config.Height, side)
		resized := resizeBackground(original, width, height)
		for _, quality := range []int{82, 65, 48, 32} {
			var output boundedJPEG
			if jpeg.Encode(&output, resized, &jpeg.Options{Quality: quality}) == nil {
				return output.Bytes(), width, height, true
			}
		}
		if side <= 32 {
			return nil, 0, 0, false
		}
		side = max(32, side*3/4)
	}
}

func projectionSize(width, height, side int) (int, int) {
	if width >= height {
		return side, max(1, int(int64(height)*int64(side)/int64(width)))
	}
	return max(1, int(int64(width)*int64(side)/int64(height))), side
}

// Bilinear sampling preserves the full desktop image's aspect ratio and avoids
// platform image libraries. Allocation is bounded by MaxBackgroundPixels.
func resizeBackground(source image.Image, width, height int) *image.RGBA {
	result := image.NewRGBA(image.Rect(0, 0, width, height))
	bounds := source.Bounds()
	for y := 0; y < height; y++ {
		sy := math.Max(0, (float64(y)+0.5)*float64(bounds.Dy())/float64(height)-0.5)
		y0 := int(sy)
		y1 := min(y0+1, bounds.Dy()-1)
		fy := sy - float64(y0)
		for x := 0; x < width; x++ {
			sx := math.Max(0, (float64(x)+0.5)*float64(bounds.Dx())/float64(width)-0.5)
			x0 := int(sx)
			x1 := min(x0+1, bounds.Dx()-1)
			fx := sx - float64(x0)
			r0, g0, b0, _ := source.At(bounds.Min.X+x0, bounds.Min.Y+y0).RGBA()
			r1, g1, b1, _ := source.At(bounds.Min.X+x1, bounds.Min.Y+y0).RGBA()
			r2, g2, b2, _ := source.At(bounds.Min.X+x0, bounds.Min.Y+y1).RGBA()
			r3, g3, b3, _ := source.At(bounds.Min.X+x1, bounds.Min.Y+y1).RGBA()
			sample := func(a, b, c, d uint32) byte {
				return byte(((float64(a)*(1-fx)+float64(b)*fx)*(1-fy) + (float64(c)*(1-fx)+float64(d)*fx)*fy) / 257)
			}
			i := result.PixOffset(x, y)
			result.Pix[i], result.Pix[i+1], result.Pix[i+2], result.Pix[i+3] = sample(r0, r1, r2, r3), sample(g0, g1, g2, g3), sample(b0, b1, b2, b3), 255
		}
	}
	return result
}
