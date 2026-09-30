# Fingerprint approval

[Documentation index](README.md)

Flux for Android, Flux for iOS, and Flux for macOS can approve `sudo` requests.
The Android phone asks for a fingerprint. The iPhone asks for Face ID or Touch ID, and the Mac asks for Touch ID.
The same device can approve the `hyprlock` lock screen, but not the Omarchy lock screen. See [lock screens](#lock-screens).
It can approve polkit requests only on a system with a setuid `polkit-agent-helper-1`. See [polkit](#polkit).
The device signs the request with its hardware-backed key.
The root helper verifies the signature against a root-owned public key.
If approval fails or times out, PAM continues to the password prompt.

The iPhone gets requests only while Flux is open on it.
The Mac and the iPhone need a Secure Enclave.
An iPhone without one, such as the iOS simulator, refuses each request.
A Mac without one has no Touch ID, so **Approve** fails with an error.

Read the [security design](approve.md) before you change the implementation.

## Enable sudo approval

The complete desktop install provides `/usr/lib/flux/flux-approve`.
The device needs a configured fingerprint, Face ID, or Touch ID, and an active Flux connection.
Installation alone does not enable approval.

1. Open Flux on the phone, the iPhone, or the Mac.
2. Check that the desktop is connected.
3. Start setup from your desktop account:

   ```sh
   sudo flux-cli approve setup
   ```

4. Select Enroll on the phone, the iPhone, or the Mac.
5. Touch the fingerprint sensor, or confirm with Face ID or Touch ID.
6. Type the key code that the device shows, all 16 characters. Spaces, hyphens, and case do not matter. You have 3 tries.
7. Test in a new terminal:

   ```sh
   sudo -k
   sudo true
   ```

`flux-cli` compares the typed code with the code of the key that `fluxd` sent.
If the codes differ, it writes no key.
The device already uses its new key, so each approval fails until you run `sudo flux-cli approve enroll` again.
If the phone tells you to type `y`, type the code instead. The terminal needs all 16 characters.
The terminal does not show the code, because a program that runs as your user can write to your terminal.
It cannot change the screen of the phone.
Such a program can type into your terminal, for example with `wtype`, so run the enrollment only in a session that you trust.
See [the approval design](approve.md#enrollment-flow).

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

Flux does not enable `sshd` or `login`, and the helper refuses `sshd`.

### Lock screens

The Omarchy lock screen runs in `omarchy-shell`.
It uses its own PAM services, `omarchy-lock-password` and `omarchy-lock-fingerprint`.
Flux does not change them, so the phone cannot unlock the Omarchy lock screen.

The `hyprlock` service applies only when `hyprlock` is your lock screen.
To let the phone approve `hyprlock`, run:

```sh
sudo flux-cli approve enable hyprlock
```

When `hyprlock` is not installed, the command stops with an error.
When `hyprlock` is installed but another program locks the screen, the command changes nothing that you see.

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
