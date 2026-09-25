package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"os/user"
	"strconv"
	"strings"
	"syscall"

	"flux/internal/approve"
)

// pamLine is the line that turns approvals on in a PAM file.
const pamLine = "auth sufficient pam_exec.so quiet stdout /usr/lib/flux/flux-approve"

// approveCmd runs flux approve status, enroll, and remove.
func approveCmd(args []string, device string) error {
	switch first(args) {
	case "", "status":
		return approveStatus()
	case "enroll":
		return approveEnroll(device)
	case "remove":
		return approveRemove()
	default:
		return fmt.Errorf("unknown command: approve %s. Use status, enroll, or remove", args[0])
	}
}

// approveUser returns the user that approvals are for: SUDO_USER under
// sudo, else the current user.
func approveUser() (string, error) {
	if name := os.Getenv("SUDO_USER"); os.Geteuid() == 0 && name != "" {
		return name, nil
	}
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	return u.Username, nil
}

// sudoUser returns the user that runs a root command through sudo.
func sudoUser(cmd string) (*user.User, int, error) {
	if os.Geteuid() != 0 {
		return nil, 0, fmt.Errorf("run it with sudo: sudo flux approve %s", cmd)
	}
	name := os.Getenv("SUDO_USER")
	if name == "" || name == "root" {
		return nil, 0, fmt.Errorf("run it with sudo from your own user: sudo flux approve %s", cmd)
	}
	if !approve.ValidUser(name) {
		return nil, 0, fmt.Errorf("%q is not a valid local user name", name)
	}
	u, err := user.Lookup(name)
	if err != nil {
		return nil, 0, err
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil || uid <= 0 {
		return nil, 0, fmt.Errorf("the user %s has no valid user ID", name)
	}
	return u, uid, nil
}

func approveStatus() error {
	name, err := approveUser()
	if err != nil {
		return err
	}
	k, err := approve.ReadKey(approve.KeyPath(name), 0)
	switch {
	case errors.Is(err, approve.ErrNoKey):
		fmt.Printf("No phone can approve for %s. To enroll a phone, run: sudo flux approve enroll\n", name)
		return nil
	case err != nil:
		return fmt.Errorf("the key file is not safe, so flux-approve does not use it: %v", err)
	}
	fmt.Printf("%s can approve for %s.\n", k.DeviceName, name)
	fmt.Printf("Key code: %s\n", approve.Fingerprint(k.DER))
	if k.Enrolled != "" {
		fmt.Printf("Enrolled: %s\n", k.Enrolled)
	}
	for _, f := range []string{"/etc/pam.d/sudo", "/etc/pam.d/polkit-1"} {
		b, err := os.ReadFile(f)
		switch {
		case err != nil:
			continue
		case strings.Contains(string(b), "/usr/lib/flux/flux-approve"):
			fmt.Printf("%s uses it.\n", f)
		default:
			fmt.Printf("%s does not use it. To turn it on, add this line at the top: %s\n", f, pamLine)
		}
	}
	return nil
}

func approveEnroll(device string) error {
	u, uid, err := sudoUser("enroll")
	if err != nil {
		return err
	}
	host, err := os.Hostname()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	k, err := approve.Enroll(ctx, approve.EnrollOptions{
		User:     u.Username,
		Host:     host,
		Device:   device,
		Socket:   fmt.Sprintf("/run/user/%d/flux/fluxd.sock", uid),
		PeerUID:  uid,
		KeyPath:  approve.KeyPath(u.Username),
		KeyOwner: 0,
		Waiting: func(phone string) {
			fmt.Printf("Confirm on %s. Flux for Android asks for your fingerprint.\n", phone)
		},
		Confirm: confirmCode,
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return errors.New("stopped. Flux wrote no key")
		}
		return err
	}
	fmt.Printf("Enrolled. %s can now approve for %s.\n", k.DeviceName, u.Username)
	fmt.Println("To turn it on for sudo, add this line at the top of /etc/pam.d/sudo:")
	fmt.Println("  " + pamLine)
	fmt.Println("Keep a root shell open while you test it. The password still works.")
	return nil
}

// confirmCode shows the key code and asks the user to compare it with the
// phone. It reads the answer from the terminal.
func confirmCode(phone, code string) bool {
	fmt.Printf("Key code: %s\n", code)
	fmt.Printf("Check that %s shows the same code. Is it the same? [y/N] ", phone)
	in := os.Stdin
	if tty, err := os.Open("/dev/tty"); err == nil {
		defer tty.Close()
		in = tty
	}
	line, _ := bufio.NewReader(in).ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	}
	return false
}

func approveRemove() error {
	u, _, err := sudoUser("remove")
	if err != nil {
		return err
	}
	if err := approve.RemoveKey(approve.KeyPath(u.Username)); err != nil {
		return err
	}
	fmt.Printf("Removed the key for %s. No phone can approve for this user now.\n", u.Username)
	fmt.Println("You can also remove the flux-approve line from your PAM files.")
	return nil
}
