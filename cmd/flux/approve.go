package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"

	"flux/internal/approve"
)

// approveCmd runs flux-cli approve status, setup, enroll, enable, disable,
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
	u, err := sudoUser("setup")
	if err != nil {
		return err
	}
	if err := checkHelper(approve.HelperPath); err != nil {
		return err
	}
	if err := checkServices(services); err != nil {
		return err
	}
	if _, err := approve.ReadKey(approve.KeyPath(u.Name), 0); errors.Is(err, approve.ErrNoKey) {
		if _, err := enrollKey(device); err != nil {
			return err
		}
	} else if err != nil {
		return fmt.Errorf("the key file is not safe: %v. Remove it with: sudo flux-cli approve remove", err)
	}
	return enablePAM(services)
}

// approveEnable adds the helper to the PAM files of services. It needs an
// enrolled key.
func approveEnable(services []string) error {
	u, err := sudoUser("enable")
	if err != nil {
		return err
	}
	if err := checkHelper(approve.HelperPath); err != nil {
		return err
	}
	if err := checkServices(services); err != nil {
		return err
	}
	if _, err := approve.ReadKey(approve.KeyPath(u.Name), 0); err != nil {
		return fmt.Errorf("no safe key for %s: %v. Run: sudo flux-cli approve setup", u.Name, err)
	}
	return enablePAM(services)
}

// polkitHelpers are the places of polkit-agent-helper-1 on Arch Linux and
// on other distributions.
var polkitHelpers = []string{"/usr/lib/polkit-1/polkit-agent-helper-1", "/usr/libexec/polkit-agent-helper-1"}

// checkServices refuses a service that cannot use approvals on this
// computer. The helper approves polkit-1 only when the polkit agent helper
// runs with setuid root, because only then the helper sees which user
// asks. polkit 126 and later run the agent helper as a systemd service
// instead, and that service cannot reach the socket of fluxd.
func checkServices(services []string) error {
	for _, s := range services {
		if s != "polkit-1" {
			continue
		}
		if err := polkitSetuid(polkitHelpers); err != nil {
			return err
		}
	}
	return nil
}

func polkitSetuid(paths []string) error {
	for _, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		if st.Mode()&os.ModeSetuid == 0 {
			return fmt.Errorf("%s does not run with setuid root, so the helper cannot see which user asks. The phone cannot approve polkit-1 on this computer", p)
		}
		return nil
	}
	return errors.New("polkit-agent-helper-1 is not installed, so polkit-1 cannot use approvals")
}

// approveDisable removes the helper from the PAM files of services, or
// from all of them. The package runs it before it removes Flux.
func approveDisable(services []string) error {
	if os.Geteuid() != 0 {
		return errors.New("run it with sudo: sudo flux-cli approve disable")
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
	fmt.Println("If the phone does not answer, the password works as before. To undo it, run: sudo flux-cli approve disable")
	return nil
}

// checkHelper refuses to add the helper at path to PAM when it is
// missing, or when a user other than root can change it.
func checkHelper(path string) error {
	st, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("%s is not installed. Install Flux with: sudo make install", path)
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok || sys.Uid != 0 || st.Mode().Perm()&0o022 != 0 || !st.Mode().IsRegular() {
		return fmt.Errorf("%s must be a file that only root can change", path)
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
func sudoUser(cmd string) (approve.User, error) {
	return findSudoUser(cmd, os.Geteuid(), os.Getenv("SUDO_USER"), approve.LookupUser)
}

// findSudoUser finds the user name of SUDO_USER with lookup. It uses the
// same user lookup as the helper, so it refuses a user that the helper
// cannot find.
func findSudoUser(cmd string, euid int, name string, lookup func(string) (approve.User, error)) (approve.User, error) {
	if euid != 0 {
		return approve.User{}, fmt.Errorf("run it with sudo: sudo flux-cli approve %s", cmd)
	}
	if name == "" || name == "root" {
		return approve.User{}, fmt.Errorf("run it with sudo from your own user: sudo flux-cli approve %s", cmd)
	}
	if !approve.ValidUser(name) {
		return approve.User{}, fmt.Errorf("%q is not a valid local user name", name)
	}
	u, err := lookup(name)
	if err != nil {
		return approve.User{}, err
	}
	if u.UID <= 0 {
		return approve.User{}, fmt.Errorf("the user %s has no valid user ID", name)
	}
	return u, nil
}

func approveStatus() error {
	name, err := approveUser()
	if err != nil {
		return err
	}
	k, err := approve.ReadKey(approve.KeyPath(name), 0)
	switch {
	case errors.Is(err, approve.ErrNoKey):
		fmt.Printf("No phone can approve for %s. To set it up, run: sudo flux-cli approve setup\n", name)
		return nil
	case errors.Is(err, fs.ErrPermission):
		// A setup under a strict umask closed /etc/flux. The helper of a
		// lock screen runs as the user, so it cannot read the key either.
		return fmt.Errorf("cannot read the key file: %v. To fix it, run: sudo chmod 755 %s %s", err, filepath.Dir(approve.KeyDir), approve.KeyDir)
	case err != nil:
		return fmt.Errorf("the key file is not safe, so flux-approve does not use it: %v", err)
	}
	fmt.Printf("%s can approve for %s.\n", safe(k.DeviceName), name)
	fmt.Printf("Key code: %s\n", approve.Fingerprint(k.DER))
	if k.Enrolled != "" {
		fmt.Printf("Enrolled: %s\n", k.Enrolled)
	}
	pam := approve.SystemPAM()
	for _, s := range approve.PAMServices {
		unsupported := checkServices([]string{s})
		switch {
		case unsupported != nil && pam.Uses(s):
			fmt.Printf("%s runs the helper, but it cannot ask the phone: %v\n", s, unsupported)
		case unsupported != nil:
			fmt.Printf("%s cannot ask the phone: %v\n", s, unsupported)
		case pam.Uses(s):
			fmt.Printf("%s asks the phone first.\n", s)
		default:
			fmt.Printf("%s does not ask the phone. To turn it on, run: sudo flux-cli approve enable %s\n", s, s)
		}
	}
	// The helper uses a fixed socket. A fluxd with FLUX_SOCKET or another
	// XDG_RUNTIME_DIR listens elsewhere, and the helper cannot find it.
	if u, err := approve.LookupUser(name); err != nil {
		fmt.Printf("The helper cannot find %s: %v. Every request goes to the password.\n", name, err)
	} else if err := approve.Reachable(approve.SocketPath(u.UID), u.UID); err != nil {
		fmt.Printf("fluxd does not answer on %s, so every request goes to the password: %v\n", approve.SocketPath(u.UID), err)
	}
	return nil
}

func approveEnroll(device string) error {
	if _, err := enrollKey(device); err != nil {
		return err
	}
	fmt.Println("To turn it on for sudo, run: sudo flux-cli approve enable")
	return nil
}

// enrollKey makes a key on the phone, and writes its public key after the
// user compares the key codes.
func enrollKey(device string) (*approve.Key, error) {
	u, err := sudoUser("enroll")
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
		User:     u.Name,
		Host:     host,
		Device:   device,
		Socket:   approve.SocketPath(u.UID),
		PeerUID:  u.UID,
		KeyPath:  approve.KeyPath(u.Name),
		KeyOwner: 0,
		Waiting: func(phone string) {
			fmt.Printf("Confirm on %s. Flux asks for your fingerprint, Face ID, or Touch ID.\n", safe(phone))
		},
		Confirm: confirmCode,
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil, errors.New("stopped. Flux wrote no key")
		}
		return nil, err
	}
	fmt.Printf("Enrolled. %s can now approve for %s.\n", safe(k.DeviceName), u.Name)
	return k, nil
}

// confirmCode asks the user to type the key code that the phone shows,
// and compares it with the code of the key that fluxd sent. The terminal
// does not show the code, because code that runs as the user can write to
// the terminal, but it cannot change the screen of the phone.
func confirmCode(phone, code string) bool {
	in := os.Stdin
	if tty, err := os.Open("/dev/tty"); err == nil {
		defer tty.Close()
		in = tty
	}
	return typedCode(bufio.NewReader(in), os.Stdout, phone, code)
}

// codeTries is the number of times that typedCode asks for the key code.
const codeTries = 3

// typedCode reads the key code that the user types, and it asks again
// after a wrong code. An earlier phone app tells the user to type y, so y
// gets a hint.
func typedCode(in *bufio.Reader, out io.Writer, phone, code string) bool {
	for try := 1; try <= codeTries; try++ {
		fmt.Fprintf(out, "Type the key code that %s shows, all 16 characters: ", phone)
		line, err := in.ReadString('\n')
		if approve.SameCode(line, code) {
			return true
		}
		if err != nil || try == codeTries {
			break
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes":
			fmt.Fprintf(out, "Do not type y. Type the 16 characters that %s shows.\n", phone)
		default:
			fmt.Fprintln(out, "This is not the code of the new key. Try again.")
		}
	}
	fmt.Fprintln(out, "The code is not the code of the new key. Flux wrote no key.")
	return false
}

// approveRemove deletes the key of the user. It turns approvals off in PAM
// only when no other user has a key, because the PAM files are shared by
// all users.
func approveRemove() error {
	u, err := sudoUser("remove")
	if err != nil {
		return err
	}
	if err := approve.RemoveKey(approve.KeyPath(u.Name)); err != nil {
		return err
	}
	fmt.Printf("Removed the key for %s. No phone can approve for this user now.\n", u.Name)
	others, err := approve.OtherKeys(approve.KeyDir, u.Name)
	if err != nil {
		return err
	}
	if len(others) > 0 {
		fmt.Printf("PAM still asks the phone first for %s. To turn it off for all users, run: sudo flux-cli approve disable\n", strings.Join(others, ", "))
		return nil
	}
	return approveDisable(nil)
}
