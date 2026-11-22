#!/usr/bin/env python3
"""The timed test of the agent answer from the notification of Flux for Android.

For each run, the script sets the agent of the fake herdr to blocked, waits
for the notification of Flux with actions, taps an action on the emulator,
and reads the time of the send call from the log of the fake herdr. It
prints 1 Markdown row for each run. It reads no logcat.

Start these first, in the namespace of the test fluxd, as the section
"Agent answers end to end" of docs/development.md says: the emulator with
Flux paired to a test fluxd, and fake_herdr.py with the same control file
and log file that this script gets. Then run:

    ANDROID_SERIAL=emulator-5554 python3 android/tools/timed_answer.py \\
        --runs 10 --fake-log SENDS.jsonl --control CONTROL.json

The script stops when ANDROID_SERIAL is not set. It stops when the serial
does not start with emulator-, because it taps the screen. It exits with 1
when a run is slower than --limit seconds, or when a run fails.

The app asks for the phone lock before the first answer, and the unlock then
stays valid for 5 minutes. Answer once by hand before a run that checks the
current app. Use --screen to tap a key of the open agent thread in place of an
action of the notification.

The times use the clock of this computer only. The "tap to herdr" time
starts before the adb command that sends the tap. It includes the start of
the input command on the phone, so it is longer than the time that a finger
needs. The "notification" time is the time from the status change to the
first poll of the notification list that shows the notification. It has the
poll interval as its error.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PACKAGE = "org.omarchy.flux"
CHANNEL = "flux.agents.input"
LIMIT_S = 2.0


def now_ms():
    return int(time.time() * 1000)


# ---------------------------------------------------------------- parsers


def parse_notifications(dump, package=PACKAGE, channel=CHANNEL):
    """Return the notifications of a package and a channel in a dumpsys notification text.

    Each item is a dict with "key", "title", "text", and "actions", the
    number of actions. The text must come from --noredact.
    """
    found = []
    starts = [m.start() for m in re.finditer(r"^\s*NotificationRecord\(", dump, re.M)]
    for i, start in enumerate(starts):
        block = dump[start:starts[i + 1] if i + 1 < len(starts) else len(dump)]
        if f"pkg={package} " not in block or f"channel={channel}" not in block:
            continue
        key = re.search(r"key=(\S+)", block)
        title = re.search(r"android\.title=\w+ \((.*?)\)\s*$", block, re.M)
        text = re.search(r"android\.text=\w+ \((.*?)\)\s*$", block, re.M)
        actions = re.search(r"\bactions=(\d+)", block)
        found.append({
            "key": key.group(1) if key else "",
            "title": title.group(1) if title else "",
            "text": text.group(1) if text else "",
            "actions": int(actions.group(1)) if actions else 0,
        })
    return found


def find_node(xml_text, pattern, button_only=False):
    """Return the center (x, y) of the first node with a text or description that matches.

    pattern is a regular expression. The match ignores the case. It returns
    None when no node matches. When button_only is true, a node counts only
    when its class is a button. The action keys of a notification are
    buttons, and the expanded text of the notification is not.
    """
    end = xml_text.find("</hierarchy>")
    if end >= 0:
        xml_text = xml_text[:end + len("</hierarchy>")]
    start = xml_text.find("<?xml")
    if start > 0:
        xml_text = xml_text[start:]
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None
    rx = re.compile(pattern, re.I)
    for node in root.iter("node"):
        label = node.get("text") or node.get("content-desc") or ""
        if not label or not rx.search(label):
            continue
        if button_only and not (node.get("class") or "").endswith("Button"):
            continue
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            return (x1 + x2) // 2, (y1 + y2) // 2
    return None


def read_log(path):
    """Return the entries of the JSON-lines log of the fake herdr."""
    if not os.path.exists(path):
        return []
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    pass
    return entries


def row(n, taps, notify_s, answer_s, sent, limit):
    """Format 1 Markdown row. A missing time is a dash."""
    fmt = lambda v: "-" if v is None else f"{v:.2f}"
    ok = answer_s is not None and answer_s <= limit and sent != "-"
    return f"| {n} | {taps} | {fmt(notify_s)} | {fmt(answer_s)} | {sent} | {'pass' if ok else 'fail'} |"


HEADER = (
    "| Run | Taps | Status change to notification (s) | Tap to herdr (s) | Sent to herdr | Result |\n"
    "| --- | --- | --- | --- | --- | --- |"
)


# ------------------------------------------------------------------ phone


class Phone:
    def __init__(self, serial):
        self.serial = serial

    def adb(self, *args, timeout=20):
        return subprocess.run(["adb", "-s", self.serial, *args], capture_output=True, text=True, timeout=timeout).stdout

    def notifications(self, channel):
        return parse_notifications(self.adb("shell", "dumpsys", "notification", "--noredact"), channel=channel)

    def ui(self):
        return self.adb("exec-out", "uiautomator", "dump", "/dev/tty")

    def tap(self, x, y):
        self.adb("shell", "input", "tap", str(x), str(y))

    def expand(self):
        self.adb("shell", "cmd", "statusbar", "expand-notifications")

    def collapse(self):
        self.adb("shell", "cmd", "statusbar", "collapse")

    def keyguard_showing(self):
        return "isKeyguardShowing=true" in self.adb("shell", "dumpsys", "window")

    def stay_awake(self, pin):
        """Keep the screen on, and dismiss the lock screen with the PIN when it shows."""
        self.adb("shell", "svc", "power", "stayon", "true")
        self.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
        if pin and self.keyguard_showing():
            self.adb("shell", "input", "swipe", "540", "2000", "540", "600")
            time.sleep(1)
            self.adb("shell", "input", "text", pin)
            self.adb("shell", "input", "keyevent", "KEYCODE_ENTER")
            time.sleep(1)


def set_control(path, **fields):
    """Write the control file of the fake herdr in 1 step."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(fields, f)
    os.replace(tmp, path)


def wait_for(fn, timeout, step=0.1):
    """Call fn until it returns a true value. Return that value, or None after timeout seconds."""
    end = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= end:
            return None
        time.sleep(step)


def run_once(phone, args, n):
    """Run 1 timed run. Return (taps, notify_s, answer_s, sent)."""
    before = len(read_log(args.fake_log))
    scenario = {"scenario": args.scenario} if args.scenario else {}
    set_control(args.control, status="working", **scenario)
    # The old notification must go before the new one counts.
    wait_for(lambda: not phone.notifications(args.channel), args.settle + 5)
    time.sleep(args.settle)

    phone.stay_awake(args.pin)
    t_block = now_ms()
    set_control(args.control, status="blocked", **scenario)
    if args.screen:
        # The action is a node of the screen of the app, for example a key of the dock.
        xy = wait_for(lambda: find_node(phone.ui(), args.action), args.timeout, step=0.2)
        notify_s = (now_ms() - t_block) / 1000
        if not xy:
            return 0, None, None, "-"
    else:
        posted = wait_for(lambda: phone.notifications(args.channel), args.timeout)
        if not posted:
            return 0, None, None, "-"
        notify_s = (now_ms() - t_block) / 1000
        if args.no_tap:
            return 0, notify_s, None, "-"
        phone.expand()
        xy = wait_for(lambda: find_node(phone.ui(), args.action, button_only=True), args.timeout, step=0.3)
        if not xy:
            phone.collapse()
            return 0, notify_s, None, "-"
    t_tap = now_ms()
    phone.tap(*xy)
    sent = wait_for(lambda: read_log(args.fake_log)[before:], args.timeout)
    if not args.screen:
        phone.collapse()
    if not sent:
        return 1, notify_s, None, "-"
    entry = sent[0]
    keys = entry["params"].get("keys")
    what = entry["method"].split(".")[-1] + (":" + ",".join(keys) if keys else "")
    if args.expect and what != args.expect:
        what += f" (expected {args.expect})"
        return 1, notify_s, None, what
    return 1, notify_s, (entry["time_ms"] - t_tap) / 1000, what


def main():
    ap = argparse.ArgumentParser(description="The timed test of the agent answer from the notification.")
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--fake-log", required=True, help="the log file of fake_herdr.py")
    ap.add_argument("--control", required=True, help="the control file of fake_herdr.py")
    ap.add_argument("--scenario", help="a scenario of fake_herdr.py for each run")
    ap.add_argument("--action", default=r"^yes", help="a regular expression for the text of the action to tap (default: ^yes)")
    ap.add_argument("--expect", help="the send that must reach herdr, for example send_keys:1")
    ap.add_argument("--channel", default=CHANNEL, help="the notification channel of the question")
    ap.add_argument("--limit", type=float, default=LIMIT_S, help="the limit of tap to herdr, in seconds")
    ap.add_argument("--timeout", type=float, default=20, help="the wait for each step, in seconds")
    ap.add_argument("--settle", type=float, default=1.5, help="the pause before each run, in seconds")
    ap.add_argument("--no-tap", action="store_true", help="measure only the time to the notification")
    ap.add_argument("--screen", action="store_true",
                    help="tap a node of the open screen of the app, not an action of the notification. The first time is then the time to that node")
    ap.add_argument("--pin", help="the PIN of the emulator, to dismiss the lock screen before each run")
    ap.add_argument("--out", help="also write the rows to this file")
    args = ap.parse_args()

    serial = os.environ.get("ANDROID_SERIAL", "")
    if not serial:
        sys.exit("Set ANDROID_SERIAL to the emulator, for example emulator-5554.")
    if not serial.startswith("emulator-"):
        sys.exit(f"ANDROID_SERIAL is {serial}. This script taps the screen, so it runs only on an emulator.")

    phone = Phone(serial)
    lines = [HEADER]
    print(HEADER, flush=True)
    failed = 0
    for n in range(1, args.runs + 1):
        taps, notify_s, answer_s, sent = run_once(phone, args, n)
        r = row(n, taps, notify_s, answer_s, sent, args.limit)
        if args.no_tap:
            r = r.rsplit("|", 2)[0] + ("| ok |" if notify_s is not None else "| fail |")
            failed += notify_s is None
        else:
            failed += not r.endswith("| pass |")
        lines.append(r)
        print(r, flush=True)
    summary = f"{args.runs - failed} of {args.runs} runs passed."
    if not args.no_tap:
        summary += f" The limit is {args.limit:g} s from the tap to herdr."
    print(summary)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n\n" + summary + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
