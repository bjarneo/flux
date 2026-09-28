//go:build !linux

package lan

import "net"

// ipv4Nets returns the IPv4 networks of ifaces by interface index.
func ipv4Nets(ifaces []net.Interface) map[int][]*net.IPNet { return interfaceNets(ifaces) }
