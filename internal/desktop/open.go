package desktop

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Open opens a file or a URL with xdg-open. It does not wait for the
// program to finish.
func Open(target string) error {
	return startDetached(exec.Command("xdg-open", target))
}

// outputWait is how long RunCommand waits for more output after the shell
// exits.
var outputWait = 2 * time.Second

// RunCommand runs a shell command with `sh -c`. It does not wait for the
// command to finish. When the command ends, done receives its error and up
// to 4 KiB of its output. done can be nil.
func RunCommand(command string, done func(err error, output []byte)) error {
	cmd := exec.Command("sh", "-c", command)
	// The command writes to an os.File, so Wait does not copy the output
	// and returns when the shell exits. A program that the command starts
	// in the background, such as `kitty &`, keeps the pipe open. A
	// goroutine reads the pipe until that program exits, so a write of the
	// program does not fail with SIGPIPE.
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	cmd.Stdout, cmd.Stderr = w, w
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err = cmd.Start()
	w.Close()
	if err != nil {
		r.Close()
		return err
	}
	out := &limitedBuffer{max: 4096}
	eof := make(chan struct{})
	go func() {
		_, _ = io.Copy(out, r)
		r.Close()
		close(eof)
	}()
	go func() {
		err := cmd.Wait()
		select {
		case <-eof:
		case <-time.After(outputWait):
		}
		if done != nil {
			done(err, out.Bytes())
		}
	}()
	return nil
}

// limitedBuffer keeps the first max bytes that a command writes. It is
// safe for concurrent use.
type limitedBuffer struct {
	mu  sync.Mutex
	buf []byte
	max int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := b.max - len(b.buf); room > 0 {
		b.buf = append(b.buf, p[:min(len(p), room)]...)
	}
	return len(p), nil
}

// Bytes returns a copy of the bytes that b keeps.
func (b *limitedBuffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return bytes.Clone(b.buf)
}

// startDetached starts cmd in a new session in the home directory. A
// goroutine waits for the process, so it does not stay as a zombie.
func startDetached(cmd *exec.Cmd) error {
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}
