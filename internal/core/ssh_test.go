package core

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
	"flux/internal/sshagent"
)

// sshPhone answers flux.ssh on the phone side of a link, as Flux for
// Android does. It sends its key when fluxd asks, and it answers each sign
// request as mode says: "sign", "deny", "error", "silent", or "wrong".
type sshPhone struct {
	t    *testing.T
	key  *ecdsa.PrivateKey
	spki string
	link *lan.Link

	mu      sync.Mutex
	mode    string
	open    int
	overlap bool
	signs   []map[string]any
	cancels []string
	delay   time.Duration
}

func (p *sshPhone) handle(pk *proto.Packet) {
	if pk.Type != proto.TypeFluxSSH {
		return
	}
	var b map[string]any
	if err := json.Unmarshal(pk.Body, &b); err != nil {
		p.t.Error(err)
		return
	}
	switch b["kind"] {
	case "key":
		_ = p.link.Send(proto.New(proto.TypeFluxSSH, map[string]any{"kind": "key", "publicKey": p.spki}))
	case "cancel":
		p.mu.Lock()
		p.cancels = append(p.cancels, b["id"].(string))
		p.mu.Unlock()
	case "sign":
		p.mu.Lock()
		p.signs = append(p.signs, b)
		p.open++
		p.overlap = p.overlap || p.open > 1
		mode, delay := p.mode, p.delay
		p.mu.Unlock()
		go p.answer(b, mode, delay)
	}
}

func (p *sshPhone) answer(b map[string]any, mode string, delay time.Duration) {
	time.Sleep(delay)
	defer func() {
		p.mu.Lock()
		p.open--
		p.mu.Unlock()
	}()
	id := b["id"].(string)
	data, _ := base64.StdEncoding.DecodeString(b["data"].(string))
	reply := map[string]any{"kind": "signed", "id": id}
	switch mode {
	case "silent":
		return
	case "deny":
		reply["denied"] = true
	case "error":
		reply["error"] = "The screen lock check failed"
	case "wrong":
		data = append(data, 1)
		fallthrough
	default:
		if b["key"] != p.spki {
			reply["error"] = "The key changed"
			break
		}
		h := sha256.Sum256(data)
		der, err := ecdsa.SignASN1(rand.Reader, p.key, h[:])
		if err != nil {
			p.t.Error(err)
		}
		reply["signature"] = base64.StdEncoding.EncodeToString(der)
	}
	_ = p.link.Send(proto.New(proto.TypeFluxSSH, reply))
}

func (p *sshPhone) setMode(mode string) {
	p.mu.Lock()
	p.mode = mode
	p.mu.Unlock()
}

func (p *sshPhone) counts() (signs, cancels int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.signs), len(p.cancels)
}

// sshSetup links a daemon to an sshPhone through real links on loopback,
// and waits until the daemon has the key of the phone.
func sshSetup(t *testing.T) (*Daemon, *Device, *sshPhone, ssh.PublicKey) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	onDesk, onPhone, _, phoneID := linkPair(t, ctx)
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := sshagent.KeyFromSPKI(der)
	if err != nil {
		t.Fatal(err)
	}
	phone := &sshPhone{t: t, key: k, spki: base64.StdEncoding.EncodeToString(der), link: onPhone, mode: "sign"}
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	trust, err := config.LoadTrust()
	if err != nil {
		t.Fatal(err)
	}
	d := &Daemon{cfg: &config.Config{}, trust: trust, devices: map[string]*Device{}, logger: log.New(io.Discard, "", 0), ctx: ctx}
	dev := &Device{ID: phoneID, Name: "Pixel 8", Paired: true, link: onDesk, Incoming: []string{proto.TypeFluxSSH}}
	d.devices[phoneID] = dev
	go onDesk.Receive(func(p *proto.Packet) { d.handlePacket(dev, onDesk, p) })
	go onPhone.Receive(phone.handle)
	d.requestSSHKey(dev, onDesk)
	deadline := time.Now().Add(5 * time.Second)
	for len(d.SSHKeys()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("fluxd got no key from the phone")
		}
		time.Sleep(10 * time.Millisecond)
	}
	return d, dev, phone, pub
}

// sshSigData returns the signed data of an SSH signature in namespace git.
func sshSigData() []byte {
	h := sha512.Sum512([]byte("commit"))
	return append([]byte("SSHSIG"), ssh.Marshal(struct {
		Namespace, Reserved, Hash string
		Digest                    []byte
	}{"git", "", "sha512", h[:]})...)
}

func TestSSHKeyFromThePhone(t *testing.T) {
	d, dev, _, pub := sshSetup(t)
	keys := d.SSHKeys()
	if len(keys) != 1 || !bytes.Equal(keys[0].Blob, pub.Marshal()) || keys[0].Comment != "Flux on Pixel 8" {
		t.Fatalf("the keys: %+v", keys)
	}
	v := d.sshView()
	if len(v.Keys) != 1 || v.Keys[0].Fingerprint != ssh.FingerprintSHA256(pub) || !strings.HasSuffix(v.Keys[0].Key, " Flux on Pixel 8") {
		t.Fatalf("the view: %+v", v)
	}

	// The list holds only a paired, connected phone that takes flux.ssh.
	d.mu.Lock()
	dev.Incoming = nil
	d.mu.Unlock()
	if len(d.SSHKeys()) != 0 {
		t.Error("a phone without flux.ssh is in the list")
	}
	d.mu.Lock()
	dev.Incoming = []string{proto.TypeFluxSSH}
	l := dev.link
	dev.link = nil
	d.mu.Unlock()
	if len(d.SSHKeys()) != 0 {
		t.Error("an offline phone is in the list")
	}
	d.mu.Lock()
	dev.link = l
	d.dropTrustLocked(dev)
	d.mu.Unlock()
	if len(d.SSHKeys()) != 0 || dev.sshKey != nil {
		t.Error("an unpair kept the key")
	}

	// A key that is not P-256 and a key that does not parse count as no key.
	k384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der, _ := x509.MarshalPKIXPublicKey(&k384.PublicKey)
	for _, bad := range []string{base64.StdEncoding.EncodeToString(der), "not base64", base64.StdEncoding.EncodeToString(make([]byte, 300))} {
		d.setSSHKey(dev, bad)
		if dev.sshKey != nil || dev.sshSPKI != "" {
			t.Errorf("fluxd took the key %q", bad)
		}
	}
}

func TestSSHSign(t *testing.T) {
	d, _, phone, pub := sshSetup(t)
	data := sshSigData()
	sig, err := d.SSHSign(context.Background(), pub.Marshal(), data, sshagent.Peer{Program: "ssh-keygen -Y sign -n git"})
	if err != nil {
		t.Fatal(err)
	}
	if err := pub.Verify(data, sig); err != nil {
		t.Fatalf("the signature is not valid: %v", err)
	}
	phone.mu.Lock()
	req := phone.signs[0]
	phone.mu.Unlock()
	if req["program"] != "ssh-keygen -Y sign -n git" || req["data"] != base64.StdEncoding.EncodeToString(data) || req["key"] != phone.spki {
		t.Fatalf("the request: %+v", req)
	}
	if timeout := req["timeout"].(float64); timeout < 29 || timeout > 30 {
		t.Fatalf("the timeout is %v", timeout)
	}

	for _, mode := range []string{"deny", "error", "wrong"} {
		phone.setMode(mode)
		start := time.Now()
		if _, err := d.SSHSign(context.Background(), pub.Marshal(), data, sshagent.Peer{}); err == nil {
			t.Errorf("%s: the agent signed", mode)
		}
		if time.Since(start) > 5*time.Second {
			t.Errorf("%s took %v", mode, time.Since(start))
		}
	}
	if d.sshSigns.pending() != 0 {
		t.Error("a request stayed in the book")
	}
}

func TestSSHSignRefusesBeforeThePhone(t *testing.T) {
	d, _, phone, pub := sshSetup(t)
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	otherPub, _ := ssh.NewPublicKey(&other.PublicKey)
	start := time.Now()
	if _, err := d.SSHSign(context.Background(), otherPub.Marshal(), sshSigData(), sshagent.Peer{}); err == nil || !strings.Contains(err.Error(), "No connected phone") {
		t.Errorf("another key: %v", err)
	}
	if _, err := d.SSHSign(context.Background(), pub.Marshal(), []byte("a message of another protocol"), sshagent.Peer{}); err == nil {
		t.Error("the agent sent other data to the phone")
	}
	if time.Since(start) > time.Second {
		t.Errorf("the refusals took %v", time.Since(start))
	}
	if signs, _ := phone.counts(); signs != 0 {
		t.Errorf("the phone got %d requests", signs)
	}
}

func TestSSHSignTimeoutAndHangup(t *testing.T) {
	old := sshSignTimeout
	sshSignTimeout = 300 * time.Millisecond
	defer func() { sshSignTimeout = old }()
	d, _, phone, pub := sshSetup(t)
	phone.setMode("silent")
	if _, err := d.SSHSign(context.Background(), pub.Marshal(), sshSigData(), sshagent.Peer{}); err == nil || !strings.Contains(err.Error(), "did not answer") {
		t.Fatalf("a phone that does not answer: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(50*time.Millisecond, cancel)
	if _, err := d.SSHSign(ctx, pub.Marshal(), sshSigData(), sshagent.Peer{}); err == nil {
		t.Fatal("a client that closed got a signature")
	}
	// Each ended request closes on the phone.
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, cancels := phone.counts(); cancels == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the phone did not get 2 cancels")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestSSHSignEndsWithTheLink(t *testing.T) {
	oldPoll := sshLinkPoll
	sshLinkPoll = 20 * time.Millisecond
	defer func() { sshLinkPoll = oldPoll }()
	d, dev, phone, pub := sshSetup(t)
	phone.setMode("silent")
	time.AfterFunc(100*time.Millisecond, func() {
		d.mu.Lock()
		dev.link = nil
		d.mu.Unlock()
	})
	start := time.Now()
	if _, err := d.SSHSign(context.Background(), pub.Marshal(), sshSigData(), sshagent.Peer{}); err == nil || !strings.Contains(err.Error(), "link") {
		t.Fatalf("a closed link: %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("the request took %v after the link closed", time.Since(start))
	}
}

// TestSSHSignOneAtATime starts 2 requests at once. The phone gets the
// second only after it answered the first.
func TestSSHSignOneAtATime(t *testing.T) {
	d, _, phone, pub := sshSetup(t)
	phone.mu.Lock()
	phone.delay = 150 * time.Millisecond
	phone.mu.Unlock()
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for range 2 {
		wg.Go(func() {
			_, err := d.SSHSign(context.Background(), pub.Marshal(), sshSigData(), sshagent.Peer{})
			errs <- err
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Error(err)
		}
	}
	phone.mu.Lock()
	defer phone.mu.Unlock()
	if phone.overlap || len(phone.signs) != 2 {
		t.Fatalf("overlap %v, %d requests", phone.overlap, len(phone.signs))
	}
}

func TestSSHAnswerChecks(t *testing.T) {
	var b sshBook
	s := b.add("phone1")
	if b.deliver("phone2", s.id, sshAnswer{denied: true}) {
		t.Fatal("another phone answered the request")
	}
	if !b.deliver("phone1", s.id, sshAnswer{denied: true}) {
		t.Fatal("the phone could not answer")
	}
	if b.deliver("phone1", s.id, sshAnswer{}) {
		t.Fatal("the phone answered twice")
	}
	b.remove(s.id)
	if b.deliver("phone1", s.id, sshAnswer{}) || b.pending() != 0 {
		t.Fatal("an answer after the end counted")
	}
	now := time.Now()
	if !b.noteDue(now) || b.noteDue(now.Add(time.Second)) || !b.noteDue(now.Add(sshNoteGap)) {
		t.Fatal("the notification gap does not hold")
	}
	if got := cleanSSHError("bad\ntext"); got != "The phone could not sign" {
		t.Fatalf("cleanSSHError = %q", got)
	}
}

// TestSSHAgentThroughThePhoneLink runs git commit -S with ssh-keygen
// through the agent socket, fluxd, and a phone on a real link.
func TestSSHAgentThroughThePhoneLink(t *testing.T) {
	for _, tool := range []string{"git", "ssh-keygen", "ssh-add"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s is not installed", tool)
		}
	}
	d, _, phone, _ := sshSetup(t)
	dir, err := os.MkdirTemp("", "fs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "ssh-agent.sock")
	ln, err := sshagent.Listen(sock)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = sshagent.Serve(ctx, ln, d, t.Logf)
	}()
	t.Cleanup(func() {
		cancel()
		<-served
	})
	env := append(os.Environ(), "HOME="+dir, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "SSH_AUTH_SOCK="+sock)
	out, err := runIn(dir, env, "ssh-add", "-L")
	line := d.sshView().Keys[0].Key
	if err != nil || strings.TrimSpace(out) != line {
		t.Fatalf("ssh-add -L: %v\n%s\nwant %s", err, out, line)
	}
	allowed := filepath.Join(dir, "allowed_signers")
	if err := os.WriteFile(allowed, []byte("test@example.com "+line+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(dir, "repo")
	gitArgs := []string{
		"-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "gpg.format=ssh",
		// The docs set the key with the output of flux-cli ssh key, so the line has the comment.
		"-c", "user.signingkey=key::" + line, "-c", "gpg.ssh.allowedSignersFile=" + allowed,
	}
	if out, err := runIn(dir, env, "git", "init", "-q", repo); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	if out, err := runIn(repo, env, "git", append(gitArgs, "commit", "-q", "--allow-empty", "-S", "-m", "Signed by the phone")...); err != nil {
		t.Fatalf("git commit -S: %v\n%s", err, out)
	}
	out, err = runIn(repo, env, "git", append(gitArgs, "verify-commit", "-v", "HEAD")...)
	if err != nil || !strings.Contains(out, `Good "git" signature for test@example.com`) {
		t.Fatalf("git verify-commit: %v\n%s", err, out)
	}
	phone.mu.Lock()
	program, _ := phone.signs[0]["program"].(string)
	phone.mu.Unlock()
	if !strings.HasPrefix(program, "ssh-keygen -Y sign -n git -f ") {
		t.Errorf("the phone saw the program %q", program)
	}

	// A denial on the phone fails the commit.
	phone.setMode("deny")
	if out, err := runIn(repo, env, "git", append(gitArgs, "commit", "-q", "--allow-empty", "-S", "-m", "Denied")...); err == nil {
		t.Fatalf("git committed after a denial\n%s", out)
	}
}

func runIn(dir string, env []string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	return string(out), err
}
