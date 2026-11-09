# SSH key on the phone

[Documentation index](README.md)

Flux for Android can keep an SSH key in the secure hardware of the phone.
`fluxd` offers the key to the computer through an ssh-agent socket.
Use it to log in with `ssh`, to push with Git over SSH, and to sign Git commits and tags.
Each signature needs your fingerprint or your screen lock on the phone.
The private key never leaves the phone.

Only Flux for Android has the SSH key.
Flux for iOS, Flux for macOS, and Flux for Windows do not have it.

## Requirements

- Flux for Android and `fluxd` of the same release, or a later release.
- A screen lock on the phone: a PIN, a pattern, or a password.
- Android 11 or later for a signature with the screen lock. On Android 10, only a strong biometric, such as a fingerprint, can sign.
- A connected phone. The agent lists the key only while the phone is connected.

## Turn on the key

1. On the phone, open Flux.
2. Open **Computers**, then **SSH key**.
3. Turn on **SSH key**. The phone makes the key, and shows the public key and its fingerprint.
4. On the computer, show the key:

   ```sh
   flux-cli ssh
   ```

5. Compare the fingerprint in the output with the fingerprint on the phone.

The output has the name of each phone with a key, its fingerprint, the line for `authorized_keys`, and the agent socket:

```text
Pixel 8 · SHA256:uk2DU7O00GnwbbL4vBzKRyuHlZ/ZfhHpgGM7thsHUig
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBNH71... Flux on Pixel 8

export SSH_AUTH_SOCK=/run/user/1000/flux/ssh-agent.sock
```

The key is 1 EC P-256 key, `ecdsa-sha2-nistp256`, for all paired computers.
**Copy the public key** on the phone puts the same line on the clipboard of the phone.

When no connected phone has a key, `flux-cli ssh` prints the socket and stops with an error.

| Command | Output |
| --- | --- |
| `flux-cli ssh` | The keys, the fingerprints, and an `export SSH_AUTH_SOCK=` line |
| `flux-cli ssh key` | Only the `authorized_keys` lines |
| `flux-cli ssh socket` | Only the socket path |
| `flux-cli ssh --json` | The socket, and each key with its device ID, name, line, and fingerprint |

With more than 1 phone, add `--device NAME` to select 1 phone:

```sh
flux-cli --device "Pixel 8" ssh key
```

## Log in with SSH

1. Add the public key to the server, or to the SSH keys of your Git host.
   To add it to a server where you can log in with another key, run:

   ```sh
   flux-cli ssh key | ssh user@server 'cat >> ~/.ssh/authorized_keys'
   ```

2. Tell `ssh` to use the Flux agent for the host. Add a block to `~/.ssh/config`:

   ```text
   Host github.com
       IdentityAgent ${XDG_RUNTIME_DIR}/flux/ssh-agent.sock
   ```

3. Log in:

   ```sh
   ssh -T git@github.com
   ```

4. Approve the request on the phone.

To use the Flux agent for all hosts in 1 shell, set `SSH_AUTH_SOCK` instead:

```sh
export SSH_AUTH_SOCK="$(flux-cli ssh socket)"
```

`ssh` offers each key of the agent to each server.
A server counts each key that it refuses as 1 try, and it closes the connection after `MaxAuthTries`.
To offer only the phone key to a host, put the public key in a file and name it in the host block:

```sh
flux-cli ssh key > ~/.ssh/flux-phone.pub
```

```text
Host github.com
    IdentityAgent ${XDG_RUNTIME_DIR}/flux/ssh-agent.sock
    IdentityFile ~/.ssh/flux-phone.pub
    IdentitiesOnly yes
```

`ssh` then asks the agent for the private key of that public key.

## Sign Git commits and tags

Git signs with `ssh-keygen -Y sign`, and `ssh-keygen` gets the signature from the agent in `SSH_AUTH_SOCK`.

1. Set the signature format and the key. The `key::` form gives Git the public key itself:

   ```sh
   git config --global gpg.format ssh
   git config --global user.signingkey "key::$(flux-cli ssh key)"
   ```

2. Optional: sign each commit:

   ```sh
   git config --global commit.gpgsign true
   ```

3. Set `SSH_AUTH_SOCK` in the shell that runs Git:

   ```sh
   export SSH_AUTH_SOCK="$(flux-cli ssh socket)"
   ```

4. Commit, and approve on the phone:

   ```sh
   git commit -S -m "Add the parser"
   ```

To set `SSH_AUTH_SOCK` for 1 command only, put it before the command:

```sh
SSH_AUTH_SOCK="$(flux-cli ssh socket)" git commit -S -m "Add the parser"
```

To check signatures, Git needs a file of the allowed signers:

```sh
echo "you@example.com $(flux-cli ssh key)" >> ~/.config/git/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
git log --show-signature -1
```

To sign a file, use the namespace `file`. The command writes `report.pdf.sig`:

```sh
SSH_AUTH_SOCK="$(flux-cli ssh socket)" ssh-keygen -Y sign -n file -f ~/.ssh/flux-phone.pub report.pdf
```

## What the phone shows

A request opens the SSH key screen on the phone, also over the lock screen.
When Flux is not on the screen, a notification opens it.
The screen shows these items:

- What the request does: **Log in as** and the user, **Sign a Git commit or tag**, **Sign a file**, or **Sign in the namespace** and the namespace. The phone reads this from the data that it signs.
- The name of the computer.
- The command line of the program that asks, for example `ssh git@github.com` or `ssh-keygen -Y sign -n git -f /tmp/.git_signing_key_tmpAbC123 -U /tmp/.git_signing_buffer_tmpXyZ789`.

**Approve** asks for the fingerprint, a strong face unlock, or the screen lock. Then the phone signs and sends the signature.
**Deny** refuses the request, also from the notification.
The request closes after 30 seconds.

Approve a request only right after you started the program yourself.

## How the agent works

`fluxd` serves the ssh-agent protocol on `$XDG_RUNTIME_DIR/flux/ssh-agent.sock`.
Without `XDG_RUNTIME_DIR`, the socket is `/run/user/<uid>/flux/ssh-agent.sock`.
The socket has mode 0600, in the runtime folder of Flux with mode 0700.
`fluxd` accepts a connection only from a process of the same user or of root.
It reads the process ID with `SO_PEERCRED` and the command line from `/proc/<pid>/cmdline`.

| Operation | Result |
| --- | --- |
| List the keys | The key of each paired, connected phone that has SSH key on. The comment is `Flux on <phone>`. |
| Sign | `fluxd` sends the request to the phone of the key and waits at most 30 seconds |
| Add, remove, remove all, lock, unlock | Refused |
| Extensions, such as `session-bind@openssh.com` | Refused. `ssh` works without them. |

`fluxd` sends a sign request to the phone only when the data is 1 of 2 kinds:

- An SSH login request, as RFC 4252 section 7 defines it, with the key of the phone. The method is `publickey`, or `publickey-hostbound-v00@openssh.com` of OpenSSH 8.9 and later.
- The signed data of an SSH signature, as `ssh-keygen -Y sign` makes it. It starts with `SSHSIG` and has a namespace.

`fluxd` refuses all other data at once, so the key cannot sign a message of another protocol.
The phone makes the same check.

A phone takes 1 sign request at a time.
A second request waits for its turn, within its own 30 seconds.

`fluxd` checks each signature with the key of the phone before the client gets it.
The phone signs with `SHA256withECDSA` and sends the ASN.1 DER signature.
`fluxd` sends it to the client as an `ecdsa-sha2-nistp256` signature in the SSH format, with r and s as mpints.

### Failures

The ssh-agent protocol has no error text.
So `ssh` and `ssh-keygen` print only `agent refused operation` or `signing failed`.
`fluxd` writes the reason to its log, and shows it in a desktop notification:

```sh
journalctl --user -u fluxd | grep 'ssh agent'
```

| Condition | Result |
| --- | --- |
| No phone is connected, or SSH key is off | The agent lists no key, and a sign request fails at once. `ssh-keygen` prints `No private key found for public key`. |
| The phone has another key | The phone refuses the request |
| The data is not a login and not an SSH signature | `fluxd` refuses it at once, and the phone does not see it |
| You deny on the phone | The request fails |
| No answer in 30 seconds | The request fails, and `fluxd` closes it on the phone |
| The program stops, for example after Ctrl+C | `fluxd` closes the request on the phone |
| The link to the phone closes | The request fails within 1 second |
| The phone has no screen lock | The phone sends an error |
| The screen lock of the phone goes away | Android makes the key invalid. The phone deletes it. Turn on SSH key again, and add the new public key to your servers. |

## Turn off the key

1. On the phone, open **Computers**, then **SSH key**.
2. Turn off **SSH key**.
3. Confirm **Delete key**.

Android deletes the private key, and nobody can get it back.
Remove the public key from your servers and your Git hosts.
A new key has a new public key.

When you unpair a computer, it can no longer ask the phone to sign.
The key stays on the phone for the other computers.

If you lose the phone, remove its public key from each server and Git host.
Keep another way to log in to your servers, because no backup of the key exists.

## Wire format

The phone and `fluxd` use the `flux.ssh` packet on their link.

| `kind` | From | Fields |
| --- | --- | --- |
| `key` | `fluxd` | None. It asks for the key at the start of each link. |
| `key` | Phone | `publicKey`: the key as a SubjectPublicKeyInfo in DER, in base64. No `publicKey` means no key. The phone also sends it when the key changes. |
| `sign` | `fluxd` | `id`, `key` as the phone sent it, `data` in base64, `program`, and `timeout` in seconds |
| `signed` | Phone | `id`, and 1 of these: `signature`, the ASN.1 DER signature in base64, `denied: true`, or `error` with a reason |
| `cancel` | `fluxd` | `id` |

`ssh.keys` on the [IPC socket](ipc.md) returns the socket path and the keys.

## Security

The [security page](security.md#ssh-key-on-the-phone) lists what a paired device can do with the key.

- The private key is in the Android Keystore, in StrongBox when the phone has it. The key screen tells where Android keeps it.
- Each signature needs a new check of a strong biometric or of the screen lock. The phone signs through `BiometricPrompt` with a `CryptoObject` that holds the `Signature` object. So 1 check signs 1 request.
- Unlike [fingerprint approval](approve.md), the screen lock can sign. A person who knows the screen lock of the phone can approve a request.
- A new fingerprint does not make the key invalid, because the screen lock can sign anyway.
- The phone reads the action from the data that it signs. The program name comes from `fluxd`, and a program can choose its own command line. So the program name is only a hint.
- A login request does not name the server. The host-bound form names only the host key of the server. So a program that runs as your user can ask for a login to another server than you expect. Approve only right after you started the command.
- Code that runs as your user can connect to the socket and ask for signatures. It can also replace `fluxd`. It cannot sign without your approval on the phone, and it cannot read the private key.
- Each paired computer can send sign requests. Unpair a computer that you do not trust.
- With agent forwarding, `ssh -A`, the remote host can ask for signatures. Each request still needs your approval. The phone then shows the local `ssh` command, not the remote program. Do not forward the agent to a host that you do not trust.
- The computer does not check Android key attestation. It trusts that the phone made the key in the Keystore.

## Limits

- Flux for Android only.
- 1 key for each phone, `ecdsa-sha2-nistp256`. Android has no Ed25519 key in StrongBox.
- The agent lists the key only while the phone is connected.
- The agent has no key constraints, such as `ssh-add -c` or a lifetime.
- The request shows as a screen and a notification. It does not show in **Chats**.
