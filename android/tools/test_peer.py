#!/usr/bin/env python3
"""A minimal Flux desktop peer for testing the Flux Android app.

The peer reaches the phone through `adb forward`, so no firewall rule is
needed on the computer. It opens TCP to the app, sends a plain-text
identity, runs TLS as the server, exchanges the protocol 8 identity, and
then sends a pairing request. After the user accepts on the phone, it sends
sample battery, command, media, and remote input packets and answers
requests. It prints the packets that the phone sends. With --theme, it also
sends an Omarchy theme from a colors.toml file, like fluxd.

Run it with a debug build installed and USB debugging on:

    python3 tools/test_peer.py

With --desktop, the peer streams a monitor of this computer to the Remote
desktop screen of the phone, like fluxd, and prints the touches. It also
answers the Omarchy panel with sample shortcuts and workspaces, and prints
the actions. It does not run them.

Requires: python3, openssl, adb. --desktop also requires gpu-screen-recorder.
"""

import argparse
import hashlib
import json
import os
import queue
import re
import select
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import uuid

PACKAGE = "org.omarchy.flux"
FORWARD_PORT = 18716
# The phone listens for links on the first free TCP port from 12100 to 12108.
PHONE_LINK_PORT = 12100


def sh(*args, data=None):
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


def packet(kind, body, **extra):
    p = {"id": int(time.time() * 1000), "type": kind, "body": body}
    p.update(extra)
    return (json.dumps(p) + "\n").encode()


def spki(der_cert):
    pem = sh("openssl", "x509", "-inform", "DER", "-pubkey", "-noout", data=der_cert)
    return sh("openssl", "pkey", "-pubin", "-outform", "DER", data=pem)


def verification_key(a, b, ts):
    """Returns the 16-digit key in 4 groups of 4, as the phone shows it."""
    if a < b:
        a, b = b, a
    key = hashlib.sha256(a + b + str(ts).encode()).hexdigest()[:16].upper()
    return " ".join(key[i:i + 4] for i in range(0, 16, 4))


def flv_frames(stream, width, height):
    """Yields the frames of the remote desktop stream from the FLV of
    gpu-screen-recorder, like pumpDesktop in fluxd: the video size first,
    then the SPS and PPS, then each frame in Annex-B form."""
    def read(n):
        b = stream.read(n)
        if len(b) < n:
            raise EOFError
        return b

    start = b"\x00\x00\x00\x01"
    try:
        header = read(9)
        assert header[:3] == b"FLV", header
        read(struct.unpack(">I", header[5:9])[0] - 9 + 4)
        yield 4, struct.pack(">HH", width, height)
        length_size = 4
        while True:
            tag = read(11)
            data = read(int.from_bytes(tag[1:4], "big"))
            read(4)
            if tag[0] != 9 or len(data) < 5 or data[0] & 0x0F != 7:
                continue
            if data[1] == 0:
                rec = data[5:]
                length_size = (rec[4] & 3) + 1
                out, rest = b"", rec[5:]
                for i in range(2):
                    n = rest[0] & (0x1F if i == 0 else 0xFF)
                    rest = rest[1:]
                    for _ in range(n):
                        size = struct.unpack(">H", rest[:2])[0]
                        out += start + rest[2:2 + size]
                        rest = rest[2 + size:]
                yield 1, out
            elif data[1] == 1:
                out, rest = b"", data[5:]
                while rest:
                    size = int.from_bytes(rest[:length_size], "big")
                    out += start + rest[length_size:length_size + size]
                    rest = rest[length_size + size:]
                if out:
                    yield (2 if data[0] >> 4 == 1 else 0), out
    except EOFError:
        return


def theme_body(path):
    """Reads an Omarchy colors.toml file into the body of a flux.theme packet."""
    body = {"name": os.path.basename(os.path.dirname(os.path.abspath(path))), "colors": {}}
    with open(path) as f:
        for line in f:
            m = re.match(r'\s*([a-z_]+)\s*=\s*"([^"]*)"', line)
            if not m:
                continue
            key, value = m.groups()
            if key == "mode":
                body["mode"] = value
            elif key == "hyprland_active_border":
                stops = re.findall(r"(?:rgba?\(|#)([0-9a-fA-F]{6,8})", value)
                angle = re.search(r"(-?\d+)deg", value)
                body["border"] = {"colors": ["#" + s.lower().ljust(8, "f") for s in stops]}
                if angle:
                    body["border"]["angle"] = int(angle.group(1))
            elif re.fullmatch(r"#[0-9a-fA-F]{6}", value):
                body["colors"][key] = value.lower()
    return body


def make_identity(dev_id, target=None, name="flux-test-peer", desktop=False):
    body = {
        "deviceId": dev_id,
        "deviceName": name,
        "deviceType": "laptop",
        "protocolVersion": 8,
        "incomingCapabilities": [
            "flux.ping", "flux.battery", "flux.clipboard", "flux.clipboard.connect",
            "flux.share.request", "flux.notification", "flux.runcommand.request",
            "flux.mpris.request", "flux.sftp.request", "flux.tunnel",
            "flux.clipboard.image",
            "flux.mousepad.request",
        ] + (["flux.desktop", "flux.shortcuts"] if desktop else []),
        "outgoingCapabilities": [
            "flux.ping", "flux.battery", "flux.clipboard", "flux.share.request",
            "flux.notification.request", "flux.findmyphone.request", "flux.runcommand",
            "flux.mpris", "flux.sftp", "flux.clipboard.image", "flux.input",
        ] + (["flux.desktop", "flux.shortcuts"] if desktop else []),
    }
    if target:
        body["targetDeviceId"] = target
        body["targetProtocolVersion"] = 8
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL", ""))
    ap.add_argument("--seconds", type=int, default=600, help="how long to answer requests after pairing")
    ap.add_argument("--send-file", help="send this file to the phone after pairing")
    ap.add_argument("--clipboard-image", help="put this PNG image on the clipboard of the phone after pairing")
    ap.add_argument("--sftp-port", type=int, help="answer Browse PC through a tunnel to an SFTP server on 127.0.0.1:<port>")
    ap.add_argument("--sftp-root", default="/", help="the folder that the SFTP server serves")
    ap.add_argument("--sftp-password", default="flux-test")
    ap.add_argument("--wait-for-pair", action="store_true", help="let the phone start the pairing")
    ap.add_argument("--name", default="flux-test-peer")
    ap.add_argument("--desktop", nargs="?", const="", metavar="MONITOR",
                    help="stream a monitor of this computer to Remote desktop, the first monitor by default")
    ap.add_argument("--theme", metavar="COLORS_TOML", help="send the Omarchy theme in this colors.toml file after pairing")
    ap.add_argument("--state", default=os.path.expanduser("~/.cache/flux-test-peer"),
                    help="keeps the peer certificate and pairing between runs")
    args = ap.parse_args()
    adb = ["adb"] + (["-s", args.serial] if args.serial else [])

    work = args.state
    os.makedirs(work, exist_ok=True)
    key, cert = os.path.join(work, "key.pem"), os.path.join(work, "cert.pem")
    id_file, paired_file = os.path.join(work, "id"), os.path.join(work, "paired")
    if not os.path.exists(cert):
        with open(id_file, "w") as f:
            f.write(uuid.uuid4().hex)
        sh("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
           "-keyout", key, "-out", cert, "-days", "3650", "-subj", f"/O=Omarchy/OU=Flux/CN={open(id_file).read()}")
    dev_id = open(id_file).read().strip()
    own_der = sh("openssl", "x509", "-in", cert, "-outform", "DER")

    phone_der = sh(*adb, "exec-out", "run-as", PACKAGE, "cat", "files/identity/certificate.der")
    phone_pem = sh("openssl", "x509", "-inform", "DER", data=phone_der).decode()
    phone_id = sh("openssl", "x509", "-noout", "-subject", "-nameopt", "multiline", data=phone_pem.encode()).decode()
    phone_id = [l.split("=", 1)[1].strip() for l in phone_id.splitlines() if "commonName" in l][0]
    print(f"phone device ID {phone_id}")

    sh(*adb, "forward", f"tcp:{FORWARD_PORT}", f"tcp:{PHONE_LINK_PORT}")
    raw = socket.create_connection(("127.0.0.1", FORWARD_PORT), timeout=10)
    desktop = args.desktop is not None
    raw.sendall(packet("flux.identity", make_identity(dev_id, target=phone_id, name=args.name, desktop=desktop)))

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(cadata=phone_pem)
    ctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    tls = ctx.wrap_socket(raw, server_side=True)
    print(f"TLS {tls.version()} {tls.cipher()[0]}")
    peer = tls.getpeercert(binary_form=True)
    assert peer == phone_der, "phone presented a different certificate"

    tls.sendall(packet("flux.identity", make_identity(dev_id, name=args.name, desktop=desktop)))
    reader = tls.makefile("rb")
    ident = json.loads(reader.readline())
    assert ident["type"] == "flux.identity", ident
    b = ident["body"]
    assert b["deviceId"] == phone_id and b["protocolVersion"] == 8, b
    assert "tcpPort" not in b, "post-TLS identity must not carry tcpPort"
    print(f"identity after TLS OK: {b['deviceName']} ({b['deviceType']})")
    tls.settimeout(None)

    already = os.path.exists(paired_file) and open(paired_file).read().strip() == phone_id
    if not already and not args.wait_for_pair:
        ts = int(time.time())
        expected = verification_key(spki(own_der), spki(phone_der), ts)
        tls.sendall(packet("flux.pair", {"pair": True, "timestamp": ts}))
        print(f"pair request sent. The phone must show {expected}")

    lock = threading.Lock()

    def send(kind, body, **extra):
        with lock:
            tls.sendall(packet(kind, body, **extra))

    paired = threading.Event()
    commands = {"lock": {"name": "Lock screen", "command": "omarchy-system-lock"},
                "suspend": {"name": "Suspend", "command": "systemctl suspend"},
                "bg": {"name": "Next background", "command": "omarchy-theme-bg-next"},
                "shot": {"name": "Screenshot", "command": "omarchy-capture-screenshot fullscreen save"},
                "bar": {"name": "Toggle bar", "command": "omarchy-toggle-bar"},
                "mute": {"name": "Mute audio", "command": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"}}
    playing = {"v": True}
    volume = {"v": 60}

    def now_playing():
        return {"player": "spotify", "title": "Weightless", "artist": "Marconi Union", "album": "Weightless",
                "isPlaying": playing["v"], "pos": 192000, "length": 489000, "canSeek": True,
                "canPlay": True, "canPause": True, "canGoNext": True, "canGoPrevious": True, "volume": volume["v"]}

    def after_pair():
        send("flux.battery", {"currentCharge": 64, "isCharging": False, "thresholdEvent": 0})
        send("flux.runcommand", {"commandList": json.dumps(commands), "canAddCommand": True})
        send("flux.mpris", {"playerList": ["spotify"], "supportAlbumArtPayload": False})
        # The touchpad screen works. The peer prints the input that it gets.
        send("flux.input", {"enabled": True, "desktop": desktop, "keyRepeat": True})
        if args.theme:
            send("flux.theme", theme_body(args.theme))
        if args.send_file:
            send_file(args.send_file)
        if args.clipboard_image:
            send_file(args.clipboard_image, "flux.clipboard.image", {"mime": "image/png"})

    def phone_client(sock):
        """Runs TLS as the client on a connection to a listener of the
        phone. The phone must present its certificate."""
        cctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        cctx.check_hostname = False
        cctx.maximum_version = ssl.TLSVersion.TLSv1_2
        cctx.load_cert_chain(cert, key)
        cctx.verify_mode = ssl.CERT_REQUIRED
        cctx.load_verify_locations(cadata=phone_pem)
        cctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        return cctx.wrap_socket(sock)

    # The flux.tunnel answers of the phone, by token. The read loop fills them.
    tunnels = {}

    def new_tunnel():
        """Returns a token for a tunnel and registers it, like NewTunnelID in fluxd."""
        token = uuid.uuid4().hex[:24]
        tunnels[token] = queue.Queue()
        return token

    def open_tunnel(token):
        """Waits for the port of the tunnel, forwards a free local port to it,
        and connects as the TLS client, like OpenTunnel in fluxd. It returns
        the TLS socket and the local port. Remove the forward after use."""
        try:
            reply = tunnels[token].get(timeout=30)
        except queue.Empty:
            raise OSError("the phone did not open a tunnel within 30 seconds") from None
        finally:
            tunnels.pop(token, None)
        if "error" in reply:
            raise OSError(f"the phone could not open a tunnel: {reply['error']}")
        with socket.socket() as free:
            free.bind(("127.0.0.1", 0))
            local = free.getsockname()[1]
        sh(*adb, "forward", f"tcp:{local}", f"tcp:{reply['port']}")
        try:
            conn = phone_client(socket.create_connection(("127.0.0.1", local), timeout=10))
        except OSError:
            sh(*adb, "forward", "--remove", f"tcp:{local}")
            raise
        conn.settimeout(None)
        return conn, local

    def send_file(path, kind="flux.share.request", body=None):
        """Sends a file through a tunnel, like pushPayload in fluxd."""
        data = open(path, "rb").read()
        if body is None:
            body = {"filename": os.path.basename(path), "open": False}
        token = new_tunnel()
        send(kind, body, payloadSize=len(data), payloadTransferInfo={"tunnel": token})
        try:
            conn, local = open_tunnel(token)
        except OSError as e:
            print(f"cannot send {path}: {e}")
            return
        try:
            conn.sendall(data)
            conn.close()
        finally:
            sh(*adb, "forward", "--remove", f"tcp:{local}")
        print(f"sent {path} ({len(data)} bytes)")

    def serve_sftp(token):
        """Relays the Browse PC session between the tunnel and the SFTP
        server on 127.0.0.1:<sftp-port>. fluxd runs its SSH server in the
        tunnel instead."""
        try:
            conn, local = open_tunnel(token)
        except OSError as e:
            print(f"Browse PC tunnel: {e}")
            return
        try:
            with socket.create_connection(("127.0.0.1", args.sftp_port), timeout=10) as server:
                server.settimeout(None)
                while True:
                    # TLS can keep decrypted bytes that select does not see.
                    ready = [conn] if conn.pending() else select.select([conn, server], [], [])[0]
                    for src in ready:
                        data = src.recv(65536)
                        if not data:
                            return
                        (server if src is conn else conn).sendall(data)
        except OSError as e:
            print(f"Browse PC relay closed: {e}")
        finally:
            conn.close()
            sh(*adb, "forward", "--remove", f"tcp:{local}")
            print("Browse PC session ended")

    recorder = {"proc": None, "stopped": False}

    # Sample Omarchy shortcuts and workspaces for the Omarchy panel.
    shortcuts = [{"ref": str(300 + i), "keys": k, "description": d} for i, (k, d) in enumerate([
        ("SUPER SPACE", "Omarchy menu"), ("SUPER ALT SPACE", "Apps menu"), ("SUPER RETURN", "Terminal"),
        ("SUPER SHIFT RETURN", "Browser"), ("SUPER SHIFT F", "File manager"), ("PRINT", "Screenshot"),
        ("SUPER W", "Close window"), ("SUPER K", "Keybindings"), ("SUPER CTRL L", "Lock system"),
        ("SUPER SHIFT M", "Music"), ("SUPER ESCAPE", "System menu"), ("SUPER CTRL E", "Emojis"),
    ])]
    spaces = {"active": 1, "windows": {1: 2, 2: 1, 4: 3}}

    def shortcut_state(with_list):
        body = {"workspaces": [{"id": i, "windows": n} for i, n in sorted(spaces["windows"].items())],
                "active": spaces["active"]}
        if with_list:
            body["shortcuts"] = shortcuts
        return body

    def stream_desktop(body):
        """Connects to the listener of the phone and streams a monitor, like
        runDesktop in fluxd."""
        port = body["port"]
        monitors = [l.split("|") for l in sh("gpu-screen-recorder", "--list-monitors").decode().split() if "|" in l]
        name, size = next((m for m in monitors if m[0] == (body.get("monitor") or args.desktop)), monitors[0])
        mw, mh = map(int, size.split("x"))
        limit = body.get("maxSize") or 1920
        scale = min(1, limit / mw, limit / mh)
        w, h = int(mw * scale) // 2 * 2, int(mh * scale) // 2 * 2
        sh(*adb, "forward", f"tcp:{port}", f"tcp:{port}")
        try:
            conn = phone_client(socket.create_connection(("127.0.0.1", port), timeout=10))
            conn.settimeout(None)
            proc = subprocess.Popen(
                ["gpu-screen-recorder", "-w", name, "-c", "flv", "-k", "h264", "-s", f"{w}x{h}", "-f", "30",
                 "-bm", "qp", "-q", "high", "-keyint", "2", "-cursor", "yes", "-fallback-cpu-encoding", "yes", "-v", "no"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            recorder["proc"], recorder["stopped"] = proc, False
            live = False
            for flags, data in flv_frames(proc.stdout, w, h):
                if not live and flags != 4:
                    live = True
                    send("flux.desktop", {"state": "live", "monitor": name, "monitors": [m[0] for m in monitors],
                                          "width": w, "height": h})
                    print(f"streams {name} at {w}x{h}")
                conn.sendall(struct.pack(">IB", len(data), flags) + data)
            if not recorder["stopped"]:
                # The recorder stopped by itself. fluxd then reports an error.
                send("flux.desktop", {"state": "error", "message": "the screen capture stopped"})
            conn.close()
        except (OSError, ssl.SSLError) as e:
            print(f"remote desktop closed: {e}")
        finally:
            if recorder["proc"]:
                recorder["proc"].terminate()
                recorder["proc"] = None
            sh(*adb, "forward", "--remove", f"tcp:{port}")

    deadline = None
    if already:
        print("already paired")
        deadline = time.time() + args.seconds
        threading.Thread(target=after_pair, daemon=True).start()
    while True:
        line = reader.readline()
        if not line:
            print("phone closed the link")
            break
        p = json.loads(line)
        kind, body = p["type"], p.get("body", {})
        if kind == "flux.pair":
            if body.get("pair") and "timestamp" in body:
                # The phone started the pairing. Accept it, like a user who
                # compares the key and clicks Accept.
                print(f"phone asks to pair with key {verification_key(spki(own_der), spki(phone_der), body['timestamp'])}")
                send("flux.pair", {"pair": True})
            if body.get("pair"):
                print("PAIRED")
                with open(paired_file, "w") as f:
                    f.write(phone_id)
                paired.set()
                deadline = time.time() + args.seconds
                threading.Thread(target=after_pair, daemon=True).start()
            else:
                print("phone rejected or unpaired")
                if os.path.exists(paired_file):
                    os.remove(paired_file)
                break
            continue
        print(f"<- {kind} {json.dumps(body)[:160]}" + (f" payload={p.get('payloadSize')}" if "payloadSize" in p else ""))
        if kind == "flux.runcommand.request" and body.get("requestCommandList"):
            send("flux.runcommand", {"commandList": json.dumps(commands), "canAddCommand": True})
        elif kind == "flux.mpris.request":
            if body.get("requestPlayerList"):
                send("flux.mpris", {"playerList": ["spotify"], "supportAlbumArtPayload": False})
            if body.get("requestNowPlaying"):
                send("flux.mpris", now_playing())
            if body.get("action") == "PlayPause":
                playing["v"] = not playing["v"]
                send("flux.mpris", now_playing())
            if "setVolume" in body:
                volume["v"] = max(0, min(100, int(body["setVolume"])))
                send("flux.mpris", now_playing())
        elif kind == "flux.desktop":
            if body.get("state") == "start" and desktop:
                threading.Thread(target=stream_desktop, args=(body,), daemon=True).start()
            elif body.get("state") == "stop" and recorder["proc"]:
                recorder["stopped"] = True
                recorder["proc"].terminate()
        elif kind == "flux.shortcuts" and desktop:
            action = body.get("action")
            if action == "workspace":
                spaces["active"] = body.get("workspace", 1)
            elif action == "moveToWorkspace":
                target = body.get("workspace", 1)
                spaces["windows"][target] = spaces["windows"].get(target, 0) + 1
            send("flux.shortcuts", shortcut_state(bool(body.get("request"))))
        elif kind == "flux.tunnel":
            waiter = tunnels.get(body.get("id"))
            if waiter:
                waiter.put(body)
        elif kind == "flux.sftp.request":
            if args.sftp_port:
                # Like fluxd: the root first as Home, then its folders. The lists have the same length.
                root = args.sftp_root.rstrip("/") or "/"
                folders = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)))
                token = new_tunnel()
                send("flux.sftp", {"tunnel": token, "user": "flux", "password": args.sftp_password, "path": root,
                                   "multiPaths": [root] + [os.path.join(root, n) for n in folders],
                                   "pathNames": ["Home"] + folders})
                threading.Thread(target=serve_sftp, args=(token,), daemon=True).start()
            else:
                send("flux.sftp", {"errorMessage": "The test peer has no SFTP server."})
        if deadline and time.time() > deadline:
            break
    sh(*adb, "forward", "--remove", f"tcp:{FORWARD_PORT}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
