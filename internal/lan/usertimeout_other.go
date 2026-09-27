//go:build !linux

package lan

import "net"

// setUserTimeout does nothing on systems without TCP_USER_TIMEOUT.
func setUserTimeout(net.Conn) {}
