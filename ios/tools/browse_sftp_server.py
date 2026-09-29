#!/usr/bin/env python3
"""Read-only asyncssh SFTP server for the Flux D1 loopback E2E.

`test_peer.py --browse-ssh` spawns one of these per run: password auth
(`--user`/`--password`, the offer's one-time password), jailed to `--root`,
ed25519 host key generated fresh per run (fluxd `browseConfig` parity:
a new host key per session, so the client must accept any key).

Instrumentation (asserted by test_peer.py, never secrets):
    AUTH user=<name> ok     password accepted
    SFTP LIST <path> <n> entries: <names>
    SFTP OPEN <path> flags=<hex>
    SFTP READ <n> bytes @ <offset>

Requires: python3, asyncssh (`pip3 install asyncssh`).
"""

import argparse
import asyncio
import inspect
import os
import sys

import asyncssh

ROOT = ""


async def _maybe_await(value):
    # asyncssh handlers return either a plain value or an awaitable.
    if inspect.isawaitable(value):
        return await value
    return value


class Handler(asyncssh.SSHServer):
    def __init__(self, user, password):
        self.user = user
        self.password = password

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        ok = username == self.user and password == self.password
        if ok:
            print(f"AUTH user={username} ok", flush=True)
        return ok


class LoggingSFTP(asyncssh.SFTPServer):
    def map_path(self, path):
        # Absolute paths under ROOT pass through (the offer carries real
        # fixture paths); everything else is jailed under ROOT. asyncssh
        # stats `.`/`..` while listing, so an escape clamps to ROOT instead
        # of failing (the phone filters dotfiles, so `..` is never shown
        # or opened — and file content can only ever come from under ROOT).
        raw = os.fsdecode(path)
        if os.path.isabs(raw):
            p = os.path.abspath(raw)
        else:
            p = os.path.abspath(os.path.join(ROOT, raw.lstrip("/")))
        if p != ROOT and not p.startswith(ROOT + os.sep):
            print(f"SFTP MAPPATH {raw!r} -> {p!r} CLAMPED to ROOT", flush=True)
            return ROOT
        return p

    async def realpath(self, path):
        # super() may return plain bytes (not awaitable) for valid paths.
        result = await _maybe_await(super().realpath(path))
        print(f"SFTP REALPATH {os.fsdecode(path)!r} -> {os.fsdecode(result)!r}", flush=True)
        return result

    async def scandir(self, path):
        names = [n async for n in super().scandir(path)]

        def show(v):
            return os.fsdecode(v) if isinstance(v, bytes) else str(v)

        print(f"SFTP LIST {show(path)!r} {len(names)} entries: "
              f"{','.join(sorted(show(n.filename) for n in names))}", flush=True)
        for n in names:
            yield n

    async def open(self, path, pflags, attrs):
        print(f"SFTP OPEN {os.fsdecode(path)!r} flags={pflags:#x}", flush=True)
        return await _maybe_await(super().open(path, pflags, attrs))

    async def read(self, handle, offset, size):
        data = await _maybe_await(super().read(handle, offset, size))
        print(f"SFTP READ {len(data)} bytes @ {offset}", flush=True)
        return data


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--user", default="kdeconnect")
    ap.add_argument("--password", required=True)
    ap.add_argument("--port-file", required=True,
                    help="write the bound port here for the parent")
    args = ap.parse_args()

    global ROOT
    ROOT = os.path.abspath(args.root)

    key = asyncssh.generate_private_key("ssh-ed25519")

    def make_server():
        return Handler(args.user, args.password)

    server = await asyncssh.create_server(
        make_server,
        "127.0.0.1",
        0,
        server_host_keys=[key],
        sftp_factory=LoggingSFTP,
    )
    port = server.get_port()
    assert port is not None
    with open(args.port_file, "w") as f:
        f.write(str(port))
    print(f"browse-sftp: serving {ROOT} for user {args.user}", flush=True)
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (asyncssh.Error, OSError) as exc:
        print(f"browse-sftp: {exc}", flush=True)
        sys.exit(1)
