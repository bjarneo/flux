"""Tests for the parsers and the checks of timed_answer.py."""

import os
import tempfile
import unittest
from unittest import mock

import timed_answer

DUMP = """\
Current Notification Manager state:
  Notification List:
    NotificationRecord(0x01: pkg=org.omarchy.flux user=UserHandle{0} id=7 tag=null importance=4 key=0|org.omarchy.flux|7|null|10200: Notification(channel=flux.agents.input shortcut=null defaults=0x0 flags=0x0 color=0x0 actions=3 vis=PRIVATE))
      uid=10200 userId=0
      extras={
        android.title=String (codex in billing needs input)
        android.text=String (Would you like to run the following command?)
      }
    NotificationRecord(0x02: pkg=org.omarchy.flux user=UserHandle{0} id=8 tag=null importance=1 key=0|org.omarchy.flux|8|null|10200: Notification(channel=flux.service shortcut=null defaults=0x0 flags=0x62 color=0x0 vis=PRIVATE))
      extras={
        android.title=String (Flux)
      }
    NotificationRecord(0x03: pkg=com.other user=UserHandle{0} id=9 tag=null importance=4 key=0|com.other|9|null|10300: Notification(channel=flux.agents.input shortcut=null actions=2 vis=PRIVATE))
"""

UI = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node text="codex in billing needs input" bounds="[40,300][1040,360]" />
  <node text="Yes, proceed" class="android.widget.Button" bounds="[40,500][340,580]" />
  <node text="" content-desc="No, and tell Codex" bounds="[360,500][660,580]" />
</hierarchy>
UI hierarchy dumped to: /dev/stdout
"""


class ParserTest(unittest.TestCase):
    def test_notifications_match_package_and_channel(self):
        (n,) = timed_answer.parse_notifications(DUMP)
        self.assertEqual(n["key"], "0|org.omarchy.flux|7|null|10200:")
        self.assertEqual(n["title"], "codex in billing needs input")
        self.assertEqual(n["text"], "Would you like to run the following command?")
        self.assertEqual(n["actions"], 3)

    def test_no_notification(self):
        self.assertEqual(timed_answer.parse_notifications(""), [])
        self.assertEqual(timed_answer.parse_notifications(DUMP, channel="flux.nothing"), [])

    def test_find_node_gives_the_center(self):
        self.assertEqual(timed_answer.find_node(UI, "yes"), (190, 540))
        self.assertEqual(timed_answer.find_node(UI, "tell codex"), (510, 540))
        self.assertIsNone(timed_answer.find_node(UI, "reject"))
        self.assertIsNone(timed_answer.find_node("not xml", "yes"))

    def test_row(self):
        self.assertEqual(timed_answer.row(1, 1, 0.5, 1.234, "send_keys:1", 2.0), "| 1 | 1 | 0.50 | 1.23 | send_keys:1 | pass |")
        self.assertTrue(timed_answer.row(2, 1, 0.5, 2.5, "send_keys:1", 2.0).endswith("| fail |"))
        self.assertEqual(timed_answer.row(3, 0, None, None, "-", 2.0), "| 3 | 0 | - | - | - | fail |")

    def test_read_log_skips_bad_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "l.jsonl")
            self.assertEqual(timed_answer.read_log(p), [])
            with open(p, "w") as f:
                f.write('{"time_ms": 1}\nnot json\n\n{"time_ms": 2}\n')
            self.assertEqual([e["time_ms"] for e in timed_answer.read_log(p)], [1, 2])

    def test_set_control_replaces_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "c.json")
            timed_answer.set_control(p, status="blocked")
            timed_answer.set_control(p, status="working", scenario="codex3")
            with open(p) as f:
                self.assertEqual(f.read(), '{"status": "working", "scenario": "codex3"}')


class SerialTest(unittest.TestCase):
    def run_main(self, serial):
        env = {"ANDROID_SERIAL": serial} if serial is not None else {}
        argv = ["timed_answer.py", "--fake-log", "x", "--control", "y"]
        with mock.patch.dict(os.environ, env, clear=True), mock.patch("sys.argv", argv):
            with self.assertRaises(SystemExit) as e:
                timed_answer.main()
        return str(e.exception)

    def test_needs_a_serial(self):
        self.assertIn("ANDROID_SERIAL", self.run_main(None))

    def test_refuses_a_device(self):
        self.assertIn("only on an emulator", self.run_main("R5CY123"))


if __name__ == "__main__":
    unittest.main()
