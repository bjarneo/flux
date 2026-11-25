package core

import (
	"errors"
	"testing"
)

func TestLinkLines(t *testing.T) {
	if got, want := linkUpLine("Pixel", "abc123", "192.168.1.5", true), "link up: Pixel (abc123) 192.168.1.5 paired=true"; got != want {
		t.Errorf("up: got %q, want %q", got, want)
	}
	if got, want := linkUpLine("Pixel", "abc123", "192.168.1.5", false), "link up: Pixel (abc123) 192.168.1.5 paired=false"; got != want {
		t.Errorf("up unpaired: got %q, want %q", got, want)
	}
	if got, want := linkDownLine("Pixel", "abc123", errors.New("EOF")), "link down: Pixel (abc123): EOF"; got != want {
		t.Errorf("down with error: got %q, want %q", got, want)
	}
	if got, want := linkDownLine("Pixel", "abc123", nil), "link down: Pixel (abc123)"; got != want {
		t.Errorf("down without error: got %q, want %q", got, want)
	}
}
