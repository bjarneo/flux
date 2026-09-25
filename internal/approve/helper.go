package approve

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"time"
)

// The limits of 1 approval. docs/approve.md lists them.
const (
	dialTimeout    = 2 * time.Second
	requestTimeout = 3 * time.Second
	grace          = 3 * time.Second
	minWait        = 5 * time.Second
	// MaxWait is the longest wait for the phone, whatever fluxd says.
	MaxWait = 120 * time.Second
)

var (
	// ErrDenied means that the user denied the request on the phone.
	ErrDenied = errors.New("the request was denied on the phone")
	// ErrTimeout means that the phone did not answer in time.
	ErrTimeout = errors.New("the phone did not answer in time")
	// ErrService means that the PAM service cannot use approvals.
	ErrService = errors.New("this PAM service cannot use approvals")
)

var userName = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

// ValidUser reports whether name is a local user name that Flux accepts.
func ValidUser(name string) bool { return userName.MatchString(name) }

// Options are the inputs of 1 approval. cmd/flux-approve sets them from
// the PAM variables and from constants. Tests set temporary paths.
type Options struct {
	User    string
	Service string
	TTY     string
	RHost   string
	Host    string

	// KeyPath is the key file of the user, and KeyOwner the user that must
	// own it. The binary uses KeyPath(user) and root.
	KeyPath  string
	KeyOwner int
	// Socket is the fluxd socket of the user, and PeerUID the user that the
	// server must run as.
	Socket  string
	PeerUID int
	// MaxWait limits the wait for the phone. Zero means MaxWait.
	MaxWait time.Duration

	// Out gets the 1 line that tells the user to look at the phone.
	Out  io.Writer
	Now  func() time.Time
	Rand io.Reader
}

func (o *Options) defaults() {
	if o.MaxWait <= 0 || o.MaxWait > MaxWait {
		o.MaxWait = MaxWait
	}
	if o.Out == nil {
		o.Out = io.Discard
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Rand == nil {
		o.Rand = rand.Reader
	}
}

// newNonce returns 32 random bytes as 64 lowercase hex digits.
func newNonce(r io.Reader) (string, error) {
	b := make([]byte, 32)
	if _, err := io.ReadFull(r, b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// waitResult is the result of approve.wait.
type waitResult struct {
	State     string `json:"state"`
	Signature string `json:"signature"`
	PublicKey string `json:"publicKey"`
	Message   string `json:"message"`
}

// Run asks the phone to approve the login and checks the signature. It
// returns nil only for a valid signature over the request that it made.
// Any other result is an error, and PAM then asks for the password.
func Run(ctx context.Context, o Options) error {
	o.defaults()
	if o.Service == "sshd" {
		return ErrService
	}
	if !ValidUser(o.User) {
		return fmt.Errorf("%q is not a valid local user name", o.User)
	}
	key, err := ReadKey(o.KeyPath, o.KeyOwner)
	if err != nil {
		return err
	}
	nonce, err := newNonce(o.Rand)
	if err != nil {
		return err
	}
	start := o.Now()
	req := Request{Host: o.Host, User: o.User, Service: o.Service, TTY: o.TTY, RHost: o.RHost, Time: start.Unix(), Nonce: nonce}
	if _, err := req.Message(); err != nil {
		return err
	}

	c, err := dial(o.Socket, o.PeerUID, dialTimeout)
	if err != nil {
		return err
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()

	var started struct {
		ID      string `json:"id"`
		Timeout int    `json:"timeout"`
	}
	params := map[string]any{
		"device": key.DeviceID, "host": req.Host, "user": req.User, "service": req.Service,
		"tty": req.TTY, "rhost": req.RHost, "time": req.Time, "nonce": req.Nonce,
	}
	if err := c.call("approve.request", params, &started, start.Add(requestTimeout)); err != nil {
		return err
	}
	if started.ID == "" {
		return errors.New("fluxd did not start the request")
	}
	wait := time.Duration(started.Timeout) * time.Second
	wait = min(max(wait, minWait), o.MaxWait)
	deadline := start.Add(wait + grace)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}

	fmt.Fprintf(o.Out, "Approve on %s, or wait for the password prompt.\n", key.DeviceName)

	for {
		var res waitResult
		err := c.call("approve.wait", map[string]any{"id": started.ID}, &res, deadline)
		if err != nil {
			var ne net.Error
			var re *RemoteError
			if errors.As(err, &ne) && ne.Timeout() || errors.As(err, &re) && re.Code == "timeout" || ctx.Err() != nil {
				return ErrTimeout
			}
			return err
		}
		switch res.State {
		case "approved":
			sig, err := base64.StdEncoding.DecodeString(res.Signature)
			if err != nil {
				return ErrBadSignature
			}
			// The time of the request came from this process. The signed
			// time can be at most the wait old, plus 1 second of rounding.
			return Verify(req, sig, key.Public, o.Now(), wait+grace+time.Second)
		case "denied":
			return ErrDenied
		case "pending":
			if !o.Now().Before(deadline) {
				return ErrTimeout
			}
		default:
			return fmt.Errorf("fluxd sent the state %q", res.State)
		}
	}
}
