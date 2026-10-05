#!/usr/bin/env python3
"""Measure how one herdr pane answers a regular sequence of wheel steps.

This isolates the herdr terminal-session bridge from Flux. It drives the same
`herdr terminal session control` stream that fluxd uses, and reads the fixture
TUI's own log of every input event. For each scenario it reports how many steps
the application received, how long each one took to arrive, and how regularly
the frames came back on the bridge.

It measures wheel delivery and frame cadence with the local fixture. It does not
measure OpenCode, Flux's phone round trip, or the perceived smoothness on a phone.

Examples:
  python3 scripts/herdr-scroll-latency.py
  python3 scripts/herdr-scroll-latency.py --count 120 --keep

Only the disposable session created by this run is touched; the default session
is never used. Evidence lands in /tmp/opencode/herdr-scroll-latency/.
"""

import argparse
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_proof():
    """Load the bridge-proof harness to reuse its fixture and its stream."""
    path = os.path.join(HERE, "herdr-bridge-proof.py")
    spec = importlib.util.spec_from_file_location("herdr_bridge_proof", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proof = load_proof()


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(q / 100.0 * (len(ordered) - 1))))
    return ordered[index]


def stats(values):
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "min": round(min(values), 2),
        "p50": round(percentile(values, 50), 2),
        "p95": round(percentile(values, 95), 2),
        "max": round(max(values), 2),
        "mean": round(sum(values) / len(values), 2),
    }


class LatencyRun:
    def __init__(self, args, session, herdr, workdir):
        self.args = args
        self.session = session
        self.herdr = herdr
        self.workdir = workdir
        self.fixture_log = os.path.join(workdir, "fixture-events.jsonl")
        self.pane = None
        self.server = None
        self.control = None
        self.report = {"session": session, "scenarios": {}, "frames": {}}

    def cli(self, *cmd, timeout=30):
        return proof.sh(self.herdr, "--session", self.session, *cmd, timeout=timeout)

    def cli_json(self, *cmd, timeout=30):
        proc = self.cli(*cmd, timeout=timeout)
        line = ""
        for out in proc.stdout.splitlines():
            if out.strip().startswith("{"):
                line = out.strip()
        if not line:
            raise RuntimeError(f"no JSON from herdr {cmd[0]}: {proc.stdout!r}")
        data = json.loads(line)
        if "error" in data:
            raise RuntimeError(f"herdr {cmd[0]}: {data['error']}")
        return data.get("result", {})

    def fixture_events(self):
        if not os.path.exists(self.fixture_log):
            return []
        events = []
        with open(self.fixture_log) as handle:
            for line in handle:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass
        return events

    def setup(self):
        server_log = os.path.join(self.workdir, "server.log")
        self.server = proof.subprocess.Popen(
            [self.herdr, "--session", self.session, "server"],
            stdout=open(server_log, "w"), stderr=proof.subprocess.STDOUT)
        started = proof.wait_for(lambda: "status: running" in proof.sh(
            self.herdr, "--session", self.session, "status", "server",
            timeout=10).stdout, timeout=15)
        if not started:
            raise RuntimeError("the disposable server did not start in 15s")
        result = self.cli_json("workspace", "create", "--cwd", self.workdir,
                               "--label", "latency")
        self.pane = result["root_pane"]["pane_id"]
        script = os.path.abspath(os.path.join(HERE, "herdr-bridge-proof.py"))
        command = proof.shlex.join([sys.executable, script, "--tui",
                                    "--log", self.fixture_log])
        ran = self.cli("pane", "run", self.pane, command)
        if ran.returncode != 0:
            raise RuntimeError(f"pane run failed: {ran.stdout!r} {ran.stderr!r}")
        ready = proof.wait_for(lambda: any(
            e.get("kind") == "ready" for e in self.fixture_events()), timeout=20)
        if not ready:
            raise RuntimeError("the fixture never logged ready")
        self.control = proof.Stream([self.herdr, "--session", self.session,
                                     "terminal", "session", "control", self.pane,
                                     "--cols", "80", "--rows", "24"])
        if not proof.wait_for(lambda: len(self.control.frames()) >= 1, timeout=8):
            raise RuntimeError("the control stream produced no frame")

    def drain(self, quiet=0.4, timeout=8.0):
        last = len(self.control.records)
        stable = time.time()
        deadline = time.time() + timeout
        while time.time() < deadline:
            time.sleep(0.05)
            count = len(self.control.records)
            if count != last:
                last = count
                stable = time.time()
            elif time.time() - stable > quiet:
                return

    def send(self, direction):
        self.control.send({"type": "terminal.scroll", "direction": direction,
                           "lines": 1, "source": "wheel",
                           "column": 20, "row": 10, "modifiers": 0})

    def measure(self, name, count, interval):
        # Start from a known offset: herdr clamps the fixture at 0.
        for _ in range(250):
            self.send("up")
        self.drain(quiet=0.3)
        offset_before = self.cli_json("pane", "get", self.pane)["pane"]["scroll"]
        mark_events = len(self.fixture_events())
        mark_records = len(self.control.records)
        sends = []
        start = time.time()
        for i in range(count):
            target = start + i * interval
            wait = target - time.time()
            if wait > 0:
                time.sleep(wait)
            sends.append(time.time())
            self.send("down")
        self.drain()
        events = [e for e in self.fixture_events()[mark_events:]
                  if e.get("kind") == "wheel"]
        records = self.control.records[mark_records:]
        frames = [rec for _, rec in records if rec.get("type") == "terminal.frame"]
        frame_times = [t for t, rec in records if rec.get("type") == "terminal.frame"]
        offset_after = self.cli_json("pane", "get", self.pane)["pane"]["scroll"]
        # Pair each application event with the step that produced it.
        arrivals = [e["t"] for e in events]
        delivery = [arrivals[i] - sends[i] for i in range(min(len(arrivals), len(sends)))]
        offsets = [e.get("offset") for e in events]
        gaps = [1000.0 * (frame_times[i + 1] - frame_times[i])
                for i in range(len(frame_times) - 1)]
        last_send = sends[-1] if sends else 0.0
        scenario = {
            "count": count,
            "interval_ms": round(interval * 1000.0, 2),
            "commanded_ms": round(1000.0 * (sends[-1] - sends[0]), 2) if sends else 0.0,
            "received": len(events),
            "delivery_ms": stats([1000.0 * d for d in delivery]),
            "first_event_after_first_send_ms": round(1000.0 * (arrivals[0] - sends[0]), 2)
            if arrivals and sends else None,
            "last_event_after_last_send_ms": round(1000.0 * (arrivals[-1] - last_send), 2)
            if arrivals and sends else None,
            "frames": len(frames),
            "frame_bytes": sum(len(f.get("bytes", "")) for f in frames),
            "frame_gap_ms": stats(gaps),
            "first_frame_after_first_send_ms": round(1000.0 * (frame_times[0] - sends[0]), 2)
            if frame_times and sends else None,
            "last_frame_after_last_send_ms": round(1000.0 * (frame_times[-1] - last_send), 2)
            if frame_times and sends else None,
            "offset_before": offset_before.get("offset_from_bottom"),
            "offset_after": offset_after.get("offset_from_bottom"),
            "offset_first": offsets[0] if offsets else None,
            "offset_last": offsets[-1] if offsets else None,
            "clamped": len(set(offsets)) < len(offsets),
        }
        self.report["scenarios"][name] = scenario
        print_scenario(name, scenario)

    def cleanup(self):
        if self.control and self.control.alive():
            self.control.proc.terminate()
            if not self.control.wait_exit():
                self.control.proc.kill()
                self.control.proc.wait(timeout=5)
        if self.args.keep:
            print(f"\nKept session {self.session}: pane {self.pane}")
            print(f"  {self.herdr} --session {self.session} pane get {self.pane}")
            print(f"  {self.herdr} session stop {self.session}")
            return
        proof.sh(self.herdr, "session", "stop", self.session, timeout=30)
        proof.sh(self.herdr, "session", "delete", self.session, timeout=30)
        if self.server and self.server.poll() is None:
            try:
                self.server.wait(timeout=5)
            except proof.subprocess.TimeoutExpired:
                self.server.terminate()

    def run(self):
        try:
            self.setup()
            self.measure("steady_100_per_s", self.args.count, 0.010)
            self.measure("steady_60_per_s", self.args.count, 1.0 / 60.0)
            self.measure("burst", self.args.count, 0.0)
        finally:
            self.cleanup()
        path = os.path.join(self.workdir, "latency.json")
        with open(path, "w") as handle:
            json.dump(self.report, handle, indent=2)
        print(f"\nEvidence: {path}")
        print_free(self.report)
        return 0


def print_scenario(name, s):
    d = s["delivery_ms"]
    g = s["frame_gap_ms"]
    print(f"\n== {name} ==")
    print(f"  steps sent {s['count']}, received by the app {s['received']}, "
          f"commanded {s['commanded_ms']} ms")
    print(f"  delivery to the app: p50={d.get('p50')} p95={d.get('p95')} "
          f"max={d.get('max')} ms")
    print(f"  last step -> last app event: {s['last_event_after_last_send_ms']} ms")
    print(f"  frames {s['frames']} ({s['frame_bytes']} B), gap p50={g.get('p50')} "
          f"p95={g.get('p95')} max={g.get('max')} ms")
    print(f"  last step -> last frame: {s['last_frame_after_last_send_ms']} ms")
    print(f"  offset {s['offset_before']} -> {s['offset_after']} "
          f"(first {s['offset_first']}, last {s['offset_last']}, clamped={s['clamped']})")


def print_free(report):
    print("\nRead it like this:")
    print("  delivery p95 high  -> herdr/the app is slow to receive wheel input")
    print("  frame gaps bursty  -> the redraw arrives in bursts, so Flux cannot be smooth")
    print("  everything small   -> the local fixture path is fast; OpenCode/Flux remain unmeasured")


def run(args):
    if args.session in ("default", ""):
        proof.die("refusing to touch the default herdr session")
    existing = proof.session_names()
    if args.session in existing:
        proof.die(f"session {args.session} already exists; pick another --session name")
    workdir = os.path.join("/tmp/opencode", "herdr-scroll-latency")
    os.makedirs(workdir, exist_ok=True)
    log = os.path.join(workdir, "fixture-events.jsonl")
    if os.path.exists(log):
        os.remove(log)
    print(f"Disposable session: {args.session} (existing: {sorted(existing)})")
    return LatencyRun(args, args.session, args.herdr, workdir).run()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session", default="flux-scroll-latency",
                    help="disposable session name to create (never 'default')")
    ap.add_argument("--herdr", default=os.environ.get("HERDR_BIN", "herdr"),
                    help="herdr binary to use")
    ap.add_argument("--count", type=int, default=100,
                    help="wheel steps per scenario")
    ap.add_argument("--keep", action="store_true",
                    help="keep the disposable session after the run")
    args = ap.parse_args()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
