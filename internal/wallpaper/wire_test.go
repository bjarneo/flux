package wallpaper

import (
	"bytes"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"strings"
	"testing"
)

func fixture(t *testing.T) (Meta, []byte) {
	t.Helper()
	var b bytes.Buffer
	png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 3840, 2160)))
	data := b.Bytes()
	return Meta{Operation: strings.Repeat("a", 32), Origin: "phone", Revision: strings.Repeat("b", 64), Theme: "matte-black", SHA256: Digest(data), MIME: "image/png", Size: len(data), Width: 3840, Height: 2160}, data
}
func TestOriginalBothDirectionsNoRecompression(t *testing.T) {
	m, data := fixture(t)
	for _, origin := range []string{"phone", "desktop"} {
		t.Run(origin, func(t *testing.T) {
			m.Origin = origin
			r := Receiver{}
			calls := 0
			var ack *Message
			e := Send(m, data, func(msg Message) error {
				raw, _ := json.Marshal(msg)
				if len(raw) > MaxMessage {
					t.Fatal("oversized message")
				}
				reply := r.Feed(raw, origin, m.Revision, func(got Meta, b []byte) (string, error) {
					calls++
					if !bytes.Equal(data, b) || got.Width != 3840 || got.Height != 2160 {
						t.Fatal("not original")
					}
					return got.Revision, nil
				})
				if reply != nil {
					ack = reply
				}
				return nil
			})
			if e != nil || calls != 1 || ack == nil || !ack.OK {
				t.Fatal(e, calls, ack)
			}
		})
	}
}
func TestCorruptTruncatedStaleAndOffsetNeverCommit(t *testing.T) {
	m, data := fixture(t)
	for _, kind := range []string{"corrupt", "truncated", "stale", "offset", "origin"} {
		t.Run(kind, func(t *testing.T) {
			r := Receiver{}
			calls := 0
			var reply *Message
			e := Send(m, data, func(msg Message) error {
				if kind == "truncated" && msg.Kind == "chunk" {
					return nil
				}
				if kind == "offset" && msg.Kind == "chunk" {
					msg.Offset++
				}
				if kind == "corrupt" && msg.Kind == "begin" {
					copy := *msg.Meta
					copy.SHA256 = strings.Repeat("0", 64)
					msg.Meta = &copy
				}
				raw, _ := json.Marshal(msg)
				origin := m.Origin
				if kind == "origin" {
					origin = "other"
				}
				a := r.Feed(raw, origin, m.Revision, func(_ Meta, _ []byte) (string, error) {
					if kind == "stale" {
						return "", errors.New("conflict")
					}
					calls++
					return m.Revision, nil
				})
				if a != nil {
					reply = a
				}
				return nil
			})
			if e != nil || calls != 0 || reply == nil || reply.OK {
				t.Fatal(kind, e, calls, reply)
			}
		})
	}
}
