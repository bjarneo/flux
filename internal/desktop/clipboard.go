// Package desktop connects fluxd to the Omarchy desktop: the clipboard,
// notifications, media players, the battery, virtual input, sound, and
// the programs that open files and URLs.
package desktop

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// maxClipboardText is the largest clipboard text that Flux syncs.
const maxClipboardText = 4 << 20

// watchScript runs once for each selection change. It prints the
// CLIPBOARD_STATE value on one line and the content as base64 on the next
// line, so text with newlines stays in one record.
const watchScript = `printf '%s\n' "$CLIPBOARD_STATE"; base64 -w0; printf '\n'`

// Clipboard reads and writes the Wayland clipboard with wl-clipboard.
type Clipboard struct {
	mu       sync.Mutex
	lastSeen string
	started  bool
}

// NewClipboard returns a clipboard that uses wl-paste and wl-copy.
func NewClipboard() *Clipboard { return &Clipboard{} }

// Watch runs `wl-paste --watch` until ctx ends. It calls onChange with the
// new text for each local text change. It skips the change that Set
// causes, text that is equal to the last text, and content that the
// source marks as sensitive, such as a password. The first selection
// after start is the current content, so Watch records it and does not
// report it. Watch starts wl-paste again 2 seconds after it exits.
func (c *Clipboard) Watch(ctx context.Context, onChange func(text string)) {
	for ctx.Err() == nil {
		c.watchOnce(ctx, onChange)
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
}

func (c *Clipboard) watchOnce(ctx context.Context, onChange func(text string)) {
	cmd := exec.CommandContext(ctx, "wl-paste", "--type", "text", "--watch", "sh", "-c", watchScript)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	defer cmd.Wait()

	r := bufio.NewReaderSize(out, 64<<10)
	for {
		state, err := r.ReadString('\n')
		if err != nil {
			return
		}
		encoded, err := r.ReadString('\n')
		if err != nil {
			return
		}
		state = strings.TrimSpace(state)
		encoded = strings.TrimSpace(encoded)
		if state == "sensitive" || state == "nil" || state == "clear" {
			continue
		}
		if base64.StdEncoding.DecodedLen(len(encoded)) > maxClipboardText {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(raw) == 0 || !isText(raw) {
			continue
		}
		if text, ok := c.observe(string(raw)); ok {
			onChange(text)
		}
	}
}

// observe records text as the last seen text. It reports whether the
// text is a new local change.
func (c *Clipboard) observe(text string) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	first := !c.started
	c.started = true
	if text == c.lastSeen {
		return "", false
	}
	c.lastSeen = text
	return text, !first
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

// Set puts text on the clipboard. Watch does not report this change.
func (c *Clipboard) Set(text string) error {
	c.mu.Lock()
	c.lastSeen = text
	c.mu.Unlock()
	cmd := exec.Command("wl-copy")
	cmd.Stdin = strings.NewReader(text)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return errors.New("wl-copy: " + msg)
		}
		return err
	}
	return nil
}

// isText reports whether b looks like text and not binary data.
func isText(b []byte) bool { return bytes.IndexByte(b, 0) < 0 }
