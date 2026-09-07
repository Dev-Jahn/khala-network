#!/usr/bin/env python3
"""Isolated compatibility tests; no installed Khala, SSH, or live peers used."""
import concurrent.futures
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
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

    def test_request_input_is_text_and_legacy_retries_migrate(self):
        first = self.send()
        record = self.home / "requests/send/sender/request1"
        expected = (b"Khala-Request: 1\nFrom: sender@test\nTo: reader@test\n"
                    b"Subject: \nTTL: 2592000\nIn-Reply-To: \nLater: 0\n\nhello\n")
        self.assertEqual((record / "input").read_bytes(), expected)
        legacy = b"\0".join([b"request-v1", b"sender@test", b"reader@test", b"",
                              b"2592000", b"", b"0", b"hello\n"])
        envelope = (record / "message").read_bytes()
        publication = (record / "published").read_bytes()
        for pending in (False, True):
            (record / "input").write_bytes(legacy)
            if pending:
                (record / "published").unlink()
                (self.home / "outbox/new" / first).unlink()
                (self.home / "spool/for/test" / first).unlink()
            self.run_cli("send", "reader@test", "--request-id", "request1", "-m", "changed", ok=False)
            self.assertEqual((record / "input").read_bytes(), legacy)
            self.assertEqual(first, self.send())
            self.assertEqual((record / "input").read_bytes(), expected)
            self.assertEqual((record / "message").read_bytes(), envelope)
            self.assertEqual((record / "published").read_bytes(), publication)

    def test_retry_ledger_survives_actual_archive_retention(self):
        first = self.send()
        self.run_cli("reconcile")
        self.assertTrue((self.home / "outbox/acked" / first).exists())
        self.run_cli("inbox", "ack-read", first, session="reader")
        # Move the CLI's clock forward without sleeping or changing host time.
        future = int(time.time()) + 31 * 86400
        real_date = shutil.which("date")
        self.assertIsNotNone(real_date)
        # DESIGN requires executable test helpers under HOME: /tmp may be noexec.
        clock_tmp = tempfile.TemporaryDirectory(prefix="khala-test-clock-", dir=Path.home())
        self.addCleanup(clock_tmp.cleanup)
        shim_dir = Path(clock_tmp.name)
        shim = shim_dir / "date"
        shim.write_text('#!/bin/sh\nif [ "$#" -eq 1 ] && [ "$1" = +%s ]; then\n'
                        f"    printf '%s\\n' {future}\nelse\n"
                        f'    exec {shlex.quote(real_date)} "$@"\nfi\n')
        shim.chmod(0o755)
        self.env["PATH"] = str(shim_dir) + os.pathsep + self.env["PATH"]
        self.run_cli("reconcile")
        self.assertFalse((self.home / "outbox/acked" / first).exists())
        self.assertFalse((self.home / "inbox/reader/cur" / first).exists())
        self.assertTrue((self.home / "requests/send/sender/request1/published").exists())
        self.assertEqual(first, self.send())
        self.assertFalse((self.home / "outbox/new" / first).exists())
        self.assertFalse((self.home / "spool/for/test" / first).exists())

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
