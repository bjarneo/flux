package proto

// TypeFluxWake carries the network cards of the computer that can wake it
// from sleep, {"targets": [{"mac": "aa:bb:cc:dd:ee:ff", "broadcast":
// "192.168.1.255"}]}. fluxd sends it to a paired phone after the link
// comes up. The phone keeps it and sends a Wake-on-LAN magic packet to
// the computer while it is offline.
const TypeFluxWake = "flux.wake"

func init() { Outgoing = append(Outgoing, TypeFluxWake) }
