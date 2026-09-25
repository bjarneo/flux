package desktop

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// The v4l2loopback control device adds and removes virtual cameras at run
// time. Omarchy can load the module for a laptop camera, so fluxd adds its
// own device next to the existing ones and does not change the module
// options.
const loopbackControl = "/dev/v4l2loopback"

// loopbackConfig is struct v4l2_loopback_config from v4l2loopback.h,
// version 0.15. It has 72 bytes.
type loopbackConfig struct {
	OutputNr        int32
	CaptureNr       int32
	CardLabel       [32]byte
	MinWidth        uint32
	MaxWidth        uint32
	MinHeight       uint32
	MaxHeight       uint32
	MaxBuffers      int32
	MaxOpeners      int32
	Debug           int32
	AnnounceAllCaps int32
}

// ioctl numbers: _IOW('~', 1, struct v4l2_loopback_config) and
// _IOW('~', 2, __u32).
var (
	loopbackAdd    = ioctlWrite('~', 1, unsafe.Sizeof(loopbackConfig{}))
	loopbackRemove = ioctlWrite('~', 2, 4)
)

func ioctlWrite(typ byte, nr uintptr, size uintptr) uintptr {
	const iocWrite = 1
	return iocWrite<<30 | size<<16 | uintptr(typ)<<8 | nr
}

// Loopback is a virtual camera that fluxd writes frames to.
type Loopback struct {
	Nr    int
	Path  string
	Label string
	added bool
}

// sysfsVideo is the sysfs folder of video devices. Tests change it.
var sysfsVideo = "/sys/class/video4linux"

// OpenLoopback returns the virtual camera with the label. It reuses a
// device with that label, for example one that a crashed fluxd left, and
// adds a new device when none exists.
func OpenLoopback(label string) (*Loopback, error) {
	if nr, ok := findLoopback(label); ok {
		return &Loopback{Nr: nr, Path: fmt.Sprintf("/dev/video%d", nr), Label: label, added: true}, nil
	}
	fd, err := unix.Open(loopbackControl, unix.O_RDWR|unix.O_CLOEXEC, 0)
	switch {
	case errors.Is(err, unix.ENOENT):
		return nil, errors.New("the v4l2loopback module is not loaded. Install v4l2loopback-dkms, then run: sudo modprobe v4l2loopback devices=0")
	case errors.Is(err, unix.EACCES), errors.Is(err, unix.EPERM):
		return nil, errors.New("fluxd cannot add a virtual camera. Install the udev rule 61-flux-v4l2loopback.rules, then run: sudo udevadm trigger /dev/v4l2loopback")
	case err != nil:
		return nil, fmt.Errorf("open %s: %w", loopbackControl, err)
	}
	defer unix.Close(fd)
	cfg := loopbackConfig{OutputNr: -1, CaptureNr: -1}
	copy(cfg.CardLabel[:len(cfg.CardLabel)-1], label)
	nr, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), loopbackAdd, uintptr(unsafe.Pointer(&cfg)))
	if errno != 0 {
		return nil, fmt.Errorf("add virtual camera: %w", errno)
	}
	l := &Loopback{Nr: int(nr), Path: fmt.Sprintf("/dev/video%d", nr), Label: label, added: true}
	// udev creates the device node a moment after the ioctl.
	for range 40 {
		if _, err := os.Stat(l.Path); err == nil {
			return l, nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return l, fmt.Errorf("%s did not appear", l.Path)
}

// findLoopback returns the number of the video device with the label.
func findLoopback(label string) (int, bool) {
	entries, _ := os.ReadDir(sysfsVideo)
	for _, e := range entries {
		name, err := os.ReadFile(filepath.Join(sysfsVideo, e.Name(), "name"))
		if err != nil || strings.TrimSpace(string(name)) != label {
			continue
		}
		if nr, err := strconv.Atoi(strings.TrimPrefix(e.Name(), "video")); err == nil {
			return nr, true
		}
	}
	return 0, false
}

// Close removes the virtual camera.
func (l *Loopback) Close() error {
	if !l.added {
		return nil
	}
	fd, err := unix.Open(loopbackControl, unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), loopbackRemove, uintptr(l.Nr)); errno != 0 {
		return fmt.Errorf("remove %s: %w", l.Path, errno)
	}
	l.added = false
	return nil
}
