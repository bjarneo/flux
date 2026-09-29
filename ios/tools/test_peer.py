#!/usr/bin/env python3
"""A minimal KDE Connect desktop peer for testing Flux for iOS.

Fork of `android/tools/test_peer.py` without `adb`: it talks to the iPhone
over the LAN directly (or to the simulator over loopback). It sends a
plain-text identity to the phone's advertised `tcpPort`, runs TLS as the
server, exchanges the protocol 8 identity, then sends a pairing request.
After the user accepts on the phone, it sends sample battery, command, and
media packets and answers requests.

Discovery:
    python3 ios/tools/test_peer.py --listen
    # waits for a UDP broadcast on 1716, prints deviceId/tcpPort, then connects.

Direct:
    python3 ios/tools/test_peer.py --host 192.168.1.20 --port 1716

Pinned (mutual TLS like a paired fluxd; pass the phone cert dumped by
`swift run FluxTestPeer --dump-cert phone.der`):

    python3 ios/tools/test_peer.py --host 192.168.1.20 --port 1716 --phone-cert phone.der

Requires: python3, openssl. No firewall rule needed beyond the LAN.
State (peer cert + pairing) lives in ~/.cache/flux-ios-test-peer.
Unbuffered output (`python3 -u`) keeps logs live when redirected.
"""

import argparse
import base64
import getpass
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

UDP_PORT = 1716


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


def make_identity(dev_id, target=None, name="flux-ios-test-peer"):
    body = {
        "deviceId": dev_id,
        "deviceName": name,
        "deviceType": "laptop",
        "protocolVersion": 8,
    # iOS v1 capability subset from docs/ios-plan.md §2.2 (desktop side).
    # flux.webcam/mic/screen are incoming like Go's Incoming: the phone
    # announces listeners and this side connects to stream (M5).
    "incomingCapabilities": [
        "kdeconnect.ping", "kdeconnect.battery", "kdeconnect.clipboard", "kdeconnect.clipboard.connect",
        "kdeconnect.share.request", "kdeconnect.notification", "kdeconnect.findmyphone.request",
        "kdeconnect.runcommand.request", "kdeconnect.mpris.request", "kdeconnect.sftp.request",
        "flux.tunnel", "flux.webcam", "flux.mic", "flux.screen", "flux.approve",
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


def wait_for_broadcast(timeout=60):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except OSError:
        pass
    s.bind(("", UDP_PORT))
    s.settimeout(timeout)
    print(f"listening for UDP broadcasts on :{UDP_PORT} ...", flush=True)
    while True:
        data, addr = s.recvfrom(65536)
        try:
            p = json.loads(data.decode().strip())
        except ValueError:
            continue
        if p.get("type") != "kdeconnect.identity":
            continue
        b = p.get("body", {})
        if b.get("tcpPort") and b.get("deviceId"):
            print(f"found {b.get('deviceName')} ({b.get('deviceType')}) id={b['deviceId']} tcpPort={b['tcpPort']} at {addr[0]}")
            return addr[0], b["tcpPort"], b["deviceId"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", help="phone IP (skip UDP discovery)")
    ap.add_argument("--port", type=int, default=UDP_PORT, help="phone tcpPort (default: 1716)")
    ap.add_argument("--phone-id", default="", help="phone deviceId for the plaintext identity (else discovered or empty)")
    ap.add_argument("--listen", action="store_true", help="wait for a UDP broadcast first")
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--name", default="flux-ios-test-peer")
    ap.add_argument("--state", default=os.path.expanduser("~/.cache/flux-ios-test-peer"))
    ap.add_argument("--wait-for-pair", action="store_true")
    ap.add_argument("--phone-cert", default="",
                    help="phone certificate (DER or PEM) to require + pin, like fluxd pins after pairing")
    ap.add_argument("--serve-file", default="",
                    help="file to send to the phone after pairing (desktop→phone, Go SendFiles role)")
    ap.add_argument("--serve-mode", default="tunnel", choices=["classic", "tunnel"],
                    help="announce a payload port (classic) or a tunnel token like fluxd does (default: tunnel)")
    ap.add_argument("--expect-file", default=[], action="append",
                    help="filename the phone will upload (phone→desktop); fetch it from the announced port "
                         "(repeatable: --expect-file a --expect-file b)")
    ap.add_argument("--expect-path", default="", help="where to save --expect-file (default: <state>/<name>)")
    ap.add_argument("--expect-bytes", type=int, default=-1, help="expected size of --expect-file (-1: any)")
    ap.add_argument("--browse-offer", default="", choices=["", "off", "tunnel"],
                    help="answer kdeconnect.sftp.request with an errorMessage (off = share_home off) "
                         "or a tunnel offer the phone opens (tunnel)")
    ap.add_argument("--browse-ssh", action="store_true",
                    help="answer kdeconnect.sftp.request with a tunnel offer AND serve SSH+SFTP "
                         "inside it (asyncssh, one-time password, fixture dir): the D1 desktop "
                         "role for the phone's --exercise-browse")
    ap.add_argument("--expect-browse", action="store_true",
                    help="at the end, require the D1 proofs: password auth + fixture listing + "
                         "a file read observed server-side (pair with --browse-ssh and the "
                         "phone's --exercise-browse); exit 1 if any is missing")
    ap.add_argument("--m4", action="store_true",
                    help="send M4 desktop→phone samples after pairing (mpris now-playing state, "
                         "an mpris.request action like `flux media`, a player-list query, flux.dnd)")
    ap.add_argument("--expect-m4", action="store_true",
                    help="at the end, require phone→desktop mpris.request, runcommand.request, "
                         "telephony, and flux.dnd (pair with the phone's --exercise-m4); exit 1 if any is missing")
    ap.add_argument("--m5", action="store_true",
                    help="answer M5 phone→desktop stream starts: connect to the announced port like fluxd "
                         "DialPeer does, checksum the H.264/PCM bytes, and reply live (+ a webcam config "
                         "change); pair with the phone's --exercise-m5")
    ap.add_argument("--expect-m5", action="store_true",
                    help="at the end, require phone→desktop flux.webcam/mic/screen starts with "
                         "byte-identical streams, scanned text, and the --expect-file captures "
                         "(pair with the phone's --exercise-m5); exit 1 if any is missing")
    ap.add_argument("--m6", action="store_true",
                    help="run the M6 approval role after pairing: enroll with a helper-made nonce "
                         "like cmd/flux-approve does, verify the enrolled signature with openssl, "
                         "request an approval, verify it, then run replay/tamper/wrong-key and "
                         "stale/bad-nonce/cancel probes (pair with the phone's --exercise-m6)")
    ap.add_argument("--m6-delay", action="store_true",
                    help="strict cancel variant of --m6: pair with the phone's --approve-delay 5 so "
                         "the prompt is still open when the cancel lands, then prove the cancelled "
                         "request is never answered while the next one is (implies --m6)")
    ap.add_argument("--expect-m6", action="store_true",
                    help="at the end, require the M6 openssl proofs and all fail-closed probes "
                         "(pair with the phone's --exercise-m6, or --approve-delay 5 with --m6-delay); "
                         "exit 1 if any is missing")
    args = ap.parse_args()

    # Stream sockets pin the phone certificate like a paired fluxd does.
    # Without --phone-cert the server requests no client certificate, so the
    # phone sends none on the main link and the pin has nothing to check
    # against: pair first, then re-run pinned (M1b/M3/M4 procedure).
    if args.m5 and not args.phone_cert:
        print("error: --m5 needs --phone-cert (pair first, then re-run pinned)", flush=True)
        sys.exit(2)

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

    host, port, phone_id = args.host, args.port, args.phone_id
    if args.listen or not host:
        host, port, discovered = wait_for_broadcast()
        phone_id = phone_id or discovered

    raw = socket.create_connection((host, port), timeout=10)
    raw.sendall(packet("kdeconnect.identity", make_identity(dev_id, target=phone_id or None, name=args.name)))

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    if args.phone_cert:
        # Mutual TLS like a paired fluxd: require the pinned phone cert.
        data = open(args.phone_cert, "rb").read()
        if b"BEGIN CERTIFICATE" not in data:
            data = sh("openssl", "x509", "-inform", "DER", "-outform", "PEM", data=data)
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(cadata=data.decode())
        ctx.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    else:
        ctx.verify_mode = ssl.CERT_NONE  # TOFU: accept any, pin after pairing
    tls = ctx.wrap_socket(raw, server_side=True)
    print(f"TLS {tls.version()} {tls.cipher()[0]}")
    peer_der = tls.getpeercert(binary_form=True)
    if peer_der:
        print(f"phone cert DER sha256: {hashlib.sha256(peer_der).hexdigest()[:16]}...")
        if args.phone_cert:
            expected = sh("openssl", "x509", "-outform", "DER", data=data)
            assert peer_der == expected, "phone presented a different certificate (re-pair required)"
    else:
        print("phone sent no certificate (pass --phone-cert to require + pin it)")

    tls.sendall(packet("kdeconnect.identity", make_identity(dev_id, name=args.name)))

    class TLSLines:
        # Line reader over the TLS socket that keeps unread bytes across
        # timeouts. (The stdlib buffered reader from makefile() can lose
        # data when a read times out, which dropped packets in M6 delay
        # runs where the answer arrives ~5 s after the request.)
        def __init__(self, conn):
            self.conn = conn
            self.buf = b""

        def readline(self, timeout=5):
            deadline = time.time() + timeout
            while True:
                if b"\n" in self.buf:
                    line, self.buf = self.buf.split(b"\n", 1)
                    return line + b"\n"
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise OSError("read timeout")
                self.conn.settimeout(remaining)
                try:
                    chunk = self.conn.recv(65536)
                except socket.timeout:
                    raise OSError("read timeout")
                if not chunk:
                    return b""
                self.buf += chunk

    reader = TLSLines(tls)
    ident = json.loads(reader.readline())
    assert ident["type"] == "kdeconnect.identity", ident
    b = ident["body"]
    assert b["deviceId"] and b["protocolVersion"] == 8, b
    assert "tcpPort" not in b, "post-TLS identity must not carry tcpPort"
    print(f"identity after TLS OK: {b['deviceName']} ({b['deviceType']})")
    # Wake every few seconds so the --seconds deadline fires even when the
    # phone sends nothing more (M4 welcome bursts arrive once, up front).
    tls.settimeout(5)

    already = os.path.exists(paired_file) and open(paired_file).read().strip() == b["deviceId"]
    if not already and not args.wait_for_pair:
        ts = int(time.time())
        print(f"pair request sent. Compare the 8-char key on the phone (ts={ts})")
        tls.sendall(packet("kdeconnect.pair", {"pair": True, "timestamp": ts}))

    lock = threading.Lock()
    tunnel_cond = threading.Condition(lock)
    tunnel_replies = {}  # token -> (port, error)

    def send(kind, body, **extra):
        with lock:
            tls.sendall(packet(kind, body, **extra))

    def payload_server_ctx():
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        c.maximum_version = ssl.TLSVersion.TLSv1_2
        c.load_cert_chain(cert, key)
        # Mutual TLS like a paired fluxd: require the pinned phone cert.
        pem = sh("openssl", "x509", "-inform", "DER", "-outform", "PEM", data=peer_der)
        c.verify_mode = ssl.CERT_REQUIRED
        c.load_verify_locations(cadata=pem.decode())
        c.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        return c

    def check_phone_der(der, what):
        if der != peer_der:
            got = hashlib.sha256(der).hexdigest() if der else "none"
            want = hashlib.sha256(peer_der).hexdigest() if peer_der else "none"
            print(f"{what}: peer cert MISMATCH got={got} want={want}", flush=True)
        assert der == peer_der, f"{what}: payload peer is not the paired phone"
        print(f"{what}: peer cert matches the paired phone", flush=True)

    def serve_classic(path):
        data = open(path, "rb").read()
        ln = None
        for port in range(1739, 1765):
            try:
                ln = socket.create_server(("0.0.0.0", port))
                break
            except OSError:
                continue
        assert ln, "no free payload port in 1739-1764"
        port = ln.getsockname()[1]
        name = os.path.basename(path)
        ln.settimeout(20)
        send("kdeconnect.share.request", {"filename": name, "open": False},
             payloadSize=len(data), payloadTransferInfo={"port": port})
        print(f"serving {name} ({len(data)} bytes) on classic port {port}", flush=True)
        if not data:
            # 0 B has no fetchable payload on any implementation
            # (hasPayload needs size != 0): the phone must not connect.
            time.sleep(3)
            ln.close()
            print("0B announce sent; no fetch expected (protocol-level drop, like Android/Go)", flush=True)
            return
        c, _ = ln.accept()
        ln.close()
        stls = payload_server_ctx().wrap_socket(c, server_side=True)
        try:
            check_phone_der(stls.getpeercert(binary_form=True), "classic payload")
            stls.sendall(data)
            print(f"served {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()}", flush=True)
        finally:
            try:
                stls.close()
            except OSError:
                pass

    def serve_tunnel(path):
        data = open(path, "rb").read()
        token = os.urandom(12).hex()  # Go NewTunnelID
        name = os.path.basename(path)
        send("kdeconnect.share.request", {"filename": name, "open": False},
             payloadSize=len(data), payloadTransferInfo={"tunnel": token})
        print(f"serving {name} ({len(data)} bytes) via tunnel {token}", flush=True)
        if not data:
            time.sleep(3)
            print("0B announce sent; no flux.tunnel ready expected (protocol-level drop, like Android/Go)", flush=True)
            return
        with tunnel_cond:
            ok = tunnel_cond.wait_for(lambda: token in tunnel_replies, timeout=30)
            assert ok, "the phone did not open a tunnel within 30 seconds"
            port, err = tunnel_replies.pop(token)
            assert not err, f"the phone could not open a tunnel: {err}"
            assert 1739 <= port <= 1764, f"phone sent port {port}, outside 1739 to 1764"
        raw2 = socket.create_connection((host, port), timeout=10)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.maximum_version = ssl.TLSVersion.TLSv1_2
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        c.load_cert_chain(cert, key)  # the phone pins this (Go DialPeer parity)
        t = c.wrap_socket(raw2, server_hostname="phone")
        try:
            check_phone_der(t.getpeercert(binary_form=True), "tunnel payload")
            t.sendall(data)
            print(f"served {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()}", flush=True)
        finally:
            try:
                t.close()
            except OSError:
                pass

    def expect_upload(name):
        # Phone→desktop is always classic: the phone announces a port and
        # this side fetches (Go FetchPayload role).
        dest = args.expect_path or os.path.join(work, "recv-" + os.path.basename(name))
        deadline = time.time() + 90
        port, size = 0, -1
        while time.time() < deadline:
            with lock:
                got = Norman.get(name)
            if got:
                port, size = got
                break
            time.sleep(0.2)
        assert port, f"the phone never announced {name}"
        raw2 = socket.create_connection((host, port), timeout=10)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.maximum_version = ssl.TLSVersion.TLSv1_2
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        c.load_cert_chain(cert, key)
        t = c.wrap_socket(raw2, server_hostname="phone")
        try:
            check_phone_der(t.getpeercert(binary_form=True), "upload fetch")
            t.settimeout(30)
            data = b""
            while len(data) < size:
                chunk = t.recv(min(65536, size - len(data)))
                if not chunk:
                    break
                data += chunk
        finally:
            try:
                t.close()
            except OSError:
                pass
        assert len(data) == size, f"received {len(data)} of {size} bytes"
        if args.expect_bytes >= 0:
            assert len(data) == args.expect_bytes, f"size {len(data)} != expected {args.expect_bytes}"
        with open(dest, "wb") as f:
            f.write(data)
        print(f"RECEIVED {name} ({len(data)} bytes) sha256={hashlib.sha256(data).hexdigest()} -> {dest}", flush=True)

    Norman = {}

    browse_result = {}  # filled by answer_browse; --expect-browse asserts it

    def answer_browse():
        if args.browse_offer == "off":
            send("kdeconnect.sftp", {"errorMessage": "Browsing is off on this computer. Set share_home = true in ~/.config/flux/config.toml"})
            print("answered sftp.request with errorMessage (share_home off)", flush=True)
            return
        ssh_mode = args.browse_ssh
        fixture = os.path.join(work, "browse-fixture")
        token = os.urandom(12).hex()
        password = "one-time-" + token[:8]
        if ssh_mode:
            roots, names = [fixture, os.path.join(fixture, "sub")], ["Fixture", "sub"]
            home = fixture
        else:
            roots, names = ["/home/ed", "/home/ed/Downloads"], ["Home", "Downloads"]
            home = "/home/ed"
        send("kdeconnect.sftp", {"tunnel": token, "user": "kdeconnect",
                                 "password": password,
                                 "path": home,
                                 "multiPaths": roots,
                                 "pathNames": names})
        print(f"answered sftp.request with tunnel {token}", flush=True)
        with tunnel_cond:
            ok = tunnel_cond.wait_for(lambda: token in tunnel_replies, timeout=30)
            assert ok, "the phone did not open a browse tunnel within 30 seconds"
            port, err = tunnel_replies.pop(token)
            assert not err, f"the phone could not open a tunnel: {err}"
        raw2 = socket.create_connection((host, port), timeout=10)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.maximum_version = ssl.TLSVersion.TLSv1_2
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        c.load_cert_chain(cert, key)
        t = c.wrap_socket(raw2, server_hostname="phone")
        try:
            check_phone_der(t.getpeercert(binary_form=True), "browse tunnel")
            browse_result["saw_tunnel"] = True
            if ssh_mode:
                serve_browse_ssh(t, token, password, fixture)
            else:
                print(f"BROWSE TUNNEL {token} ESTABLISHED on port {port} (SSH bytes deferred to M4+)", flush=True)
                time.sleep(3)
        finally:
            try:
                t.close()
            except OSError:
                pass

    def serve_browse_ssh(t, token, password, fixture):
        # D1 desktop role: deterministic fixture + a real SSH/SFTP server
        # (asyncssh, fresh ed25519 host key, one-time password) bridged
        # into the tunnel. The phone's SSH bytes arrive here; auth, readdir
        # and file reads are observed server-side for --expect-browse.
        os.makedirs(os.path.join(fixture, "sub"), exist_ok=True)
        files = {
            "hello.txt": b"hello from the browse fixture\n",
            "sub/nested.txt": b"nested fixture file\n",
            # Size-bearing file: the device download leg died on a
            # 614 KB zip at OPEN, so the loopback must prove a mid-size
            # download too (relay/Citadel vs. desktop localization).
            "big.bin": bytes((i * 31 + 7) & 0xFF for i in range(600 * 1024)),
        }
        shas = {}
        for rel, data in files.items():
            with open(os.path.join(fixture, rel), "wb") as f:
                f.write(data)
            shas[rel] = hashlib.sha256(data).hexdigest()
        browse_result["fixture_shas"] = shas
        print("BROWSE FIXTURE " + " ".join(f"{n} sha256={s}" for n, s in shas.items()), flush=True)
        tools = os.path.dirname(os.path.abspath(__file__))
        port_file = os.path.join(work, "browse-sftp-port")
        try:
            os.remove(port_file)
        except OSError:
            pass
        try:
            import asyncssh  # noqa: F401  (server dependency, pip3 install asyncssh)
        except ImportError:
            print("BROWSE SSH FAILED: asyncssh is missing (pip3 install asyncssh)", flush=True)
            browse_result["server_error"] = "asyncssh missing"
            return
        srv = subprocess.Popen(
            [sys.executable, "-u", os.path.join(tools, "browse_sftp_server.py"),
             "--root", fixture, "--user", "kdeconnect", "--password", password,
             "--port-file", port_file],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        markers = []
        browse_result["markers"] = markers
        collector = threading.Thread(
            target=lambda: [markers.append(line.rstrip()) or
                            print(f"sftp-server: {line.rstrip()}", flush=True)
                            for line in srv.stdout],
            daemon=True)
        collector.start()
        deadline = time.time() + 15
        while time.time() < deadline and not os.path.exists(port_file):
            time.sleep(0.1)
        if not os.path.exists(port_file):
            print("BROWSE SSH FAILED: the SFTP server never bound a port", flush=True)
            browse_result["server_error"] = "no port"
            srv.terminate()
            return
        sport = int(open(port_file).read().strip())
        tcp = socket.create_connection(("127.0.0.1", sport), timeout=10)
        # Blocking pumps from here on: idle SSH sessions must survive
        # (timeouts here killed the relay at 10 s idle and faked a
        # device-side idle death — the pumps end on EOF/error only).
        tcp.settimeout(None)
        t.settimeout(None)
        # Pump tunnel TLS <-> SFTP server until the phone closes the
        # session (BROWSE DONE) or the 120 s cap ends the attempt.
        stop = time.time() + 120
        byte_count = {"up": 0, "down": 0}

        def pump(src, dst, name):
            first = True
            try:
                while time.time() < stop:
                    chunk = src.recv(32768)
                    if not chunk:
                        print(f"BROWSE PUMP {name}: EOF after {byte_count[name]} bytes", flush=True)
                        break
                    if first:
                        first = False
                        print(f"BROWSE PUMP {name}: first {min(64, len(chunk))}b: {chunk[:64].hex()}", flush=True)
                    dst.sendall(chunk)
                    byte_count[name] += len(chunk)
            except OSError as e:
                print(f"BROWSE PUMP {name}: {e} after {byte_count[name]} bytes", flush=True)

        up = threading.Thread(target=pump, args=(t, tcp, "up"), daemon=True)
        down = threading.Thread(target=pump, args=(tcp, t, "down"), daemon=True)
        up.start()
        down.start()
        up.join(timeout=125)
        try:
            tcp.close()
        except OSError:
            pass
        srv.terminate()
        print(f"BROWSE SERVED tunnel {token} ({len(markers)} server markers)", flush=True)

    def answer_stream(kind, body):
        # M5 desktop role (Go DialPeer parity): connect to the phone's
        # stream listener as a TLS client, read the raw bytes, checksum
        # them, then answer live (+ a settings change for the webcam).
        port = body.get("port", 0)
        assert 1739 <= port <= 1764, f"phone sent stream port {port}, outside 1739 to 1764"
        raw2 = socket.create_connection((host, port), timeout=10)
        c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        c.maximum_version = ssl.TLSVersion.TLSv1_2
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
        c.load_cert_chain(cert, key)  # the phone pins this (Go DialPeer parity)
        t = c.wrap_socket(raw2, server_hostname="phone")
        try:
            check_phone_der(t.getpeercert(binary_form=True), f"{kind} stream")
            t.settimeout(30)
            data = b""
            while True:
                try:
                    chunk = t.recv(65536)
                except OSError:
                    break
                if not chunk:
                    break
                data += chunk
        finally:
            try:
                t.close()
            except OSError:
                pass
        with lock:
            stream_bytes[kind] = data
        print(f"STREAM {kind} RECEIVED {len(data)} bytes sha256={hashlib.sha256(data).hexdigest()}", flush=True)
        if kind == "flux.webcam":
            send(kind, {"state": "live", "device": "/dev/video42", "label": "Flux Camera"})
            send(kind, {"state": "config", "config": {"brightness": 0.2}})
            print(f"answered {kind} start with live + a config change", flush=True)
        elif kind == "flux.mic":
            send(kind, {"state": "live", "source": "Flux Microphone"})
            print(f"answered {kind} start with live", flush=True)
        elif kind == "flux.screen":
            send(kind, {"state": "live", "player": "mpv"})
            print(f"answered {kind} start with live", flush=True)

    stream_bytes = {}  # flux.* kind -> raw stream bytes (--m5 reads these)
    stream_starts = set()  # flux.* kinds announced (--expect-m5 asserts on these)
    scan_text_seen = []  # scanned texts from the phone camera
    approve_replies = {}  # flux.approve id -> [body, ...] (--m6 reads these)
    m6_ok = []  # labels of passed M6 checks (--expect-m6 asserts on these)
    m6_failures = []  # M6 error strings

    def wait_approve(req_id, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with lock:
                got = list(approve_replies.get(req_id, []))
            if got:
                return got
            time.sleep(0.2)
        return []

    def openssl_verify(pubkey_der, sig, msg, tag):
        # Helper role (Go Verify parity): the signature must check out over
        # the exact bytes this side built from its own fields. True only for
        # `openssl ... Verified OK`.
        d = os.path.join(work, "m6-" + tag)
        os.makedirs(d, exist_ok=True)
        pub_pem = sh("openssl", "pkey", "-pubin", "-inform", "DER", "-outform", "PEM", data=pubkey_der)
        with open(os.path.join(d, "pub.pem"), "wb") as f:
            f.write(pub_pem)
        with open(os.path.join(d, "sig.bin"), "wb") as f:
            f.write(sig)
        with open(os.path.join(d, "msg.bin"), "wb") as f:
            f.write(msg)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", os.path.join(d, "pub.pem"),
                            "-signature", os.path.join(d, "sig.bin"), os.path.join(d, "msg.bin")],
                           capture_output=True)
        ok = r.returncode == 0 and b"Verified OK" in r.stdout
        print(f"M6 {tag}: {'openssl Verified OK' if ok else 'openssl REJECTED'}", flush=True)
        return ok

    def approval_msg(host, user, service, tty, rhost, t, nonce):
        return (f"flux-approve-v1\nhost={host}\nuser={user}\nservice={service}\n"
                f"tty={tty}\nrhost={rhost}\ntime={t}\nnonce={nonce}\n").encode()

    def enroll_msg(host, user, pubkey_der, t, nonce):
        keyhex = hashlib.sha256(pubkey_der).hexdigest()
        return (f"flux-approve-enroll-v1\nhost={host}\nuser={user}\n"
                f"key={keyhex}\ntime={t}\nnonce={nonce}\n").encode()

    def do_m6(strict_cancel=False):
        # M6 desktop role (cmd/flux-approve parity): make fresh 32-byte
        # nonces, send enroll + approval requests, and verify every phone
        # signature with openssl against the enrolled pubkey. Then prove the
        # fail-closed paths: replay/tamper/wrong-key must NOT verify, and
        # stale/bad-nonce requests must get failure packets (the phone never
        # verifies — the helper does — so signature attacks are checked here,
        # request-shape attacks on the wire).
        try:
            host = socket.gethostname()
        except OSError:
            host = "flux-ios-test-peer"
        try:
            user = getpass.getuser()
        except Exception:
            user = "flux"
        try:
            # 1. Enroll with a helper-made nonce.
            nonce = os.urandom(32).hex()
            eid = "enroll-%s" % os.urandom(4).hex()
            t = int(time.time())
            send("flux.approve", {"kind": "enroll", "id": eid, "host": host, "user": user,
                                  "time": t, "nonce": nonce, "timeout": 120})
            print(f"M6 enroll {eid} sent (nonce={nonce[:16]}...)", flush=True)
            got = wait_approve(eid)
            assert got, "the phone never answered the enrollment"
            enrolled = got[0]
            assert enrolled.get("kind") == "enrolled", f"enrollment refused: {enrolled}"
            pubkey_der = base64.b64decode(enrolled["publicKey"])
            esig = base64.b64decode(enrolled["signature"])
            fp = hashlib.sha256(pubkey_der).hexdigest()[:16].upper()
            print(f"M6 enrolled: pubkey {len(pubkey_der)} bytes, "
                  f"key code (compare with phone) {fp[0:4]} {fp[4:8]} {fp[8:12]} {fp[12:16]}", flush=True)
            assert openssl_verify(pubkey_der, esig, enroll_msg(host, user, pubkey_der, t, nonce), "enroll"), \
                "enrollment signature invalid"
            m6_ok.append("enroll")

            # 2. Approval with a fresh nonce.
            nonce2 = os.urandom(32).hex()
            aid = "approve-%s" % os.urandom(4).hex()
            t2 = int(time.time())
            send("flux.approve", {"kind": "request", "id": aid, "host": host, "user": user,
                                  "service": "sudo", "tty": "/dev/pts/3", "rhost": "",
                                  "time": t2, "nonce": nonce2, "timeout": 20})
            print(f"M6 approval {aid} sent (nonce={nonce2[:16]}...)", flush=True)
            got = wait_approve(aid)
            assert got, "the phone never answered the approval"
            resp = got[0]
            assert resp.get("kind") == "response" and resp.get("signature"), \
                f"approval refused: {resp}"
            asig = base64.b64decode(resp["signature"])
            good = approval_msg(host, user, "sudo", "/dev/pts/3", "", t2, nonce2)
            assert openssl_verify(pubkey_der, asig, good, "approve"), "approval signature invalid"
            m6_ok.append("approve")

            # 3. Replay: the approval signature over a new nonce must fail.
            replay = approval_msg(host, user, "sudo", "/dev/pts/3", "", t2, os.urandom(32).hex())
            assert not openssl_verify(pubkey_der, asig, replay, "replay"), "replayed signature verified?!"
            m6_ok.append("replay-rejected")

            # 4. Tamper: a flipped service field must fail.
            tampered = approval_msg(host, user, "sshd", "/dev/pts/3", "", t2, nonce2)
            assert not openssl_verify(pubkey_der, asig, tampered, "tamper"), "tampered message verified?!"
            m6_ok.append("tamper-rejected")

            # 5. Wrong key must fail.
            fresh_priv = sh("openssl", "ecparam", "-genkey", "-name", "prime256v1",
                            "-noout", "-outform", "DER")
            fresh_spki = sh("openssl", "ec", "-inform", "DER", "-pubout",
                            "-outform", "DER", data=fresh_priv)
            assert not openssl_verify(fresh_spki, asig, good, "wrong-key"), "wrong key verified?!"
            m6_ok.append("wrong-key-rejected")

            # 6. Stale request: a 20-minute-old time gets the clock failure.
            sid = "stale-%s" % os.urandom(4).hex()
            send("flux.approve", {"kind": "request", "id": sid, "host": host, "user": user,
                                  "service": "sudo", "tty": "", "rhost": "",
                                  "time": t2 - 1200, "nonce": os.urandom(32).hex(), "timeout": 20})
            got = wait_approve(sid)
            assert got and "10 minutes" in (got[0].get("error") or ""), f"stale accepted: {got}"
            m6_ok.append("stale-rejected")

            # 7. Bad nonce shape gets the invalid failure.
            bid = "badnonce-%s" % os.urandom(4).hex()
            send("flux.approve", {"kind": "request", "id": bid, "host": host, "user": user,
                                  "service": "sudo", "tty": "", "rhost": "",
                                  "time": int(time.time()), "nonce": "xyz", "timeout": 20})
            got = wait_approve(bid)
            assert got and "not valid" in (got[0].get("error") or ""), f"bad nonce accepted: {got}"
            m6_ok.append("bad-nonce-rejected")

            # 8. Cancel: hold C, cancel C, then D must be answered (not busy).
            # In auto mode C is already answered when the cancel lands (the
            # cancel is ignored and D still works); in strict delay mode the
            # prompt is still open, so the cancel must clear it: C is never
            # answered (its late answer is dropped by id) while D is.
            cid = "cancel-%s" % os.urandom(4).hex()
            send("flux.approve", {"kind": "request", "id": cid, "host": host, "user": user,
                                  "service": "sudo", "tty": "", "rhost": "",
                                  "time": int(time.time()), "nonce": os.urandom(32).hex(),
                                  "timeout": 30})
            time.sleep(1)  # let the phone hold it
            send("flux.approve", {"kind": "cancel", "id": cid})
            did = "aftercancel-%s" % os.urandom(4).hex()
            nonce3 = os.urandom(32).hex()
            t3 = int(time.time())
            send("flux.approve", {"kind": "request", "id": did, "host": host, "user": user,
                                  "service": "sudo", "tty": "", "rhost": "",
                                  "time": t3, "nonce": nonce3, "timeout": 20})
            got = wait_approve(did)
            assert got and got[0].get("signature"), f"request after cancel refused: {got}"
            dsig = base64.b64decode(got[0]["signature"])
            assert openssl_verify(pubkey_der, dsig,
                                  approval_msg(host, user, "sudo", "", "", t3, nonce3),
                                  "after-cancel"), "post-cancel signature invalid"
            if strict_cancel:
                time.sleep(6)  # past the peer's --approve-delay: C must stay silent
                with lock:
                    c_got = list(approve_replies.get(cid, []))
                assert not c_got, f"cancelled request was answered: {c_got}"
                m6_ok.append("cancel-cleared")
            else:
                m6_ok.append("cancel-safe")
            print(f"M6 done: {sorted(m6_ok)}", flush=True)
        except Exception as e:
            m6_failures.append(str(e)[:200])
            print(f"M6 FAILED: {e}", flush=True)

    def after_pair():
        if args.serve_file:
            (serve_tunnel if args.serve_mode == "tunnel" else serve_classic)(args.serve_file)
        for name in args.expect_file:
            expect_upload(name)
        send("kdeconnect.battery", {"currentCharge": 64, "isCharging": False, "thresholdEvent": 0})
        send("kdeconnect.runcommand", {"commandList": json.dumps({"lock": {"name": "Lock screen", "command": "loginctl lock-session"}}), "canAddCommand": True})
        send("kdeconnect.mpris", {"playerList": ["spotify"], "supportAlbumArtPayload": False})
        # M2 messaging primitives: flux ping/clip/url/notify/ring equivalents.
        send("kdeconnect.ping", {"message": "hello iPhone"})
        send("kdeconnect.battery.request", {})
        send("kdeconnect.clipboard", {"content": "hello clipboard from desktop"})
        send("kdeconnect.clipboard.connect", {"content": "hello connect from desktop",
                                              "timestamp": int(time.time() * 1000)})
        send("kdeconnect.share.request", {"text": "shared text from desktop"})
        send("kdeconnect.share.request", {"url": "https://example.com/flux-m2"})
        now = int(time.time() * 1000)
        send("kdeconnect.notification", {
            "id": "flux-m2-1", "appName": "flux-ios-test-peer",
            "title": "Build done", "text": "M2 exercise",
            "ticker": "Build done: M2 exercise",
            "isClearable": True, "time": str(now),
        })
        send("kdeconnect.findmyphone.request", {})
        # Second ring request stops the ring again (toggle).
        time.sleep(1)
        send("kdeconnect.findmyphone.request", {})
        if args.m4:
            # M4 desktop→phone samples: the full now-playing state, one
            # `flux media` action (PhoneMediaAction role), one player-list
            # query, and desktop Do Not Disturb. The runcommand list and the
            # bare player list above already go out on every run.
            send("kdeconnect.mpris", {"player": "spotify", "title": "Test Tone",
                                      "artist": "Test Band", "album": "M4",
                                      "isPlaying": True, "pos": 1000, "length": 180000,
                                      "volume": 80, "canPlay": True, "canPause": True,
                                      "canGoNext": True, "canGoPrevious": True,
                                      "canSeek": True})
            send("kdeconnect.mpris.request", {"player": "Music", "action": "Pause"})
            send("kdeconnect.mpris.request", {"requestPlayerList": True})
            send("flux.dnd", {"on": True})
        if args.m6 or args.m6_delay:
            do_m6(strict_cancel=args.m6_delay)

    deadline = None
    seen = set()  # phone→desktop packet types (--expect-m4 asserts on these)
    if already:
        print("already paired")
        deadline = time.time() + args.seconds
        threading.Thread(target=after_pair, daemon=True).start()
    while True:
        try:
            line = reader.readline()
        except OSError:
            # The 5 s socket timeout surfaces as OSError ("cannot read from
            # timed out object") through the buffered reader: re-check the
            # deadline instead of dying. A true dead socket keeps timing
            # out, so the deadline still ends the run.
            if deadline and time.time() > deadline:
                break
            continue
        if not line:
            print("phone closed the link")
            break
        p = json.loads(line)
        kind, body = p["type"], p.get("body", {})
        seen.add(kind)
        if kind == "flux.approve":
            with lock:
                approve_replies.setdefault(body.get("id", ""), []).append(body)
            print(f"<- {kind} {json.dumps(body)[:160]}", flush=True)
            if deadline and time.time() > deadline:
                break
            continue
        if kind == "flux.tunnel":
            with tunnel_cond:
                tunnel_replies[body.get("id", "")] = (body.get("port", 0), body.get("error", ""))
                tunnel_cond.notify_all()
            print(f"<- {kind} {json.dumps(body)[:160]}", flush=True)
            if deadline and time.time() > deadline:
                break
            continue
        if kind in ("flux.webcam", "flux.mic", "flux.screen") and body.get("state") == "start":
            stream_starts.add(kind)
            print(f"<- {kind} {json.dumps(body)[:160]}", flush=True)
            if args.m5:
                threading.Thread(target=answer_stream, args=(kind, body), daemon=True).start()
            if deadline and time.time() > deadline:
                break
            continue
        if kind == "kdeconnect.share.request" and p.get("payloadTransferInfo", {}).get("port"):
            # Phone→desktop upload announcement: record the fetch port +
            # the photo/scan flags (photo_dir/scan_dir routing proof).
            Norman[body.get("filename", "")] = (
                p["payloadTransferInfo"]["port"], p.get("payloadSize", 0))
            flags = [k for k in ("scan", "photo", "screenshot") if body.get(k)]
            print(f"<- {kind} {json.dumps(body)[:160]} flags={flags}", flush=True)
            if deadline and time.time() > deadline:
                break
            continue
        if kind == "kdeconnect.share.request" and body.get("text") and body.get("scan"):
            scan_text_seen.append(body["text"])
            print(f"<- {kind} SCAN TEXT {json.dumps(body['text'])[:160]}", flush=True)
            if deadline and time.time() > deadline:
                break
            continue
        if kind == "kdeconnect.sftp.request" and (args.browse_offer or args.browse_ssh):
            threading.Thread(target=answer_browse, daemon=True).start()
        if kind == "kdeconnect.pair":
            if body.get("pair"):
                print("PAIRED")
                with open(paired_file, "w") as f:
                    f.write(b["deviceId"])
                deadline = time.time() + args.seconds
                threading.Thread(target=after_pair, daemon=True).start()
            else:
                print("phone rejected or unpaired")
                if os.path.exists(paired_file):
                    os.remove(paired_file)
                break
            continue
        print(f"<- {kind} {json.dumps(body)[:160]}")
        if deadline and time.time() > deadline:
            break

    if args.expect_m4:
        want = {"kdeconnect.mpris.request", "kdeconnect.runcommand.request",
                "kdeconnect.telephony", "flux.dnd"}
        missing = sorted(want - seen)
        if missing:
            print(f"M4 EXPECTATIONS FAILED: missing phone→desktop {missing}", flush=True)
            sys.exit(1)
        print(f"M4 EXPECTATIONS MET: saw {sorted(want)}", flush=True)

    if args.expect_m5:
        failures = []
        want_streams = {"flux.webcam", "flux.mic", "flux.screen"}
        missing = sorted(want_streams - stream_starts)
        if missing:
            failures.append(f"missing phone→desktop stream starts {missing}")
        for kind in sorted(want_streams):
            data = stream_bytes.get(kind, b"")
            if not data:
                failures.append(f"no stream bytes for {kind}")
        if not scan_text_seen:
            failures.append("no scanned text (share.request text+scan)")
        for name in args.expect_file:
            dest = args.expect_path or os.path.join(work, "recv-" + os.path.basename(name))
            if not os.path.exists(dest):
                failures.append(f"capture {name} never landed at {dest}")
        if failures:
            print(f"M5 EXPECTATIONS FAILED: {failures}", flush=True)
            sys.exit(1)
        got = {k: len(v) for k, v in stream_bytes.items()}
        print(f"M5 EXPECTATIONS MET: streams {got}, "
              f"scan text {len(scan_text_seen)} message(s), "
              f"captures {[os.path.basename(n) for n in args.expect_file]}", flush=True)

    if args.expect_m6:
        want = {"enroll", "approve", "replay-rejected", "tamper-rejected", "wrong-key-rejected",
                "stale-rejected", "bad-nonce-rejected",
                "cancel-cleared" if args.m6_delay else "cancel-safe"}
        missing = sorted(want - set(m6_ok))
        if missing or m6_failures:
            print(f"M6 EXPECTATIONS FAILED: missing={missing} errors={m6_failures}", flush=True)
            sys.exit(1)
        print(f"M6 EXPECTATIONS MET: {sorted(m6_ok)}", flush=True)

    if args.expect_browse:
        failures = []
        if browse_result.get("server_error"):
            failures.append(f"sftp server: {browse_result['server_error']}")
        if not browse_result.get("saw_tunnel"):
            failures.append("no browse tunnel established")
        markers = browse_result.get("markers", [])
        if not any(m.startswith("AUTH user=kdeconnect ok") for m in markers):
            failures.append("no password auth observed server-side")
        lists = [m for m in markers if m.startswith("SFTP LIST")]
        if len(lists) < 2:
            failures.append(f"expected >=2 directory listings, saw {len(lists)}")
        for want_open in ("hello.txt", "big.bin"):
            if not any(m.startswith("SFTP OPEN") and want_open in m for m in markers):
                failures.append(f"{want_open} never opened server-side")
        if not any(m.startswith("SFTP READ") for m in markers):
            failures.append("no file bytes read server-side")
        if failures:
            print(f"BROWSE EXPECTATIONS FAILED: {failures}", flush=True)
            sys.exit(1)
        shas = browse_result.get("fixture_shas", {})
        print("BROWSE EXPECTATIONS MET: auth + "
              f"{len(lists)} listings + file reads "
              f"(fixture {' '.join(f'{n}={s[:16]}...' for n, s in shas.items())}; "
              "compare with the phone's BROWSE FILE sha256 lines)", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
