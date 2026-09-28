"""Stub-server tests for the Matrix write composites."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import io
from contextlib import redirect_stdout

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

    def assert_authenticated(self):
        self.assertTrue(self.requests(), "expected one or more Matrix requests")
        self.assertTrue(all(row["authorization"] == "Bearer stub-secret" for row in self.requests()))

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
        self.assert_authenticated()

    def test_butler_matrix_send_rate_limit_spaces_chunks(self):
        client = Client(self.token, self.config, state_dir=self.state, interval=0.08)
        started = time.monotonic()
        matrix_cli.send(client, "x" * (matrix_cli.MAX_CHUNK_BYTES + 1), self.room)
        self.assertGreaterEqual(time.monotonic() - started, 0.07)

    def test_butler_matrix_cli_preserves_leading_dash_values(self):
        output = io.StringIO()
        for value in ("--json", "-", "-h"):
            argv = [str(self.token), str(self.config), str(self.state), "send", "--", value]
            with redirect_stdout(output):
                matrix_cli.main(argv)
        self.assertEqual([row["body"] for row in self.put_bodies()], ["--json", "-", "-h"])
        self.assertIn("Sent 1", output.getvalue())
        self.assert_authenticated()

    def test_butler_matrix_reply_cli_preserves_leading_dash_text(self):
        output = io.StringIO()
        for value in ("--json", "-", "-h"):
            argv = [str(self.token), str(self.config), str(self.state), "reply", "--", "$event", value]
            with redirect_stdout(output):
                matrix_cli.main(argv)
        bodies = self.put_bodies()
        self.assertEqual([row["body"] for row in bodies], ["--json", "-", "-h"])
        self.assertTrue(all(row["m.relates_to"]["m.in_reply_to"]["event_id"] == "$event"
                            for row in bodies))
        self.assert_authenticated()

    def test_butler_matrix_send_rejects_empty_text(self):
        with self.assertRaisesRegex(MatrixError, "must not be empty"):
            matrix_cli.send(self.client, "", self.room)
        self.assertEqual(self.requests(), [])

    def test_butler_matrix_reply_checks_same_room_and_formats_relation(self):
        result = matrix_cli.reply(self.client, "$event", "answer", self.room)
        self.assertEqual(result["sent"], 1)
        body = self.put_bodies()[0]
        self.assertEqual(body["msgtype"], "m.text")
        self.assertEqual(body["m.relates_to"]["m.in_reply_to"]["event_id"], "$event")
        self.assertTrue(any("/context/%24event" in row["path"] for row in self.requests()))
        self.assert_authenticated()

    def test_butler_matrix_reply_rejects_cross_room_without_sending(self):
        with self.assertRaises(MatrixError):
            matrix_cli.reply(self.client, "$other-room", "answer", self.room)
        self.assertEqual(self.put_bodies(), [])

    def test_butler_matrix_react_formats_annotation(self):
        matrix_cli.react(self.client, "$event", "👍", self.room)
        body = self.put_bodies()[0]
        self.assertEqual(body["m.relates_to"], {
            "rel_type": "m.annotation", "event_id": "$event", "key": "👍"})
        self.assert_authenticated()

    def test_butler_matrix_redact_sends_reason(self):
        matrix_cli.redact(self.client, "$event", "cleanup", self.room)
        body = self.put_bodies()[0]
        self.assertEqual(body["reason"], "cleanup")
        self.assertIn("/redact/", self.requests()[0]["path"])
        self.assert_authenticated()

    def test_butler_matrix_join_and_leave_use_operator_routes(self):
        matrix_cli.join(self.client, self.room)
        matrix_cli.leave(self.client, self.room)
        self.assertEqual([row["method"] for row in self.requests()], ["POST", "POST"])
        self.assertIn("/join", self.requests()[0]["path"])
        self.assertIn("/leave", self.requests()[1]["path"])
        self.assert_authenticated()

    def test_butler_matrix_upload_sends_media_and_message(self):
        source = self.root / "image.png"
        source.write_bytes(b"\x89PNG\r\n\x1a\nmedia")
        result = matrix_cli.upload(self.client, str(source), self.room)
        self.assertTrue(result["event_id"])
        rows = self.requests()
        self.assertTrue(any("/_matrix/media/v3/upload" in row["path"] for row in rows))
        self.assertTrue(any("/send/m.image/" in row["path"] for row in rows))
        self.assert_authenticated()

    def test_butler_matrix_upload_rejects_over_20_mib_before_request(self):
        source = self.root / "too-large.bin"
        with source.open("wb") as output:
            output.truncate(matrix_cli.MAX_UPLOAD_BYTES + 1)
        with self.assertRaisesRegex(MatrixError, "exceeds 20 MiB limit"):
            matrix_cli.upload(self.client, str(source), self.room)
        self.assertEqual(self.requests(), [])

    def test_butler_matrix_write_errors_surface_for_each_verb(self):
        error_get = self.root / "error-get.log"
        error_put = self.root / "error-put.log"
        error_server = subprocess.Popen(
            [sys.executable, str(ROOT / "tests/support/matrix_stub_server.py"),
             str(self.fixture), str(error_get), str(error_put), "400"],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            port = int(error_server.stdout.readline().strip())
            error_config = self.root / "error-config"
            error_config.write_text(
                f"http://127.0.0.1:{port}\n{self.room}\n@bot:example.org\n", encoding="utf-8")
            client = Client(self.token, error_config, state_dir=self.root / "error-state", interval=0)
            media = self.root / "error.bin"
            media.write_bytes(b"media")
            operations = (
                lambda: matrix_cli.send(client, "bad", self.room),
                lambda: matrix_cli.reply(client, "$event", "bad", self.room),
                lambda: matrix_cli.react(client, "$event", "x", self.room),
                lambda: matrix_cli.upload(client, str(media), self.room),
                lambda: matrix_cli.redact(client, "$event", "bad", self.room),
                lambda: matrix_cli.join(client, self.room),
                lambda: matrix_cli.leave(client, self.room),
            )
            for operation in operations:
                with self.subTest(operation=operation):
                    with self.assertRaisesRegex(MatrixError, "Matrix HTTP 400"):
                        operation()
            requests = [json.loads(row) for row in error_get.with_name("error-get.log.requests")
                        .read_text(encoding="utf-8").splitlines()]
            self.assertTrue(requests)
            self.assertTrue(all(row["authorization"] == "Bearer stub-secret" for row in requests))
        finally:
            error_server.terminate()
            error_server.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
