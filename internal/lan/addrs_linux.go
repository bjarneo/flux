//go:build linux

package lan

import (
	"encoding/binary"
	"net"
	"syscall"
)

// ipv4Nets returns the IPv4 networks of the interfaces by interface index.
// It reads the addresses of all interfaces with 1 netlink request.
// Interface.Addrs sends 1 request for each interface. When the request
// fails, ipv4Nets asks each interface in ifaces.
func ipv4Nets(ifaces []net.Interface) map[int][]*net.IPNet {
	tab, err := syscall.NetlinkRIB(syscall.RTM_GETADDR, syscall.AF_INET)
	if err != nil {
		return interfaceNets(ifaces)
	}
	msgs, err := syscall.ParseNetlinkMessage(tab)
	if err != nil {
		return interfaceNets(ifaces)
	}
	out := map[int][]*net.IPNet{}
	for i := range msgs {
		m := &msgs[i]
		if m.Header.Type == syscall.NLMSG_DONE {
			break
		}
		// The data starts with struct ifaddrmsg: the family, the prefix
		// length, the flags, the scope, and the interface index.
		if m.Header.Type != syscall.RTM_NEWADDR || len(m.Data) < syscall.SizeofIfAddrmsg || m.Data[0] != syscall.AF_INET {
			continue
		}
		attrs, err := syscall.ParseNetlinkRouteAttr(m)
		if err != nil {
			continue
		}
		// IFA_LOCAL is the address of this computer. On a point-to-point
		// link, IFA_ADDRESS is the address of the peer. The net package
		// makes the same choice.
		var local, addr []byte
		for _, a := range attrs {
			switch a.Attr.Type {
			case syscall.IFA_LOCAL:
				local = a.Value
			case syscall.IFA_ADDRESS:
				addr = a.Value
			}
		}
		if local == nil {
			local = addr
		}
		if len(local) != net.IPv4len {
			continue
		}
		index := int(binary.NativeEndian.Uint32(m.Data[4:8]))
		ip := net.IPv4(local[0], local[1], local[2], local[3]).To4()
		out[index] = append(out[index], &net.IPNet{IP: ip, Mask: net.CIDRMask(int(m.Data[1]), 8*net.IPv4len)})
	}
	return out
}
