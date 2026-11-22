package approve

import (
	"errors"
	"fmt"
)

// The lines that the helper prints before the password prompt. Each line
// names 1 row of the failure table in docs/approve.md. Every line is a
// fixed text. It holds no value from fluxd, from the phone, from the key
// file, or from the environment, so it gives an attacker nothing that the
// password prompt does not already show.
const (
	reasonKeyFile     = "The key file of the phone is not safe, so the helper does not use it. Run: flux-cli approve status"
	reasonFluxd       = "fluxd does not answer, so the phone cannot get the request. Run: flux-cli doctor"
	reasonPhone       = "The phone is not paired or not connected."
	reasonBusy        = "Another approval waits for the phone."
	reasonDenied      = "The request was denied on the phone."
	reasonTimeout     = "The phone did not answer in time."
	reasonSignature   = "The signature of the phone is not valid."
	reasonStale       = "The time of the signature is out of range. Check the clock of the phone."
	reasonPhoneFailed = "The phone could not approve the request. Open Flux on the phone for the reason."
)

// reasoned adds the line of a failure to its error. An empty line means
// that the helper prints nothing.
type reasoned struct {
	line string
	err  error
}

func (r *reasoned) Error() string { return r.err.Error() }
func (r *reasoned) Unwrap() error { return r.err }

func withReason(line string, err error) error { return &reasoned{line: line, err: err} }

// quiet marks a failure that prints nothing.
func quiet(err error) error { return withReason("", err) }

// Reason returns the line that the helper prints for err, or an empty
// string. These 4 failures give an empty string, so the helper prints
// nothing for them: no key file, the service sshd, a request of another
// user, and a PAM caller that stops. A failure that the table does not
// list also gives an empty string.
func Reason(err error) string {
	var r *reasoned
	if errors.As(err, &r) {
		return r.line
	}
	switch {
	case errors.Is(err, ErrDenied):
		return reasonDenied
	case errors.Is(err, ErrTimeout):
		return reasonTimeout
	case errors.Is(err, ErrBadSignature):
		return reasonSignature
	case errors.Is(err, ErrStale):
		return reasonStale
	}
	return ""
}

// startReason returns the error of a failed approve.request.
func startReason(err error) error {
	var re *RemoteError
	if errors.As(err, &re) {
		switch re.Code {
		case "busy":
			return withReason(reasonBusy, err)
		case "offline", "not_paired", "unsupported", "not_found":
			return withReason(reasonPhone, err)
		}
	}
	return withReason(reasonFluxd, err)
}

func phoneFailed(message string) error {
	return withReason(reasonPhoneFailed, fmt.Errorf("the phone could not approve: %s", message))
}
