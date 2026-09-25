package desktop

import (
	"bytes"
	"os"
	"os/exec"
	"syscall"
)

// Open opens a file or a URL with xdg-open. It does not wait for the
// program to finish.
func Open(target string) error {
	return startDetached(exec.Command("xdg-open", target))
}

// RunCommand runs a shell command with `sh -c`. It does not wait for the
// command to finish. When the command ends, done receives its error and up
// to 4 KiB of its output. done can be nil.
func RunCommand(command string, done func(err error, output []byte)) error {
	cmd := exec.Command("sh", "-c", command)
	out := &limitedBuffer{max: 4096}
	cmd.Stdout, cmd.Stderr = out, out
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() {
		err := cmd.Wait()
		if done != nil {
			done(err, out.Bytes())
		}
	}()
	return nil
}

// limitedBuffer keeps the first max bytes that a command writes.
type limitedBuffer struct {
	bytes.Buffer
	max int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := b.max - b.Len(); room > 0 {
		if len(p) > room {
			b.Buffer.Write(p[:room])
		} else {
			b.Buffer.Write(p)
		}
	}
	return len(p), nil
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
