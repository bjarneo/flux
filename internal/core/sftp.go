package core

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// maxBrowseSession is the longest time that a Browse PC session stays open.
const maxBrowseSession = time.Hour

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
		"tunnel": id, "user": "flux", "password": password,
		"path": home, "multiPaths": roots, "pathNames": names,
	})); err != nil {
		l.CancelTunnel(id)
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(d.ctx, maxBrowseSession)
		defer cancel()
		cancelOnLinkDown(ctx, l, cancel)
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
