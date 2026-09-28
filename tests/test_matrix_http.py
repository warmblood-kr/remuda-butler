import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

PACKAGE_DIR = next(parent / "packages" / "butler" for parent in Path(__file__).resolve().parents
                   if (parent / "packages" / "butler").is_dir())
sys.path.insert(0, str(PACKAGE_DIR))


class MatrixHttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.log = self.root / "requests.jsonl"
        self.token = self.root / "token"
        self.token.write_text("secret-token\n")
        self.config = self.root / "config"
        self.config.write_text("https://matrix.example.org\n!room:example.org\n@bot:example.org\n@alice:example.org\n\n\nca_file=/etc/ssl/cert.pem\n")

    def tearDown(self):
        self.temp.cleanup()

    def run_py(self, source, *args, env=None):
        code = "import sys, matrix_http; " + source
        env = (env or os.environ).copy()
        env["PYTHONPATH"] = str(PACKAGE_DIR)
        subprocess.run([sys.executable, "-c", code, str(self.token), str(self.config), *args],
                       check=True, env=env)

    def test_authenticated_get_and_allowlist(self):
        import matrix_http

        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = b'{"ok":true}'
        opener = mock.MagicMock()
        opener.open.return_value = response
        with mock.patch.object(matrix_http.Client, "_opener", return_value=opener):
            client = matrix_http.Client(str(self.token), str(self.config))
            self.assertEqual(client.get("/_matrix/client/v3/joined_rooms"), {"ok": True})
            request = opener.open.call_args.args[0]
            self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")
            with self.assertRaises(matrix_http.MatrixError):
                client.get("/rooms", room="!other:example.org")

    def test_authenticated_put_post_shapes_and_error(self):
        import matrix_http

        def response_for(payload):
            response = mock.MagicMock()
            response.__enter__.return_value.read.return_value = json.dumps(payload).encode()
            return response

        opener = mock.MagicMock()
        opener.open.side_effect = [response_for({"put": True}), response_for({"post": True})]
        with mock.patch.object(matrix_http.Client, "_opener", return_value=opener):
            client = matrix_http.Client(str(self.token), str(self.config), interval=0)
            self.assertEqual(client.put("/put", {"x": 1}, room="!room:example.org"), {"put": True})
            self.assertEqual(client.post("/post", {"x": 2}), {"post": True})
        put_req, post_req = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual((put_req.method, put_req.data), ("PUT", b'{"x": 1}'))
        self.assertEqual((post_req.method, post_req.data), ("POST", b'{"x": 2}'))
        self.assertEqual(put_req.get_header("Authorization"), "Bearer secret-token")

    def test_request_raw_preserves_binary_response_and_content_headers(self):
        import matrix_http

        response = mock.MagicMock()
        response.status = 201
        response.headers.items.return_value = [("Content-Type", "application/octet-stream"), ("X-Media", "stub")]
        response.__enter__.return_value = response
        response.read.return_value = b"\x00\xffmatrix-media"
        opener = mock.MagicMock()
        opener.open.return_value = response
        with mock.patch.object(matrix_http.Client, "_opener", return_value=opener):
            client = matrix_http.Client(str(self.token), str(self.config), interval=0)
            status, headers, body = client.request_raw(
                "PUT", "/_matrix/media/v3/upload", b"\x00\xffmatrix-media",
                "application/octet-stream", room="!room:example.org")
        self.assertEqual(status, 201)
        self.assertEqual(headers["Content-Type"], "application/octet-stream")
        self.assertEqual(body, b"\x00\xffmatrix-media")
        request = opener.open.call_args.args[0]
        self.assertEqual((request.method, request.data), ("PUT", b"\x00\xffmatrix-media"))
        self.assertEqual(request.get_header("Content-type"), "application/octet-stream")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")

    def test_request_raw_rejects_disallowed_room_before_network(self):
        import matrix_http

        opener = mock.MagicMock()
        with mock.patch.object(matrix_http.Client, "_opener", return_value=opener):
            client = matrix_http.Client(str(self.token), str(self.config), interval=0)
            with self.assertRaisesRegex(matrix_http.MatrixError, "outside the configured Matrix allowlist"):
                client.request_raw("PUT", "/upload", b"payload", "application/octet-stream",
                                   room="!other:example.org")
        opener.open.assert_not_called()

    def test_https_fails_closed_without_tls_policy(self):
        import matrix_http

        self.config.write_text("https://matrix.example.org\n!room:example.org\n@bot:example.org\n")
        with self.assertRaisesRegex(matrix_http.MatrixError, "requires ca_file=PATH or pin_sha256=HEX"):
            matrix_http.Client(str(self.token), str(self.config))

    def test_cross_process_rate_spacing(self):
        env = os.environ.copy()
        env["REMUDA_BUTLER_MATRIX_RATE_INTERVAL"] = "0.4"
        started = time.monotonic()
        source = "matrix_http.Client(sys.argv[1],sys.argv[2])._rate_limit()"
        self.run_py(source, env=env)
        self.run_py(source, env=env)
        self.assertGreaterEqual(time.monotonic() - started, 0.35)


if __name__ == "__main__":
    unittest.main()
