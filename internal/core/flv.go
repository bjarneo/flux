package core

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// The recorder writes FLV. Each FLV tag gives its size first, so a frame is
// complete when its last byte arrives. A raw H.264 stream shows the end of
// a frame only at the start of the next frame, 1 frame later.

// Flags of a frame in the stream to the phone.
const (
	frameConfig byte = 1 // the SPS and the PPS
	frameKey    byte = 2 // a frame that a decoder can start at
	frameFormat byte = 4 // the video size: width and height as 2 big-endian uint16
)

// maxTag is the largest FLV tag that flvReader accepts.
const maxTag = 16 << 20

// videoFrame is 1 frame of H.264 in Annex-B form, with its flags.
type videoFrame struct {
	flags byte
	data  []byte
}

var startCode = []byte{0, 0, 0, 1}

// flvReader reads the H.264 video of an FLV stream. It skips the other
// tags.
type flvReader struct {
	r       *bufio.Reader
	started bool
	// lengthSize is the size of each NAL unit length in a frame. The
	// sequence header gives it.
	lengthSize int
}

func newFLVReader(r io.Reader) *flvReader {
	return &flvReader{r: bufio.NewReaderSize(r, 64<<10), lengthSize: 4}
}

// next returns the next video frame, or io.EOF at the end of the stream.
func (f *flvReader) next() (videoFrame, error) {
	if !f.started {
		if err := f.header(); err != nil {
			return videoFrame{}, err
		}
		f.started = true
	}
	for {
		var hdr [11]byte
		if _, err := io.ReadFull(f.r, hdr[:]); err != nil {
			return videoFrame{}, eof(err)
		}
		size := int(hdr[1])<<16 | int(hdr[2])<<8 | int(hdr[3])
		if size > maxTag {
			return videoFrame{}, fmt.Errorf("an FLV tag of %d bytes", size)
		}
		// The data, then the size of the previous tag.
		data := make([]byte, size+4)
		if _, err := io.ReadFull(f.r, data); err != nil {
			return videoFrame{}, eof(err)
		}
		if hdr[0] != 9 {
			continue
		}
		v, ok, err := f.video(data[:size])
		if err != nil || ok {
			return v, err
		}
	}
}

// header reads the FLV header and the first previous tag size.
func (f *flvReader) header() error {
	var h [9]byte
	if _, err := io.ReadFull(f.r, h[:]); err != nil {
		return eof(err)
	}
	if string(h[:3]) != "FLV" {
		return errors.New("the stream is not FLV")
	}
	offset := binary.BigEndian.Uint32(h[5:])
	if offset < 9 || offset > 1024 {
		return fmt.Errorf("an FLV header of %d bytes", offset)
	}
	_, err := f.r.Discard(int(offset) - 9 + 4)
	return eof(err)
}

// video decodes the data of a video tag. It reports false for a tag that
// holds no frame, such as the end of the sequence.
func (f *flvReader) video(b []byte) (videoFrame, bool, error) {
	if len(b) < 5 {
		return videoFrame{}, false, nil
	}
	if b[0]&0x80 != 0 {
		return videoFrame{}, false, errors.New("the stream uses enhanced FLV, which Flux does not read")
	}
	if codec := b[0] & 0x0f; codec != 7 {
		return videoFrame{}, false, fmt.Errorf("the stream has video codec %d, not H.264", codec)
	}
	key := b[0]>>4 == 1
	// The packet type, then 3 bytes of composition time.
	switch b[1] {
	case 0:
		data, lengthSize, err := avcConfig(b[5:])
		if err != nil {
			return videoFrame{}, false, err
		}
		f.lengthSize = lengthSize
		return videoFrame{frameConfig, data}, true, nil
	case 1:
		data, err := annexB(b[5:], f.lengthSize)
		if err != nil {
			return videoFrame{}, false, err
		}
		if len(data) == 0 {
			return videoFrame{}, false, nil
		}
		flags := byte(0)
		if key {
			flags = frameKey
		}
		return videoFrame{flags, data}, true, nil
	}
	return videoFrame{}, false, nil
}

// avcConfig reads an AVCDecoderConfigurationRecord. It returns the SPS and
// PPS units in Annex-B form and the size of the NAL unit lengths.
func avcConfig(b []byte) ([]byte, int, error) {
	bad := errors.New("the H.264 sequence header is not valid")
	if len(b) < 7 {
		return nil, 0, bad
	}
	lengthSize := int(b[4]&3) + 1
	var out []byte
	rest := b[5:]
	for i := range 2 {
		if len(rest) < 1 {
			return nil, 0, bad
		}
		// The SPS count has 5 bits. The PPS count has 8 bits.
		n := int(rest[0])
		if i == 0 {
			n &= 0x1f
		}
		rest = rest[1:]
		for range n {
			if len(rest) < 2 {
				return nil, 0, bad
			}
			size := int(binary.BigEndian.Uint16(rest))
			if len(rest) < 2+size {
				return nil, 0, bad
			}
			out = append(append(out, startCode...), rest[2:2+size]...)
			rest = rest[2+size:]
		}
	}
	return out, lengthSize, nil
}

// annexB turns NAL units with length prefixes into NAL units with start
// codes.
func annexB(b []byte, lengthSize int) ([]byte, error) {
	out := make([]byte, 0, len(b)+16)
	for len(b) > 0 {
		if len(b) < lengthSize {
			return nil, errors.New("an H.264 frame ends inside a NAL unit length")
		}
		size := 0
		for _, c := range b[:lengthSize] {
			size = size<<8 | int(c)
		}
		b = b[lengthSize:]
		if size > len(b) {
			return nil, errors.New("an H.264 NAL unit is longer than its frame")
		}
		out = append(append(out, startCode...), b[:size]...)
		b = b[size:]
	}
	return out, nil
}

// eof turns the end of the stream inside a tag into io.EOF.
func eof(err error) error {
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return io.EOF
	}
	return err
}

// writeFrame writes 1 frame to the phone: the size of the data as a
// big-endian uint32, the flags, and the data. It writes all in 1 call, so
// that a frame goes out in as few TLS records as possible.
func writeFrame(w io.Writer, flags byte, data []byte) error {
	b := make([]byte, 5, 5+len(data))
	binary.BigEndian.PutUint32(b, uint32(len(data)))
	b[4] = flags
	_, err := w.Write(append(b, data...))
	return err
}

// writeError is an error of the stream to the phone, not of the recorder.
type writeError struct{ err error }

func (e writeError) Error() string { return "write to the phone: " + e.err.Error() }
func (e writeError) Unwrap() error { return e.err }

// pumpDesktop reads the FLV stream of the recorder and writes its frames to
// the phone. The first frame is the video size. It calls live once, before
// the first frame. It returns io.EOF when the recorder ends the stream, and
// a writeError when the phone closes it.
func pumpDesktop(r io.Reader, w io.Writer, width, height int, live func()) error {
	fr := newFLVReader(r)
	first := true
	for {
		f, err := fr.next()
		if err != nil {
			return err
		}
		if first {
			first = false
			live()
			size := binary.BigEndian.AppendUint16(binary.BigEndian.AppendUint16(nil, uint16(width)), uint16(height))
			if err := writeFrame(w, frameFormat, size); err != nil {
				return writeError{err}
			}
		}
		if err := writeFrame(w, f.flags, f.data); err != nil {
			return writeError{err}
		}
	}
}
