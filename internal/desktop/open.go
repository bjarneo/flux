package desktop

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Open opens a file or a URL with xdg-open. It does not wait for the
// program to finish. The program starts in its own scope, see
// UserCommand.
func Open(target string) error {
	return startDetached(UserCommand("xdg-open", target))
}

// userScope reports whether fluxd can start a program in its own
// transient systemd scope. It runs systemd-run once. It is false when
// fluxd does not run as a systemd service, because then no restart of the
// service stops the programs. systemd sets INVOCATION_ID for a service.
// Tests replace it, so that they start no systemd unit.
var userScope = sync.OnceValue(func() bool {
	if os.Getenv("INVOCATION_ID") == "" {
		return false
	}
	path, err := exec.LookPath("systemd-run")
	if err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, path, scopeArgs(true, "true", nil)[1:]...).Run() == nil
})

// UserCommand returns a command that starts the program name with args for
// the user, such as a browser or an editor. The program runs in its own
// transient systemd scope. systemd stops only the processes in the cgroup
// of fluxd.service, so the program keeps running when fluxd restarts after
// an update. Without a working systemd-run, or outside a systemd
// service, the program starts in the cgroup of fluxd.
func UserCommand(name string, args ...string) *exec.Cmd {
	argv := scopeArgs(userScope(), name, args)
	return exec.Command(argv[0], argv[1:]...)
}

// scopeArgs returns the command line that starts name with args. With
// scope, systemd-run starts the program in a new scope and then runs it
// as its own process, so Wait and the output of the program work as
// without the scope.
func scopeArgs(scope bool, name string, args []string) []string {
	argv := append([]string{name}, args...)
	if !scope {
		return argv
	}
	return append([]string{"systemd-run", "--user", "--scope", "--collect", "--quiet", "--"}, argv...)
}

// outputWait is how long RunCommand waits for more output after the shell
// exits.
var outputWait = 2 * time.Second

// RunCommand runs a shell command with `sh -c`. It does not wait for the
// command to finish. When the command ends, done receives its error and up
// to 4 KiB of its output. done can be nil. The command starts in its own
// scope, see UserCommand.
func RunCommand(command string, done func(err error, output []byte)) error {
	cmd := UserCommand("sh", "-c", command)
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
