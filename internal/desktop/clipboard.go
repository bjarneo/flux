// Package desktop connects fluxd to the Omarchy desktop: the clipboard,
// notifications, media players, the battery, virtual input, sound, and
// the programs that open files and URLs.
package desktop

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// maxClipboardText is the largest clipboard text that Flux syncs.
const maxClipboardText = 4 << 20

// MaxClipboardImage is the largest clipboard image that Flux syncs.
const MaxClipboardImage = 16 << 20

// ImageType is the MIME type of the images that Watch reports.
const ImageType = "image/png"

// pngMagic starts every PNG file.
var pngMagic = []byte("\x89PNG\r\n\x1a\n")

// watchScript runs once for each selection change. It prints 3 lines: the
// CLIPBOARD_STATE value, the content as base64, and the MIME types of the
// selection. The base64 keeps text with newlines in one line.
const watchScript = `printf '%s\n' "$CLIPBOARD_STATE"; base64 -w0; printf '\n'; wl-paste --list-types | tr '\n' ' '; printf '\n'`

// initialWindow is the time after the start of wl-paste in which its first
// selection is the current content and not a change.
const initialWindow = time.Second

// Clipboard reads and writes the Wayland clipboard with wl-clipboard.
type Clipboard struct {
	mu sync.Mutex
	// lastSeen identifies the last content, from contentKey.
	lastSeen string
}

// NewClipboard returns a clipboard that uses wl-paste and wl-copy.
func NewClipboard() *Clipboard { return &Clipboard{} }

// Watch runs 2 `wl-paste --watch` processes until ctx ends: 1 for text
// and 1 for PNG images. It calls onText for each local text change and
// onImage for each local image change. A selection with plain text is
// text. A selection with a PNG image and no plain text is an image.
//
// Watch skips the change that Set or SetImage causes, content that is
// equal to the last content, and content that the source marks as
// sensitive, such as a password. wl-paste reports the current content
// when it starts, so Watch records that content and does not report it.
// Watch starts wl-paste again 2 seconds after it exits.
func (c *Clipboard) Watch(ctx context.Context, onText func(text string), onImage func(data []byte, mime string)) {
	var wg sync.WaitGroup
	for _, typ := range []string{"text", ImageType} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for ctx.Err() == nil {
				c.watchOnce(ctx, typ, onText, onImage)
				select {
				case <-ctx.Done():
					return
				case <-time.After(2 * time.Second):
				}
			}
		}()
	}
	wg.Wait()
}

// watchOnce runs 1 `wl-paste --watch` process for the type typ, which is
// "text" or ImageType.
func (c *Clipboard) watchOnce(ctx context.Context, typ string, onText func(string), onImage func([]byte, string)) {
	cmd := exec.CommandContext(ctx, "wl-paste", "--type", typ, "--watch", "sh", "-c", watchScript)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	defer cmd.Wait()
	start := time.Now()
	first := true

	r := bufio.NewReaderSize(out, 64<<10)
	for {
		var lines [3]string
		for i := range lines {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			lines[i] = strings.TrimSpace(line)
		}
		initial := first && time.Since(start) < initialWindow
		first = false
		c.record(typ, lines, initial, onText, onImage)
	}
}

// record handles 1 record of watchScript from the wl-paste process for the
// type typ. initial marks the current content at the start of wl-paste.
func (c *Clipboard) record(typ string, lines [3]string, initial bool, onText func(string), onImage func([]byte, string)) {
	state, encoded, types := lines[0], lines[1], strings.Fields(lines[2])
	if state == "sensitive" || state == "nil" || state == "clear" {
		return
	}
	limit := maxClipboardText
	if typ == ImageType {
		limit = MaxClipboardImage
	}
	if base64.StdEncoding.DecodedLen(len(encoded)) > limit {
		return
	}
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(raw) == 0 {
		return
	}
	if typ == ImageType {
		if isImage(types) && bytes.HasPrefix(raw, pngMagic) && c.observe(contentKey(ImageType, raw), initial) {
			onImage(raw, ImageType)
		}
		return
	}
	if !isImage(types) && isText(raw) && c.observe(contentKey("text", raw), initial) {
		onText(string(raw))
	}
}

// observe records key as the last content. It reports whether the content
// is a new local change. Initial content is never a change.
func (c *Clipboard) observe(key string, initial bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if key == c.lastSeen {
		return false
	}
	c.lastSeen = key
	return !initial
}

// contentKey identifies clipboard content of the type typ, so that Watch
// can find a repeat without a copy of the content.
func contentKey(typ string, data []byte) string {
	sum := sha256.Sum256(data)
	return typ + " " + hex.EncodeToString(sum[:])
}

// isPlainText reports whether a selection MIME type is plain text.
func isPlainText(typ string) bool {
	return strings.HasPrefix(typ, "text/plain") || typ == "UTF8_STRING" || typ == "STRING" || typ == "TEXT"
}

// isImage reports whether a selection with the MIME types is an image: it
// has a PNG image and no plain text. A browser offers an image as a PNG
// and as HTML, and an office program offers cells as plain text and as an
// image.
func isImage(types []string) bool {
	png := false
	for _, t := range types {
		if isPlainText(t) {
			return false
		}
		if t == ImageType {
			png = true
		}
	}
	return png
}

// Get returns the text on the clipboard. It returns an empty string when
// the clipboard is empty or holds no text.
func (c *Clipboard) Get() (string, error) {
	var stderr bytes.Buffer
	cmd := exec.Command("wl-paste", "--no-newline", "--type", "text")
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := stderr.String()
		if strings.Contains(msg, "Nothing is copied") || strings.Contains(msg, "No suitable type") {
			return "", nil
		}
		if msg != "" {
			return "", errors.New("wl-paste: " + strings.TrimSpace(msg))
		}
		return "", err
	}
	if !isText(out) {
		return "", nil
	}
	return string(out), nil
}

// GetImage returns the PNG image on the clipboard. It returns nil when the
// clipboard holds no image, as isImage defines it.
func (c *Clipboard) GetImage() ([]byte, error) {
	types, err := exec.Command("wl-paste", "--list-types").Output()
	if err != nil || !isImage(strings.Fields(string(types))) {
		return nil, nil
	}
	cmd := exec.Command("wl-paste", "--type", ImageType)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("wl-paste: %w", err)
	}
	data, err := io.ReadAll(io.LimitReader(out, MaxClipboardImage+1))
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if err != nil {
		return nil, err
	}
	if len(data) > MaxClipboardImage {
		return nil, fmt.Errorf("the image is larger than %d MiB", MaxClipboardImage>>20)
	}
	if !bytes.HasPrefix(data, pngMagic) {
		return nil, nil
	}
	return data, nil
}

// Set puts text on the clipboard. Watch does not report this change.
func (c *Clipboard) Set(text string) error {
	c.mu.Lock()
	c.lastSeen = contentKey("text", []byte(text))
	c.mu.Unlock()
	// wl-copy forks a background process that serves the clipboard until
	// the clipboard changes. That process inherits stdout and stderr, so a
	// pipe on either one makes Run wait until the clipboard changes. The
	// output goes to /dev/null, so Run returns when the first process exits.
	cmd := exec.Command("wl-copy")
	cmd.Stdin = strings.NewReader(text)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wl-copy: %w", err)
	}
	return nil
}

// SetImage puts an image on the clipboard with the MIME type mime, such as
// image/png. Watch does not report this change. The next text copy syncs,
// also when it equals the last text.
func (c *Clipboard) SetImage(data []byte, mime string) error {
	c.mu.Lock()
	c.lastSeen = contentKey(mime, data)
	c.mu.Unlock()
	// As in Set, the output goes to /dev/null so that Run does not wait
	// for the process that serves the clipboard.
	cmd := exec.Command("wl-copy", "--type", mime)
	cmd.Stdin = bytes.NewReader(data)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wl-copy: %w", err)
	}
	return nil
}

// isText reports whether b looks like text and not binary data.
func isText(b []byte) bool { return bytes.IndexByte(b, 0) < 0 }
