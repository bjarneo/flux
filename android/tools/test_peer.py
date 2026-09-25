#!/usr/bin/env python3
"""A minimal KDE Connect desktop peer for testing the Flux Android app.

The peer reaches the phone through `adb forward`, so no firewall rule is
needed on the computer. It opens TCP to the app, sends a plain-text
identity, runs TLS as the server, exchanges the protocol 8 identity, and
then sends a pairing request. After the user accepts on the phone, it sends
sample battery, theme, command, and media packets and answers requests.

Run it with a debug build installed and USB debugging on:

    python3 tools/test_peer.py

Requires: python3, openssl, adb.
"""

import argparse
import hashlib
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time
import uuid

PACKAGE = "org.omarchy.flux"
FORWARD_PORT = 18716


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
    if a < b:
        a, b = b, a
    return hashlib.sha256(a + b + str(ts).encode()).hexdigest()[:8].upper()


def make_identity(dev_id, target=None, name="flux-test-peer"):
    body = {
        "deviceId": dev_id,
        "deviceName": name,
        "deviceType": "laptop",
        "protocolVersion": 8,
        "incomingCapabilities": [
            "kdeconnect.ping", "kdeconnect.battery", "kdeconnect.clipboard", "kdeconnect.clipboard.connect",
            "kdeconnect.share.request", "kdeconnect.notification", "kdeconnect.findmyphone.request",
            "kdeconnect.runcommand.request", "kdeconnect.mpris.request", "kdeconnect.sftp.request",
            "flux.tunnel",
        ],
        "outgoingCapabilities": [
            "kdeconnect.ping", "kdeconnect.battery", "kdeconnect.clipboard", "kdeconnect.share.request",
            "kdeconnect.notification.request", "kdeconnect.findmyphone.request", "kdeconnect.runcommand",
            "kdeconnect.mpris", "kdeconnect.sftp",
        ],
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
    ap.add_argument("--sftp-port", type=int, help="answer Browse PC with an SFTP server on 127.0.0.1:<port>")
    ap.add_argument("--sftp-root", default="/", help="the folder that the SFTP server serves")
    ap.add_argument("--sftp-password", default="flux-test")
    ap.add_argument("--wait-for-pair", action="store_true", help="let the phone start the pairing")
    ap.add_argument("--name", default="flux-test-peer")
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
           "-keyout", key, "-out", cert, "-days", "3650", "-subj", f"/O=KDE/OU=KDE Connect/CN={open(id_file).read()}")
    dev_id = open(id_file).read().strip()
    own_der = sh("openssl", "x509", "-in", cert, "-outform", "DER")

    phone_der = sh(*adb, "exec-out", "run-as", PACKAGE, "cat", "files/identity/certificate.der")
    phone_pem = sh("openssl", "x509", "-inform", "DER", data=phone_der).decode()
    phone_id = sh("openssl", "x509", "-noout", "-subject", "-nameopt", "multiline", data=phone_pem.encode()).decode()
    phone_id = [l.split("=", 1)[1].strip() for l in phone_id.splitlines() if "commonName" in l][0]
    print(f"phone device ID {phone_id}")

    sh(*adb, "forward", f"tcp:{FORWARD_PORT}", "tcp:1716")
    raw = socket.create_connection(("127.0.0.1", FORWARD_PORT), timeout=10)
    raw.sendall(packet("kdeconnect.identity", make_identity(dev_id, target=phone_id, name=args.name)))

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

    tls.sendall(packet("kdeconnect.identity", make_identity(dev_id, name=args.name)))
    reader = tls.makefile("rb")
    ident = json.loads(reader.readline())
    assert ident["type"] == "kdeconnect.identity", ident
    b = ident["body"]
    assert b["deviceId"] == phone_id and b["protocolVersion"] == 8, b
    assert "tcpPort" not in b, "post-TLS identity must not carry tcpPort"
    print(f"identity after TLS OK: {b['deviceName']} ({b['deviceType']})")
    tls.settimeout(None)

    already = os.path.exists(paired_file) and open(paired_file).read().strip() == phone_id
    if not already and not args.wait_for_pair:
        ts = int(time.time())
        expected = verification_key(spki(own_der), spki(phone_der), ts)
        tls.sendall(packet("kdeconnect.pair", {"pair": True, "timestamp": ts}))
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

    def now_playing():
        return {"player": "spotify", "title": "Weightless", "artist": "Marconi Union", "album": "Weightless",
                "isPlaying": playing["v"], "pos": 192000, "length": 489000, "canSeek": True,
                "canPlay": True, "canPause": True, "canGoNext": True, "canGoPrevious": True, "volume": 60}

    def after_pair():
        send("kdeconnect.battery", {"currentCharge": 64, "isCharging": False, "thresholdEvent": 0})
        send("kdeconnect.runcommand", {"commandList": json.dumps(commands), "canAddCommand": True})
        send("kdeconnect.mpris", {"playerList": ["spotify"], "supportAlbumArtPayload": False})
        if args.send_file:
            send_file(args.send_file)

    def send_file(path):
        data = open(path, "rb").read()
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        port = srv.getsockname()[1]
        srv.listen(1)
        # The phone connects to 127.0.0.1:<port> on itself. adb reverse maps it here.
        sh(*adb, "reverse", f"tcp:{port}", f"tcp:{port}")
        send("kdeconnect.share.request", {"filename": os.path.basename(path), "open": False},
             payloadSize=len(data), payloadTransferInfo={"port": port})
        conn, _ = srv.accept()
        pctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        pctx.maximum_version = ssl.TLSVersion.TLSv1_2
        pctx.load_cert_chain(cert, key)
        pctx.verify_mode = ssl.CERT_REQUIRED
        pctx.load_verify_locations(cadata=phone_pem)
        pctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        c = pctx.wrap_socket(conn, server_side=True)
        c.sendall(data)
        c.close()
        srv.close()
        sh(*adb, "reverse", "--remove", f"tcp:{port}")
        print(f"sent {path} ({len(data)} bytes)")

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
        if kind == "kdeconnect.pair":
            if body.get("pair") and "timestamp" in body:
                # The phone started the pairing. Accept it, like a user who
                # compares the key and clicks Accept.
                print(f"phone asks to pair with key {verification_key(spki(own_der), spki(phone_der), body['timestamp'])}")
                send("kdeconnect.pair", {"pair": True})
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
        if kind == "kdeconnect.runcommand.request" and body.get("requestCommandList"):
            send("kdeconnect.runcommand", {"commandList": json.dumps(commands), "canAddCommand": True})
        elif kind == "kdeconnect.mpris.request":
            if body.get("requestPlayerList"):
                send("kdeconnect.mpris", {"playerList": ["spotify"], "supportAlbumArtPayload": False})
            if body.get("requestNowPlaying"):
                send("kdeconnect.mpris", now_playing())
            if body.get("action") == "PlayPause":
                playing["v"] = not playing["v"]
                send("kdeconnect.mpris", now_playing())
        elif kind == "kdeconnect.sftp.request":
            if args.sftp_port:
                sh(*adb, "reverse", f"tcp:{args.sftp_port}", f"tcp:{args.sftp_port}")
                root = args.sftp_root.rstrip("/")
                names = sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)))
                send("kdeconnect.sftp", {"ip": "127.0.0.1", "port": args.sftp_port, "user": "kdeconnect",
                                         "password": args.sftp_password, "path": root or "/",
                                         "multiPaths": [f"{root}/{n}" for n in names], "pathNames": names})
            else:
                send("kdeconnect.sftp", {"errorMessage": "The test peer has no SFTP server."})
        if deadline and time.time() > deadline:
            break
    sh(*adb, "forward", "--remove", f"tcp:{FORWARD_PORT}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
