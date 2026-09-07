#!/usr/bin/env python3
"""Isolated compatibility tests; no installed Khala, SSH, or live peers used."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "bin/khala"


class MailboxCompatibility(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "khala"
        self.env = {**os.environ, "KHALA_HOME": str(self.home), "KHALA_SESSION": "sender"}
        self.run_cli("init", "test")

    def run_cli(self, *args, session=None, body=None, ok=True):
        env = {**self.env, **({"KHALA_SESSION": session} if session else {})}
        result = subprocess.run([str(CLI), *args], input=body, text=True,
                                capture_output=True, env=env, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result.stdout.strip()

    def send(self, key="request1", **kwargs):
        return self.run_cli("send", "reader@test", "--request-id", key, "-m", "hello", **kwargs)

    def test_retry_and_conflict(self):
        first = self.send()
        self.assertEqual(first, self.send())
        self.assertEqual(len(list((self.home / "outbox/new").iterdir())), 1)
        self.run_cli("send", "reader@test", "--request-id", "request1", "-m", "changed", ok=False)
        self.run_cli("send", "other@test", "--request-id", "request1", "-m", "hello", ok=False)

    def test_concurrent_retries(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            ids = list(pool.map(lambda _: self.send(), range(6)))
        self.assertEqual(len(set(ids)), 1)
        self.assertEqual(len(list((self.home / "outbox/new").iterdir())), 1)

    def test_restart_before_publication_and_retained_receipt(self):
        first = self.send()
        record = self.home / "requests/send/sender/request1"
        # Simulate interruption after intent publication, before queue install.
        (record / "published").unlink()
        (self.home / "outbox/new" / first).unlink()
        (self.home / "spool/for/test" / first).unlink()
        self.assertEqual(first, self.send())
        self.assertTrue((self.home / "outbox/new" / first).exists())
        # Once published, retention must never turn a retry into another send.
        (self.home / "outbox/new" / first).unlink()
        (self.home / "spool/for/test" / first).unlink()
        self.assertEqual(first, self.send())
        self.assertFalse((self.home / "outbox/new" / first).exists())

    def test_interruption_after_queue_install(self):
        first = self.send()
        (self.home / "requests/send/sender/request1/published").unlink()
        self.assertEqual(first, self.send())
        self.assertTrue((self.home / "requests/send/sender/request1/published").exists())

    def test_options_identity_and_exact_stdin(self):
        args = ("send", "reader@test", "--as", "explicit", "--request-id", "stdin1",
                "-s", "subject", "--later", "--reply-to", "123.1.2.other@test")
        first = self.run_cli(*args, body="body\n\n")
        self.assertEqual(first, self.run_cli(*args, body="body\n\n"))
        self.run_cli(*args, body="body\n", ok=False)
        text = (self.home / "outbox/new" / first).read_text()
        self.assertIn("From: explicit@test\n", text)
        self.assertIn("Priority: later\n", text)
        self.assertIn("In-Reply-To: 123.1.2.other@test\n", text)
        self.assertTrue(text.endswith("\n\nbody\n\n"))

    def test_selective_ack_and_lost_response(self):
        first, second = self.send("one"), self.send("two")
        self.run_cli("reconcile")
        self.assertIn("hello", self.run_cli("inbox", "read", first, session="reader"))
        inbox = self.home / "inbox/reader"
        self.assertTrue((inbox / "new" / first).exists())
        self.run_cli("inbox", "ack-read", first, session="reader")
        before = (inbox / "cur" / first).stat().st_mtime_ns
        self.run_cli("inbox", "ack-read", first, session="reader")
        self.assertEqual(before, (inbox / "cur" / first).stat().st_mtime_ns)
        self.assertTrue((inbox / "new" / second).exists())
        self.run_cli("inbox", "ack-read", second, "123.1.2.missing@test", session="reader", ok=False)
        self.assertTrue((inbox / "new" / second).exists())
        self.run_cli("inbox", "ack-read", second, session="intruder", ok=False)

    def test_invalid_keys_and_ids(self):
        for key in ("", "../outside", "x" * 129, "bad.key"):
            self.send(key, ok=False)
        self.run_cli("inbox", "ack-read", "../../config", ok=False)
        self.run_cli("inbox", "ack-read", ok=False)

    def test_duplicate_copies_do_not_leave_unread_mail(self):
        message_id = self.send()
        self.run_cli("reconcile")
        inbox = self.home / "inbox/reader"
        self.run_cli("inbox", "ack-read", message_id, session="reader")
        current = inbox / "cur" / message_id
        duplicate = inbox / "new" / message_id
        duplicate.write_bytes(current.read_bytes() + b"different")
        self.run_cli("inbox", "ack-read", message_id, session="reader", ok=False)
        self.assertTrue(duplicate.exists())
        duplicate.write_bytes(current.read_bytes())
        self.run_cli("inbox", "ack-read", message_id, session="reader")
        self.assertFalse(duplicate.exists())
        self.assertTrue(current.exists())

    def test_legacy_send_still_creates_distinct_ids(self):
        first = self.run_cli("send", "reader@test", "-m", "legacy")
        second = self.run_cli("send", "reader@test", "-m", "legacy")
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main(verbosity=2)
