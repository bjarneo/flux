package core

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"slices"
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

// nals returns NAL units with 4-byte lengths, as in an FLV video tag.
func nals(units ...[]byte) []byte {
	var b []byte
	for _, u := range units {
		b = binary.BigEndian.AppendUint32(b, uint32(len(u)))
		b = append(b, u...)
	}
	return b
}

// written splits the output of pumpDesktop into its frames.
func written(t *testing.T, b []byte) []videoFrame {
	t.Helper()
	var frames []videoFrame
	for len(b) > 0 {
		if len(b) < 5 {
			t.Fatalf("a frame header of %d bytes", len(b))
		}
		size := int(binary.BigEndian.Uint32(b))
		if len(b) < 5+size {
			t.Fatalf("a frame of %d bytes with %d bytes left", size, len(b)-5)
		}
		frames = append(frames, videoFrame{b[4], b[5 : 5+size]})
		b = b[5+size:]
	}
	return frames
}

func flagsOf(frames []videoFrame) []byte {
	var flags []byte
	for _, f := range frames {
		flags = append(flags, f.flags)
	}
	return flags
}

func TestPumpDesktop(t *testing.T) {
	var out bytes.Buffer
	lives := 0
	err := pumpDesktop(bytes.NewReader(flvStream()), &out, 1920, 1200, func() { lives++ })
	if !errors.Is(err, io.EOF) || lives != 1 {
		t.Fatalf("err %v, live called %d times", err, lives)
	}
	// The format, then the config, the key frame, and the inter frame.
	frames := written(t, out.Bytes())
	if flags := flagsOf(frames); !bytes.Equal(flags, []byte{frameFormat, frameConfig, frameKey, 0}) {
		t.Fatalf("flags %v", flags)
	}
	format := frames[0].data
	if w, h := binary.BigEndian.Uint16(format), binary.BigEndian.Uint16(format[2:]); len(format) != 4 || w != 1920 || h != 1200 {
		t.Fatalf("format of %d bytes: %dx%d", len(format), w, h)
	}

	err = pumpDesktop(bytes.NewReader(flvStream()), failWriter{}, 1920, 1200, func() {})
	var we writeError
	if !errors.As(err, &we) {
		t.Fatalf("a closed phone gave %v", err)
	}
}

// With VAAPI the key frames carry an SPS and a PPS that differ from the
// sequence header. They go out as a config frame before the first such key
// frame.
func TestPumpDesktopInlineSets(t *testing.T) {
	header := []byte{0, 0, 0, 1, 0x67, 0xaa, 0xbb, 0, 0, 0, 1, 0x68, 0xcc}
	inline := []byte{0, 0, 0, 1, 0x67, 0xaa, 0xdd, 0, 0, 0, 1, 0x68, 0xee}
	cases := []struct {
		name     string
		sps, pps []byte
		flags    []byte
	}{
		{"other sets", []byte{0x67, 0xaa, 0xdd}, []byte{0x68, 0xee}, []byte{frameFormat, frameConfig, frameConfig, frameKey, 0, frameKey}},
		{"same sets", []byte{0x67, 0xaa, 0xbb}, []byte{0x68, 0xcc}, []byte{frameFormat, frameConfig, frameKey, 0, frameKey}},
	}
	for _, c := range cases {
		b := []byte("FLV\x01\x01\x00\x00\x00\x09\x00\x00\x00\x00")
		b = append(b, flvTag(9, []byte{
			0x17, 0, 0, 0, 0,
			1, 0x64, 0, 0x32, 0xff,
			0xe1, 0, 3, 0x67, 0xaa, 0xbb,
			1, 0, 2, 0x68, 0xcc,
		})...)
		key := nals(c.sps, c.pps, []byte{0x06, 0x01}, []byte{0x65, 0x88})
		b = append(b, flvTag(9, append([]byte{0x17, 1, 0, 0, 0}, key...))...)
		b = append(b, flvTag(9, append([]byte{0x27, 1, 0, 0, 0}, nals([]byte{0x41, 0x9a})...))...)
		b = append(b, flvTag(9, append([]byte{0x17, 1, 0, 0, 0}, key...))...)

		var out bytes.Buffer
		if err := pumpDesktop(bytes.NewReader(b), &out, 1920, 1200, func() {}); !errors.Is(err, io.EOF) {
			t.Fatalf("%s: %v", c.name, err)
		}
		frames := written(t, out.Bytes())
		if flags := flagsOf(frames); !bytes.Equal(flags, c.flags) {
			t.Fatalf("%s: flags %v, want %v", c.name, flags, c.flags)
		}
		if !bytes.Equal(frames[1].data, header) {
			t.Errorf("%s: first config % x", c.name, frames[1].data)
		}
		if c.flags[2] == frameConfig && !bytes.Equal(frames[2].data, inline) {
			t.Errorf("%s: second config % x, want % x", c.name, frames[2].data, inline)
		}
	}
}

func TestParameterSets(t *testing.T) {
	sps := []byte{0, 0, 0, 1, 0x67, 0xaa, 0xbb}
	pps := []byte{0, 0, 0, 1, 0x68, 0xcc}
	sei := []byte{0, 0, 0, 1, 0x06, 0x01}
	idr := []byte{0, 0, 0, 1, 0x65, 0x88}
	frame := slices.Concat(sps, pps, sei, idr)
	want := slices.Concat(sps, pps)
	got := parameterSets(frame)
	if !bytes.Equal(got, want) {
		t.Fatalf("got % x, want % x", got, want)
	}
	// The result is a copy: the next read reuses the frame.
	clear(frame)
	if !bytes.Equal(got, want) {
		t.Fatalf("after a change of the frame: % x", got)
	}
	if got := parameterSets(slices.Concat(sps, idr)); got != nil {
		t.Errorf("only an SPS: % x", got)
	}
	if got := parameterSets(slices.Concat(sei, idr)); got != nil {
		t.Errorf("no sets: % x", got)
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
