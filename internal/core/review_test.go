package core

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

func TestReviewReadKeepsNewestRequest(t *testing.T) {
	for _, mode := range []string{"diff", "ansi"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			d := &Daemon{cfg: &config.Config{Herdr: true}}
			dev := &Device{ID: "phone", Paired: true}
			started := make(chan string, 3)
			release := make(chan struct{})
			sent := make(chan *proto.Packet, 3)
			read := func(r reviewRead) *proto.Packet {
				started <- r.path
				if r.request == "1" {
					select {
					case <-release:
					case <-ctx.Done():
					}
				}
				return proto.New(proto.TypeFluxHerdr, map[string]any{"kind": "output", "pane": r.pane, "text": r.path})
			}
			send := func(p *proto.Packet) { sent <- p }
			d.queueHerdrView(dev, nil, reviewRead{pane: "pane", format: "diff", path: "first.go", request: json.Number("1")}, read, send)
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("the first read did not start")
			}
			d.queueHerdrView(dev, nil, reviewRead{pane: "pane", format: "diff", path: "skipped.go", request: json.Number("2")}, read, send)
			d.queueHerdrView(dev, nil, reviewRead{pane: "pane", format: mode, path: "latest.go", request: json.Number("3")}, read, send)
			close(release)
			select {
			case path := <-started:
				if path != "latest.go" {
					t.Fatal(path)
				}
			case <-time.After(time.Second):
				t.Fatal("the latest request was lost")
			}
			select {
			case p := <-sent:
				var got struct {
					Request          int
					View, Path, Text string
				}
				if err := p.Decode(&got); err != nil {
					t.Fatal(err)
				}
				if got.Request != 3 || got.View != mode || got.Path != "latest.go" || got.Text != "latest.go" {
					t.Fatal(got)
				}
			case <-time.After(time.Second):
				t.Fatal("no response")
			}
		})
	}
}

func TestReviewOutputIsBounded(t *testing.T) {
	b := &boundedOutput{limit: 32}
	if _, err := io.Copy(b, bytes.NewReader(bytes.Repeat([]byte("x"), 1024))); err != nil {
		t.Fatal(err)
	}
	if b.Len() != 32 || !b.truncated {
		t.Fatal("review output exceeded its bound")
	}
}

func TestReviewShowsStagedAndUntrackedFiles(t *testing.T) {
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git: %s: %v", out, err)
		}
	}
	git("init", "-q")
	if err := os.WriteFile(filepath.Join(dir, "staged.txt"), []byte("staged text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	git("add", "staged.txt")
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("new text\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	text, cut, err := repositoryDiff(context.Background(), dir, "")
	if err != nil || cut || !strings.Contains(text, "+staged text") || !strings.Contains(text, "+new text") {
		t.Fatalf("%v %v %s", err, cut, text)
	}
	if strings.Contains(text, "root:") {
		t.Fatal("review followed a symbolic link")
	}
	text, _, err = repositoryDiff(context.Background(), dir, "new.txt")
	if err != nil || strings.Contains(text, "staged text") {
		t.Fatalf("path filter: %v %s", err, text)
	}
	if _, _, err := repositoryDiff(context.Background(), dir, "../outside"); err == nil {
		t.Fatal("review accepted an outside path")
	}
}
