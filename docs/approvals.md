# Fingerprint approval

[Documentation index](README.md)

Flux for Android can approve `sudo`, polkit, and hyprlock requests with a fingerprint.
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
   sudo flux approve setup
   ```

4. Select Enroll on the phone.
5. Touch the fingerprint sensor.
6. Compare the key code on the phone with the terminal code.
7. Type `y` only when the codes match.
8. Test in a new terminal:

   ```sh
   sudo -k
   sudo true
   ```

The terminal shows an approval prompt and the phone shows the request.
Approve only a request that follows the command you just entered.
The phone shows the service, user, host, terminal, and time.

## PAM services

Setup checks the helper ownership and backs up the PAM file in `/etc/flux/approve/pam-backup/`.
It adds this line before the first authentication rule:

```text
auth sufficient pam_exec.so quiet stdout /usr/lib/flux/flux-approve
```

To enable additional supported services:

```sh
sudo flux approve enable polkit-1 hyprlock
```

Setup copies the vendor polkit file to `/etc/pam.d/polkit-1` when necessary.
Flux does not change the separate PAM services used by the Omarchy lock screen.
It does not enable `sshd` or `login`, and the helper refuses `sshd`.

## Status, timeout, and removal

```sh
flux approve
sudo flux approve disable
sudo flux approve remove
```

Disable removes the Flux PAM lines.
Remove also deletes the enrolled phone public key.
`sudo flux approve enroll` enrolls a phone without enabling a PAM service.

`approve_timeout` in `config.toml` accepts 5 to 120 seconds.
The default is 20 seconds.
If the phone is disconnected, the helper stops immediately and PAM asks for the password.

| Path | Purpose |
| --- | --- |
| `/etc/flux/approve/<user>.pub` | Root-owned phone public key |
| `/usr/lib/flux/flux-approve` | PAM helper |
| `/etc/flux/approve/pam-backup/` | Original PAM configuration |
