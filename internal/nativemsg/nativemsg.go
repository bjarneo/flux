// Package nativemsg is the native messaging protocol that Chromium and
// Firefox use to start a local host program for a browser extension.
// Chromium, Firefox, Brave, Edge, and Zen all speak it.
package nativemsg

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
)

// Host is the native messaging name of flux-native. The extension uses it
// to start the host, and the host manifest that `flux-cli browser install`
// writes uses it as its own name. Both sides must agree on it.
const Host = "org.omarchy.flux"

// MaxMessage is the largest message that this package reads or writes.
// Chromium refuses to pass a bigger one, and it caps a message from a
// host at 1 MB as well.
const MaxMessage = 1 << 20

// Read returns the next message from r. Both browsers start every message
// with its length as a 4-byte little-endian number, followed by the UTF-8
// JSON of the message. It returns io.EOF when the browser closes the pipe.
func Read(r io.Reader) ([]byte, error) {
	var head [4]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return nil, err
	}
	n := binary.LittleEndian.Uint32(head[:])
	if n == 0 || n > MaxMessage {
		return nil, fmt.Errorf("the message length %d is not between 1 and %d", n, MaxMessage)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("the message of %d bytes ended early: %w", n, err)
	}
	return buf, nil
}

// Write sends v to w as one message. It writes the whole message with one
// call, because a browser reads from the pipe as it arrives.
func Write(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(b) > MaxMessage {
		return fmt.Errorf("the message is %d bytes, over the %d limit", len(b), MaxMessage)
	}
	var head [4]byte
	binary.LittleEndian.PutUint32(head[:], uint32(len(b)))
	if _, err := w.Write(append(head[:], b...)); err != nil {
		return err
	}
	return nil
}
