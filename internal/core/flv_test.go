package core

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

// flvTag returns 1 FLV tag and the size of the tag after it.
func flvTag(typ byte, data []byte) []byte {
	b := []byte{typ, byte(len(data) >> 16), byte(len(data) >> 8), byte(len(data)), 0, 0, 0, 0, 0, 0, 0}
	b = append(b, data...)
	return binary.BigEndian.AppendUint32(b, uint32(11+len(data)))
}

// flvStream returns an FLV stream with a script tag, a sequence header, a
// key frame of 2 NAL units, an inter frame, and the end of the sequence.
func flvStream() []byte {
	b := []byte("FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00")
	b = append(b, flvTag(18, []byte("onMetaData"))...)
	config := []byte{
		1, 0x64, 0, 0x32, 0xff, // version, profile, compatibility, level, 4-byte lengths
		0xe1, 0, 3, 0x67, 0xaa, 0xbb, // 1 SPS
		1, 0, 2, 0x68, 0xcc, // 1 PPS
	}
	b = append(b, flvTag(9, append([]byte{0x17, 0, 0, 0, 0}, config...))...)
	key := []byte{0x17, 1, 0, 0, 0, 0, 0, 0, 2, 0x06, 0x01, 0, 0, 0, 3, 0x65, 0x88, 0x99}
	b = append(b, flvTag(9, key)...)
	b = append(b, flvTag(8, []byte{0xaf, 1, 2})...)
	b = append(b, flvTag(9, []byte{0x27, 1, 0, 0, 0, 0, 0, 0, 2, 0x41, 0x9a})...)
	return append(b, flvTag(9, []byte{0x17, 2, 0, 0, 0})...)
}

func TestFLVReader(t *testing.T) {
	r := newFLVReader(bytes.NewReader(flvStream()))
	want := []videoFrame{
		{frameConfig, []byte{0, 0, 0, 1, 0x67, 0xaa, 0xbb, 0, 0, 0, 1, 0x68, 0xcc}},
		{frameKey, []byte{0, 0, 0, 1, 0x06, 0x01, 0, 0, 0, 1, 0x65, 0x88, 0x99}},
		{0, []byte{0, 0, 0, 1, 0x41, 0x9a}},
	}
	for i, w := range want {
		f, err := r.next()
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if f.flags != w.flags || !bytes.Equal(f.data, w.data) {
			t.Fatalf("frame %d: got %d % x, want %d % x", i, f.flags, f.data, w.flags, w.data)
		}
	}
	if _, err := r.next(); !errors.Is(err, io.EOF) {
		t.Fatalf("after the last frame: %v", err)
	}
}

func TestFLVReaderErrors(t *testing.T) {
	stream := flvStream()
	cases := map[string][]byte{
		"not FLV":        []byte("RIFF0000000000000"),
		"enhanced FLV":   append(stream[:13:13], flvTag(9, []byte{0x90, 'a', 'v', 'c', '1'})...),
		"other codec":    append(stream[:13:13], flvTag(9, []byte{0x12, 1, 0, 0, 0})...),
		"long NAL unit":  append(stream[:13:13], flvTag(9, []byte{0x27, 1, 0, 0, 0, 0, 0, 0, 9, 0x41})...),
		"short config":   append(stream[:13:13], flvTag(9, []byte{0x17, 0, 0, 0, 0, 1, 0x64})...),
		"truncated data": stream[:len(stream)-60],
	}
	for name, b := range cases {
		r := newFLVReader(bytes.NewReader(b))
		var err error
		for range 10 {
			if _, err = r.next(); err != nil {
				break
			}
		}
		if err == nil {
			t.Errorf("%s: no error", name)
		}
		if name == "truncated data" && !errors.Is(err, io.EOF) {
			t.Errorf("%s: %v, want io.EOF", name, err)
		}
	}
}

// failWriter fails each write.
type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }

func TestPumpDesktop(t *testing.T) {
	var out bytes.Buffer
	lives := 0
	err := pumpDesktop(bytes.NewReader(flvStream()), &out, 1920, 1200, func() { lives++ })
	if !errors.Is(err, io.EOF) || lives != 1 {
		t.Fatalf("err %v, live called %d times", err, lives)
	}
	// The format, then the config, the key frame, and the inter frame.
	var flags []byte
	b := out.Bytes()
	for len(b) > 0 {
		size := binary.BigEndian.Uint32(b)
		flags = append(flags, b[4])
		if flags[0] == frameFormat && len(flags) == 1 {
			if w, h := binary.BigEndian.Uint16(b[5:]), binary.BigEndian.Uint16(b[7:]); size != 4 || w != 1920 || h != 1200 {
				t.Fatalf("format of %d bytes: %dx%d", size, w, h)
			}
		}
		b = b[5+size:]
	}
	if !bytes.Equal(flags, []byte{frameFormat, frameConfig, frameKey, 0}) {
		t.Fatalf("flags %v", flags)
	}

	err = pumpDesktop(bytes.NewReader(flvStream()), failWriter{}, 1920, 1200, func() {})
	var we writeError
	if !errors.As(err, &we) {
		t.Fatalf("a closed phone gave %v", err)
	}
}

func TestAnnexB(t *testing.T) {
	want := []byte{0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x41}
	// 4-byte lengths change in place.
	four := []byte{0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 1, 0x41}
	got, err := annexB(nil, four, 4)
	if err != nil || !bytes.Equal(got, want) || &got[0] != &four[0] {
		t.Errorf("4-byte lengths: % x, %v", got, err)
	}
	// 2-byte lengths go to dst.
	two := []byte{0, 2, 0x65, 0x88, 0, 1, 0x41}
	dst := make([]byte, 0, 64)
	got, err = annexB(dst, two, 2)
	if err != nil || !bytes.Equal(got, want) || &got[:1][0] != &dst[:1][0] {
		t.Errorf("2-byte lengths: % x, %v", got, err)
	}
	if _, err := annexB(nil, []byte{0, 9, 0x65}, 2); err == nil {
		t.Error("a long NAL unit gave no error")
	}
	if _, err := annexB(nil, []byte{0, 0, 0}, 4); err == nil {
		t.Error("a short length gave no error")
	}
}
