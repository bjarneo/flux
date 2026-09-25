package core

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// SftpInfo is the body of a kdeconnect.sftp packet.
type SftpInfo struct {
	IP         string   `json:"ip"`
	Port       int      `json:"port"`
	User       string   `json:"user"`
	Password   string   `json:"password"`
	Path       string   `json:"path"`
	MultiPaths []string `json:"multiPaths"`
	PathNames  []string `json:"pathNames"`
	Error      string   `json:"errorMessage"`
}

// BrowseRoot is a top folder that the phone shares.
type BrowseRoot struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// BrowseEntry is one file or folder on the phone.
type BrowseEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Dir   bool   `json:"dir"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
	Kind  string `json:"kind"`
}

func (d *Daemon) handleSftp(dev *Device, p *proto.Packet) {
	var info SftpInfo
	if p.Decode(&info) != nil {
		return
	}
	d.mu.Lock()
	waiters := dev.sftpWait
	dev.sftpWait = nil
	d.mu.Unlock()
	for _, ch := range waiters {
		select {
		case ch <- info:
		default:
		}
	}
}

// BrowseOpen starts the SFTP server on the phone and connects to it.
func (d *Daemon) BrowseOpen(dev *Device) ([]BrowseRoot, error) {
	d.mu.Lock()
	if dev.sftpClient != nil {
		roots := dev.sftpRoots
		d.mu.Unlock()
		if _, err := dev.sftpClient.Getwd(); err == nil {
			return roots, nil
		}
		d.mu.Lock()
		dev.closeSftp()
	}
	ch := make(chan SftpInfo, 1)
	dev.sftpWait = append(dev.sftpWait, ch)
	d.mu.Unlock()
	if err := d.send(dev, proto.New(proto.TypeSftpRequest, map[string]any{"startBrowsing": true})); err != nil {
		return nil, err
	}
	var info SftpInfo
	select {
	case info = <-ch:
	case <-time.After(15 * time.Second):
		return nil, apiErr("timeout", "%s did not start file sharing. Allow storage access in the KDE Connect app", dev.Name)
	}
	if info.Error != "" {
		return nil, apiErr("phone", "%s", info.Error)
	}
	host := info.IP
	if host == "" {
		host = dev.IP
	}
	conn, err := ssh.Dial("tcp", net.JoinHostPort(host, fmt.Sprint(info.Port)), &ssh.ClientConfig{
		User: info.User,
		Auth: []ssh.AuthMethod{ssh.Password(info.Password)},
		// The phone makes a new host key for each install. The password comes
		// over the TLS link, so the key is not pinned.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	})
	if err != nil {
		return nil, apiErr("sftp", "Connect to %s: %v", dev.Name, err)
	}
	client, err := sftp.NewClient(conn)
	if err != nil {
		conn.Close()
		return nil, apiErr("sftp", "SFTP on %s: %v", dev.Name, err)
	}
	roots := []BrowseRoot{}
	for i, p := range info.MultiPaths {
		name := path.Base(p)
		if i < len(info.PathNames) && info.PathNames[i] != "" {
			name = info.PathNames[i]
		}
		roots = append(roots, BrowseRoot{Name: name, Path: p})
	}
	if len(roots) == 0 {
		roots = append(roots, BrowseRoot{Name: path.Base(info.Path), Path: info.Path})
	}
	d.mu.Lock()
	dev.sftpSSH, dev.sftpClient, dev.sftpRoots = conn, client, roots
	d.mu.Unlock()
	return roots, nil
}

func (d *Daemon) sftpFor(dev *Device) (*sftp.Client, error) {
	d.mu.Lock()
	c := dev.sftpClient
	d.mu.Unlock()
	if c != nil {
		return c, nil
	}
	if _, err := d.BrowseOpen(dev); err != nil {
		return nil, err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	return dev.sftpClient, nil
}

// BrowseList lists a folder on the phone. Folders come first.
func (d *Daemon) BrowseList(dev *Device, dir string) ([]BrowseEntry, error) {
	c, err := d.sftpFor(dev)
	if err != nil {
		return nil, err
	}
	infos, err := c.ReadDir(dir)
	if err != nil {
		return nil, apiErr("sftp", "%s: %v", dir, err)
	}
	out := make([]BrowseEntry, 0, len(infos))
	for _, fi := range infos {
		if strings.HasPrefix(fi.Name(), ".") {
			continue
		}
		e := BrowseEntry{Name: fi.Name(), Path: path.Join(dir, fi.Name()), Dir: fi.IsDir(), Size: fi.Size(), Mtime: fi.ModTime().Unix()}
		e.Kind = fileKind(e.Name, e.Dir)
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dir != out[j].Dir {
			return out[i].Dir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// BrowseGet downloads a file from the phone into the download folder.
func (d *Daemon) BrowseGet(dev *Device, remote string) (*Transfer, error) {
	c, err := d.sftpFor(dev)
	if err != nil {
		return nil, err
	}
	fi, err := c.Stat(remote)
	if err != nil {
		return nil, apiErr("sftp", "%s: %v", remote, err)
	}
	t := d.newTransfer(dev, path.Base(remote), "in", fi.Size())
	ctx, cancel := context.WithCancel(d.ctx)
	d.mu.Lock()
	t.cancel = cancel
	dir := d.cfg.DownloadPath()
	d.mu.Unlock()
	go func() {
		defer cancel()
		err := func() error {
			src, err := c.Open(remote)
			if err != nil {
				return err
			}
			defer src.Close()
			stop := context.AfterFunc(ctx, func() { src.Close() })
			defer stop()
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return err
			}
			dest := uniquePath(filepath.Join(dir, safeName(path.Base(remote))))
			d.mu.Lock()
			t.Path, t.Name = dest, filepath.Base(dest)
			d.mu.Unlock()
			f, err := os.Create(dest + ".part")
			if err != nil {
				return err
			}
			_, err = io.Copy(f, &countingReader{r: src, fn: d.progress(t)})
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err != nil {
				os.Remove(dest + ".part")
				return err
			}
			return os.Rename(dest+".part", dest)
		}()
		d.finishTransfer(t, err)
	}()
	return t, nil
}

func fileKind(name string, dir bool) string {
	if dir {
		return "folder"
	}
	switch strings.ToLower(path.Ext(name)) {
	case ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".avif":
		return "image"
	case ".mp4", ".mkv", ".mov", ".webm", ".3gp":
		return "video"
	case ".mp3", ".flac", ".ogg", ".opus", ".m4a", ".wav":
		return "audio"
	case ".pdf":
		return "pdf"
	case ".txt", ".md", ".json", ".csv", ".log":
		return "text"
	case ".zip", ".tar", ".gz", ".7z", ".rar":
		return "archive"
	case ".apk":
		return "apk"
	case ".iso", ".img":
		return "iso"
	}
	return "file"
}

// maxBrowseSession is the longest time that a Browse PC session stays open.
const maxBrowseSession = time.Hour

// handleBrowseRequest answers kdeconnect.sftp.request from a Flux phone.
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
	allowed := d.cfg.ShareHome
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
	roots, names := []string{home}, []string{"Home"}
	for _, r := range []struct{ name, path string }{
		{"Downloads", downloads},
		{"Documents", filepath.Join(home, "Documents")},
		{"Pictures", filepath.Join(home, "Pictures")},
		{"Music", filepath.Join(home, "Music")},
		{"Videos", filepath.Join(home, "Videos")},
	} {
		if fi, err := os.Stat(r.path); err == nil && fi.IsDir() {
			roots, names = append(roots, r.path), append(names, r.name)
		}
	}
	id := l.NewTunnelID()
	if err := l.Send(proto.New(proto.TypeSftp, map[string]any{
		"tunnel": id, "user": "kdeconnect", "password": password,
		"path": home, "multiPaths": roots, "pathNames": names,
	})); err != nil {
		l.TunnelReady(id, 0, "canceled")
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(d.ctx, maxBrowseSession)
		defer cancel()
		tc, err := l.OpenTunnel(ctx, id)
		if err != nil {
			d.logf("%s: Browse PC tunnel: %v", dev.Name, err)
			return
		}
		stop := context.AfterFunc(ctx, func() { tc.Close() })
		defer stop()
		d.toast("%s is browsing this computer", dev.Name)
		serveSSH(tc, cfg, home, d.logf)
	}()
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
			if c.User() == "kdeconnect" && subtle.ConstantTimeCompare(pw, []byte(password)) == 1 {
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
func serveSSH(conn net.Conn, cfg *ssh.ServerConfig, home string, logf func(string, ...any)) {
	defer conn.Close()
	sc, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		logf("Browse PC SSH: %v", err)
		return
	}
	defer sc.Close()
	go ssh.DiscardRequests(reqs)
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
				server, err := sftp.NewServer(ch, sftp.ReadOnly(), sftp.WithServerWorkingDirectory(home))
				if err != nil {
					logf("sftp server: %v", err)
					ch.Close()
					return
				}
				_ = server.Serve()
				server.Close()
				return
			}
		}()
	}
}
