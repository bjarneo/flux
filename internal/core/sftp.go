package core

import (
	"cmp"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"io"
	"net"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxBrowseSession is the longest time that a Browse PC session stays open.
const maxBrowseSession = time.Hour

// Browse PC gives a paired phone read-only access to these folders: the
// home folder, the download folder, and the Documents, Pictures, Music, and
// Videos folders. The SFTP server serves only these roots. It opens each
// path through an os.Root, so an absolute path, a ".." path, or a symlink
// cannot leave a root. It hides each name that starts with a dot, such as
// ~/.ssh and ~/.config, and the Flux folders. It refuses each write.
//
// Each device has 1 session. The desktop shows a notification with a Stop
// button while a session runs. The session ends when share_home turns off,
// when the device is no longer paired, and when the link drops.

// browseSession is 1 Browse PC session.
type browseSession struct {
	dev    *Device
	cancel context.CancelFunc
	// notice is the desktop notification that shows while the session
	// runs.
	notice uint32

	// start is the time when the session began.
	start time.Time
}

// BrowseView is 1 Browse PC session for the window. Since is the start in
// Unix seconds.
type BrowseView struct {
	Device string `json:"device"`
	Name   string `json:"name"`
	Since  int64  `json:"since"`
}

// browseViewLocked lists the Browse PC sessions, the oldest first.
func (d *Daemon) browseViewLocked() []BrowseView {
	out := make([]BrowseView, 0, len(d.sessions.browse))
	for _, s := range d.sessions.browse {
		out = append(out, BrowseView{Device: s.dev.ID, Name: s.dev.Name, Since: s.start.Unix()})
	}
	slices.SortFunc(out, func(a, b BrowseView) int {
		return cmp.Or(cmp.Compare(a.Since, b.Since), strings.Compare(a.Device, b.Device))
	})
	return out
}

// handleBrowseRequest answers flux.sftp.request from a Flux phone.
// The SFTP server does not listen on the network. The phone opens a tunnel
// listener, fluxd connects out to it, and the SSH session runs inside the
// tunnel, so Browse PC works with a firewall that blocks incoming traffic.
func (d *Daemon) handleBrowseRequest(dev *Device, l *lan.Link, p *proto.Packet) {
	var b struct {
		Start bool `json:"startBrowsing"`
	}
	if p.Decode(&b) != nil || !b.Start {
		return
	}
	d.mu.Lock()
	allowed := d.cfg.ShareHome && dev.Paired && d.permittedLocked(dev.ID, "shareHome")
	downloads := d.cfg.DownloadPath()
	d.mu.Unlock()
	if !allowed {
		_ = l.Send(proto.New(proto.TypeSftp, map[string]any{"errorMessage": "Browsing is off on this computer. Set share_home = true in ~/.config/flux/config.toml"}))
		return
	}
	if !l.CanTunnel() {
		_ = l.Send(proto.New(proto.TypeSftp, map[string]any{"errorMessage": "Browsing this computer needs Flux for Android"}))
		return
	}
	cfg, password, err := browseConfig()
	if err != nil {
		_ = l.Send(proto.New(proto.TypeSftp, map[string]any{"errorMessage": err.Error()}))
		return
	}
	home, _ := os.UserHomeDir()
	fsys, err := openBrowseFS(browseRoots(home, downloads), browseHidden())
	if err != nil {
		_ = l.Send(proto.New(proto.TypeSftp, map[string]any{"errorMessage": err.Error()}))
		return
	}
	roots, names := make([]string, 0, len(fsys.roots)), make([]string, 0, len(fsys.roots))
	for _, r := range fsys.roots {
		roots, names = append(roots, r.path), append(names, r.name)
	}
	id := l.NewTunnelID()
	if err := l.Send(proto.New(proto.TypeSftp, map[string]any{
		"tunnel": id, "user": "flux", "password": password,
		"path": fsys.start, "multiPaths": roots, "pathNames": names,
	})); err != nil {
		l.CancelTunnel(id)
		fsys.Close()
		return
	}
	d.startBrowse(dev, l, fsys, cfg, func(ctx context.Context) (net.Conn, error) {
		tc, err := l.OpenTunnel(ctx, id)
		if err != nil {
			return nil, err
		}
		return tc, nil
	})
}

// startBrowse registers a Browse PC session of a device and serves fsys on
// the tunnel that open returns. It returns the context of the session.
func (d *Daemon) startBrowse(dev *Device, l interface{ Done() <-chan struct{} }, fsys *browseFS, cfg *ssh.ServerConfig, open func(context.Context) (net.Conn, error)) context.Context {
	ctx, cancel := context.WithTimeout(d.ctx, maxBrowseSession)
	n, s := d.addBrowse(dev, cancel)
	// Each request and each read checks again, so a session cannot read
	// after share_home turns off or after an unpair.
	fsys.allowed = func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return d.cfg.ShareHome && dev.Paired && d.permittedLocked(dev.ID, "shareHome") && d.sessions.browse[n] == s && ctx.Err() == nil
	}
	d.watchSession(ctx, cancel, dev, l, func() bool { return d.cfg.ShareHome && d.permittedLocked(dev.ID, "shareHome") })

	go func() {
		defer d.dropBrowse(n, s)
		defer cancel()
		defer fsys.Close()
		name := d.nameOf(dev)
		tc, err := open(ctx)
		if err != nil {
			d.logf("%s: Browse PC tunnel: %v", name, err)
			return
		}
		stop := context.AfterFunc(ctx, func() { tc.Close() })
		defer stop()
		// The tunnel wait can span a change of the switch.
		if !fsys.allowed() {
			tc.Close()
			return
		}
		// The notification stays until the session ends, so that the user
		// sees the session and its Stop button.
		notice := d.notify(desktop.Notification{
			AppName: "Flux", Title: name + " browses this computer",
			Body:    "The device can read the files in your home folder.",
			Actions: []desktop.Action{{Key: "browse-stop:" + strconv.FormatUint(n, 10), Label: "Stop"}},
			Timeout: -1,
		})
		d.mu.Lock()
		s.notice = notice
		d.mu.Unlock()
		d.logf("%s: Browse PC started", name)
		serveSSH(tc, cfg, fsys, d.logf)
		d.logf("%s: Browse PC stopped", name)
	}()
	return ctx
}

// addBrowse registers a new Browse PC session of a device and ends the
// older session of that device. It returns the number of the session.
func (d *Daemon) addBrowse(dev *Device, cancel context.CancelFunc) (uint64, *browseSession) {
	s := &browseSession{dev: dev, cancel: cancel, start: time.Now()}
	d.mu.Lock()
	if d.sessions.browse == nil {
		d.sessions.browse = map[uint64]*browseSession{}
	}
	var old []*browseSession
	for n, o := range d.sessions.browse {
		if o.dev.ID == dev.ID {
			old = append(old, o)
			delete(d.sessions.browse, n)
		}
	}
	d.sessions.browseGen++
	n := d.sessions.browseGen
	d.sessions.browse[n] = s
	d.mu.Unlock()
	for _, o := range old {
		o.cancel()
	}
	d.markDirty()
	return n, s
}

// dropBrowse removes a session that ended and closes its notification.
func (d *Daemon) dropBrowse(n uint64, s *browseSession) {
	d.mu.Lock()
	if d.sessions.browse[n] == s {
		delete(d.sessions.browse, n)
	}
	notice := s.notice
	d.mu.Unlock()
	if notice != 0 && d.notifier != nil {
		_ = d.notifier.Close(notice)
	}
	d.markDirty()
}

// endBrowse ends the Browse PC sessions of a device. An empty ID ends
// every session. It returns the number of sessions that it ended.
func (d *Daemon) endBrowse(deviceID string) int {
	d.mu.Lock()
	var ended []*browseSession
	for n, s := range d.sessions.browse {
		if deviceID == "" || s.dev.ID == deviceID {
			ended = append(ended, s)
			delete(d.sessions.browse, n)
		}
	}
	d.mu.Unlock()
	for _, s := range ended {
		s.cancel()
	}
	if len(ended) > 0 {
		d.markDirty()
	}
	return len(ended)
}

// StopBrowse ends the Browse PC session of the device with the ID or the
// name key. An empty key ends every session.
func (d *Daemon) StopBrowse(key string) error {
	id := ""
	if key != "" {
		dev, err := d.find(key, nil)
		if err != nil {
			return err
		}
		id = dev.ID
	}
	if d.endBrowse(id) == 0 {
		return apiErr("not_active", "No device browses this computer")
	}
	return nil
}

// stopBrowse ends the Browse PC session with the number from the Stop
// button of its notification.
func (d *Daemon) stopBrowse(number string) {
	n, err := strconv.ParseUint(number, 10, 64)
	if err != nil {
		return
	}
	d.mu.Lock()
	s := d.sessions.browse[n]
	delete(d.sessions.browse, n)
	d.mu.Unlock()
	if s != nil {
		s.cancel()
		d.markDirty()
	}
}

// shareHomeChanged ends every Browse PC session when share_home is off.
func (d *Daemon) shareHomeChanged() {
	d.mu.Lock()
	on := d.cfg.ShareHome
	d.mu.Unlock()
	if !on {
		d.endBrowse("")
	}
}

// browseConfig returns the SSH settings for 1 Browse PC session. Each
// session gets a new host key and a new one-time password.
func browseConfig() (*ssh.ServerConfig, string, error) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, "", err
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		return nil, "", err
	}
	password := config.NewID(16)
	cfg := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
			if c.User() == "flux" && subtle.ConstantTimeCompare(pw, []byte(password)) == 1 {
				return nil, nil
			}
			return nil, errors.New("access denied")
		},
	}
	cfg.AddHostKey(signer)
	return cfg, password, nil
}

// serveSSH runs a read-only SFTP server on one connection until the client
// closes it.
func serveSSH(conn net.Conn, cfg *ssh.ServerConfig, fsys *browseFS, logf func(string, ...any)) {
	defer conn.Close()
	sc, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		logf("Browse PC SSH: %v", err)
		return
	}
	defer sc.Close()
	go ssh.DiscardRequests(reqs)
	handlers := sftp.Handlers{FileGet: fsys, FilePut: fsys, FileCmd: fsys, FileList: fsys}
	for nc := range chans {
		if nc.ChannelType() != "session" {
			_ = nc.Reject(ssh.UnknownChannelType, "only sessions")
			continue
		}
		ch, requests, err := nc.Accept()
		if err != nil {
			continue
		}
		go func() {
			for req := range requests {
				ok := req.Type == "subsystem" && len(req.Payload) > 4 && string(req.Payload[4:]) == "sftp"
				_ = req.Reply(ok, nil)
				if !ok {
					continue
				}
				server := sftp.NewRequestServer(ch, handlers, sftp.WithStartDirectory(fsys.start))
				_ = server.Serve()
				server.Close()
				return
			}
		}()
	}
}

// browseRoots returns the folders that the phone can browse, as name and
// path pairs: the home folder first, then the download folder and the
// usual folders of home that exist. A download_dir that holds the home
// folder, such as /, is left out. A download_dir inside a folder of home
// with a dot name, such as ~/.config, is left out too.
func browseRoots(home, downloads string) [][2]string {
	home = filepath.Clean(home)
	roots := [][2]string{{"Home", home}}
	for _, r := range [][2]string{
		{"Downloads", downloads},
		{"Documents", filepath.Join(home, "Documents")},
		{"Pictures", filepath.Join(home, "Pictures")},
		{"Music", filepath.Join(home, "Music")},
		{"Videos", filepath.Join(home, "Videos")},
	} {
		p := filepath.Clean(r[1])
		switch {
		case p != home && within(p, home):
			continue
		case within(home, p) && hiddenName(strings.TrimPrefix(p, home)):
			continue
		}
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			roots = append(roots, r)
		}
	}
	return roots
}

// browseHidden returns the Flux folders, which Browse PC never shows. They
// hold the private key of this computer and the pinned certificates.
func browseHidden() []string {
	return []string{config.ConfigDir(), config.DataDir(), config.CacheDir(), config.RuntimeDir()}
}

// browseRoot is 1 folder that the phone can browse.
type browseRoot struct {
	name string
	// path is the path that the phone uses, and real is the same folder
	// without symlinks.
	path string
	real string
	root *os.Root
}

// browseFS serves the roots of 1 Browse PC session read-only. It is the
// set of handlers of the SFTP request server.
type browseFS struct {
	roots []browseRoot
	// start is the path of the first root, where a relative path starts.
	start string
	// hidden are the paths of the folders that stay hidden, as given and
	// without symlinks.
	hidden []string
	// allowed reports whether the session can still read. Nil allows it.
	allowed func() bool
}

// errBrowseDenied is the answer to a path outside the roots, a hidden
// path, and a write.
var errBrowseDenied = sftp.ErrSSHFxPermissionDenied

// openBrowseFS opens the roots, as name and path pairs. It skips a root
// that it cannot open, and it fails when it opens none.
func openBrowseFS(roots [][2]string, hidden []string) (*browseFS, error) {
	fsys := &browseFS{}
	for _, r := range roots {
		p := filepath.Clean(r[1])
		if !filepath.IsAbs(p) {
			continue
		}
		real, err := filepath.EvalSymlinks(p)
		if err != nil {
			continue
		}
		root, err := os.OpenRoot(p)
		if err != nil {
			continue
		}
		fsys.roots = append(fsys.roots, browseRoot{name: r[0], path: p, real: real, root: root})
	}
	if len(fsys.roots) == 0 {
		return nil, errors.New("this computer has no folder to browse")
	}
	fsys.start = fsys.roots[0].path
	for _, h := range hidden {
		fsys.hidden = append(fsys.hidden, filepath.Clean(h))
		if real, err := filepath.EvalSymlinks(h); err == nil {
			fsys.hidden = append(fsys.hidden, real)
		}
	}
	return fsys, nil
}

// Close closes the roots.
func (fsys *browseFS) Close() {
	for _, r := range fsys.roots {
		_ = r.root.Close()
	}
}

// within reports whether p is dir or a path inside dir.
func within(dir, p string) bool {
	return p == dir || strings.HasPrefix(p, strings.TrimSuffix(dir, "/")+"/")
}

// hiddenName reports whether a path has a part that starts with a dot.
func hiddenName(rel string) bool {
	for part := range strings.SplitSeq(rel, "/") {
		if strings.HasPrefix(part, ".") {
			return true
		}
	}
	return false
}

// resolve returns the root of an absolute path and the path inside that
// root. The root with the longest path wins, because a folder such as
// ~/Documents can be a symlink to another drive.
func (fsys *browseFS) resolve(p string) (*browseRoot, string, error) {
	if fsys.allowed != nil && !fsys.allowed() {
		return nil, "", errBrowseDenied
	}
	if !path.IsAbs(p) {
		return nil, "", errBrowseDenied
	}
	p = path.Clean(p)
	var best *browseRoot
	for i := range fsys.roots {
		r := &fsys.roots[i]
		if within(r.path, p) && (best == nil || len(r.path) > len(best.path)) {
			best = r
		}
	}
	if best == nil {
		return nil, "", errBrowseDenied
	}
	rel := strings.TrimPrefix(strings.TrimPrefix(p, best.path), "/")
	if rel == "" {
		return best, ".", nil
	}
	if hiddenName(rel) {
		return nil, "", errBrowseDenied
	}
	return best, rel, nil
}

// visible reports whether a real path is in the root and is not hidden.
func (fsys *browseFS) visible(r *browseRoot, real string) bool {
	if !within(r.real, real) {
		return false
	}
	if rel := strings.TrimPrefix(strings.TrimPrefix(real, r.real), "/"); rel != "" && hiddenName(rel) {
		return false
	}
	for _, h := range fsys.hidden {
		if within(h, real) {
			return false
		}
	}
	return true
}

// openIn opens a regular file or a folder through a root. A symlink in the
// root can point to a hidden path, so openIn checks the real path of the
// file that it opened.
func (fsys *browseFS) openIn(r *browseRoot, rel string) (*os.File, string, error) {
	f, err := openRootFile(r.root, rel)
	if err != nil {
		// os.Root refuses each absolute symlink, also 1 whose target is in
		// the root. Such a target opens by its path in the root.
		target, terr := filepath.EvalSymlinks(filepath.Join(r.path, rel))
		if terr != nil || !within(r.real, target) {
			return nil, "", err
		}
		inner := strings.TrimPrefix(strings.TrimPrefix(target, r.real), "/")
		if inner == "" {
			inner = "."
		}
		if f, err = openRootFile(r.root, inner); err != nil {
			return nil, "", err
		}
	}
	real, err := fdPath(f)
	if err != nil || !fsys.visible(r, real) {
		f.Close()
		return nil, "", errBrowseDenied
	}
	if fi, err := f.Stat(); err != nil || (!fi.Mode().IsRegular() && !fi.IsDir()) {
		f.Close()
		return nil, "", errBrowseDenied
	}
	return f, real, nil
}

// openRootFile opens a regular file or a folder in root. It does not open
// a device or a named pipe.
func openRootFile(root *os.Root, rel string) (*os.File, error) {
	if fi, err := root.Stat(rel); err != nil {
		return nil, err
	} else if !fi.Mode().IsRegular() && !fi.IsDir() {
		return nil, errBrowseDenied
	}
	return root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}

// fdPath returns the path of an open file as the kernel knows it, without
// symlinks.
func fdPath(f *os.File) (string, error) {
	sc, err := f.SyscallConn()
	if err != nil {
		return "", err
	}
	var real string
	var readErr error
	err = sc.Control(func(fd uintptr) {
		real, readErr = os.Readlink("/proc/self/fd/" + strconv.FormatUint(uint64(fd), 10))
	})
	if err != nil {
		return "", err
	}
	return real, readErr
}

// Fileread opens a file for a download.
func (fsys *browseFS) Fileread(req *sftp.Request) (io.ReaderAt, error) {
	r, rel, err := fsys.resolve(req.Filepath)
	if err != nil {
		return nil, err
	}
	f, _, err := fsys.openIn(r, rel)
	if err != nil {
		return nil, err
	}
	if fi, err := f.Stat(); err != nil || fi.IsDir() {
		f.Close()
		return nil, errBrowseDenied
	}
	return &browseFile{File: f, allowed: fsys.allowed}, nil
}

// browseFile is a file of a download. Each read checks that the session
// can still read.
type browseFile struct {
	*os.File
	allowed func() bool
}

func (f *browseFile) ReadAt(b []byte, off int64) (int, error) {
	if f.allowed != nil && !f.allowed() {
		return 0, errBrowseDenied
	}
	return f.File.ReadAt(b, off)
}

// Filewrite refuses each upload.
func (fsys *browseFS) Filewrite(*sftp.Request) (io.WriterAt, error) {
	return nil, errBrowseDenied
}

// Filecmd refuses each change: rename, remove, links, folders, and
// attributes. This includes hardlink@openssh.com.
func (fsys *browseFS) Filecmd(*sftp.Request) error { return errBrowseDenied }

// Filelist lists a folder or returns the attributes of 1 path. Lstat works
// as Stat. Readlink is refused, so no answer shows a target outside the
// roots.
func (fsys *browseFS) Filelist(req *sftp.Request) (sftp.ListerAt, error) {
	if req.Method != "List" && req.Method != "Stat" {
		return nil, errBrowseDenied
	}
	r, rel, err := fsys.resolve(req.Filepath)
	if err != nil {
		return nil, err
	}
	f, real, err := fsys.openIn(r, rel)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if req.Method == "Stat" {
		fi, err := f.Stat()
		if err != nil {
			return nil, err
		}
		return fileList{namedInfo{fi, path.Base(req.Filepath)}}, nil
	}
	entries, err := f.ReadDir(-1)
	if err != nil {
		return nil, err
	}
	var out fileList
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		// A symlink shows as its target when the target is visible in the
		// same root.
		if e.Type()&os.ModeSymlink != 0 {
			if t, _, err := fsys.openIn(r, path.Join(rel, name)); err == nil {
				fi, err := t.Stat()
				t.Close()
				if err == nil {
					out = append(out, namedInfo{fi, name})
				}
			}
			continue
		}
		if !fsys.visible(r, path.Join(real, name)) {
			continue
		}
		// Only files and folders show. A device, a socket, or a named pipe
		// cannot be opened.
		if fi, err := e.Info(); err == nil && (fi.Mode().IsRegular() || fi.IsDir()) {
			out = append(out, fi)
		}
	}
	return out, nil
}

// RealPath returns the absolute form of a path inside the roots. A
// relative path starts at the first root.
func (fsys *browseFS) RealPath(p string) (string, error) {
	if !path.IsAbs(p) {
		p = path.Join(fsys.start, p)
	}
	p = path.Clean(p)
	if _, _, err := fsys.resolve(p); err != nil {
		return "", err
	}
	return p, nil
}

// namedInfo gives the attributes of a file another name.
type namedInfo struct {
	os.FileInfo
	name string
}

func (n namedInfo) Name() string { return n.name }

// fileList is the list of 1 folder or 1 file for the SFTP request server.
type fileList []os.FileInfo

func (l fileList) ListAt(out []os.FileInfo, off int64) (int, error) {
	if off >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(out, l[off:])
	if n < len(out) {
		return n, io.EOF
	}
	return n, nil
}
