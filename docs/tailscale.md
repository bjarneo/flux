# Connect through Tailscale

[Documentation index](README.md)

Flux can reach a paired phone when the phone is not on the local network of the desktop.
Add the Tailscale name of the phone as an extra address.
`fluxd` then connects to the phone through Tailscale while the phone uses mobile data or another Wi-Fi network.

```text
fluxd ─┬─ last address, 192.168.1.20 ──────────── phone on the home Wi-Fi
       └─ extra address, pixel-8 ─── Tailscale ── phone on mobile data
```

Files, clipboard, notifications, streams, and the other features use the same link.
So they also work through the extra address.
The link still uses the pinned TLS certificates from pairing.

The steps are the same for a Mac that runs Flux for macOS.

## Requirements

- Tailscale runs on the desktop and on the phone, in the same tailnet.
- The phone is paired with the desktop. Pair it on the local network first.
- Flux for Android runs on the phone.

Tailscale does not carry the mDNS and UDP broadcasts that Flux uses for discovery.
So Flux cannot find or pair a device through Tailscale.

## Add the phone

1. Connect the phone to Tailscale.
2. On the desktop, find the name of the phone:

   ```sh
   tailscale status
   ```

   The second column shows the name, for example `pixel-8`.

3. Add the name as an extra address:

   ```sh
   flux --device "Pixel 8" addresses add pixel-8
   ```

4. Check the result:

   ```sh
   flux addresses
   flux doctor
   ```

When the phone is the only connected paired device, you can omit `--device`.
`flux doctor` checks that each extra host name resolves:

```text
✓ pixel-8 resolves, so fluxd can reach Pixel 8 through it
```

A MagicDNS name needs MagicDNS on the desktop.
Without MagicDNS, add the Tailscale IP address of the phone:

```sh
flux --device "Pixel 8" addresses add "$(tailscale ip -4 pixel-8)"
```

Flux for macOS listens on IPv4 only.
For a Mac, use the MagicDNS name or the IPv4 address.

## Use Flux away from home

Keep Tailscale connected on the phone.
When the phone leaves the local network, `fluxd` finds the dead link within 30 seconds.
It dials the phone again 2 seconds later, and the link comes back through Tailscale.

To check the link, run:

```sh
flux status
journalctl --user -u fluxd -n 50 --no-pager | grep "link up"
```

The `link up` line shows the address of the link, for example `link up: Pixel 8 (100.101.102.103) paired=true`.

A link through Tailscale stays up when the phone returns to the local network.
Tailscale then sends the traffic directly over the local network when it can.
If you turn off Tailscale on the phone, the link drops, and `fluxd` finds the phone on the local network through mDNS.

## Remove an address

```sh
flux --device "Pixel 8" addresses remove pixel-8
```

`flux unpair` also removes the extra addresses of the device.

## How it works

- `fluxd` opens every connection to the phone. The phone listens on all its network interfaces, so it accepts connections through Tailscale.
- For an offline paired device, `fluxd` dials the last address first. Then it dials the extra addresses in the order that you added them.
- `fluxd` starts the next address when the previous address fails or does not answer within 300 milliseconds. The first address that answers makes the link.
- `fluxd` dials every 30 seconds while the device is offline. It also dials 2 seconds after a link drops, and at once when you add an address.
- `fluxd` closes a link when sent data gets no acknowledgment for 30 seconds. So an old link does not stay open after the phone leaves the Wi-Fi.
- When mDNS reports the phone, `fluxd` dials the extra addresses too. Avahi can report an old address from its cache.
- `fluxd` uses the TCP port of the device from the last link. A device without a known port gets port 1716.
- Payloads, tunnels, and streams use the address of the link, so they also go through Tailscale.

The addresses are in the `addresses` field of each device in `~/.local/share/flux/devices.json`.
A device can have 5 extra addresses.
An address is a host name or an IP address without a port.

In the state from `flux status --json`, each device has an `addresses` list.
Scripts can change the list with the `addresses.add` and `addresses.remove` [IPC methods](ipc.md#extra-addresses).

## Other VPNs

An extra address can be any host name or IP address that routes to the phone.
Use the same command for another VPN, such as WireGuard.
The desktop must be able to open TCP connections to the phone on ports 1716 to 1764.

## Access and security

Each link uses TLS with the certificates that you pinned at pairing, as on the local network.
Tailscale adds a second layer of encryption.

Other devices in your tailnet can reach the Flux ports of the phone.
They can send a pair request, as a device on the local network can.
To stop this, use Tailscale access controls to limit TCP ports 1716 to 1764 on the phone to the desktop.

## Limits

- Android runs 1 VPN at a time. When another VPN app starts, Tailscale stops.
- Battery optimization can stop Tailscale on the phone. Turn off battery optimization for Tailscale.
- When Tailscale cannot make a direct connection, it sends the traffic through a relay server. The webcam and the screen mirror can lag through a relay.
- Flux for Android shows `Not on Wi-Fi` while the phone uses mobile data. The link through Tailscale still works.

## Troubleshoot

1. Check that both devices are in the tailnet:

   ```sh
   tailscale status
   ```

2. Check the route to the phone. The output shows `via DERP` when the traffic goes through a relay server.

   ```sh
   tailscale ping pixel-8
   ```

3. Check that the Flux port of the phone answers:

   ```sh
   timeout 3 bash -c '</dev/tcp/pixel-8/1716' && echo "port 1716 answers"
   ```

4. If the port does not answer, open Flux for Android and check that it runs.
5. Read the dial errors of `fluxd`:

   ```sh
   journalctl --user -u fluxd -n 50 --no-pager | grep "connect to"
   ```

6. Check the extra addresses and their names:

   ```sh
   flux addresses
   flux doctor
   ```
