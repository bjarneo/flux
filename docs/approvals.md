# Fingerprint approval

[Documentation index](README.md)

Flux for Android can approve `sudo` and hyprlock requests with a fingerprint.
It can approve polkit requests only on a system with a setuid `polkit-agent-helper-1`. See [polkit](#polkit).
The phone signs the request with its hardware-backed key.
The root helper verifies the signature against a root-owned public key.
If approval fails or times out, PAM continues to the password prompt.

Read the [security design](approve.md) before you change the implementation.

## Enable sudo approval

The complete desktop install provides `/usr/lib/flux/flux-approve`.
The phone needs a configured fingerprint and an active Flux connection.
Installation alone does not enable approval.

1. Open Flux on the phone.
2. Check that the desktop is connected.
3. Start setup from your desktop account:

   ```sh
   sudo flux-cli approve setup
   ```

4. Select Enroll on the phone.
5. Touch the fingerprint sensor.
6. Type the key code that the phone shows, all 16 characters. Spaces, hyphens, and case do not matter. You have 3 tries.
7. Test in a new terminal:

   ```sh
   sudo -k
   sudo true
   ```

`flux-cli` compares the typed code with the code of the key that `fluxd` sent.
If the codes differ, it writes no key.
If the phone tells you to type `y`, type the code instead. The terminal needs all 16 characters.
The terminal does not show the code, because a program that runs as your user can write to your terminal.
It cannot change the screen of the phone.

The terminal shows `Approve on <phone> for terminal <tty>`, and the phone shows the request.
Approve only a request that follows the command you just entered.
The phone shows the service, user, host, terminal, and time.
Check that the terminal on the phone is the terminal in the prompt.

When `sudo` stops before you approve, the helper ends the request on the phone.
The next `sudo` can then ask the phone at once.

The helper approves only for the user that asks.
It refuses a request that another user makes for your account, for example with the `targetpw` or `runaspw` option of sudoers.
PAM then asks for the password.

## PAM services

Setup checks the helper ownership and backs up the PAM file in `/etc/flux/approve/pam-backup/`.
It adds this line before the first authentication rule:

```text
auth sufficient pam_exec.so quiet stdout /usr/lib/flux/flux-approve
```

To enable additional supported services:

```sh
sudo flux-cli approve enable hyprlock
```

Flux does not change the separate PAM services used by the Omarchy lock screen.
It does not enable `sshd` or `login`, and the helper refuses `sshd`.

### polkit

polkit does not tell PAM which user asks.
The helper can see it only when `polkit-agent-helper-1` runs with setuid root, as in polkit 125 and earlier, or on a distribution that still installs it that way.
polkit 126 and later on Arch Linux run the agent helper as the `polkit-agent-helper@.service` system service.
That service cannot reach the socket of `fluxd`, so a polkit request never reaches the phone.
On such a system, `sudo flux-cli approve enable polkit-1` refuses to add the helper, and `flux-cli approve` says why.
Do not weaken the sandbox of the polkit service to make approvals work.

On a system with a setuid `polkit-agent-helper-1`, run:

```sh
sudo flux-cli approve enable polkit-1
```

The helper then approves only a polkit request of the same user that the agent runs as.
Setup copies the vendor polkit file to `/etc/pam.d/polkit-1` when necessary.

## Status, timeout, and removal

```sh
flux-cli approve
sudo flux-cli approve disable
sudo flux-cli approve remove
```

Disable removes the Flux PAM lines for all users.
When setup copied the vendor polkit file, disable removes `/etc/pam.d/polkit-1` again, so PAM uses the vendor file and its later updates.
A copy that an administrator changed stays, without the Flux line.

Remove deletes the enrolled phone public key of your user.
When no other user has a key, it also removes the Flux PAM lines.
When other users have keys, the PAM lines stay, and the command names those users.
`sudo flux-cli approve enroll` enrolls a phone without enabling a PAM service.

`sudo pacman -R omarchy-flux` and `sudo make uninstall` run `flux-cli approve disable` before they remove the helper.
The key files in `/etc/flux/approve` stay.

`flux-cli approve` also checks that `fluxd` answers on `/run/user/<uid>/flux/fluxd.sock`.
The helper uses only this socket. It does not read `FLUX_SOCKET` or `XDG_RUNTIME_DIR`.
The helper finds the user in `/etc/passwd`, so setup refuses a user of systemd-homed, SSSD, or LDAP.

The helper of `hyprlock` runs as your user, so it must reach the key file.
Setup sets the mode of `/etc/flux/approve` to 0755.
It also sets the mode of `/etc/flux` to 0755 when an earlier setup under a strict umask made it private.
If `flux-cli approve` cannot read the key file, run `sudo flux-cli approve setup` again, or run:

```sh
sudo chmod 755 /etc/flux /etc/flux/approve
```

`approve_timeout` in `config.toml` accepts 5 to 120 seconds.
The default is 20 seconds.
If the phone is disconnected, the helper stops immediately and PAM asks for the password.

| Path | Purpose |
| --- | --- |
| `/etc/flux/approve/<user>.pub` | Root-owned phone public key |
| `/usr/lib/flux/flux-approve` | PAM helper |
| `/etc/flux/approve/pam-backup/` | Original PAM configuration |
