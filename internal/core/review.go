package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"flux/internal/herdr"
	"flux/internal/lan"
	"flux/internal/proto"
)

const reviewLimit = 512 << 10

type reviewRead struct {
	pane, path, format string
	lines              int
	request            json.Number
}

type reviewReadJob struct{ next *reviewRead }

func viewResponse(p *proto.Packet, r reviewRead) *proto.Packet {
	b := p.Fields()
	b["view"], b["path"] = r.format, r.path
	return withRequest(proto.New(proto.TypeFluxHerdr, b), r.request)
}

func (d *Daemon) readHerdrView(dev *Device, link *lan.Link, r reviewRead) {
	d.queueHerdrView(dev, link, r, func(r reviewRead) *proto.Packet {
		if r.format == "diff" {
			return d.readReview(r.pane, r.path)
		}
		return d.readHerdr(r.pane, r.lines, r.format == "ansi")
	}, func(p *proto.Packet) { d.herdrSend(dev, link, p) })
}

// queueHerdrView keeps the newest requested view while one read runs.
func (d *Daemon) queueHerdrView(dev *Device, link *lan.Link, r reviewRead, read func(reviewRead) *proto.Packet, send func(*proto.Packet)) {
	key := herdrReadKey{link: link, pane: r.pane}
	d.mu.Lock()
	if job := d.reviewJobs[key]; job != nil {
		job.next = &r
		d.mu.Unlock()
		return
	}
	if len(d.reviewJobs) >= 8 {
		d.mu.Unlock()
		send(viewResponse(proto.New(proto.TypeFluxHerdr, map[string]any{"kind": "output", "pane": r.pane, "error": "Too many agent reads. Try again."}), r))
		return
	}
	if d.reviewJobs == nil {
		d.reviewJobs = map[herdrReadKey]*reviewReadJob{}
	}
	job := &reviewReadJob{next: &r}
	d.reviewJobs[key] = job
	d.mu.Unlock()
	go func() {
		for {
			d.mu.Lock()
			current := *job.next
			job.next = nil
			d.mu.Unlock()
			result := read(current)
			d.mu.Lock()
			if job.next != nil {
				d.mu.Unlock()
				continue
			}
			delete(d.reviewJobs, key)
			allowed := dev.Paired && d.cfg.Herdr && d.permittedLocked(dev.ID, "herdr")
			d.mu.Unlock()
			if allowed {
				send(viewResponse(result, current))
			}
			return
		}
	}()
}

type boundedOutput struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (b *boundedOutput) Len() int       { return b.buffer.Len() }
func (b *boundedOutput) String() string { return b.buffer.String() }

func (b *boundedOutput) Write(p []byte) (int, error) {
	n := min(len(p), max(0, b.limit-b.Len()))
	b.buffer.Write(p[:n])
	if n < len(p) {
		b.truncated = true
	}
	return len(p), nil
}

func reviewGit(ctx context.Context, dir string, args ...string) (string, bool, error) {
	cmd := exec.CommandContext(ctx, "git", append([]string{"--no-pager", "--literal-pathspecs", "-C", dir, "-c", "color.ui=never"}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_OPTIONAL_LOCKS=0")
	out := &boundedOutput{limit: reviewLimit}
	var stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = out, &stderr
	err := cmd.Run()
	if err != nil {
		return "", false, fmt.Errorf("git: %s", strings.TrimSpace(stderr.String()))
	}
	return out.String(), out.truncated, nil
}

func repositoryDiff(ctx context.Context, dir, path string) (string, bool, error) {
	if path != "" && (!filepath.IsLocal(path) || strings.ContainsRune(path, 0)) {
		return "", false, errors.New("select a file inside the repository")
	}
	root, _, err := reviewGit(ctx, dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", false, err
	}
	root = strings.TrimSpace(root)
	paths := []string{"--"}
	if path != "" {
		paths = append(paths, path)
	}
	status, cut, err := reviewGit(ctx, root, append([]string{"status", "--short", "--untracked-files=all"}, paths...)...)
	if err != nil {
		return "", false, err
	}
	args := []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color"}
	if _, _, err := reviewGit(ctx, root, "rev-parse", "--verify", "HEAD"); err == nil {
		args = append(args, "HEAD")
	}
	text, truncated, err := reviewGit(ctx, root, append(args, paths...)...)
	if err != nil {
		return "", false, err
	}
	// An unborn branch has no HEAD. Its index needs a separate diff.
	if len(args) == 4 {
		staged, c, err := reviewGit(ctx, root, append([]string{"diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color"}, paths...)...)
		if err != nil {
			return "", false, err
		}
		text += staged
		truncated = truncated || c
	}
	untracked, c, err := reviewGit(ctx, root, append([]string{"ls-files", "--others", "--exclude-standard", "-z"}, paths...)...)
	if err != nil {
		return "", false, err
	}
	truncated = truncated || c || cut
	files, err := os.OpenRoot(root)
	if err != nil {
		return "", false, err
	}
	defer files.Close()
	out := &boundedOutput{limit: reviewLimit}
	fmt.Fprintln(out, "Changed files\n"+status+"\nWorking tree changes")
	io.WriteString(out, text)
	for _, name := range strings.Split(untracked, "\x00") {
		if name == "" || out.truncated {
			continue
		}
		info, err := files.Lstat(name)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		fmt.Fprintf(out, "\ndiff --git a/%s b/%s\nnew file\n", name, name)
		if info.Size() > 128<<10 {
			fmt.Fprintln(out, "The new file is larger than the preview limit.")
			continue
		}
		f, err := files.Open(name)
		if err != nil {
			return "", false, err
		}
		data, err := io.ReadAll(io.LimitReader(f, (128<<10)+1))
		f.Close()
		if err != nil {
			return "", false, err
		}
		if bytes.ContainsRune(data, 0) {
			fmt.Fprintln(out, "Binary file")
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			fmt.Fprintln(out, "+"+line)
		}
	}
	if strings.TrimSpace(status) == "" {
		return "No changes in this repository.", false, nil
	}
	return colorDiff(out.String()), truncated || out.truncated, nil
}

func colorDiff(text string) string {
	text = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, text)
	var out strings.Builder
	for _, line := range strings.Split(text, "\n") {
		color := ""
		switch {
		case strings.HasPrefix(line, "+"):
			color = "\x1b[32m"
		case strings.HasPrefix(line, "-"):
			color = "\x1b[31m"
		case strings.HasPrefix(line, "@@"):
			color = "\x1b[36m"
		}
		out.WriteString(color + line)
		if color != "" {
			out.WriteString("\x1b[0m")
		}
		out.WriteByte('\n')
	}
	return out.String()
}

func (d *Daemon) readReview(pane, path string) *proto.Packet {
	reply := map[string]any{"kind": "output", "pane": pane, "format": "ansi", "review": true}
	d.mu.Lock()
	allowed := d.cfg.Herdr && d.herdrAgentLocked(pane)
	d.mu.Unlock()
	if !allowed {
		reply["error"] = "No accessible agent runs in this pane"
		return proto.New(proto.TypeFluxHerdr, reply)
	}
	ctx, cancel := context.WithTimeout(d.ctx, 10*time.Second)
	defer cancel()
	snap, err := herdr.GetSnapshot(ctx, d.herdrPath)
	var dir string
	if err == nil {
		for _, agent := range snap.Agents {
			if agent.PaneID == pane {
				dir = agent.ForegroundCwd
				if dir == "" {
					dir = agent.Cwd
				}
				break
			}
		}
		if dir == "" {
			err = errors.New("the agent has no project folder")
		}
	}
	if err == nil {
		reply["text"], reply["truncated"], err = repositoryDiff(ctx, dir, path)
	}
	if err != nil {
		reply["error"] = err.Error()
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}
