# Approve with fingerprint: security design

Flux can approve `sudo`, polkit, and the `hyprlock` lock screen on a
paired device: an Android phone, an iPhone, or a Mac. The device signs
each request with a private key that never leaves its secure hardware,
and only after a fingerprint, Face ID, or Touch ID. A small helper on the
computer checks the signature with a public key that only root can
change. If anything fails, PAM asks for the password as usual.

The Omarchy lock screen runs in `omarchy-shell` with its own PAM
services, `omarchy-lock-password` and `omarchy-lock-fingerprint`. Flux
does not change them, so an approval does not unlock the Omarchy lock
screen. The `hyprlock` service applies only when `hyprlock` is the lock
screen.

In this document, "the phone" means the device that signs: Flux for
Android, Flux for iOS, or Flux for macOS. A section that names 1 app
applies only to that app.

This document is the design. The code must follow it. Read it before you
change one of these parts:

- `internal/approve`, `cmd/flux-approve`, and `internal/core/approve.go`.
- The approve code in Flux for Android: `core/Approve*` and
  `ui/ApproveActivity.kt`.
- The approve code of the iPhone and the Mac:
  `macos/Sources/FluxKit/Plugins/Approve/`, `macos/App/Features/Approve/`,
  and `ios/App/Features/Approve/`.

## Parts

| Part | Runs as | Job |
| --- | --- | --- |
| `flux-approve` | The PAM caller, root for `sudo` and polkit | Makes the request, checks the signature, and gives the PAM result |
| `/etc/flux/approve/<user>.pub` | A file owned by root | The trust anchor: the public key of the phone |
| `fluxd` | The user | Carries the messages between the helper and the phone |
| Flux for Android | The phone user | Shows the request, asks for the fingerprint, and signs with a key in the Android Keystore |
| Flux for iOS and Flux for macOS | The user of the iPhone or the Mac | Show the request, ask for Face ID or Touch ID, and sign with a key in the Secure Enclave. The code is in `FluxKit`. |
| `flux-cli approve enroll` | root, through `sudo` | Gets the public key from the phone and writes the key file |

## Threat model

The feature protects root access through `sudo`, polkit admin actions,
and a lock screen. It must not make these easier to get than with the
password.

The design considers these attackers:

1. **A network attacker.** This attacker can read, change, and send
   traffic on the Wi-Fi network.
2. **Code that runs as the user.** This attacker can run any program as
   the user. It can replace `fluxd`, read and write the files of the user,
   and connect to the `fluxd` socket.
3. **A person with the locked phone.** This person does not have the
   fingerprint of the user.
4. **A person with the unlocked phone.** This person can open Flux, but
   does not have the fingerprint of the user.

These are out of scope:

- Code that runs as root on the computer. Root can change PAM itself.
- A phone whose operating system or secure hardware is broken.
- A user who approves a request without reading it. The open risks below
  describe how the design reduces this risk.

## Trust anchor

The public key of the phone is in `/etc/flux/approve/<user>.pub`. Only
`flux-cli approve enroll`, which runs as root, writes it. The helper uses the
key only if all of these are true:

- The file is a regular file, not a symbolic link.
- The owner of the file is root.
- No group and no other user can write to the file.
- Each folder from `/etc/flux/approve` up to `/` is owned by root. No
  group and no other user can write to it, except a folder with the sticky
  bit that root owns.
- The file opens with `O_NOFOLLOW`, and it is the same file that the
  check examined.
- The file is a PEM `PUBLIC KEY` block that holds an EC key on the curve
  P-256. The file is at most 16 KiB.

The key path is fixed in the helper. The helper has no flag and no
environment variable that changes it. So the user cannot point the helper
to a key that the user controls.

The PEM headers `Device-Id` and `Device-Name` name the phone. The helper
uses them only to find the phone and to name it on the screen. They do
not change what a valid signature is.

## Keys on the device

Each app makes 1 key for each paired computer. The key is EC P-256, for
signing with SHA-256 only. A signature is not possible without a new
biometric check, even for code that runs in the Flux app.

### Android

- Flux for Android keeps the key in the Android Keystore. The alias is
  `flux-approve-<computer device ID>`.
- The key needs user authentication for each use, with a strong
  biometric and no time window. On Android 11 and later, this is
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`. On Android
  10, it is a validity of -1 seconds, which also means each use.
- A new fingerprint in the phone settings makes the key invalid. The user
  then enrolls again.
- The phone uses StrongBox when the phone has it.
- The phone signs only through `BiometricPrompt` with a `CryptoObject`
  that holds the `Signature` object. The prompt allows only
  `BIOMETRIC_STRONG`, so the PIN of the phone cannot sign.
- An enrollment keeps the current key until the phone sends the new key
  to the computer. The phone makes the new key under the second alias,
  `flux-approve-<computer device ID>.b`, or under the first alias when the
  current key uses the second. When the send works, the phone deletes the
  old key. When the user cancels, the fingerprint check fails, or the send
  fails, the phone deletes the new key, and the old key stays. With 2
  keys, the older key is the current key. When the command then writes no
  key file, for example after a wrong key code, each approval fails until
  the next enrollment.
- An unpair on the phone deletes the keys of that computer. The key file
  on the computer stays until `sudo flux-cli approve remove`.
- On Android 12 and later, the approval screen hides the windows of other
  apps. The phone refuses **Approve** when the window of another app
  covered the screen during the tap.

### iPhone and Mac

- Flux for iOS and Flux for macOS keep the key in the Secure Enclave. The
  code is in `ApproveKeys.swift`.
- The access control is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
  with the flags `.privateKeyUsage` and `.biometryCurrentSet`. Do not add
  `.devicePasscode` or `.userPresence`, because the passcode or the
  password could then sign.
- Each signature uses a new `LAContext` with
  `touchIDAuthenticationAllowableReuseDuration` set to 0 and
  `localizedFallbackTitle` set to an empty string. So 1 biometric check
  does not sign 2 requests, and the system offers no password fallback.
- The key works only while the device is unlocked. A signature on a
  locked device fails with an error.
- The Secure Enclave wraps the private key. Flux stores the wrapped blob,
  the public key, the host, the user, and the time of the enrollment in
  `<data>/approve/<computer device ID>.json`. `<data>` is
  `~/Library/Application Support/Flux` on the Mac, and the Application
  Support folder of the app on the iPhone. The file has mode 0600, and
  the folder has mode 0700. Only the Secure Enclave of the same device can
  use the blob. The key needs no keychain entitlement, so it works in an
  ad hoc signed app.
- On the iPhone, the `approve` folder is excluded from iCloud and
  computer backups.
- Flux stores `evaluatedPolicyDomainState` with the key. When the
  enrolled fingerprints or faces change, the Secure Enclave refuses the
  key, and Flux deletes it before it asks. The user then enrolls again.
- An iPhone without a Secure Enclave refuses each request. The iOS
  simulator counts as such an iPhone. A Mac without a Secure Enclave has
  no Touch ID, so **Approve** fails with an error. Flux never makes a key
  outside the Secure Enclave.
- An enrollment keeps the current key until the new key goes out to the
  computer. Flux stores the new key in `<computer device ID>.pending` in
  the same folder. When the send works, Flux renames the file to
  `<computer device ID>.json` in place of the old key. When the send
  fails, Flux deletes the new key, and the old key stays. When the command
  then writes no key file, for example after a wrong key code, each
  approval fails until the next enrollment.
- An unpair on the Mac or the iPhone deletes the key of that computer.
  **Remove Key** on the page of the computer also deletes it. The key
  file on the computer stays until `sudo flux-cli approve remove`.
- An enrollment that replaces the current key of the computer says so on
  the prompt and in the notification.
- On the iPhone, **Approve** in the notification needs an unlocked iPhone
  and opens Flux, because Face ID needs Flux on the screen. **Deny** works
  on the lock screen. On the Mac, **Approve** in the notification asks for
  Touch ID at once.

## Messages

The phone signs the exact bytes below with `SHA256withECDSA`. The result
is an ASN.1 DER signature. The helper checks it with `ecdsa.VerifyASN1`
over the SHA-256 hash of the same bytes.

An approval message has 8 lines. Each line ends with 1 newline character:

```text
flux-approve-v1
host=<host name>
user=<user name>
service=<PAM service>
tty=<PAM_TTY, or empty>
rhost=<PAM_RHOST, or empty>
time=<Unix time in seconds>
nonce=<32 random bytes as 64 lowercase hex digits>
```

An enrollment message has 6 lines. Each line ends with 1 newline character:

```text
flux-approve-enroll-v1
host=<host name>
user=<user name>
key=<SHA-256 of the public key in DER, as 64 lowercase hex digits>
time=<Unix time in seconds>
nonce=<32 random bytes as 64 lowercase hex digits>
```

Each field value has these rules. The helper, `fluxd`, and the phone all
check them, and a request that breaks a rule fails:

- The value is valid UTF-8, at most 256 bytes long.
- The value has no control character, so no value can hold a newline.
  So each message has only 1 meaning.
- `host`, `user`, and `service` are not empty.
- `nonce` is exactly 64 lowercase hex digits.

The Go, Kotlin, and Swift code build the same bytes. The tests
`internal/approve/message_test.go`, `ApproveMessageTest.kt`, and
`ApproveMessageTests.swift` check them with the same vectors.

The first line names the version and the purpose. So a signature for an
enrollment is never a valid approval, and the reverse.

## Approval flow

1. PAM starts `flux-approve` through `pam_exec`. The helper reads
   `PAM_USER`, `PAM_SERVICE`, `PAM_TTY`, `PAM_RHOST`, `PAM_RUSER`, and its
   real user ID.
2. The helper refuses the `sshd` service, and the user names that are not
   valid local user names. It also refuses a request that another user
   makes: `PAM_RUSER` is set and differs from `PAM_USER`, or the real user
   ID is not 0 and not the user ID of `PAM_USER`. For `polkit-1`, the real
   user ID must be the user ID of `PAM_USER`, because polkit gives no PAM
   item for the user that asks.
3. The helper reads and checks the key file. With no key file, it stops at
   once.
4. The helper makes a 32-byte nonce with `crypto/rand` and takes the time.
5. The helper connects to `/run/user/<uid>/flux/fluxd.sock`. It checks that
   the folder of the socket and the socket belong to the user, and with
   `SO_PEERCRED` that the process at the other end runs as the same user.
   Without `fluxd`, it stops at once. The helper does not read
   `FLUX_SOCKET` or `XDG_RUNTIME_DIR`, so it finds only a `fluxd` that
   listens on this path.
6. The helper calls `approve.request`. `fluxd` sends a `flux.approve`
   request to the phone in the key file. If the phone is not connected,
   `fluxd` returns an error, and the helper stops at once.
7. The helper prints 1 line: `Approve on <phone> for terminal <tty>, or
   wait for the password prompt.` Without a TTY, the line has no terminal.
8. The phone shows `Approve <service> for user <user> on host <host>?`
   with the TTY, the remote host, and the time. It shows Approve and Deny.
9. Approve asks for the biometric check: `BiometricPrompt` on Android,
   Face ID or Touch ID on the iPhone and the Mac. After the check, the
   phone signs the approval message and sends it. Deny sends a denial.
10. The helper calls `approve.wait` until it gets a result or its time
    ends.
11. The helper builds the approval message again from its own fields. It
    does not use any field that `fluxd` or the phone sends back. It checks
    the signature with the key from the key file, and it checks the time.
12. The helper exits with 0 only when the signature is valid. Any other
    result is a non-zero exit, and PAM goes on to the password.

## Enrollment flow

1. The user runs `sudo flux-cli approve enroll`. The command runs as root and
   takes the user from `SUDO_USER`.
2. The command connects to the socket of that user and checks the peer
   with `SO_PEERCRED`.
3. The command makes a nonce and calls `approve.enroll`. `fluxd` sends the
   enrollment request to the phone.
4. The phone shows `Use this phone to approve sudo for user <user> on host
   <host>?`. The iPhone and the Mac say `this iPhone` and `this Mac`.
   Approve makes a new key and asks for the biometric check.
5. After the check, the phone signs the enrollment message and sends the
   public key and the signature. The phone shows the key code: the first 8
   bytes of the SHA-256 of the public key, as 16 uppercase hex digits in 4
   groups of 4.
6. The command checks the signature with the new public key. This proves
   that the phone has the private key and that the key works with the
   biometric check.
7. The command asks the user to type the key code that the phone shows. It
   compares the typed code with the code of the public key that it got. It
   ignores spaces, hyphens, and case, and it needs all 16 hex digits. The
   user has 3 tries. The terminal does not show the code of the public key,
   because code that runs as the user can write to the terminal of the user.
8. The command writes the key file. It writes a temporary file in the same
   folder, sets the mode to 0644 and the owner to root, syncs it, and
   renames it. It sets the mode of `/etc/flux/approve` to 0755. It sets
   the mode of `/etc/flux` to 0755 when other users cannot pass through
   it. The `hyprlock` helper runs as the user and must read the key.

The typed key code in step 7 stops only a changed `fluxd` that cannot
send keys to the terminal. Such a `fluxd` can send its own key, but it
cannot make the phone show the code of that key. The command does not
trust its terminal output, so a rewritten terminal line does not help it.

The typed key code does not stop code that runs as the user. A changed
`fluxd` runs as the user too, and it knows the code of the key that it
sent. It can type that code into the terminal of
`sudo flux-cli approve enroll`. It can use a virtual keyboard, for example
`wtype`, which Omarchy installs for the phone keyboard. It can also use
the remote control of the terminal. The command reads the code from
`/dev/tty`, and it cannot tell typed keys from synthetic keys. The command
then writes the key of the attacker, and the attacker can approve `sudo`
without the phone. So this check is defense in depth only. Run the
enrollment only in a session that you trust. Code that runs as the user
can also get root when the user runs `sudo`, for example with a shell
alias.

## Replay protection

- Each approval has a new 32-byte random nonce from the helper.
- The signature covers the nonce. The helper checks the signature over the
  nonce that it made itself. So an old signature is never valid for a new
  request.
- The helper keeps the nonce only in memory, for 1 request.
- The helper also checks that the signed time is at most the wait time in
  the past and at most 5 seconds in the future.
- The phone refuses a request whose time is more than 10 minutes from the
  phone clock.
- `fluxd`, the helper, and the phones refuse a time that is not from 1 to
  2^40 seconds.

## Timeouts

| Step | Limit |
| --- | --- |
| Connect to `fluxd` | 2 seconds |
| `approve.request` | 3 seconds |
| The wait for the phone | `approve_timeout` in `config.toml`, 20 seconds by default, from 5 to 120 seconds |
| The whole helper | 130 seconds at most, whatever `fluxd` says |
| The request on the phone | The wait time, then the phone closes it |

The helper waits in `approve.wait`. When the wait time ends during
`approve.wait`, `fluxd` sends a cancel to the phone, and the helper exits
with a failure. PAM then asks for the password. `fluxd` also sends a
cancel when the connection that started the request closes, and for
`approve.cancel`. The phone closes the request at the end of the wait time
in each case, also when no cancel comes. The phone takes a cancel only
from the computer of the open request. An unpair from either side closes
the open request of that computer at once.

## Failure modes

Every failure gives a non-zero exit, and PAM asks for the password.

| Condition | Result |
| --- | --- |
| No key file | The helper stops at once and prints nothing |
| A key file that fails a check | The helper stops at once |
| `fluxd` does not run, or the peer is another user | The helper stops at once |
| The phone is not paired or not connected | The helper stops at once |
| Another approval waits for the same phone | `fluxd` refuses the request |
| The user denies on the phone | The helper stops |
| No answer in time | The helper stops, and `fluxd` cancels the request on the phone |
| A wrong signature, a wrong key, or a changed field | The helper stops |
| A stale or future time | The helper stops |
| The phone has no strong biometric | The phone sends an error |
| A new fingerprint on the phone | The key is invalid, the phone sends an error, and the user enrolls again |
| The service is `sshd` | The helper stops at once |
| Another user asks, for example with the sudoers option `targetpw` | The helper stops at once |
| `polkit-1` without a setuid `polkit-agent-helper-1` | The helper stops at once. `flux-cli approve enable polkit-1` refuses this service |
| The PAM caller stops, for example when the user closes the terminal or kills `sudo` | The helper gets `SIGTERM` and ends the request. `fluxd` also ends a request when the connection of its helper closes, and it closes the request on the phone |

## What an attacker can do

| Attacker | Can | Cannot |
| --- | --- | --- |
| Network | Block or delay the link, so that PAM asks for the password | Read or change the messages, because the link uses TLS with pinned certificates. Make a valid signature. |
| Code that runs as the user | Stop the approval, so that PAM asks for the password. Send requests to the phone. Start `sudo` and wait for the user to approve it. Enroll its own key during `sudo flux-cli approve enroll`, because it can type the key code into the terminal, see the open risks. | Make a valid signature. Change the key file without an enrollment or a `sudo` that the user starts. Point the helper to another key. Use an old signature again. |
| A person with the locked phone | See a request on the lock screen, and deny it | Approve a request without the fingerprint |
| A person with the unlocked phone | Deny requests. Remove Flux. | Approve a request without the fingerprint |

The helper runs as root for `sudo`. It reads only the key file, the socket,
`/etc/passwd`, and its PAM variables. It limits each line from `fluxd` to
64 KiB, and it parses the lines with the Go JSON decoder, so the data from
the user process cannot corrupt its memory. It does not read any file of
the user.

For a lock screen, the helper runs as the user. Code that runs as the user
can already end the lock screen, so the approval protects only against a
person at the keyboard. The password protects against the same person.

## Open risks

- **Approval fatigue.** Code that runs as the user can start `sudo` and
  wait. The phone then shows a real request. If the user approves it
  without thought, that code gets root. The phone shows the service, the
  user, the host, the TTY, and the time. Approve a request only right
  after you typed the command. Code that runs as the user can also get the
  password in other ways, for example with a shell alias for `sudo`.
- **No key attestation.** The computer trusts that the phone made the key
  with the settings above. Android key attestation can prove it, but Flux
  does not check it yet. The computer also cannot check the settings of a
  Secure Enclave key. Apple App Attest is a different mechanism, and Flux
  does not use it. So a changed app on any device can enroll a key without
  these settings.
- **A substituted request.** A changed `fluxd` sees a real request of the
  user. It can start its own `sudo` in the same second and send that
  request to the phone in its place. The phone then shows the same
  service, user, host, and time. Only the terminal differs, so the helper
  prints the terminal of the request. The advice to approve right after you
  typed the command does not find this substitution.
- **Requests from other users.** The helper refuses a request that another
  user makes for the user. polkit gives no PAM item for the user that asks.
  So `polkit-1` works only with a setuid `polkit-agent-helper-1`. polkit 126
  and later on Arch Linux run the agent helper as a system service that
  cannot reach the socket of `fluxd`, and approvals for `polkit-1` do not
  work there.
- **Enrollment depends on the phone screen.** The user must type the code
  from the phone. If the user types a code from another source, a changed
  `fluxd` can enroll its own key.
- **Enrollment trusts the session.** Code that runs as the user can type
  the key code of its own key into the terminal of the enrollment. It can
  use a virtual keyboard, such as `wtype`, or the remote control of the
  terminal. The command cannot tell these keys from the keys of the user.
  The typed code stops only a changed `fluxd` that cannot send keys. Run
  `sudo flux-cli approve enroll` only in a session that you trust.
- **Only local users.** The helper finds the user in `/etc/passwd`. Users
  from a network directory do not work.
