package approve

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// passwdPath is the file of the local users.
const passwdPath = "/etc/passwd"

// User is a local user from /etc/passwd.
type User struct {
	Name string
	UID  int
}

// LookupUser finds a local user in /etc/passwd. The helper and flux-cli
// both use it, so the setup refuses a user that the helper cannot find,
// such as a user of systemd-homed, SSSD, or LDAP.
func LookupUser(name string) (User, error) { return lookupUser(passwdPath, name) }

func lookupUser(path, name string) (User, error) {
	if !ValidUser(name) {
		return User{}, fmt.Errorf("%q is not a valid local user name", name)
	}
	f, err := os.Open(path)
	if err != nil {
		return User{}, err
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Split(s.Text(), ":")
		if len(fields) < 7 || fields[0] != name {
			continue
		}
		uid, err := strconv.Atoi(fields[2])
		if err != nil || uid < 0 {
			return User{}, fmt.Errorf("the user %s has no valid user ID in %s", name, path)
		}
		return User{Name: name, UID: uid}, nil
	}
	if err := s.Err(); err != nil {
		return User{}, err
	}
	return User{}, fmt.Errorf("%s is not in %s. Flux approves only local users", name, path)
}
