package ipc

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

// PrivateDir makes the runtime folder of Flux, dir, with mode 0700 when it
// is missing, and checks it as OwnDir does. fluxd keeps its socket and its
// runtime files in this folder, so another user cannot put a socket or a
// file in their place. Flux owns this folder, so a folder that others can
// only read, such as a folder that a desktop host made with mode 0755, gets
// mode 0700.
func PrivateDir(dir string) error {
	st, err := OwnDir(dir)
	if err != nil {
		return err
	}
	if st.Mode().Perm()&0o077 != 0 {
		return os.Chmod(dir, 0o700)
	}
	return nil
}

// OwnDir makes the folder dir with mode 0700 when it is missing. It checks
// that dir is a real folder of this user that no other user can write to.
// It does not change the mode of a folder, because FLUX_SOCKET can name a
// folder that Flux does not own, such as the home folder.
func OwnDir(dir string) (fs.FileInfo, error) {
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return nil, fmt.Errorf("%s is not a folder", dir)
	}
	if err := checkOwner(dir, st, os.Getuid()); err != nil {
		return nil, err
	}
	if perm := st.Mode().Perm(); perm&0o022 != 0 {
		return nil, fmt.Errorf("other users can write to %s, because its mode is %04o. Remove the folder, or run: chmod 700 %s", dir, perm, dir)
	}
	return st, nil
}

// CheckSocket checks that the folder of the socket path and the socket
// belong to the user uid, so that a client does not send data to a socket
// of another user.
func CheckSocket(path string, uid int) error {
	dir := filepath.Dir(path)
	st, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if err := checkOwner(dir, st, uid); err != nil {
		return err
	}
	st, err = os.Lstat(path)
	if err != nil {
		return err
	}
	if st.Mode().Type() != fs.ModeSocket {
		return fmt.Errorf("%s is not a socket", path)
	}
	return checkOwner(path, st, uid)
}

func checkOwner(path string, st fs.FileInfo, uid int) error {
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("cannot read the owner of %s", path)
	}
	if int(sys.Uid) != uid {
		return fmt.Errorf("%s belongs to user %d, not to user %d", path, sys.Uid, uid)
	}
	return nil
}

// CheckPeer checks with SO_PEERCRED that the process at the other end of a
// Unix socket runs as the user uid.
func CheckPeer(c net.Conn, uid int) error {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return errors.New("the socket is not a Unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if credErr != nil {
		return credErr
	}
	if int(cred.Uid) != uid {
		return fmt.Errorf("the socket belongs to user %d, not to user %d", cred.Uid, uid)
	}
	return nil
}

// peerClosed reports whether the client closed its end of the connection
// completely. After a half-close with shutdown(SHUT_WR), the client can
// still read, and the kernel reports no hang-up.
func peerClosed(c net.Conn) bool {
	sc, ok := c.(syscall.Conn)
	if !ok {
		return false
	}
	raw, err := sc.SyscallConn()
	if err != nil {
		return false
	}
	closed := false
	_ = raw.Control(func(fd uintptr) {
		fds := []unix.PollFd{{Fd: int32(fd)}}
		if n, err := unix.Poll(fds, 0); err == nil && n > 0 {
			closed = fds[0].Revents&(unix.POLLHUP|unix.POLLERR) != 0
		}
	})
	return closed
}
