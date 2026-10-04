package core

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

func TestDesktopAudioFrames(t *testing.T) {
	pcm := bytes.Repeat([]byte{0, 1, 2, 3}, desktopAudioBytes/2)
	var out bytes.Buffer
	if err := pumpDesktopAudio(bytes.NewReader(pcm), &out); !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		header := out.Next(5)
		if len(header) != 5 || int(binary.BigEndian.Uint32(header)) != desktopAudioBytes || header[4] != frameAudio {
			t.Fatal(header)
		}
		if !bytes.Equal(out.Next(desktopAudioBytes), pcm[i*desktopAudioBytes:(i+1)*desktopAudioBytes]) {
			t.Fatal("PCM changed")
		}
	}
}
