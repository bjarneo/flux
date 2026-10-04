#!/usr/bin/env python3
"""Phase 0 proof for the Herdr terminal-session CLI bridge.

Harness mode creates a disposable named Herdr session and proves the contract
that Flux will rely on for pane-specific interactive control:

  * observe streams ANSI frames at the observer viewport without resizing
  * control owns the terminal size and receives pane-specific wheel events
  * wheel routing reaches the application in mouse-report and
    alternate-scroll modes, and host scrollback otherwise
  * one controller at a time, clean release, no orphan processes

Fixture mode (--tui) is a small alternate-screen test application that logs
every input event it receives. The harness asserts against that log.

Existing sessions are never touched; only the session created by this run is
stopped and deleted. Use --keep to leave it running for manual checks.

Examples:
  python3 scripts/herdr-bridge-proof.py
  python3 scripts/herdr-bridge-proof.py --session flux-bridge-proof --keep
  python3 scripts/herdr-bridge-proof.py --tui --log /tmp/opencode/fixture.jsonl
"""

import argparse
import base64
import json
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import termios
import threading
import time
import tty

MARKER = "PROOF-TUI READY"
DEFAULT_SESSION = "flux-bridge-proof"
DEFAULT_ROWS = 200
SGR_MOUSE_RE = re.compile(rb"^\x1b\[<(\d+);(\d+);(\d+)([Mm])$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?<>=!]*[ -/]*[@-~]|\x1b[@-Z\\-_]")


class ProofError(Exception):
    pass


def b64(data):
    return base64.b64encode(data).decode("ascii")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def sh(*argv, timeout=20):
    return subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout)


# --- Fixture TUI -------------------------------------------------------------
# Runs inside a Herdr pane. It draws a scrollable list on the alternate screen,
# toggles terminal modes with single keys, and logs every input event to JSONL
# so the harness can prove which bytes reached the application.


class Fixture:
    def __init__(self, log_path):
        self.log_path = log_path
        self.logf = open(log_path, "a", buffering=1)
        self.buf = b""
        self.offset = 50
        self.screen = "alt"
        self.mouse = True
        self.altscroll = False
        self.size = (80, 24)
        self.running = True
        self.winched = False
        self.fd = sys.stdin.fileno()

    def log(self, kind, **kw):
        rec = {"t": round(time.time(), 3), "kind": kind}
        rec.update(kw)
        self.logf.write(json.dumps(rec) + "\n")

    def run(self):
        old = termios.tcgetattr(self.fd)
        tty.setraw(self.fd)
        signal.signal(signal.SIGWINCH, lambda *_: setattr(self, "winched", True))
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "running", False))
        try:
            self.refresh_size(log=False)
            self.apply_modes()
            self.render()
            self.log("ready", marker=MARKER, cols=self.size[0], rows=self.size[1])
            while self.running:
                ready, _, _ = select.select([self.fd], [], [], 0.2)
                if self.winched:
                    self.winched = False
                    self.refresh_size(log=True)
                    self.render()
                if ready:
                    data = os.read(self.fd, 4096)
                    if not data:
                        break
                    self.buf += data
                    self.consume()
        finally:
            self.restore()
            termios.tcsetattr(self.fd, termios.TCSADRAIN, old)
        self.log("exit")

    def refresh_size(self, log=True):
        size = os.get_terminal_size(self.fd)
        self.size = (size.columns, size.lines)
        if log:
            self.log("size", cols=size.columns, rows=size.lines)

    def restore(self):
        sys.stdout.write("\x1b[?1000l\x1b[?1003l\x1b[?1006l\x1b[?1007l")
        sys.stdout.write("\x1b[?25h\x1b[?1049l")
        sys.stdout.flush()

    def apply_modes(self):
        out = ["\x1b[?1049h" if self.screen == "alt" else "\x1b[?1049l"]
        if self.mouse:
            out.append("\x1b[?1000h\x1b[?1003h\x1b[?1006h")
        else:
            out.append("\x1b[?1000l\x1b[?1003l\x1b[?1006l")
        out.append("\x1b[?1007h" if self.altscroll else "\x1b[?1007l")
        sys.stdout.write("".join(out))
        sys.stdout.flush()
        self.log("mode", screen=self.screen, mouse=self.mouse,
                 altscroll=self.altscroll)

    def body_rows(self):
        return max(1, self.size[1] - 2)

    def max_offset(self):
        return max(0, DEFAULT_ROWS - self.body_rows())

    def render(self):
        if self.screen != "alt":
            return
        cols, rows = self.size
        body = self.body_rows()
        self.offset = min(self.offset, self.max_offset())
        lines = []
        for i in range(self.offset, self.offset + body):
            head = f"ROW-{i + 1:03d}"
            if i == self.offset:
                head += f" {MARKER}"
            lines.append(head + " proof content " + "~" * max(0, cols - 44))
        status = self.status_line()
        out = ["\x1b[H\x1b[2J"]
        out += [line[:cols] + "\r\n" for line in lines]
        out.append("\x1b[7m" + status[:cols].ljust(cols) + "\x1b[0m")
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def status_line(self):
        cols, rows = self.size
        return (f"{MARKER} screen={self.screen} "
                f"mouse={'on' if self.mouse else 'off'} "
                f"altscroll={'on' if self.altscroll else 'off'} "
                f"size={cols}x{rows} offset={self.offset}")

    def print_main(self):
        out = [f"MAIN-ROW-{i + 1:03d}\r\n" for i in range(DEFAULT_ROWS)]
        out.append(f"{MARKER} screen=main mouse=off altscroll=off\r\n")
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def consume(self):
        while self.buf:
            eaten, ev = self.parse_one(self.buf)
            if eaten == 0:
                return
            self.buf = self.buf[eaten:]
            if ev:
                self.handle(ev)

    def parse_one(self, buf):
        if buf.startswith(b"\x1b[<"):
            for j in range(3, min(len(buf), 48)):
                if buf[j] in b"Mm":
                    m = SGR_MOUSE_RE.match(buf[: j + 1])
                    raw = buf[: j + 1]
                    if m:
                        return j + 1, self.mouse_event(int(m.group(1)),
                                                       int(m.group(2)),
                                                       int(m.group(3)),
                                                       m.group(4) == b"m", raw)
                    return j + 1, {"kind": "unknown", "raw": b64(raw)}
            return (1, None) if len(buf) > 48 else (0, None)
        if buf.startswith(b"\x1b[M") and len(buf) >= 6:
            raw = buf[:6]
            return 6, self.mouse_event(buf[3] - 32, buf[4] - 32, buf[5] - 32,
                                       False, raw)
        if buf.startswith(b"\x1b["):
            for j in range(2, min(len(buf), 64)):
                if 0x40 <= buf[j] <= 0x7E:
                    return j + 1, self.csi_event(buf[: j + 1])
            return (1, None) if len(buf) > 64 else (0, None)
        if buf.startswith(b"\x1bO") and len(buf) >= 3:
            return 3, self.csi_event(buf[:3])
        if buf.startswith(b"\x1b"):
            if len(buf) < 2:
                return 0, None
            return 2, {"kind": "key", "key": "alt-char", "value": chr(buf[1]),
                       "raw": b64(buf[:2])}
        return 1, {"kind": "key", "key": "char", "value": chr(buf[0]),
                   "raw": b64(buf[:1])}

    def mouse_event(self, btn, x, y, release, raw):
        ev = {"x": x, "y": y, "btn": btn, "raw": b64(raw)}
        if btn & 64:
            ev["kind"] = "wheel"
            ev["dir"] = ("up", "down", "left", "right")[btn & 3]
        elif btn & 32:
            ev["kind"] = "mouse"
            ev["action"] = "move" if (btn & 3) == 3 else "drag"
        else:
            ev["kind"] = "mouse"
            ev["action"] = "up" if release else "down"
        return ev

    def csi_event(self, seq):
        if seq[:2] in (b"\x1b[", b"\x1bO") and seq[-1:] in (b"A", b"B"):
            return {"kind": "key", "key": "up" if seq[-1:] == b"A" else "down",
                    "raw": b64(seq)}
        return {"kind": "key", "key": "csi", "value": seq.decode("ascii", "replace"),
                "raw": b64(seq)}

    def handle(self, ev):
        kind = ev.get("kind")
        if kind == "wheel":
            if ev["dir"] == "up":
                self.offset = max(0, self.offset - 1)
            elif ev["dir"] == "down":
                self.offset = min(self.max_offset(), self.offset + 1)
            self.log("wheel", dir=ev["dir"], x=ev["x"], y=ev["y"],
                     offset=self.offset, raw=ev["raw"])
            self.render()
        elif kind == "mouse":
            self.log("mouse", action=ev["action"], x=ev["x"], y=ev["y"],
                     btn=ev["btn"], raw=ev["raw"])
        elif kind == "key":
            self.log("key", key=ev.get("key"), value=ev.get("value"),
                     raw=ev.get("raw"))
            self.toggle(ev.get("value") or "")
        elif kind == "unknown":
            self.log("unknown", raw=ev["raw"])

    def toggle(self, value):
        if value == "m":
            self.mouse = not self.mouse
        elif value == "a":
            self.screen, self.mouse, self.altscroll = "alt", False, True
        elif value == "n":
            self.screen, self.mouse, self.altscroll = "main", False, False
        elif value == "t":
            self.screen = "alt"
        elif value == "q":
            self.running = False
            return
        else:
            return
        self.apply_modes()
        if self.screen == "alt":
            self.render()
        else:
            self.print_main()


# --- Bridge streams ----------------------------------------------------------


class Stream:
    """One herdr terminal-session subprocess speaking JSONL on stdio."""

    def __init__(self, argv):
        self.argv = argv
        self.records = []
        self.stderr = []
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                self.stderr.append(line)
                continue
            self.records.append((time.time(), rec))

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.stderr.append(line.rstrip())

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def frames(self):
        return [rec for _, rec in self.records
                if rec.get("type") == "terminal.frame"]

    def closed_reason(self):
        for _, rec in self.records:
            if rec.get("type") == "terminal.closed":
                return rec.get("reason")
        return None

    def alive(self):
        return self.proc.poll() is None

    def wait_exit(self, timeout=5):
        try:
            self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return False
        return True


# --- Harness -----------------------------------------------------------------


class Harness:
    def __init__(self, args, session, herdr, workdir):
        self.args = args
        self.session = session
        self.herdr = herdr
        self.workdir = workdir
        self.fixture_log = os.path.join(workdir, "fixture-events.jsonl")
        self.results = []
        self.evidence = {}
        self.pane = None
        self.terminal_id = None
        self.fixture = None
        self.observe = None
        self.control = None
        self.server = None

    # -- plumbing --

    def cli(self, *cmd, timeout=20):
        return sh(self.herdr, "--session", self.session, *cmd, timeout=timeout)

    def cli_json(self, *cmd, timeout=20):
        proc = self.cli(*cmd, timeout=timeout)
        line = ""
        for out in proc.stdout.splitlines():
            if out.strip().startswith("{"):
                line = out.strip()
        if not line:
            raise ProofError(f"no JSON from herdr {cmd[0]} {cmd[1]}: "
                             f"{proc.stdout.strip()!r} {proc.stderr.strip()!r}")
        data = json.loads(line)
        if "error" in data:
            err = data["error"]
            raise ProofError(f"herdr {cmd[0]} {cmd[1]}: "
                             f"{err.get('code')}: {err.get('message')}")
        return data.get("result", {})

    def check(self, name, ok, detail, evidence=None):
        self.results.append({"name": name, "ok": ok, "detail": detail})
        if evidence is not None:
            self.evidence[name] = evidence
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    def fixture_events(self):
        if not os.path.exists(self.fixture_log):
            return []
        out = []
        with open(self.fixture_log) as handle:
            for line in handle:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
        return out

    def wait_events(self, count, timeout=6):
        return wait_for(lambda: len(self.fixture_events()) >= count,
                        timeout=timeout)

    def layout_size(self):
        result = self.cli_json("pane", "layout")
        rect = result["layout"]["panes"][0]["rect"]
        return rect["width"], rect["height"]

    def scroll_state(self):
        result = self.cli_json("pane", "get", self.pane)
        return result["pane"]["scroll"]

    # -- steps --

    def step_version(self):
        proc = sh(self.herdr, "--version", timeout=10)
        text = (proc.stdout + proc.stderr).strip()
        digits = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
        ok = bool(digits) and tuple(map(int, digits.groups())) >= (0, 9, 3)
        self.check("herdr_version", ok, text.splitlines()[0] if text else "no output",
                   {"output": text})

    def step_server(self):
        server_log = os.path.join(self.workdir, "server.log")
        self.server = subprocess.Popen(
            [self.herdr, "--session", self.session, "server"],
            stdout=open(server_log, "w"), stderr=subprocess.STDOUT)
        started = wait_for(lambda: "status: running" in sh(
            self.herdr, "--session", self.session, "status", "server",
            timeout=10).stdout, timeout=15)
        self.check("server_start", started, f"session {self.session} running"
                   if started else "server did not start in 15s",
                   {"server_log": server_log})

    def step_workspace(self):
        result = self.cli_json("workspace", "create", "--cwd", self.workdir,
                               "--label", "proof")
        root = result["root_pane"]
        self.pane = root["pane_id"]
        self.terminal_id = root["terminal_id"]
        size = self.layout_size()
        self.check("workspace_create", bool(self.pane),
                   f"pane {self.pane}, terminal {self.terminal_id}, {size[0]}x{size[1]}",
                   {"root_pane": root, "layout": self.cli_json("pane", "layout")})

    def step_fixture(self):
        script = os.path.abspath(__file__)
        command = shlex.join([sys.executable, script, "--tui",
                              "--log", self.fixture_log])
        # pane run prints no JSON; empty output with exit 0 is success.
        ran = self.cli("pane", "run", self.pane, command)
        if ran.returncode != 0:
            raise ProofError(f"pane run failed: {ran.stdout!r} {ran.stderr!r}")
        started = wait_for(lambda: any(
            e.get("kind") == "ready" for e in self.fixture_events()), timeout=20)
        ready = next((e for e in self.fixture_events()
                      if e.get("kind") == "ready"), None)
        self.check("fixture_start", started,
                   f"fixture ready at {ready.get('cols')}x{ready.get('rows')}"
                   if ready else "fixture never logged ready",
                   {"command": command, "ready": ready})

    def step_observe_passive(self):
        mark = len(self.fixture_events())
        self.observe = Stream([self.herdr, "--session", self.session, "terminal",
                               "session", "observe", self.pane,
                               "--cols", "80", "--rows", "24"])
        wait_for(lambda: any(
            MARKER in strip_ansi(base64.b64decode(f.get("bytes", ""))
                                 .decode("utf-8", "replace"))
            for f in self.observe.frames()), timeout=8)
        frames = self.observe.frames()
        shown = None
        for frame in frames:
            text = strip_ansi(base64.b64decode(frame.get("bytes", ""))
                              .decode("utf-8", "replace"))
            if MARKER in text:
                shown = (frame, text)
                break
        seq = [f.get("seq") for f in frames]
        resized = [e for e in self.fixture_events()[mark:]
                   if e.get("kind") == "size"]
        ok = shown is not None
        width = height = encoding = None
        decoded = ""
        if shown:
            frame, decoded = shown
            width, height = frame.get("width"), frame.get("height")
            encoding = frame.get("encoding")
            ok = ok and encoding == "ansi" and (width, height) == (80, 24)
            ok = ok and all(a < b for a, b in zip(seq, seq[1:]))
        # Passive observe must not resize the pane's PTY.
        ok = ok and not resized
        self.check("observe_passive", ok,
                   f"{len(frames)} frame(s), {width}x{height}, encoding={encoding}, "
                   f"marker seen={shown is not None}, pty resize events={len(resized)}",
                   {"seqs": seq, "frame_text": decoded[-300:],
                    "layout": self.cli_json("pane", "layout")})

    def step_control_open(self):
        mark = len(self.fixture_events())
        self.control = Stream([self.herdr, "--session", self.session, "terminal",
                               "session", "control", self.pane,
                               "--cols", "80", "--rows", "24"])
        got = wait_for(lambda: len(self.control.frames()) >= 1, timeout=8)
        # Ground truth for the app is the PTY size the fixture reports; the
        # workspace layout rect may keep its own geometry.
        resized = wait_for(lambda: any(
            e.get("kind") == "size" and (e.get("cols"), e.get("rows")) == (80, 24)
            for e in self.fixture_events()[mark:]), timeout=6)
        self.check("control_open", got and resized,
                   f"frames={len(self.control.frames())}, pty resized to the "
                   f"controller viewport 80x24={resized}",
                   {"layout": self.cli_json("pane", "layout"),
                    "events": self.fixture_events()[mark:]})

    def step_exclusive(self):
        other = Stream([self.herdr, "--session", self.session, "terminal",
                        "session", "control", self.pane,
                        "--cols", "80", "--rows", "24"])
        other.wait_exit(timeout=6)
        detail = (f"exit={other.proc.returncode}, closed={other.closed_reason()}, "
                  f"stderr={other.stderr[-1:] }")
        ok = not other.alive() or other.closed_reason() is not None
        self.check("controller_exclusive", ok, detail,
                   {"records": other.records[-3:], "stderr": other.stderr[-5:]})

    def send_scroll(self, direction, count, column, row):
        for _ in range(count):
            self.control.send({"type": "terminal.scroll", "direction": direction,
                               "lines": 1, "source": "wheel",
                               "column": column, "row": row, "modifiers": 0})

    def step_wheel_mouse(self):
        mark = len(self.fixture_events())
        self.send_scroll("up", 3, 20, 10)
        self.send_scroll("down", 2, 40, 15)
        self.wait_events(mark + 5)
        events = [e for e in self.fixture_events()[mark:]
                  if e.get("kind") == "wheel"]
        ups = [e for e in events if e.get("dir") == "up"]
        downs = [e for e in events if e.get("dir") == "down"]
        offsets = [e.get("offset") for e in events]
        delta = None
        if ups and downs:
            delta = (downs[0]["x"] - ups[0]["x"], downs[0]["y"] - ups[0]["y"])
        ok = (len(ups) == 3 and len(downs) == 2 and delta == (20, 5)
              and offsets == [49, 48, 47, 48, 49])
        self.check("wheel_mouse_report", ok,
                   f"{len(ups)} up + {len(downs)} down at app, offsets={offsets}, "
                   f"cell delta={delta}",
                   {"events": events})

    def step_observe_live(self):
        frames_before = len(self.observe.frames())
        self.send_scroll("up", 2, 20, 10)
        wait_for(lambda: len(self.observe.frames()) > frames_before, timeout=6)
        after = len(self.observe.frames())
        self.check("observe_live_with_control", after > frames_before,
                   f"observer frames {frames_before} -> {after} while control active")

    def send_key(self, text):
        self.control.send({"type": "terminal.input", "text": text})

    def step_wheel_alt(self):
        mark = len(self.fixture_events())
        self.send_key("a")
        wait_for(lambda: any(e.get("kind") == "mode" and e.get("altscroll")
                             for e in self.fixture_events()[mark:]), timeout=6)
        self.send_scroll("up", 2, 20, 10)
        self.wait_events(mark + 3)
        events = self.fixture_events()[mark:]
        keys = [e for e in events if e.get("kind") == "key"
                and e.get("key") in ("up", "down")]
        wheels = [e for e in events if e.get("kind") in ("wheel", "mouse")]
        mode = next((e for e in events if e.get("kind") == "mode"
                     and e.get("altscroll")), None)
        ok = mode is not None and len(keys) == 2 and not wheels
        self.check("wheel_alternate_scroll", ok,
                   f"mode altscroll={bool(mode)}, arrow events={len(keys)}, "
                   f"mouse events={len(wheels)}",
                   {"events": events})

    def step_wheel_host(self):
        mark0 = len(self.fixture_events())
        self.send_key("n")
        wait_for(lambda: any(e.get("kind") == "mode" and e.get("screen") == "main"
                             for e in self.fixture_events()[mark0:]), timeout=6)
        # The toggle keystroke itself arrives at the app; count from here.
        mark = len(self.fixture_events())
        before = self.scroll_state()
        self.send_scroll("up", 5, 20, 10)
        moved = wait_for(
            lambda: self.scroll_state()["offset_from_bottom"] >= 5, timeout=6)
        after = self.scroll_state()
        inputs = [e for e in self.fixture_events()[mark:]
                  if e.get("kind") in ("wheel", "mouse", "key")]
        ok = moved and not inputs
        self.check("wheel_host_scroll", ok,
                   f"app input events={len(inputs)}, scroll offset "
                   f"{before['offset_from_bottom']} -> {after['offset_from_bottom']}",
                   {"before": before, "after": after})

    def step_resize(self):
        mark = len(self.fixture_events())
        self.control.send({"type": "terminal.resize", "cols": 100, "rows": 30,
                           "cell_width_px": 0, "cell_height_px": 0})
        got = wait_for(lambda: any(
            e.get("kind") == "size" and (e.get("cols"), e.get("rows")) == (100, 30)
            for e in self.fixture_events()[mark:]), timeout=6)
        self.check("resize_authority", got,
                   f"fixture size event 100x30={got}",
                   {"events": self.fixture_events()[mark:]})

    def step_release(self):
        self.control.send({"type": "terminal.release"})
        exited = self.control.wait_exit(timeout=6)
        reason = self.control.closed_reason()
        self.check("release_clean", exited and reason == "detached",
                   f"exit={exited}, reason={reason}",
                   {"records": self.control.records[-3:]})

    def cleanup(self, keep):
        if keep:
            print(f"\nKept session {self.session}: pane {self.pane}")
            print("Manual checks:")
            print(f"  {self.herdr} --session {self.session} pane get {self.pane}")
            print(f"  {self.herdr} --session {self.session} terminal session "
                  f"observe {self.pane} --cols 80 --rows 24")
            print(f"  printf '%s\\n' "
                  "'{\"type\":\"terminal.scroll\",\"direction\":\"up\","
                  "\"lines\":3,\"source\":\"wheel\",\"column\":20,\"row\":10}' "
                  "'{\"type\":\"terminal.release\"}' | "
                  f"{self.herdr} --session {self.session} terminal session "
                  f"control {self.pane} --cols 80 --rows 24")
            print(f"  {self.herdr} session stop {self.session}")
            print(f"  {self.herdr} session delete {self.session}")
            return
        if self.observe and self.observe.alive():
            self.observe.proc.terminate()
        if self.control and self.control.alive():
            self.control.proc.terminate()
        sh(self.herdr, "session", "stop", self.session, timeout=30)
        sh(self.herdr, "session", "delete", self.session, timeout=30)
        if self.server and self.server.poll() is None:
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.terminate()
        names = set(session_names())
        leftovers = [line for line in sh("ps", "-eo", "pid,args").stdout.splitlines()
                     if f"--session {self.session}" in line
                     and "herdr-bridge-proof.py" not in line]
        self.check("cleanup", self.session not in names and not leftovers,
                   f"session removed={self.session not in names}, "
                   f"leftover processes={len(leftovers)}",
                   {"leftovers": leftovers})

    def run(self):
        steps = [self.step_version, self.step_server, self.step_workspace,
                 self.step_fixture, self.step_observe_passive,
                 self.step_control_open, self.step_exclusive,
                 self.step_wheel_mouse, self.step_observe_live,
                 self.step_wheel_alt, self.step_wheel_host, self.step_resize,
                 self.step_release]
        try:
            for step in steps:
                try:
                    step()
                except ProofError as err:
                    self.check(step.__name__, False, str(err))
                except Exception as err:  # noqa: BLE001 - report and continue
                    self.check(step.__name__, False, f"{type(err).__name__}: {err}")
        finally:
            try:
                self.cleanup(self.args.keep)
            except Exception as err:  # noqa: BLE001 - report cleanup failures
                self.check("cleanup", False, f"{type(err).__name__}: {err}")
        passed = sum(1 for r in self.results if r["ok"])
        failed = len(self.results) - passed
        results_path = os.path.join(self.workdir, "results.json")
        with open(results_path, "w") as handle:
            json.dump({"session": self.session, "results": self.results,
                       "evidence": self.evidence}, handle, indent=2)
        print(f"\nSummary: {passed} passed, {failed} failed")
        print(f"Evidence: {results_path}")
        return 1 if failed else 0


def wait_for(pred, timeout=5.0, interval=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return False


def session_names():
    proc = sh("herdr", "session", "list", "--json", timeout=15)
    try:
        return {s["name"] for s in json.loads(proc.stdout).get("sessions", [])}
    except ValueError:
        return set()


def run_harness(args):
    if args.session in ("default", ""):
        die("refusing to touch the default herdr session")
    existing = session_names()
    if args.session in existing:
        die(f"session {args.session} already exists; pick another --session name")
    herdr = args.herdr
    workdir = os.path.join("/tmp/opencode", "herdr-bridge-proof")
    os.makedirs(workdir, exist_ok=True)
    log = os.path.join(workdir, "fixture-events.jsonl")
    if os.path.exists(log):
        os.remove(log)
    print(f"Disposable session: {args.session} (existing: {sorted(existing)})")
    return Harness(args, args.session, herdr, workdir).run()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session", default=DEFAULT_SESSION,
                    help="disposable session name to create (never 'default')")
    ap.add_argument("--herdr", default=os.environ.get("HERDR_BIN", "herdr"),
                    help="herdr binary to use")
    ap.add_argument("--keep", action="store_true",
                    help="keep the disposable session running after the proof")
    ap.add_argument("--tui", action="store_true",
                    help="run the fixture TUI instead of the harness")
    ap.add_argument("--log", help="fixture event log path (with --tui)")
    args = ap.parse_args()
    if args.tui:
        if not args.log:
            die("--tui requires --log PATH")
        Fixture(args.log).run()
        return 0
    return run_harness(args)


if __name__ == "__main__":
    sys.exit(main())
