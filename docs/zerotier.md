# Connect through ZeroTier

[Documentation index](README.md)

Flux can reach a paired phone through ZeroTier when the phone is not on the local network of the desktop.
ZeroTier makes a virtual Ethernet network between computers.
Unlike [Tailscale](tailscale.md), it carries the mDNS and the UDP broadcasts that Flux uses for discovery.
So Flux can find and pair a Mac or a Windows computer through ZeroTier.

On a phone, ZeroTier One runs as a VPN, and the VPN carries no mDNS.
So Flux does not find a phone through ZeroTier.
Pair the phone on the local network, and add its ZeroTier address as an extra address.

```text
fluxd ─┬─ last address, 192.168.1.20 ─────────────── phone on the home Wi-Fi
       └─ extra address, 10.147.17.30 ── ZeroTier ── phone on mobile data
```

Files, clipboard, notifications, streams, and the other features use the same link.
The link still uses the pinned TLS certificates from pairing.

## Requirements

- ZeroTier runs on the desktop and on the device, and both joined the same network.
- The network gives each member an IPv4 address. Flux finds devices over IPv4 only.
- A phone is paired with the desktop. Pair it on the local network first.
- For discovery of a computer, the network allows broadcasts, and Avahi uses the ZeroTier interface. Both are the defaults.

## Set up the desktop

1. Install and start ZeroTier:

   ```sh
   sudo pacman -S zerotier-one
   sudo systemctl enable --now zerotier-one
   ```

2. Join the network, and authorize the desktop in ZeroTier Central:

   ```sh
   sudo zerotier-cli join NETWORK
   ```

3. Check the network:

   ```sh
   sudo zerotier-cli listnetworks
   flux-cli doctor
   ```

`flux-cli doctor` checks each ZeroTier interface:

```text
✓ ZeroTier network ztabcdef12 (10.147.17.20/24) carries mDNS and broadcasts, so fluxd can find devices on it
```

The check fails when the interface is down, has no IPv4 address, or is left out by `allow-interfaces` or `deny-interfaces` in `/etc/avahi/avahi-daemon.conf`.
Each failure names the fix.

`fluxd` needs no restart.
It sends its broadcasts to each network at each discovery, and Avahi adds a new interface by itself.

## Add a phone

1. Install ZeroTier One on the phone, and join the same network.
2. Authorize the phone in ZeroTier Central.
3. Find the ZeroTier address of the phone. The ZeroTier One app shows it, and ZeroTier Central shows it under **Members**.
4. Add the address as an extra address:

   ```sh
   flux-cli --device "Pixel 8" addresses add 10.147.17.30
   ```

5. Check the result:

   ```sh
   flux-cli addresses
   flux-cli doctor
   ```

When the phone is the only connected paired device, you can omit `--device`.
The steps are the same for an iPhone, where ZeroTier One also runs as a VPN.

Give the phone a fixed address in ZeroTier Central, so that the extra address stays correct.
`fluxd` then dials the phone through ZeroTier, as through [Tailscale](tailscale.md#how-it-works).

### Why a phone needs the address

On a computer, ZeroTier adds a network interface with broadcast and multicast, so Avahi sends and hears mDNS on it.
On a phone, ZeroTier One must use the VPN service of the system.
The VPN takes only the IP packets that route to the range of the network.
mDNS goes to `224.0.0.251`, outside that range, so the phone sends it on Wi-Fi or mobile data.
The UDP broadcasts of Flux go the same way.
A connection to the ZeroTier address of the phone is in the range, so `fluxd` can dial it.

`fluxd` dials the address of the last link first.
After a link through ZeroTier, that address works even without the extra address.
After the phone links on the home Wi-Fi again, only the extra address leads `fluxd` back to ZeroTier.
So keep the extra address.

## Find a computer

A Mac or a Windows computer in the network shows up in `flux-cli status` and in the Flux window, as on the local network.
Open Flux on the computer, and pair it in the same way: [pair a Mac](macos.md#pair-a-mac) or [pair a Windows computer](windows.md#pair-a-windows-computer).
The default Omarchy firewall lets mDNS in and blocks the UDP broadcasts of the devices, as on the local network.
See [network ports](security.md#network-ports).

To check what Avahi sees on the ZeroTier interface, run:

```sh
avahi-browse -t -r -p _flux._udp | grep '^=' | grep ';zt'
```

If the computer does not show up, add its ZeroTier address as an extra address, as for a phone.

## Use Flux away from home

Keep ZeroTier connected on the phone.
When the phone leaves the local network, `fluxd` finds the dead link within 30 seconds.
It dials the phone again 2 seconds later, and the link comes back through the extra address.

To check the link, run:

```sh
flux-cli status
journalctl --user -u fluxd -n 50 --no-pager | grep "link up"
```

The `link up` line shows the address of the link, for example `link up: Pixel 8 (10.147.17.30) paired=true`.

## Access and security

Each link uses TLS with the certificates that you pinned at pairing, as on the local network.
ZeroTier adds a second layer of encryption.

Each member of the network is on the same virtual Ethernet network as the desktop.
So each member can find the desktop, and the desktop can find each member.
Flux for Android takes a connection from a device that is not paired only while Flux is on the screen or while it scans.
In that time, another member can send a pair request, as a device on the local network can.
Use a private network, and authorize only your own devices.
To limit the other members, use the flow rules of the network.

The default Omarchy firewall blocks inbound traffic to the Flux ports of the desktop on the ZeroTier interface too.
Do not add a rule such as `ufw allow in on ztabcdef12` for Flux.
With such a rule, each member of the network can open a link to `fluxd` and send a pair request.

## Limits

- Android runs 1 VPN at a time. When another VPN app starts, ZeroTier stops.
- Battery optimization can stop ZeroTier on the phone. Turn off battery optimization for ZeroTier One.
- When ZeroTier cannot make a direct connection, it sends the traffic through a relay. The webcam and the screen mirror can lag through a relay.
- Flux for Android shows `Not on Wi-Fi` while the phone uses mobile data. The link through ZeroTier still works.
- A network with more than 32 members can drop mDNS and broadcasts, because of the multicast limit of the network. Raise the limit in ZeroTier Central.

## Troubleshoot

1. Check that both devices are online in the network:

   ```sh
   sudo zerotier-cli listnetworks
   sudo zerotier-cli peers
   ```

   The `peers` output shows `RELAY` when the traffic goes through a relay.
   A latency of `-1` means that the desktop gets no answer from the device, even when ZeroTier Central shows the device online.
   Then turn the network off and on in ZeroTier One on the device, and turn off battery optimization for ZeroTier One.

2. Check that the device answers:

   ```sh
   ping -c 3 10.147.17.30
   timeout 3 bash -c '</dev/tcp/10.147.17.30/12100' && echo "port 12100 answers"
   ip neigh show 10.147.17.30
   ```

   `INCOMPLETE` or `FAILED` from `ip neigh` means that no member of the network has the address.
   Check the address of the device in ZeroTier Central.

3. If the port does not answer, open Flux on the device and check that it runs.
4. Check the ZeroTier interfaces, Avahi, and the extra addresses:

   ```sh
   flux-cli doctor
   flux-cli addresses
   ```

5. Read the dial errors of `fluxd`:

   ```sh
   journalctl --user -u fluxd -n 50 --no-pager | grep "connect to"
   ```
