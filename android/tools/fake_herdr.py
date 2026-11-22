#!/usr/bin/env python3
"""A fake herdr server for tests of Flux.

The fake listens on a Unix socket and speaks the herdr API of protocol 22,
as the fake server in internal/herdr/herdr_test.go does. It has 1 agent in
the pane w1:p1. The agent shows a fixed dialog, and a control file changes
its status and its question at the time that the test picks.

Run it:

    python3 android/tools/fake_herdr.py --socket SOCKET --scenario codex3 \\
        --control CONTROL.json --log SENDS.jsonl

The methods are ping, session.snapshot, events.subscribe, agent.get,
agent.read, pane.read, server.agent_manifests, agent.send_keys, agent.prompt,
pane.send_input, and pane.close. Each send call goes to the log, 1 JSON
object for each line, with the host time in milliseconds in "time_ms".

Scenarios:

    codex3     a codex dialog with 3 numbered choices
    freetext   a question that needs free text and has no choices
    choices4   a dialog with 4 numbered choices
    opencode   an opencode menu row, with arrow keys

The control file is a JSON object. The fake reads it every 50 ms. It
accepts these fields, and each one is optional:

    status     idle, working, blocked, or done
    scenario   a scenario name
    question   the question line of the dialog

A change of the status sends a pane_agent_status_changed event to each
subscription. A change of the scenario or the question sends the same
event, because the output of the agent changed.

With --after-send working, which is the default, a send call to a blocked
agent sets the status to working, as a real agent does after an answer.
With --after-send keep, the status stays.

The fake needs only Python 3. It never connects to another herdr. Keep the
socket path under 108 bytes. A test fluxd that runs in a user namespace
must find the fake in the same namespace, because herdr peers are checked
by user id.
"""

import argparse
import json
import os
import re
import socketserver
import sys
import threading
import time

VERSION = "0.9.1"
PROTOCOL = 22
PANE = "w1:p1"
WORKSPACE = "w1"
TAB = "w1:t1"
CWD = "/srv/fake/billing"
STATUSES = ("idle", "working", "blocked", "done")
SEND_METHODS = ("agent.send_keys", "agent.prompt", "pane.send_input")

ESC = "\x1b"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def sgr(code, text):
    return f"{ESC}[{code}m{text}{ESC}[0m"


def codex3(question):
    return "\n".join([
        "• I will apply the migration now.",
        "",
        f"  {question}",
        "",
        "  $ bin/migrate --apply",
        "",
        sgr("38;5;6", "› 1. Yes, proceed (y)"),
        "  2. Yes, and don't ask again for this command (a)",
        "  3. No, and tell Codex what to do differently " + sgr("38;5;8", "(esc)"),
        "",
    ])


def freetext(question):
    return "\n".join([
        sgr("38;2;215;119;87", "●") + " I need one detail before I change the config.",
        "",
        sgr("38;5;4", "─" * 60),
        f" {question}",
        "",
        " Type the answer and press Enter.",
        "",
        "❯ ",
        "",
    ])


def choices4(question):
    return "\n".join([
        sgr("38;2;215;119;87", "●") + " The project has no database yet.",
        "",
        sgr("38;5;4", "─" * 60),
        f" {question}",
        sgr("38;5;4", " ❯ 1. SQLite"),
        "   2. PostgreSQL",
        "   3. MySQL",
        "   4. Another database " + sgr("38;5;8", "(type it)"),
        "",
    ])


def opencode(question):
    bar = sgr("38;2;240;198;116;48;2;43;46;49", "┃")
    gray, accent = "48;2;50;53;57", "48;2;240;198;116"
    row = (
        bar + f"{ESC}[{gray}m  {ESC}[{accent}m {ESC}[38;2;29;31;33;{accent}mAllow once{ESC}[{accent}m {ESC}[0m"
        + f"{ESC}[{gray}m  {ESC}[38;2;169;169;169;{gray}mAllow always{ESC}[{gray}m   "
        + f"{ESC}[38;2;169;169;169;{gray}mReject"
        + f"{ESC}[{gray}m  {ESC}[38;2;197;200;198;{gray}mctrl+f {ESC}[38;2;169;169;169;{gray}mfullscreen"
        + f"{ESC}[{gray}m  {ESC}[38;2;197;200;198;{gray}m⇆ {ESC}[38;2;169;169;169;{gray}mselect{ESC}[0m"
    )
    return "\n".join([
        "   $ node invoice.test.js",
        "   ▣  Build · Big Pickle",
        "┃",
        f"┃  △ {question}",
        "┃    # Shell command",
        "┃",
        "┃  $ node invoice.test.js",
        "┃",
        "┃",
        row,
        "┃",
        "",
    ])


# Each scenario has the agent kind, the default question, and the screen
# of a blocked agent.
SCENARIOS = {
    "codex3": ("codex", "Would you like to run the following command?", codex3),
    "freetext": ("claude", "What port should the server use?", freetext),
    "choices4": ("claude", "Which database should the project use?", choices4),
    "opencode": ("opencode", "Permission required", opencode),
}

IDLE = {
    "codex": "• Done. The migration is applied.\n\n› Ask Codex to do anything\n",
    "claude": "● Done. The config is changed.\n\n❯ \n",
    "opencode": "   Done. The test passes.\n\n   ▣  Build · Big Pickle · 4.1s\n\n┃\n┃  Build · Big Pickle OpenCode Zen\n",
}
WORKING = {
    "codex": "• I will apply the migration now.\n\n• Working (3s • esc to interrupt)\n\n› Ask Codex to do anything\n",
    "claude": "● I am changing the config.\n\n✻ Working… (3s · esc to interrupt)\n\n❯ \n",
    "opencode": "   $ node invoice.test.js\n   ▣  Build · Big Pickle\n\n┃\n┃  Build · Big Pickle OpenCode Zen\n",
}


class State:
    """The shared state of the fake. All access goes through the lock."""

    def __init__(self, scenario, log_path, after_send):
        self.lock = threading.Lock()
        self.scenario = scenario
        self.question = None
        self.status = "idle"
        self.closed = False
        self.after_send = after_send
        self.log_path = log_path
        self.subscribers = []

    def kind(self):
        return SCENARIOS[self.scenario][0]

    def screen(self):
        kind, default, build = SCENARIOS[self.scenario]
        if self.status == "blocked":
            return build(self.question or default)
        if self.status == "working":
            return WORKING[kind]
        return IDLE[kind]

    def agent(self):
        return {
            "pane_id": PANE, "workspace_id": WORKSPACE, "agent": self.kind(),
            "agent_status": self.status, "cwd": CWD, "foreground_cwd": CWD,
            "terminal_title_stripped": "billing",
        }

    def snapshot(self):
        panes, agents = [], []
        if not self.closed:
            panes = [{"pane_id": PANE, "workspace_id": WORKSPACE, "tab_id": TAB, "cwd": CWD,
                      "terminal_title_stripped": "billing"}]
            agents = [self.agent()]
        return {
            "version": VERSION, "protocol": PROTOCOL,
            "workspaces": [{"workspace_id": WORKSPACE, "label": "billing", "number": 1, "active_tab_id": TAB}],
            "tabs": [{"tab_id": TAB, "workspace_id": WORKSPACE, "label": "1", "number": 1}],
            "panes": panes, "agents": agents,
        }

    def log_send(self, method, params, result):
        entry = {"time_ms": int(time.time() * 1000), "method": method, "params": params, "result": result}
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
            f.flush()

    def emit(self, name, data):
        """Send an event to each subscription. The caller holds the lock."""
        line = (json.dumps({"event": name, "data": data}) + "\n").encode()
        for conn in list(self.subscribers):
            try:
                conn.sendall(line)
            except OSError:
                self.subscribers.remove(conn)

    def changed(self):
        self.emit("pane_agent_status_changed", {"pane_id": PANE, "workspace_id": WORKSPACE, "agent_status": self.status})

    def apply_control(self, ctl):
        """Apply the fields of the control file. Return nothing."""
        with self.lock:
            before = (self.status, self.scenario, self.question)
            if ctl.get("scenario") in SCENARIOS:
                self.scenario = ctl["scenario"]
            if ctl.get("status") in STATUSES:
                self.status = ctl["status"]
            if "question" in ctl and (ctl["question"] is None or isinstance(ctl["question"], str)):
                self.question = ctl["question"]
            if before != (self.status, self.scenario, self.question):
                self.changed()


def ok(result=None):
    return {"id": "flux", "result": result if result is not None else {"type": "ok"}}


def err(code, message):
    return {"id": "flux", "error": {"code": code, "message": message}}


def tail(text, lines):
    if not isinstance(lines, int) or lines <= 0:
        return text
    rows = text.split("\n")
    return "\n".join(rows[-lines:])


def answer(state, method, params):
    """Return the reply for 1 request. A subscription is handled by the caller."""
    target = params.get("target") or params.get("pane_id")
    with state.lock:
        if method == "ping":
            return ok({"type": "pong", "version": VERSION, "protocol": PROTOCOL})
        if method == "session.snapshot":
            return ok({"type": "session_snapshot", "snapshot": state.snapshot()})
        if method == "events.subscribe":
            return ok({"type": "subscription_started"})
        if method == "server.agent_manifests":
            return ok({"type": "agent_manifest_status",
                       "manifests": [{"agent": "claude"}, {"agent": "codex"}, {"agent": "opencode"}]})
        if method in ("agent.get", "agent.read", "pane.read") or method in SEND_METHODS or method == "pane.close":
            if target != PANE or state.closed:
                return err("agent_not_found", f"agent target {target} not found")
        if method == "agent.get":
            return ok({"type": "agent_info", "agent": state.agent()})
        if method in ("agent.read", "pane.read"):
            text = state.screen()
            if params.get("format") != "ansi" or params.get("strip_ansi", True):
                text = ANSI.sub("", text)
            return ok({"type": "pane_read", "read": {"pane_id": PANE, "text": tail(text, params.get("lines")),
                                                       "truncated": False}})
        if method == "pane.close":
            state.closed = True
            state.emit("pane_closed", {"pane_id": PANE})
            return ok()
        if method in SEND_METHODS:
            # herdr refuses a prompt to an agent that waits for a choice.
            if method == "agent.prompt" and state.status == "blocked":
                reply = err("agent_blocked", "the agent waits for an answer")
                state.log_send(method, params, "agent_blocked")
                return reply
            state.log_send(method, params, "ok")
            if state.status == "blocked" and state.after_send == "working":
                state.status = "working"
                state.changed()
            return ok()
    return err("unknown_method", f"unknown method {method}")


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        state = self.server.state
        for raw in self.rfile:
            try:
                req = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(req, dict):
                continue
            method = req.get("method", "")
            params = req.get("params") if isinstance(req.get("params"), dict) else {}
            reply = answer(state, method, params)
            self.connection.sendall((json.dumps(reply) + "\n").encode())
            if method == "events.subscribe" and "result" in reply:
                with state.lock:
                    state.subscribers.append(self.connection)
        with state.lock:
            if self.connection in state.subscribers:
                state.subscribers.remove(self.connection)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def watch_control(state, path, stop):
    """Read the control file every 50 ms and apply a change."""
    last = None
    while not stop.is_set():
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
            if text != last:
                last = text
                ctl = json.loads(text)
                if isinstance(ctl, dict):
                    state.apply_control(ctl)
        except (OSError, ValueError):
            pass
        stop.wait(0.05)


def make_server(socket_path, scenario, control, log, after_send="working"):
    """Create the server and the control thread. Return (server, stop event)."""
    if len(socket_path.encode()) >= 108:
        raise ValueError("the socket path is 108 bytes or longer")
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    os.makedirs(os.path.dirname(os.path.abspath(socket_path)), exist_ok=True)
    state = State(scenario, log, after_send)
    server = Server(socket_path, Handler)
    server.state = state
    stop = threading.Event()
    threading.Thread(target=watch_control, args=(state, control, stop), daemon=True).start()
    return server, stop


def main():
    ap = argparse.ArgumentParser(description="A fake herdr server for tests of Flux.")
    ap.add_argument("--socket", required=True, help="the Unix socket to listen on, under 108 bytes")
    ap.add_argument("--scenario", default="codex3", choices=sorted(SCENARIOS))
    ap.add_argument("--control", required=True, help="the JSON control file that the test writes")
    ap.add_argument("--log", required=True, help="the JSON-lines log of the send calls")
    ap.add_argument("--after-send", default="working", choices=("working", "keep"))
    args = ap.parse_args()
    server, stop = make_server(args.socket, args.scenario, args.control, args.log, args.after_send)
    print(f"fake herdr: listening on {args.socket}, scenario {args.scenario}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()
        if os.path.exists(args.socket):
            os.unlink(args.socket)


if __name__ == "__main__":
    sys.exit(main())
