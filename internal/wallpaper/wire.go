// Package wallpaper transports originals in bounded chunks on the existing TLS
// control channel. It never opens a listener or interprets a remote file path.
package wallpaper

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	_ "golang.org/x/image/webp"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"regexp"
	"time"
)

const Type = "flux.wallpaper.v2"
const MaxBytes = 32 << 20
const MaxPixels = 32 << 20
const ChunkBytes = 24 << 10
const MaxMessage = 34 << 10

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)
var opPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
var idPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)
var themePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

type Meta struct {
	Operation string `json:"operation"`
	Origin    string `json:"origin"`
	Revision  string `json:"revision"`
	Theme     string `json:"theme"`
	SHA256    string `json:"sha256"`
	MIME      string `json:"mime"`
	Size      int    `json:"size"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
}
type Message struct {
	Kind      string `json:"kind"`
	Operation string `json:"operation"`
	Meta      *Meta  `json:"meta,omitempty"`
	Offset    int    `json:"offset,omitempty"`
	Data      string `json:"data,omitempty"`
	OK        bool   `json:"ok,omitempty"`
	Revision  string `json:"revision,omitempty"`
	Error     string `json:"error,omitempty"`
}

func (m Meta) Valid() bool {
	return opPattern.MatchString(m.Operation) && idPattern.MatchString(m.Origin) && hex64.MatchString(m.Revision) && themePattern.MatchString(m.Theme) && !bytes.Contains([]byte(m.Theme), []byte("..")) && hex64.MatchString(m.SHA256) && m.Size > 0 && m.Size <= MaxBytes && m.Width > 0 && m.Height > 0 && int64(m.Width)*int64(m.Height) <= MaxPixels && (m.MIME == "image/jpeg" || m.MIME == "image/png" || m.MIME == "image/webp")
}
func Inspect(data []byte) (string, int, int, error) {
	if len(data) == 0 || len(data) > MaxBytes {
		return "", 0, 0, errors.New("size")
	}
	c, f, e := image.DecodeConfig(bytes.NewReader(data))
	if e != nil {
		return "", 0, 0, e
	}
	if c.Width < 1 || c.Height < 1 || int64(c.Width)*int64(c.Height) > MaxPixels {
		return "", 0, 0, errors.New("pixels")
	}
	mime := map[string]string{"jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp"}[f]
	if mime == "" {
		return "", 0, 0, errors.New("format")
	}
	return mime, c.Width, c.Height, nil
}
func Digest(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }
func Validate(m Meta, data []byte) error {
	if !m.Valid() || len(data) != m.Size || Digest(data) != m.SHA256 {
		return errors.New("size/hash")
	}
	mime, w, h, e := Inspect(data)
	if e != nil || mime != m.MIME || w != m.Width || h != m.Height {
		return errors.New("image metadata")
	}
	return nil
}
func Send(m Meta, data []byte, send func(Message) error) error {
	if e := Validate(m, data); e != nil {
		return e
	}
	if e := send(Message{Kind: "begin", Operation: m.Operation, Meta: &m}); e != nil {
		return e
	}
	for off := 0; off < len(data); off += ChunkBytes {
		end := min(off+ChunkBytes, len(data))
		if e := send(Message{Kind: "chunk", Operation: m.Operation, Offset: off, Data: base64.StdEncoding.EncodeToString(data[off:end])}); e != nil {
			return e
		}
	}
	return send(Message{Kind: "end", Operation: m.Operation})
}

// Receiver is owned by one authorized control session, with at most one bounded
// in-flight original. Discard the receiver when that session/epoch is replaced.
type Receiver struct {
	meta    *Meta
	data    []byte
	started time.Time
}

func (r *Receiver) Expire() {
	if r.meta != nil && time.Since(r.started) > 60*time.Second {
		r.Reset()
	}
}

func (r *Receiver) Reset() { r.meta = nil; r.data = nil }
func (r *Receiver) Feed(raw []byte, origin, revision string, commit func(Meta, []byte) (string, error)) *Message {
	var m Message
	if len(raw) > MaxMessage || json.Unmarshal(raw, &m) != nil || !opPattern.MatchString(m.Operation) {
		r.Reset()
		return nil
	}
	fail := func(reason string) *Message {
		r.Reset()
		return &Message{Kind: "ack", Operation: m.Operation, Error: reason}
	}
	if m.Kind == "ack" {
		return nil
	}
	if m.Kind == "begin" {
		r.Reset()
		if m.Meta == nil || !m.Meta.Valid() || m.Meta.Operation != m.Operation || m.Meta.Origin != origin {
			return fail("metadata")
		}
		// CAS is checked at commit too. An already-committed operation may replay
		// against an older revision; commit recognizes its content without applying.
		copy := *m.Meta
		r.meta = &copy
		r.started = time.Now()
		return nil
	}
	if r.meta == nil || r.meta.Operation != m.Operation {
		return fail("no-transfer")
	}
	if time.Since(r.started) > 60*time.Second {
		return fail("timeout")
	}
	switch m.Kind {
	case "chunk":
		if len(m.Data) > ((ChunkBytes+2)/3)*4 || m.Offset != len(r.data) {
			return fail("offset")
		}
		b, e := base64.StdEncoding.Strict().DecodeString(m.Data)
		if e != nil || len(b) == 0 || len(b) > ChunkBytes || len(r.data)+len(b) > r.meta.Size {
			return fail("chunk")
		}
		r.data = append(r.data, b...)
		return nil
	case "end":
		meta, data := *r.meta, r.data
		r.Reset()
		if Validate(meta, data) != nil {
			return fail("integrity")
		}
		next, e := commit(meta, data)
		if e != nil {
			return fail(e.Error())
		}
		return &Message{Kind: "ack", Operation: m.Operation, OK: true, Revision: next}
	default:
		return fail("kind")
	}
}
