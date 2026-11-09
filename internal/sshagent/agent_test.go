package sshagent

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

// fakePhone signs like the phone: SHA256withECDSA over the data, as ASN.1
// DER. Signature then makes the SSH signature.
type fakePhone struct {
	key  *ecdsa.PrivateKey
	pub  ssh.PublicKey
	none bool

	mu    sync.Mutex
	seen  []Data
	raw   [][]byte
	peers []Peer
	// hold makes SSHSign wait until its context ends, and reports the end.
	hold  bool
	ended chan error
}

func newFakePhone(t *testing.T) *fakePhone {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := KeyFromSPKI(der)
	if err != nil {
		t.Fatal(err)
	}
	return &fakePhone{key: k, pub: pub, ended: make(chan error, 1)}
}

func (f *fakePhone) SSHKeys() []Key {
	if f.none {
		return nil
	}
	return []Key{{Blob: f.pub.Marshal(), Comment: "Flux on Test Phone"}}
}

func (f *fakePhone) SSHSign(ctx context.Context, blob, data []byte, peer Peer) (*ssh.Signature, error) {
	if f.none || !bytes.Equal(blob, f.pub.Marshal()) {
		return nil, errors.New("no connected phone has this key")
	}
	d, err := ParseData(data, blob)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	f.seen = append(f.seen, d)
	f.raw = append(f.raw, data)
	f.peers = append(f.peers, peer)
	f.mu.Unlock()
	if f.hold {
		<-ctx.Done()
		f.ended <- ctx.Err()
		return nil, ctx.Err()
	}
	h := sha256.Sum256(data)
	der, err := ecdsa.SignASN1(rand.Reader, f.key, h[:])
	if err != nil {
		return nil, err
	}
	return Signature(f.pub, data, der)
}

func (f *fakePhone) data() []Data {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Data(nil), f.seen...)
}

// serveAgent serves the agent of b on a socket in a new folder and returns
// the socket path.
func serveAgent(t *testing.T, b Backend) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "fa")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "agent.sock")
	ln, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = Serve(ctx, ln, b, t.Logf)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	return path
}

func need(t *testing.T, tools ...string) {
	t.Helper()
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed", tool)
		}
	}
}

// run runs a program with the agent socket and returns its output.
func run(t *testing.T, sock, dir string, stdin []byte, name string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "SSH_AUTH_SOCK="+sock)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestListenMode(t *testing.T) {
	path := serveAgent(t, newFakePhone(t))
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("the socket has mode %04o, want 0600", st.Mode().Perm())
	}
	if _, err := Listen(path); err == nil {
		t.Fatal("a second agent listened on the socket of the first")
	}
}

func TestListenReplacesAStaleSocket(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	// Keep the file of a socket that nobody answers on.
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	ln, err = Listen(path)
	if err != nil {
		t.Fatalf("a stale socket stopped the agent: %v", err)
	}
	ln.Close()
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(path); err == nil {
		t.Fatal("the agent removed a file that is not a socket")
	}
}

// TestSSHKeygenSignAndVerify signs with ssh-keygen -Y sign through the
// agent, and checks the signature with ssh-keygen -Y verify.
func TestSSHKeygenSignAndVerify(t *testing.T) {
	need(t, "ssh-keygen", "ssh-add")
	phone := newFakePhone(t)
	sock := serveAgent(t, phone)
	dir := t.TempDir()
	line := AuthorizedKey(phone.pub, "Flux on Test Phone")

	out, err := run(t, sock, dir, nil, "ssh-add", "-L")
	if err != nil || strings.TrimSpace(out) != line {
		t.Fatalf("ssh-add -L: %v\n%s\nwant %s", err, out, line)
	}
	out, err = run(t, sock, dir, nil, "ssh-add", "-l")
	if err != nil || !strings.Contains(out, ssh.FingerprintSHA256(phone.pub)) || !strings.Contains(out, "(ECDSA)") {
		t.Fatalf("ssh-add -l: %v\n%s", err, out)
	}

	pubFile := filepath.Join(dir, "phone.pub")
	msg := filepath.Join(dir, "message.txt")
	allowed := filepath.Join(dir, "allowed_signers")
	if err := os.WriteFile(pubFile, []byte(line+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(msg, []byte("Flux signs this text.\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(allowed, []byte("test@example.com "+line+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, ns := range []string{"git", "file"} {
		os.Remove(msg + ".sig")
		if out, err := run(t, sock, dir, nil, "ssh-keygen", "-Y", "sign", "-n", ns, "-f", pubFile, msg); err != nil {
			t.Fatalf("ssh-keygen -Y sign -n %s: %v\n%s", ns, err, out)
		}
		sig, err := os.ReadFile(msg + ".sig")
		if err != nil {
			t.Fatal(err)
		}
		text, _ := os.ReadFile(msg)
		out, err := run(t, sock, dir, text, "ssh-keygen", "-Y", "verify", "-f", allowed, "-I", "test@example.com", "-n", ns, "-s", msg+".sig")
		if err != nil || !strings.Contains(out, "Good") {
			t.Fatalf("ssh-keygen -Y verify -n %s: %v\n%s\n%s", ns, err, out, sig)
		}
		// The namespace is part of the signature.
		if out, err := run(t, sock, dir, text, "ssh-keygen", "-Y", "verify", "-f", allowed, "-I", "test@example.com", "-n", "other", "-s", msg+".sig"); err == nil {
			t.Fatalf("a signature for %s was valid in another namespace\n%s", ns, out)
		}
	}
	got := phone.data()
	if len(got) != 2 || got[0] != (Data{Kind: KindSignature, Namespace: "git"}) || got[1] != (Data{Kind: KindSignature, Namespace: "file"}) {
		t.Fatalf("the phone saw %+v", got)
	}
	phone.mu.Lock()
	program := phone.peers[0].Program
	phone.mu.Unlock()
	if !strings.HasPrefix(program, "ssh-keygen -Y sign -n git -f ") {
		t.Fatalf("the program is %q", program)
	}
}

// TestGitCommitSignature signs a commit with git and the key:: form, then
// verifies it with git.
func TestGitCommitSignature(t *testing.T) {
	need(t, "git", "ssh-keygen")
	phone := newFakePhone(t)
	sock := serveAgent(t, phone)
	home := t.TempDir()
	repo := filepath.Join(home, "repo")
	line := AuthorizedKey(phone.pub, "")
	allowed := filepath.Join(home, "allowed_signers")
	if err := os.WriteFile(allowed, []byte("test@example.com "+line+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{
			"-c", "user.name=Test", "-c", "user.email=test@example.com",
			"-c", "gpg.format=ssh", "-c", "user.signingkey=key::" + line,
			"-c", "gpg.ssh.allowedSignersFile=" + allowed, "-c", "init.defaultBranch=main",
		}, args...)...)
		cmd.Dir = home
		if _, err := os.Stat(repo); err == nil {
			cmd.Dir = repo
		}
		cmd.Env = append(os.Environ(), "HOME="+home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "SSH_AUTH_SOCK="+sock)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
		return string(out)
	}
	git("init", "-q", repo)
	git("commit", "-q", "--allow-empty", "-S", "-m", "Signed by the phone")
	if out := git("verify-commit", "-v", "HEAD"); !strings.Contains(out, "Good \"git\" signature for test@example.com") {
		t.Fatalf("git verify-commit:\n%s", out)
	}
	if got := phone.data(); len(got) != 1 || got[0].Namespace != "git" {
		t.Fatalf("the phone saw %+v", got)
	}
}

// TestSSHLogin logs in with the real ssh client to a Go SSH server that
// accepts only the key of the phone.
func TestSSHLogin(t *testing.T) {
	need(t, "ssh")
	phone := newFakePhone(t)
	sock := serveAgent(t, phone)
	port := sshServer(t, phone.pub)
	out, err := run(t, sock, t.TempDir(), nil, "ssh", "-F", "/dev/null",
		"-o", "IdentityFile=none", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=/dev/null",
		"-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "ControlPath=none",
		"-o", "PreferredAuthentications=publickey", "-o", "IdentityAgent="+sock, "-o", "LogLevel=ERROR",
		"-p", port, "flux-user@127.0.0.1", "true")
	if err != nil {
		t.Fatalf("ssh: %v\n%s", err, out)
	}
	got := phone.data()
	if len(got) != 1 || got[0] != (Data{Kind: KindLogin, User: "flux-user"}) {
		t.Fatalf("the phone saw %+v", got)
	}
}

// sshServer starts an SSH server on loopback that accepts only key and
// runs each command with exit status 0. It returns the port.
func sshServer(t *testing.T, key ssh.PublicKey) string {
	t.Helper()
	cfg := &ssh.ServerConfig{
		PublicKeyCallback: func(_ ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if bytes.Equal(k.Marshal(), key.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("unknown key")
		},
	}
	hk, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(hk)
	if err != nil {
		t.Fatal(err)
	}
	cfg.AddHostKey(signer)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				_, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				for nc := range chans {
					if nc.ChannelType() != "session" {
						_ = nc.Reject(ssh.UnknownChannelType, "no")
						continue
					}
					ch, chReqs, err := nc.Accept()
					if err != nil {
						continue
					}
					go func() {
						for r := range chReqs {
							_ = r.Reply(r.Type == "exec", nil)
							if r.Type == "exec" {
								_, _ = ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
								ch.Close()
							}
						}
					}()
				}
			}()
		}
	}()
	return strings.TrimPrefix(ln.Addr().String(), "127.0.0.1:")
}

// TestAgentRefusesChanges checks that a client cannot add, remove, or lock.
func TestAgentRefusesChanges(t *testing.T) {
	sock := serveAgent(t, newFakePhone(t))
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	a := agent.NewClient(c)
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err := a.Add(agent.AddedKey{PrivateKey: k}); err == nil {
		t.Error("the agent added a key")
	}
	if err := a.RemoveAll(); err == nil {
		t.Error("the agent removed the keys")
	}
	if err := a.Lock([]byte("x")); err == nil {
		t.Error("the agent locked")
	}
	keys, err := a.List()
	if err != nil || len(keys) != 1 {
		t.Fatalf("the list after the refused changes: %v %v", keys, err)
	}
}

func TestNoPhone(t *testing.T) {
	need(t, "ssh-add")
	phone := newFakePhone(t)
	phone.none = true
	sock := serveAgent(t, phone)
	out, err := run(t, sock, t.TempDir(), nil, "ssh-add", "-L")
	if err == nil || !strings.Contains(out, "no identities") {
		t.Fatalf("ssh-add -L without a phone: %v\n%s", err, out)
	}
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	start := time.Now()
	if _, err := agent.NewClient(c).Sign(phone.pub, signedData("git")); err == nil {
		t.Fatal("the agent signed without a phone")
	}
	if time.Since(start) > time.Second {
		t.Fatalf("the sign without a phone took %v", time.Since(start))
	}
}

// TestHangupEndsTheRequest closes the client during a sign request. The
// request must end, so the phone closes its prompt.
func TestHangupEndsTheRequest(t *testing.T) {
	phone := newFakePhone(t)
	phone.hold = true
	sock := serveAgent(t, phone)
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = agent.NewClient(c).Sign(phone.pub, signedData("git")) }()
	for len(phone.data()) == 0 {
		time.Sleep(10 * time.Millisecond)
	}
	c.Close()
	select {
	case err := <-phone.ended:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("the request ended with %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the request did not end after the client closed")
	}
}

// signedData returns the signed data of an SSH signature in namespace ns.
func signedData(ns string) []byte {
	h := sha512.Sum512([]byte("message"))
	return append([]byte("SSHSIG"), ssh.Marshal(struct {
		Namespace, Reserved, Hash string
		Digest                    []byte
	}{ns, "", "sha512", h[:]})...)
}

// loginData returns a login request for key.
func loginData(user, method string, key []byte, extra ...any) []byte {
	b := ssh.Marshal(struct {
		Session []byte
		Msg     byte
		User    string
		Service string
		Method  string
		Signs   bool
		Alg     string
		Key     []byte
	}{bytes.Repeat([]byte{7}, 32), 50, user, "ssh-connection", method, true, ssh.KeyAlgoECDSA256, key})
	for _, e := range extra {
		b = append(b, ssh.Marshal(e)...)
	}
	return b
}

func TestParseData(t *testing.T) {
	phone := newFakePhone(t)
	key := phone.pub.Marshal()
	other := newFakePhone(t).pub.Marshal()
	host := struct{ Host []byte }{[]byte("host key")}
	h := sha256.Sum256([]byte("m"))
	sha256Data := append([]byte("SSHSIG"), ssh.Marshal(struct {
		Namespace, Reserved, Hash string
		Digest                    []byte
	}{"file", "", "sha256", h[:]})...)
	good := []struct {
		name string
		data []byte
		want Data
	}{
		{"a login", loginData("git", methodPublicKey, key), Data{Kind: KindLogin, User: "git"}},
		{"a host-bound login", loginData("alice", methodHostBound, key, host), Data{Kind: KindLogin, User: "alice"}},
		{"a signature with sha512", signedData("git"), Data{Kind: KindSignature, Namespace: "git"}},
		{"a signature with sha256", sha256Data, Data{Kind: KindSignature, Namespace: "file"}},
	}
	for _, c := range good {
		got, err := ParseData(c.data, key)
		if err != nil || got != c.want {
			t.Errorf("%s: got %+v %v, want %+v", c.name, got, err, c.want)
		}
	}
	bad := []struct {
		name string
		data []byte
	}{
		{"nothing", nil},
		{"text", []byte("hello")},
		{"a login for another key", loginData("git", methodPublicKey, other)},
		{"a login with extra bytes", append(loginData("git", methodPublicKey, key), 0)},
		{"a host-bound login without a host key", loginData("git", methodHostBound, key)},
		{"a login with a newline in the user", loginData("git\nroot", methodPublicKey, key)},
		{"a login with a bidi control in the user", loginData("git‮", methodPublicKey, key)},
		{"a login with another method", loginData("git", "password", key)},
		{"a signature with a control character", signedData("git\x1b[2J")},
		{"a signature without a namespace", signedData("")},
		{"a signature with extra bytes", append(signedData("git"), 1)},
		{"a cut signature", signedData("git")[:20]},
		{"too much data", append(signedData("git"), make([]byte, MaxData)...)},
	}
	for _, c := range bad {
		if got, err := ParseData(c.data, key); err == nil {
			t.Errorf("%s: parsed as %+v", c.name, got)
		}
	}
}

func TestSignature(t *testing.T) {
	phone := newFakePhone(t)
	data := signedData("git")
	h := sha256.Sum256(data)
	der, err := ecdsa.SignASN1(rand.Reader, phone.key, h[:])
	if err != nil {
		t.Fatal(err)
	}
	sig, err := Signature(phone.pub, data, der)
	if err != nil {
		t.Fatal(err)
	}
	// The blob holds r and s as mpints, as RFC 5656 section 3.1.2 says.
	var rs struct{ R, S *big.Int }
	if err := ssh.Unmarshal(sig.Blob, &rs); err != nil || sig.Format != "ecdsa-sha2-nistp256" {
		t.Fatalf("the signature blob: %v %s", err, sig.Format)
	}
	var want struct{ R, S *big.Int }
	if _, err := asn1.Unmarshal(der, &want); err != nil || rs.R.Cmp(want.R) != 0 || rs.S.Cmp(want.S) != 0 {
		t.Fatal("r and s changed")
	}
	if _, err := Signature(newFakePhone(t).pub, data, der); err == nil {
		t.Error("a signature of another key was valid")
	}
	if _, err := Signature(phone.pub, append(data, 1), der); err == nil {
		t.Error("a signature of other data was valid")
	}
	for _, bad := range [][]byte{nil, {0x30, 0}, append(der, 0), der[:len(der)-1]} {
		if _, err := Signature(phone.pub, data, bad); err == nil {
			t.Errorf("the DER %x parsed", bad)
		}
	}
}

func TestKeyFromSPKI(t *testing.T) {
	k384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ := x509.MarshalPKIXPublicKey(&k384.PublicKey)
	if _, err := KeyFromSPKI(der); err == nil {
		t.Error("a P-384 key was taken")
	}
	if _, err := KeyFromSPKI([]byte("not a key")); err == nil {
		t.Error("garbage was taken")
	}
	phone := newFakePhone(t)
	if got := AuthorizedKey(phone.pub, " Flux on Pixel 8 "); !strings.HasPrefix(got, "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABB") || !strings.HasSuffix(got, "= Flux on Pixel 8") {
		t.Errorf("the authorized key line is %q", got)
	}
}

func TestCleanProgram(t *testing.T) {
	cases := map[string]string{
		"ssh\x00git@github.com\x00":                 "ssh git@github.com",
		"/usr/bin/ssh\x00-T\x00host\x00":            "ssh -T host",
		"/usr/bin/\x00x\x00":                        "/usr/bin/ x",
		"ssh-keygen\x00-Y\x00sign\x00-n\x00git\x00": "ssh-keygen -Y sign -n git",
		"evil\x00a\nb\x1b[2J‮c\x00":                 "evil a b [2J c",
		"":                                          "",
		"\xff\xfe":                                  "",
	}
	for in, want := range cases {
		if got := CleanProgram([]byte(in)); got != want {
			t.Errorf("CleanProgram(%q) = %q, want %q", in, got, want)
		}
	}
	long := CleanProgram([]byte(strings.Repeat("é", 300)))
	if len(long) > maxProgram || !strings.HasSuffix(long, "…") || !ValidText(long) {
		t.Errorf("a long program gave %d bytes: %q", len(long), long)
	}
}

func TestProgramReadsProc(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Skip(err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	// The start can return before the exec of the child ends. Until then,
	// the child has no arguments or the arguments of the test, so the
	// test waits for the arguments of sleep.
	got := ""
	for deadline := time.Now().Add(3 * time.Second); got != "sleep 30" && time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		got = program(cmd.Process.Pid)
	}
	if got != "sleep 30" {
		t.Fatalf("program = %q", got)
	}
	if got := program(0); got != "" {
		t.Fatalf("program(0) = %q", got)
	}
}

// TestSSHLoginToOpenSSH logs in to a real sshd that runs as this user. An
// OpenSSH server offers the host-bound login, so the phone signs that
// form. The test skips when sshd does not start without root.
func TestSSHLoginToOpenSSH(t *testing.T) {
	need(t, "ssh", "ssh-keygen")
	sshd, err := exec.LookPath("sshd")
	if err != nil {
		t.Skip("sshd is not installed")
	}
	phone := newFakePhone(t)
	sock := serveAgent(t, phone)
	dir := t.TempDir()
	hostKey := filepath.Join(dir, "host_key")
	if out, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", hostKey).CombinedOutput(); err != nil {
		t.Fatalf("ssh-keygen: %v\n%s", err, out)
	}
	authorized := filepath.Join(dir, "authorized_keys")
	if err := os.WriteFile(authorized, []byte(AuthorizedKey(phone.pub, "Flux on Test Phone")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := strings.TrimPrefix(ln.Addr().String(), "127.0.0.1:")
	ln.Close()
	cfg := filepath.Join(dir, "sshd_config")
	if err := os.WriteFile(cfg, []byte(strings.Join([]string{
		"ListenAddress 127.0.0.1:" + port, "HostKey " + hostKey, "AuthorizedKeysFile " + authorized,
		"PidFile none", "UsePAM no", "StrictModes no", "PasswordAuthentication no",
		"KbdInteractiveAuthentication no", "PubkeyAuthentication yes", "LogLevel ERROR", "",
	}, "\n")), 0o600); err != nil {
		t.Fatal(err)
	}
	server := exec.Command(sshd, "-D", "-e", "-f", cfg)
	var log bytes.Buffer
	server.Stdout, server.Stderr = &log, &log
	if err := server.Start(); err != nil {
		t.Skip(err)
	}
	defer func() {
		_ = server.Process.Kill()
		_ = server.Wait()
	}()
	up := false
	for range 50 {
		if c, err := net.Dial("tcp", "127.0.0.1:"+port); err == nil {
			c.Close()
			up = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !up {
		t.Skipf("sshd did not start as this user:\n%s", log.String())
	}
	user := os.Getenv("USER")
	if user == "" {
		t.Skip("USER is not set")
	}
	out, err := run(t, sock, dir, nil, "ssh", "-F", "/dev/null",
		"-o", "IdentityFile=none", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=/dev/null",
		"-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "ControlPath=none",
		"-o", "PreferredAuthentications=publickey", "-o", "IdentityAgent="+sock, "-o", "LogLevel=ERROR",
		"-p", port, user+"@127.0.0.1", "true")
	if err != nil && len(phone.data()) == 0 {
		// sshd refused the user before the key, for example a locked
		// account in a build container.
		t.Skipf("sshd did not ask for the key: %v\n%s\nsshd:\n%s", err, out, log.String())
	}
	if err != nil {
		t.Fatalf("ssh: %v\n%s\nsshd:\n%s", err, out, log.String())
	}
	got := phone.data()
	if len(got) != 1 || got[0] != (Data{Kind: KindLogin, User: user}) {
		t.Fatalf("the phone saw %+v", got)
	}
	phone.mu.Lock()
	raw := phone.raw[0]
	phone.mu.Unlock()
	if !bytes.Contains(raw, []byte(methodHostBound)) {
		t.Errorf("sshd did not use the host-bound login")
	}
}

// The shared vectors. SshMessageTest.kt in Flux for Android uses the same
// values, so that the phone and fluxd agree on the key, the fingerprint,
// and the data.
const (
	vectorSPKI        = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE0fvX8Z0xxlym8ZekiVKUzbH41pZi6APeveBFIYS7nJEP6tNHnpTjN+lYesUoqn1u3T0xL0Tdj6zXh/IKW//0Fw=="
	vectorLine        = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNH71/GdMcZcpvGXpIlSlM2x+NaWYugD3r3gRSGEu5yRD+rTR56U4zfpWHrFKKp9bt09MS9E3Y+s14fyClv/9Bc= Flux on Pixel 8"
	vectorFingerprint = "SHA256:uk2DU7O00GnwbbL4vBzKRyuHlZ/ZfhHpgGM7thsHUig"
	// vectorLogin is a host-bound login as git with the vector key.
	vectorLogin = "00000020070707070707070707070707070707070707070707070707070707070707070732000000036769740000000e7373682d636f6e6e656374696f6e000000237075626c69636b65792d686f7374626f756e642d763030406f70656e7373682e636f6d010000001365636473612d736861322d6e69737470323536000000680000001365636473612d736861322d6e69737470323536000000086e697374703235360000004104d1fbd7f19d31c65ca6f197a4895294cdb1f8d69662e803debde0452184bb9c910fead3479e94e337e9587ac528aa7d6edd3d312f44dd8facd787f20a5bfff41700000008686f7374206b6579"
	// vectorSignature is the signed data of an SSH signature in the
	// namespace git, with SHA-256.
	vectorSignature = "5353485349470000000367697400000000000000067368613235360000002062c66a7a5dd70c3146618063c344e531e6d4b59e379808443ce962b3abd63c5a"
)

func TestSharedVectors(t *testing.T) {
	der, _ := base64.StdEncoding.DecodeString(vectorSPKI)
	key, err := KeyFromSPKI(der)
	if err != nil {
		t.Fatal(err)
	}
	if got := AuthorizedKey(key, "Flux on Pixel 8"); got != vectorLine {
		t.Errorf("the line is %s", got)
	}
	if got := ssh.FingerprintSHA256(key); got != vectorFingerprint {
		t.Errorf("the fingerprint is %s", got)
	}
	login, _ := hex.DecodeString(vectorLogin)
	if d, err := ParseData(login, key.Marshal()); err != nil || d != (Data{Kind: KindLogin, User: "git"}) {
		t.Errorf("the login: %+v %v", d, err)
	}
	sig, _ := hex.DecodeString(vectorSignature)
	if d, err := ParseData(sig, key.Marshal()); err != nil || d != (Data{Kind: KindSignature, Namespace: "git"}) {
		t.Errorf("the signature: %+v %v", d, err)
	}
}
