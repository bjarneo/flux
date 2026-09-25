# Approve with fingerprint: security design

Flux can approve `sudo`, polkit, and a lock screen with a fingerprint on
the paired phone. The phone signs each request with a private key that
never leaves its secure hardware. A small helper on the computer checks
the signature with a public key that only root can change. If anything
fails, PAM asks for the password as usual.

This document is the design. The code must follow it. Read it before you
change `internal/approve`, `cmd/flux-approve`, `internal/core/approve.go`,
or the approve code in Flux for Android.

## Parts

| Part | Runs as | Job |
| --- | --- | --- |
| `flux-approve` | The PAM caller, root for `sudo` and polkit | Makes the request, checks the signature, and gives the PAM result |
| `/etc/flux/approve/<user>.pub` | A file owned by root | The trust anchor: the public key of the phone |
| `fluxd` | The user | Carries the messages between the helper and the phone |
| Flux for Android | The phone user | Shows the request, asks for the fingerprint, and signs |
| `flux approve enroll` | root, through `sudo` | Gets the public key from the phone and writes the key file |

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
`flux approve enroll`, which runs as root, writes it. The helper uses the
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

## Keys on the phone

- Flux for Android makes 1 key for each paired computer, in the Android
  Keystore. The alias is `flux-approve-<computer device ID>`.
- The key is EC P-256, for signing with SHA-256 only.
- The key needs user authentication for each use, with a strong
  biometric and no time window. On Android 11 and later, this is
  `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`. On Android
  10, it is a validity of -1 seconds, which also means each use.
- A new fingerprint in the phone settings makes the key invalid. The user
  then enrolls again.
- The phone uses StrongBox when the phone has it.
- The phone signs only through `BiometricPrompt` with a `CryptoObject`
  that holds the `Signature` object. So a signature is not possible
  without a fingerprint, even for code that runs in the Flux app.

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

An enrollment message has 7 lines:

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

The first line names the version and the purpose. So a signature for an
enrollment is never a valid approval, and the reverse.

## Approval flow

1. PAM starts `flux-approve` through `pam_exec`. The helper reads
   `PAM_USER`, `PAM_SERVICE`, `PAM_TTY`, and `PAM_RHOST`.
2. The helper refuses the `sshd` service, and the user names that are not
   valid local user names.
3. The helper reads and checks the key file. With no key file, it stops at
   once.
4. The helper makes a 32-byte nonce with `crypto/rand` and takes the time.
5. The helper connects to `/run/user/<uid>/flux/fluxd.sock`. It checks with
   `SO_PEERCRED` that the process at the other end runs as the same user.
   Without `fluxd`, it stops at once.
6. The helper calls `approve.request`. `fluxd` sends a `flux.approve`
   request to the phone in the key file. If the phone is not connected,
   `fluxd` returns an error, and the helper stops at once.
7. The helper prints 1 line: `Approve on <phone>, or wait for the password
   prompt.`
8. The phone shows `Approve sudo for user <user> on host <host>?` with the
   TTY, the remote host, and the time. It shows Approve and Deny.
9. Approve opens `BiometricPrompt`. After the fingerprint, the phone signs
   the approval message and sends it. Deny sends a denial.
10. The helper calls `approve.wait` until it gets a result or its time
    ends.
11. The helper builds the approval message again from its own fields. It
    does not use any field that `fluxd` or the phone sends back. It checks
    the signature with the key from the key file, and it checks the time.
12. The helper exits with 0 only when the signature is valid. Any other
    result is a non-zero exit, and PAM goes on to the password.

## Enrollment flow

1. The user runs `sudo flux approve enroll`. The command runs as root and
   takes the user from `SUDO_USER`.
2. The command connects to the socket of that user and checks the peer
   with `SO_PEERCRED`.
3. The command makes a nonce and calls `approve.enroll`. `fluxd` sends the
   enrollment request to the phone.
4. The phone shows `Use this phone to approve sudo for user <user> on host
   <host>?`. Approve makes a new key and opens `BiometricPrompt`.
5. After the fingerprint, the phone signs the enrollment message and sends
   the public key and the signature. The phone shows the key code, which
   is the first 8 bytes of the SHA-256 of the public key, in 4 groups.
6. The command checks the signature with the new public key. This proves
   that the phone has the private key and that the key works with the
   fingerprint.
7. The command shows the same key code and asks the user to compare it with
   the phone. The user must type `y`.
8. The command writes the key file. It writes a temporary file in the same
   folder, sets the mode to 0644 and the owner to root, syncs it, and
   renames it.

The comparison of the key codes in step 7 is the protection against a
changed `fluxd`. A changed `fluxd` can send its own key, but it cannot make
the phone show the code of that key.

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

## Timeouts

| Step | Limit |
| --- | --- |
| Connect to `fluxd` | 2 seconds |
| `approve.request` | 3 seconds |
| The wait for the phone | `approve_timeout` in `config.toml`, 20 seconds by default, from 5 to 120 seconds |
| The whole helper | 130 seconds at most, whatever `fluxd` says |
| The request on the phone | The wait time, then the phone closes it |

At the end of the wait, `fluxd` sends a cancel to the phone, and the
helper exits with a failure. PAM then asks for the password.

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

## What an attacker can do

| Attacker | Can | Cannot |
| --- | --- | --- |
| Network | Block or delay the link, so that PAM asks for the password | Read or change the messages, because the link uses TLS with pinned certificates. Make a valid signature. |
| Code that runs as the user | Stop the approval, so that PAM asks for the password. Send requests to the phone. Start `sudo` and wait for the user to approve it. | Make a valid signature. Change the key file. Point the helper to another key. Use an old signature again. |
| A person with the locked phone | See a request on the lock screen, and deny it | Approve a request without the fingerprint |
| A person with the unlocked phone | Deny requests. Remove Flux. | Approve a request without the fingerprint |

The helper runs as root for `sudo`. It reads only the key file, the socket,
and its PAM variables. It limits each line from `fluxd` to 64 KiB, and it
parses the lines with the Go JSON decoder, so the data from the user
process cannot corrupt its memory. It does not read any file of the user.

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
  does not check it yet.
- **Enrollment depends on the user.** If the user does not compare the key
  codes, a changed `fluxd` can enroll its own key.
- **Only local users.** The helper finds the user in `/etc/passwd`. Users
  from a network directory do not work.
