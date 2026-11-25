"""Tests for fake_herdr.py and the parsers of timed_answer.py.

Run them from the repository root:

    python3 -m unittest discover -s android/tools -p 'test_*.py'
"""

import json
import os
import socket
import tempfile
import threading
import time
import unittest

import fake_herdr


def call(path, method, params=None):
    """Send 1 request, as the herdr client of fluxd does, and return the reply."""
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5)
        s.connect(path)
        s.sendall((json.dumps({"id": "flux", "method": method, "params": params or {}}) + "\n").encode())
        return json.loads(s.makefile().readline())


class FakeHerdrTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.sock = os.path.join(self.dir.name, "h.sock")
        self.control = os.path.join(self.dir.name, "control.json")
        self.log = os.path.join(self.dir.name, "sends.jsonl")
        self.start("codex3")

    def start(self, scenario, after_send="working"):
        server, stop = fake_herdr.make_server(self.sock, scenario, self.control, self.log, after_send)
        threading.Thread(target=server.serve_forever, daemon=True).start()

        def end():
            stop.set()
            server.shutdown()
            server.server_close()

        self.addCleanup(end)
        self.server = server

    def set_control(self, **fields):
        tmp = self.control + ".tmp"
        with open(tmp, "w") as f:
            json.dump(fields, f)
        os.replace(tmp, self.control)

    def wait_status(self, want):
        for _ in range(100):
            snap = call(self.sock, "session.snapshot")["result"]["snapshot"]
            if snap["agents"][0]["agent_status"] == want:
                return snap
            time.sleep(0.02)
        self.fail(f"the status did not become {want}")

    def wait_read(self, text):
        for _ in range(100):
            if text in self.read():
                return
            time.sleep(0.02)
        self.fail(f"the screen never showed {text!r}")

    def read(self, ansi=False, lines=100):
        params = {"target": "w1:p1", "source": "recent_unwrapped", "lines": lines}
        if ansi:
            params.update({"format": "ansi", "strip_ansi": False})
        return call(self.sock, "agent.read", params)["result"]["read"]["text"]

    def sends(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def test_ping(self):
        r = call(self.sock, "ping")["result"]
        self.assertEqual((r["protocol"], r["version"]), (22, "0.9.1"))

    def test_snapshot_has_one_idle_agent(self):
        snap = call(self.sock, "session.snapshot")["result"]["snapshot"]
        self.assertEqual(snap["protocol"], 22)
        self.assertEqual([a["pane_id"] for a in snap["agents"]], ["w1:p1"])
        self.assertEqual(snap["agents"][0]["agent"], "codex")
        self.assertEqual(snap["agents"][0]["agent_status"], "idle")
        self.assertEqual([p["pane_id"] for p in snap["panes"]], ["w1:p1"])

    def test_agent_get_and_unknown_pane(self):
        self.assertEqual(call(self.sock, "agent.get", {"target": "w1:p1"})["result"]["agent"]["agent"], "codex")
        self.assertEqual(call(self.sock, "agent.get", {"target": "w9:p1"})["error"]["code"], "agent_not_found")
        self.assertEqual(call(self.sock, "nothing")["error"]["code"], "unknown_method")

    def test_read_for_each_scenario(self):
        want = {
            "codex3": ("codex", "Would you like to run the following command?", ["1. Yes, proceed", "2. Yes, and", "3. No, and tell"]),
            "freetext": ("claude", "What port should the server use?", []),
            "choices4": ("claude", "Which database should the project use?", ["1. SQLite", "2. PostgreSQL", "3. MySQL", "4. Another"]),
            "opencode": ("opencode", "Permission required", ["Allow once", "Allow always", "Reject"]),
        }
        for name, (kind, question, choices) in want.items():
            with self.subTest(name):
                self.set_control(scenario=name, status="blocked")
                self.wait_read(question)
                snap = self.wait_status("blocked")
                self.assertEqual(snap["agents"][0]["agent"], kind)
                plain = self.read()
                self.assertIn(question, plain)
                for c in choices:
                    self.assertIn(c, plain)
                self.assertNotIn("\x1b", plain)
                self.assertIn("\x1b[", self.read(ansi=True))
                self.assertEqual(fake_herdr.ANSI.sub("", self.read(ansi=True)), plain)
        # A scenario with no choices has no numbered line.
        self.set_control(scenario="freetext", status="blocked")
        self.wait_read("What port")
        self.assertNotRegex(self.read(), r"(?m)^\W*\d\. ")

    def test_read_follows_the_status(self):
        self.assertIn("Ask Codex", self.read())
        self.set_control(status="working")
        self.wait_status("working")
        self.assertIn("Working", self.read())

    def test_read_limits_the_lines(self):
        self.set_control(status="blocked")
        self.wait_status("blocked")
        self.assertEqual(len(self.read(lines=3).split("\n")), 3)

    def test_question_changes_the_dialog(self):
        self.set_control(status="blocked", question="Run the other command?")
        self.wait_read("Run the other command?")
        self.set_control(status="blocked", question=None)
        self.wait_read("Would you like to run")

    def test_status_change_sends_an_event(self):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5)
            s.connect(self.sock)
            s.sendall((json.dumps({"id": "flux", "method": "events.subscribe",
                                   "params": {"subscriptions": [{"type": "pane.agent_status_changed", "pane_id": "w1:p1"}]}}) + "\n").encode())
            f = s.makefile()
            self.assertEqual(json.loads(f.readline())["result"]["type"], "subscription_started")
            self.set_control(status="blocked")
            ev = json.loads(f.readline())
            self.assertEqual(ev["event"], "pane_agent_status_changed")
            self.assertEqual(ev["data"], {"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "blocked"})

    def test_send_keys_is_logged_with_the_time(self):
        self.set_control(status="blocked")
        self.wait_status("blocked")
        before = int(time.time() * 1000)
        self.assertEqual(call(self.sock, "agent.send_keys", {"target": "w1:p1", "keys": ["2"]})["result"]["type"], "ok")
        after = int(time.time() * 1000)
        (entry,) = self.sends()
        self.assertEqual(entry["method"], "agent.send_keys")
        self.assertEqual(entry["params"], {"target": "w1:p1", "keys": ["2"]})
        self.assertEqual(entry["result"], "ok")
        self.assertTrue(before <= entry["time_ms"] <= after)
        # The agent resumes after an answer.
        self.wait_status("working")

    def test_keep_leaves_the_status(self):
        self.server.state.after_send = "keep"
        self.set_control(status="blocked")
        self.wait_status("blocked")
        call(self.sock, "agent.send_keys", {"target": "w1:p1", "keys": ["1"]})
        time.sleep(0.2)
        self.wait_status("blocked")

    def test_prompt_to_a_blocked_agent_is_refused_and_logged(self):
        self.set_control(status="blocked")
        self.wait_status("blocked")
        r = call(self.sock, "agent.prompt", {"target": "w1:p1", "text": "hello"})
        self.assertEqual(r["error"]["code"], "agent_blocked")
        (entry,) = self.sends()
        self.assertEqual((entry["method"], entry["result"]), ("agent.prompt", "agent_blocked"))
        self.wait_status("blocked")

    def test_prompt_to_an_idle_agent_and_send_input(self):
        self.assertEqual(call(self.sock, "agent.prompt", {"target": "w1:p1", "text": "hello"})["result"]["type"], "ok")
        self.assertEqual(call(self.sock, "pane.send_input", {"pane_id": "w1:p1", "text": "8080", "keys": ["enter"]})["result"]["type"], "ok")
        self.assertEqual([s["method"] for s in self.sends()], ["agent.prompt", "pane.send_input"])

    def test_send_to_an_unknown_pane_is_not_logged(self):
        r = call(self.sock, "agent.send_keys", {"target": "w9:p1", "keys": ["1"]})
        self.assertEqual(r["error"]["code"], "agent_not_found")
        self.assertEqual(self.sends(), [])

    def test_pane_close_removes_the_agent(self):
        call(self.sock, "pane.close", {"pane_id": "w1:p1"})
        snap = call(self.sock, "session.snapshot")["result"]["snapshot"]
        self.assertEqual((snap["agents"], snap["panes"]), ([], []))

    def test_a_long_socket_path_is_refused(self):
        with self.assertRaises(ValueError):
            fake_herdr.make_server("/" + "a" * 120, "codex3", self.control, self.log)


if __name__ == "__main__":
    unittest.main()
