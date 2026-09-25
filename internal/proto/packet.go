// Package proto implements the KDE Connect packet format, the identity,
// and the certificate helpers that the LAN backend needs.
package proto

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
	"time"
)

// ProtocolVersion is the KDE Connect protocol version that Flux speaks.
const ProtocolVersion = 8

// MaxPacketSize is the largest packet that Flux reads. Larger lines drop
// the link. SMS threads with many messages are the largest packets.
const MaxPacketSize = 16 << 20

// Packet is one KDE Connect network packet.
type Packet struct {
	ID                  PacketID        `json:"id"`
	Type                string          `json:"type"`
	Body                json.RawMessage `json:"body"`
	PayloadSize         int64           `json:"payloadSize,omitempty"`
	PayloadTransferInfo *TransferInfo   `json:"payloadTransferInfo,omitempty"`
}

// TransferInfo tells the receiver where to fetch the payload.
type TransferInfo struct {
	Port int `json:"port,omitempty"`
	// Tunnel is set instead of Port by the Flux tunnel extension. The
	// receiver then listens, and the sender connects.
	Tunnel string `json:"tunnel,omitempty"`
}

// PacketID is a timestamp in milliseconds. Some peers send it as a string,
// so it accepts both forms.
type PacketID int64

// UnmarshalJSON accepts a number or a numeric string.
func (id *PacketID) UnmarshalJSON(b []byte) error {
	b = bytes.Trim(b, `"`)
	if len(b) == 0 || string(b) == "null" {
		*id = 0
		return nil
	}
	n, err := strconv.ParseInt(string(b), 10, 64)
	if err != nil {
		f, ferr := strconv.ParseFloat(string(b), 64)
		if ferr != nil {
			return fmt.Errorf("packet id %q: %w", b, err)
		}
		n = int64(f)
	}
	*id = PacketID(n)
	return nil
}

// New returns a packet of the type with the body encoded as JSON.
func New(typ string, body any) *Packet {
	raw, err := json.Marshal(body)
	if err != nil || body == nil {
		raw = []byte("{}")
	}
	return &Packet{ID: PacketID(time.Now().UnixMilli()), Type: typ, Body: raw}
}

// Marshal returns the packet as one JSON line with a trailing newline.
func (p *Packet) Marshal() ([]byte, error) {
	if len(p.Body) == 0 {
		p.Body = []byte("{}")
	}
	b, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// Unmarshal parses one packet line.
func Unmarshal(line []byte) (*Packet, error) {
	p := &Packet{}
	if err := json.Unmarshal(line, p); err != nil {
		return nil, err
	}
	if p.Type == "" {
		return nil, fmt.Errorf("packet has no type")
	}
	if len(p.Body) == 0 || string(p.Body) == "null" {
		p.Body = []byte("{}")
	}
	return p, nil
}

// Decode decodes the body into v.
func (p *Packet) Decode(v any) error { return json.Unmarshal(p.Body, v) }

// Fields decodes the body into a generic map. It returns an empty map when
// the body is not an object.
func (p *Packet) Fields() map[string]any {
	m := map[string]any{}
	_ = json.Unmarshal(p.Body, &m)
	return m
}

// HasPayload reports whether the packet announces a payload that the
// receiver can fetch.
func (p *Packet) HasPayload() bool {
	return p.PayloadSize != 0 && p.PayloadTransferInfo != nil && p.PayloadTransferInfo.Port > 0
}
