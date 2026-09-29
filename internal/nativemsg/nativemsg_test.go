package nativemsg

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

// TestRoundTrip writes 2 messages and reads them back. A browser keeps one
// host for the whole session, so the host must find the message boundary
// after every reply.
func TestRoundTrip(t *testing.T) {
	type message struct {
		OK    bool   `json:"ok"`
		Error string `json:"error,omitempty"`
	}
	var buf bytes.Buffer
	for _, m := range []message{{OK: true}, {Error: "no_device"}} {
		if err := Write(&buf, m); err != nil {
			t.Fatal(err)
		}
	}
	r := bytes.NewReader(buf.Bytes())
	for _, want := range []string{`{"ok":true}`, `{"ok":false,"error":"no_device"}`} {
		got, err := Read(r)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("read %s, want %s", got, want)
		}
	}
	if _, err := Read(r); err != io.EOF {
		t.Errorf("after the last message: %v, want io.EOF", err)
	}
}

// TestLengthPrefix checks the framing that both browsers require: the
// length first, as a 4-byte little-endian number, and nothing else.
func TestLengthPrefix(t *testing.T) {
	var buf bytes.Buffer
	body := `{"command":"devices"}`
	if err := Write(&buf, json.RawMessage(body)); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	if len(raw) != 4+len(body) {
		t.Fatalf("wrote %d bytes for a %d byte body", len(raw), len(body))
	}
	if n := binary.LittleEndian.Uint32(raw[:4]); int(n) != len(body) {
		t.Errorf("the length prefix is %d, want %d", n, len(body))
	}
	if string(raw[4:]) != body {
		t.Errorf("the body is %s, want %s", raw[4:], body)
	}
}

// TestEmptyStream checks that a host that starts with no browser on the
// other end stops at once, without a message.
func TestEmptyStream(t *testing.T) {
	if _, err := Read(bytes.NewReader(nil)); err != io.EOF {
		t.Errorf("empty stream: %v, want io.EOF", err)
	}
}

// TestBadLength rejects the lengths that neither browser sends. A host that
// trusts the length would wait for gigabytes, or allocate them.
func TestBadLength(t *testing.T) {
	cases := map[string]uint32{
		"zero":     0,
		"too big":  MaxMessage + 1,
		"overflow": 1 << 31,
	}
	for name, n := range cases {
		t.Run(name, func(t *testing.T) {
			var head [4]byte
			binary.LittleEndian.PutUint32(head[:], n)
			_, err := Read(bytes.NewReader(head[:]))
			if err == nil || !strings.Contains(err.Error(), "length") {
				t.Errorf("length %d: %v, want a length error", n, err)
			}
		})
	}
}

// TestShortBody catches a pipe that ends in the middle of a message, which
// happens when the browser closes the port while a reply is on its way.
func TestShortBody(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, map[string]any{"ok": true}); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	if _, err := Read(bytes.NewReader(raw[:len(raw)-2])); err == nil {
		t.Error("a cut message was accepted")
	}
}

// TestWriteTooBig keeps the host from writing a message that the browser
// would drop without a word.
func TestWriteTooBig(t *testing.T) {
	var buf bytes.Buffer
	err := Write(&buf, strings.Repeat("x", MaxMessage))
	if err == nil {
		t.Error("a message over the limit was written")
	}
}
