"""Stub-server tests for the Matrix write composites."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packages" / "butler"))

from matrix_http import Client, MatrixError  # noqa: E402
import matrix_cli  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]


class ButlerMatrixCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="butler-matrix-cli-")
        cls.root = Path(cls.temp.name)
        cls.fixture = cls.root / "fixture.jsonl"
        cls.fixture.write_text("", encoding="utf-8")
        cls.get_log = cls.root / "get.log"
        cls.put_log = cls.root / "put.log"
        cls.server = subprocess.Popen(
            [sys.executable, str(ROOT / "tests/support/matrix_stub_server.py"),
             str(cls.fixture), str(cls.get_log), str(cls.put_log), "200"],
            stdout=subprocess.PIPE, text=True,
        )
        cls.port = int(cls.server.stdout.readline().strip())
        cls.room = "!stub:example.org"
        cls.token = cls.root / "token"
        cls.token.write_text("stub-secret\n", encoding="utf-8")
        cls.config = cls.root / "config"
        cls.config.write_text(
            f"http://127.0.0.1:{cls.port}\n{cls.room}\n@bot:example.org\n",
            encoding="utf-8",
        )

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)
        cls.temp.cleanup()

    def setUp(self):
        self.state = self.root / (self._testMethodName + ".state")
        for path in (self.get_log, self.put_log, self.get_log.with_name("get.log.requests")):
            path.write_text("", encoding="utf-8")
        self.client = Client(self.token, self.config, state_dir=self.state, interval=0)

    def requests(self):
        path = self.get_log.with_name("get.log.requests")
        return [json.loads(row) for row in path.read_text(encoding="utf-8").splitlines()]

    def put_bodies(self):
        return [json.loads(row) for row in self.put_log.read_text(encoding="utf-8").splitlines()]

    def test_butler_matrix_send_chunks_utf8_and_uses_unique_transactions(self):
        text = "한" * 1400
        result = matrix_cli.send(self.client, text, self.room)
        bodies = self.put_bodies()
        self.assertEqual(result["sent"], 2)
        self.assertEqual(len(bodies), 2)
        self.assertTrue(all(len(row["body"].encode("utf-8")) <= matrix_cli.MAX_CHUNK_BYTES for row in bodies))
        self.assertEqual("".join(row["body"] for row in bodies), text)
        paths = [row["path"] for row in self.requests()]
        self.assertEqual(len(paths), 2)
        self.assertNotEqual(paths[0].rsplit("/", 1)[-1], paths[1].rsplit("/", 1)[-1])
        self.assertTrue(all(row["authorization"] == "Bearer stub-secret" for row in self.requests()))

    def test_butler_matrix_send_rate_limit_spaces_chunks(self):
        client = Client(self.token, self.config, state_dir=self.state, interval=0.08)
        started = time.monotonic()
        matrix_cli.send(client, "x" * (matrix_cli.MAX_CHUNK_BYTES + 1), self.room)
        self.assertGreaterEqual(time.monotonic() - started, 0.07)

    def test_butler_matrix_reply_checks_same_room_and_formats_relation(self):
        result = matrix_cli.reply(self.client, "$event", "answer", self.room)
        self.assertEqual(result["sent"], 1)
        body = self.put_bodies()[0]
        self.assertEqual(body["msgtype"], "m.text")
        self.assertEqual(body["m.relates_to"]["m.in_reply_to"]["event_id"], "$event")
        self.assertTrue(any("/context/%24event" in row["path"] for row in self.requests()))

    def test_butler_matrix_reply_rejects_cross_room_without_sending(self):
        with self.assertRaises(MatrixError):
            matrix_cli.reply(self.client, "$other-room", "answer", self.room)
        self.assertEqual(self.put_bodies(), [])

    def test_butler_matrix_react_formats_annotation(self):
        matrix_cli.react(self.client, "$event", "👍", self.room)
        body = self.put_bodies()[0]
        self.assertEqual(body["m.relates_to"], {
            "rel_type": "m.annotation", "event_id": "$event", "key": "👍"})

    def test_butler_matrix_redact_sends_reason(self):
        matrix_cli.redact(self.client, "$event", "cleanup", self.room)
        body = self.put_bodies()[0]
        self.assertEqual(body["reason"], "cleanup")
        self.assertIn("/redact/", self.requests()[0]["path"])

    def test_butler_matrix_join_and_leave_use_operator_routes(self):
        matrix_cli.join(self.client, self.room)
        matrix_cli.leave(self.client, self.room)
        self.assertEqual([row["method"] for row in self.requests()], ["POST", "POST"])
        self.assertIn("/join", self.requests()[0]["path"])
        self.assertIn("/leave", self.requests()[1]["path"])

    def test_butler_matrix_upload_sends_media_and_message(self):
        source = self.root / "image.png"
        source.write_bytes(b"\x89PNG\r\n\x1a\nmedia")
        result = matrix_cli.upload(self.client, str(source), self.room)
        self.assertTrue(result["event_id"])
        rows = self.requests()
        self.assertTrue(any("/_matrix/media/v3/upload" in row["path"] for row in rows))
        self.assertTrue(any("/send/m.image/" in row["path"] for row in rows))


if __name__ == "__main__":
    unittest.main()
