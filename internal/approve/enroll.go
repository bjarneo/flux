package approve

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"time"
)

// enrollWait is the longest wait for the phone during an enrollment.
const enrollWait = 120 * time.Second

// ErrNotConfirmed means that the user did not confirm the key code.
var ErrNotConfirmed = errors.New("the key codes were not confirmed, so Flux wrote no key")

// EnrollOptions are the inputs of 1 enrollment. The CLI sets them.
type EnrollOptions struct {
	User string
	Host string
	// Device names the phone. Empty means the only connected paired phone.
	Device string

	Socket   string
	PeerUID  int
	KeyPath  string
	KeyOwner int

	// Confirm shows the key code and returns true only when the user says
	// that the phone shows the same code.
	Confirm func(phone, code string) bool
	// Waiting gets the name of the phone before the wait starts.
	Waiting func(phone string)

	Now  func() time.Time
	Rand io.Reader
}

// Enroll gets a new public key from the phone, checks the proof that the
// phone holds the private key, asks the user to compare the key codes, and
// writes the key file.
func Enroll(ctx context.Context, o EnrollOptions) (*Key, error) {
	random := o.Rand
	if random == nil {
		random = rand.Reader
	}
	now := o.Now
	if now == nil {
		now = time.Now
	}
	if !ValidUser(o.User) {
		return nil, fmt.Errorf("%q is not a valid local user name", o.User)
	}
	if o.Confirm == nil {
		return nil, errors.New("enrollment needs a confirmation")
	}
	nonce, err := newNonce(random)
	if err != nil {
		return nil, err
	}
	start := now()
	e := Enrollment{Host: o.Host, User: o.User, Time: start.Unix(), Nonce: nonce}
	if _, err := e.Message(nil); err != nil {
		return nil, err
	}

	c, err := dial(o.Socket, o.PeerUID, dialTimeout)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()

	var started struct {
		ID     string `json:"id"`
		Device string `json:"device"`
		Name   string `json:"name"`
	}
	params := map[string]any{"device": o.Device, "host": e.Host, "user": e.User, "time": e.Time, "nonce": e.Nonce}
	if err := c.call("approve.enroll", params, &started, start.Add(requestTimeout)); err != nil {
		return nil, err
	}
	if started.ID == "" || started.Device == "" || CheckField("device", started.Device) != nil {
		return nil, errors.New("fluxd did not start the enrollment")
	}
	name := started.Name
	if name == "" || CheckField("name", name) != nil {
		name = "the phone"
	}
	if o.Waiting != nil {
		o.Waiting(name)
	}

	deadline := start.Add(enrollWait + grace)
	var res waitResult
	for {
		res = waitResult{}
		err := c.call("approve.wait", map[string]any{"id": started.ID}, &res, deadline)
		if err != nil {
			if ctx.Err() != nil {
				// The user stopped the command. The phone is free again at once.
				cancelRequest(o.Socket, o.PeerUID, started.ID)
				return nil, ctx.Err()
			}
			var ne net.Error
			var re *RemoteError
			if errors.As(err, &ne) && ne.Timeout() || errors.As(err, &re) && re.Code == "timeout" {
				return nil, ErrTimeout
			}
			return nil, err
		}
		if res.State != "pending" {
			break
		}
		if !now().Before(deadline) {
			return nil, ErrTimeout
		}
	}
	switch res.State {
	case "enrolled":
	case "denied":
		return nil, ErrDenied
	case "failed":
		return nil, fmt.Errorf("the phone could not make the key: %s", res.Message)
	default:
		return nil, fmt.Errorf("fluxd sent the state %q", res.State)
	}
	spki, err := base64.StdEncoding.DecodeString(res.PublicKey)
	if err != nil {
		return nil, errors.New("the phone sent a public key that is not base64")
	}
	sig, err := base64.StdEncoding.DecodeString(res.Signature)
	if err != nil {
		return nil, ErrBadSignature
	}
	pub, err := VerifyEnrollment(e, spki, sig, now(), enrollWait+grace+time.Second)
	if err != nil {
		return nil, err
	}
	if !o.Confirm(name, Fingerprint(spki)) {
		return nil, ErrNotConfirmed
	}
	content, err := EncodeKey(spki, started.Device, name, now())
	if err != nil {
		return nil, err
	}
	if err := WriteKey(o.KeyPath, o.KeyOwner, content); err != nil {
		return nil, err
	}
	return &Key{Public: pub, DER: spki, DeviceID: started.Device, DeviceName: name}, nil
}
