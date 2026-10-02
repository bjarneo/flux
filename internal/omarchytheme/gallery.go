package omarchytheme

import (
	"bytes"
	"context"
	"errors"
	"flux/internal/wallpaper"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"golang.org/x/sys/unix"
)

const MaxGalleryChoices = 1024
const MaxGalleryPreview = 16 << 10

type GalleryChoice struct {
	ID, Label string
	Preview   []byte
}

type Gallery struct {
	Theme, Revision, Current string
	Choices                  []GalleryChoice
}

// Gallery lists only the current theme's two canonical image albums. Paths,
// personal folders and the separate received-image cache never enter the wire.
func (r Reader) Gallery(ctx context.Context) (Gallery, error) {
	c, ok := r.ReadRevision()
	if !ok {
		return Gallery{}, errors.New("current-theme")
	}
	paths, err := r.galleryPaths(ctx, c.Current)
	if err != nil {
		return Gallery{}, err
	}
	selected, _ := canonicalOriginalPath(filepath.Join(r.Home, ".local/state/omarchy/current"))
	selectedDigest := ""
	if filepath.Dir(selected) == filepath.Join(r.Home, ".local/state/omarchy/flux-wallpapers") {
		if _, _, meta, err := galleryImage(selected); err == nil {
			selectedDigest = meta.SHA256
		}
	}
	result := Gallery{Theme: c.Current, Revision: c.Revision, Choices: []GalleryChoice{}}
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return Gallery{}, err
		}
		data, id, meta, err := galleryImage(path)
		if err != nil {
			continue
		}
		preview, err := galleryPreview(data)
		if err != nil {
			continue
		}
		if len(result.Choices) == MaxGalleryChoices {
			return Gallery{}, errors.New("gallery-limit")
		}
		result.Choices = append(result.Choices, GalleryChoice{ID: id, Label: galleryLabel(path), Preview: preview})
		if path == selected || result.Current == "" && selectedDigest != "" && meta.SHA256 == selectedDigest {
			result.Current = id
		}
	}
	after, ok := r.ReadRevision()
	if err := ctx.Err(); err != nil {
		return Gallery{}, err
	}
	if !ok || after.Current != result.Theme || after.Revision != result.Revision {
		return Gallery{}, errors.New("stale-gallery")
	}
	return result, nil
}

// GalleryOriginal re-resolves an opaque content-bound ID against today's
// current albums. It accepts no filename or filesystem path from a peer.
func (r Reader) GalleryOriginal(ctx context.Context, theme, revision, id string) (wallpaper.Meta, []byte, error) {
	if !ValidSelectionID(theme) || !ValidRevision(revision) || !ValidRevision(id) {
		return wallpaper.Meta{}, nil, errors.New("choice")
	}
	c, ok := r.ReadRevision()
	if !ok || c.Current != theme || c.Revision != revision {
		return wallpaper.Meta{}, nil, errors.New("conflict")
	}
	paths, err := r.galleryPaths(ctx, theme)
	if err != nil {
		return wallpaper.Meta{}, nil, err
	}
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return wallpaper.Meta{}, nil, err
		}
		data, choiceID, meta, err := galleryImage(path)
		if err != nil || choiceID != id {
			continue
		}
		after, ok := r.ReadRevision()
		if err := ctx.Err(); err != nil {
			return wallpaper.Meta{}, nil, err
		}
		if !ok || after.Current != theme || after.Revision != revision {
			return wallpaper.Meta{}, nil, errors.New("conflict")
		}
		meta.Theme, meta.Revision = theme, revision
		return meta, data, nil
	}
	return wallpaper.Meta{}, nil, errors.New("unknown-choice")
}

func (r Reader) galleryPaths(ctx context.Context, theme string) ([]string, error) {
	if !ValidSelectionID(theme) {
		return nil, errors.New("theme")
	}
	paths := []string{}
	for _, root := range []string{filepath.Join(r.Home, ".config/omarchy/backgrounds", theme), filepath.Join(r.Home, ".local/state/omarchy/current/theme/backgrounds")} {
		fd, err := openSafe(root, unix.O_RDONLY|unix.O_DIRECTORY)
		if err != nil {
			continue
		}
		f := os.NewFile(uintptr(fd), root)
		for {
			if err := ctx.Err(); err != nil {
				f.Close()
				return nil, err
			}
			entries, readErr := f.ReadDir(128)
			for _, entry := range entries {
				ext := strings.ToLower(filepath.Ext(entry.Name()))
				if entry.Type().IsRegular() && (ext == ".jpg" || ext == ".jpeg" || ext == ".png" || ext == ".webp") {
					if len(paths) == MaxGalleryChoices {
						f.Close()
						return nil, errors.New("gallery-limit")
					}
					paths = append(paths, filepath.Join(root, entry.Name()))
				}
			}
			if readErr != nil {
				break
			}
		}
		f.Close()
	}
	sort.Slice(paths, func(i, j int) bool {
		a, b := filepath.Base(paths[i]), filepath.Base(paths[j])
		if a != b {
			return a < b
		}
		return paths[i] < paths[j]
	})
	return paths, nil
}

func galleryImage(path string) ([]byte, string, wallpaper.Meta, error) {
	before, ok := generation(path, false)
	if !ok {
		return nil, "", wallpaper.Meta{}, errors.New("source")
	}
	data, err := readRegular(path, wallpaper.MaxBytes)
	if err != nil {
		return nil, "", wallpaper.Meta{}, err
	}
	mime, width, height, err := wallpaper.Inspect(data)
	if err != nil {
		return nil, "", wallpaper.Meta{}, err
	}
	after, ok := generation(path, false)
	if !ok || before != after {
		return nil, "", wallpaper.Meta{}, errors.New("changed-source")
	}
	digest := wallpaper.Digest(data)
	id := wallpaper.Digest([]byte(path + "\x00" + digest))
	return data, id, wallpaper.Meta{SHA256: digest, MIME: mime, Size: len(data), Width: width, Height: height}, nil
}

func galleryLabel(path string) string {
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	runes := []rune(strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, name)))
	if len(runes) > 160 {
		runes = runes[:160]
	}
	if len(runes) == 0 {
		return "Background"
	}
	return string(runes)
}

type galleryJPEG struct{ bytes.Buffer }

func (b *galleryJPEG) Write(p []byte) (int, error) {
	if len(p) > MaxGalleryPreview-b.Len() {
		return 0, errBackgroundLimit
	}
	return b.Buffer.Write(p)
}

func galleryPreview(data []byte) ([]byte, error) {
	_, width, height, err := wallpaper.Inspect(data)
	if err != nil {
		return nil, err
	}
	decoded, _, err := image.Decode(bytes.NewReader(data))
	if err != nil || decoded.Bounds().Dx() != width || decoded.Bounds().Dy() != height {
		return nil, errors.New("decode")
	}
	w, h := projectionSize(width, height, min(width, 320))
	if h > 180 {
		w, h = max(1, int(int64(w)*180/int64(h))), 180
	}
	for {
		preview := resizeBackground(decoded, w, h)
		for _, quality := range []int{60, 45, 30} {
			var b galleryJPEG
			if jpeg.Encode(&b, preview, &jpeg.Options{Quality: quality}) == nil {
				return b.Bytes(), nil
			}
		}
		if w <= 16 || h <= 16 {
			return nil, errors.New("preview-limit")
		}
		w, h = max(1, w*3/4), max(1, h*3/4)
	}
}
