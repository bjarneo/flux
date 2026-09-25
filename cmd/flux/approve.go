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

// approveCmd runs flux approve status, setup, enroll, enable, disable,
// and remove.
func approveCmd(args []string, device string) error {
	var rest []string
	if len(args) > 1 {
		rest = args[1:]
	}
	switch first(args) {
	case "", "status":
		return approveStatus()
	case "setup":
		return approveSetup(device, rest)
	case "enroll":
		return approveEnroll(device)
	case "enable":
		return approveEnable(rest)
	case "disable":
		return approveDisable(rest)
	case "remove":
		return approveRemove()
	default:
		return fmt.Errorf("unknown command: approve %s. Use status, setup, enroll, enable, disable, or remove", args[0])
	}
}

// approveSetup turns approvals on in 1 step: it enrolls the phone when no
// key exists, and it adds the helper to the PAM files of services.
func approveSetup(device string, services []string) error {
	u, _, err := sudoUser("setup")
	if err != nil {
		return err
	}
	if err := checkHelper(); err != nil {
		return err
	}
	if _, err := approve.ReadKey(approve.KeyPath(u.Username), 0); errors.Is(err, approve.ErrNoKey) {
		if _, err := enrollKey(device); err != nil {
			return err
		}
	} else if err != nil {
		return fmt.Errorf("the key file is not safe: %v. Remove it with: sudo flux approve remove", err)
	}
	return enablePAM(services)
}

// approveEnable adds the helper to the PAM files of services. It needs an
// enrolled key.
func approveEnable(services []string) error {
	u, _, err := sudoUser("enable")
	if err != nil {
		return err
	}
	if err := checkHelper(); err != nil {
		return err
	}
	if _, err := approve.ReadKey(approve.KeyPath(u.Username), 0); err != nil {
		return fmt.Errorf("no safe key for %s: %v. Run: sudo flux approve setup", u.Username, err)
	}
	return enablePAM(services)
}

// approveDisable removes the helper from the PAM files of services, or
// from all of them.
func approveDisable(services []string) error {
	if os.Geteuid() != 0 {
		return errors.New("run it with sudo: sudo flux approve disable")
	}
	if len(services) == 0 {
		services = approve.PAMServices
	}
	pam := approve.SystemPAM()
	for _, s := range services {
		changed, err := pam.Disable(s)
		switch {
		case err != nil:
			return err
		case changed:
			fmt.Printf("Removed the phone approval from %s/%s.\n", pam.Dir, s)
		}
	}
	fmt.Println("The password works as before.")
	return nil
}

func enablePAM(services []string) error {
	if len(services) == 0 {
		services = []string{"sudo"}
	}
	pam := approve.SystemPAM()
	for _, s := range services {
		changed, err := pam.Enable(s)
		if err != nil {
			return err
		}
		if changed {
			fmt.Printf("%s now asks the phone first. The file before the change is in %s/%s.\n", s, pam.Backup, s)
		} else {
			fmt.Printf("%s already asks the phone.\n", s)
		}
	}
	fmt.Println("Test it in a new terminal: sudo -k && sudo true")
	fmt.Println("If the phone does not answer, the password works as before. To undo it, run: sudo flux approve disable")
	return nil
}

// checkHelper refuses to add the helper to PAM when it is missing, or when
// a user other than root can change it.
func checkHelper() error {
	st, err := os.Stat(approve.HelperPath)
	if err != nil {
		return fmt.Errorf("%s is not installed. Install Flux with: sudo make install", approve.HelperPath)
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok || sys.Uid != 0 || st.Mode().Perm()&0o022 != 0 || !st.Mode().IsRegular() {
		return fmt.Errorf("%s must be a file that only root can change", approve.HelperPath)
	}
	if _, err := os.Stat("/usr/lib/security/pam_exec.so"); err != nil {
		return errors.New("pam_exec.so is not installed, so PAM cannot run the helper")
	}
	return nil
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
		fmt.Printf("No phone can approve for %s. To set it up, run: sudo flux approve setup\n", name)
		return nil
	case err != nil:
		return fmt.Errorf("the key file is not safe, so flux-approve does not use it: %v", err)
	}
	fmt.Printf("%s can approve for %s.\n", k.DeviceName, name)
	fmt.Printf("Key code: %s\n", approve.Fingerprint(k.DER))
	if k.Enrolled != "" {
		fmt.Printf("Enrolled: %s\n", k.Enrolled)
	}
	pam := approve.SystemPAM()
	for _, s := range approve.PAMServices {
		if pam.Uses(s) {
			fmt.Printf("%s asks the phone first.\n", s)
		} else {
			fmt.Printf("%s does not ask the phone. To turn it on, run: sudo flux approve enable %s\n", s, s)
		}
	}
	return nil
}

func approveEnroll(device string) error {
	if _, err := enrollKey(device); err != nil {
		return err
	}
	fmt.Println("To turn it on for sudo, run: sudo flux approve enable")
	return nil
}

// enrollKey makes a key on the phone, and writes its public key after the
// user compares the key codes.
func enrollKey(device string) (*approve.Key, error) {
	u, uid, err := sudoUser("enroll")
	if err != nil {
		return nil, err
	}
	host, err := os.Hostname()
	if err != nil {
		return nil, err
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
			return nil, errors.New("stopped. Flux wrote no key")
		}
		return nil, err
	}
	fmt.Printf("Enrolled. %s can now approve for %s.\n", k.DeviceName, u.Username)
	return k, nil
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
	return approveDisable(nil)
}
