#!/usr/bin/env python3
"""A stub Matrix homeserver for the `packages/butler` tests. stdlib only —
no real Matrix homeserver is ever contacted by that test suite.

argv: <fixture_path> <get_log_path> <put_log_path> <send_status>

Binds 127.0.0.1:0 (OS-assigned) and prints the chosen port as the first
line of stdout, flushed, so the test harness can read it back.

GET /_matrix/client/v3/sync answers with the next line of `fixture_path`
(one JSON object per line, in order) each time it is called; every request
is also appended to `get_log_path` (full path + query string), which is how
a test proves what `since` value a later call carried. A fixture row may use
`__http_status` to return an HTTP error. Once exhausted, it keeps answering
with an empty room list and the SAME `next_batch` it last used — deliberately
not incrementing, so a caller that is killed and restarted against a
persisted `since` sees a stable token to resume from, not a moving target.
Idle /sync requests wait for their requested timeout like a long-poll server.

PUT .../rooms/<id>/send/m.room.message/<txn> logs the request body to
`put_log_path` and answers with `send_status` (200 -> a fake event_id,
anything else -> a bare error body) — enough to test both the success and
failure paths of `remuda.process`'s `on_exit`.
"""
import json
import re
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

fixture_path, get_log_path, put_log_path, send_status = sys.argv[1:5]
send_status = int(send_status)
tls_cert, tls_key = sys.argv[5:7] if len(sys.argv) >= 7 else (None, None)

with open(fixture_path) as f:
    fixture = [json.loads(line) for line in f if line.strip()]

state = {"index": 0, "last_token": "stub-idle-0", "lock": threading.Lock()}
request_log_path = get_log_path + ".requests"


def append(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")
        f.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # keep test output quiet; the two log files are the real record

    def _reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        route = urllib.parse.urlsplit(self.path).path
        append(request_log_path, json.dumps({"method": "GET", "path": self.path,
                                             "authorization": self.headers.get("Authorization")}))
        if route == "/_matrix/client/v3/joined_rooms":
            self._reply(200, {"joined_rooms": ["!stub:example.org"]})
            return
        context = re.match(r"^/_matrix/client/v3/rooms/([^/]+)/context/([^/]+)$", route)
        if context:
            room = urllib.parse.unquote(context.group(1))
            event_id = urllib.parse.unquote(context.group(2))
            if event_id == "$other-room":
                room = "!other:example.org"
            self._reply(200, {"event": {"room_id": room, "event_id": event_id}})
            return
        if route != "/_matrix/client/v3/sync" and not re.match(
            r"^/_matrix/client/v3/rooms/[^/]+/messages$", route
        ):
            self._reply(404, {"errcode": "M_NOT_FOUND"})
            return
        append(get_log_path, self.path)
        status = 200
        exhausted = False
        with state["lock"]:
            if state["index"] < len(fixture):
                body = fixture[state["index"]]
                state["index"] += 1
                status = int(body.get("__http_status", 200))
                if status != 200:
                    body = {"errcode": "M_UNKNOWN", "error": "stub sync failure"}
                else:
                    state["last_token"] = body.get("next_batch", state["last_token"])
            else:
                body = {"rooms": {"join": {}}, "next_batch": state["last_token"]}
                exhausted = True
        params = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        timeout_ms = int((params.get("timeout") or ["0"])[0])
        if exhausted and route == "/_matrix/client/v3/sync" and timeout_ms > 0:
            # Model Matrix /sync long polling after all canned events. This
            # keeps an idle relay from turning the fixture into a busy loop.
            time.sleep(timeout_ms / 1000)
        try:
            self._reply(status, body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        append(put_log_path, body)
        append(request_log_path, json.dumps({"method": "PUT", "path": self.path,
                                             "authorization": self.headers.get("Authorization")}))
        if not re.match(r"^/_matrix/client/v3/rooms/[^/]+/send/[^/]+/", self.path):
            self._reply(200, {"ok": True})
            return
        if send_status == 200:
            self._reply(200, {"event_id": "$stub-fake-event"})
        else:
            self._reply(send_status, {"errcode": "M_UNKNOWN", "error": "stub failure"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        append(put_log_path, body)
        append(request_log_path, json.dumps({"method": "POST", "path": self.path,
                                             "authorization": self.headers.get("Authorization")}))
        if urllib.parse.urlsplit(self.path).path == "/_matrix/media/v3/upload":
            self._reply(200, {"content_uri": "mxc://example.org/stub-media"})
            return
        self._reply(200, {"ok": True})


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    if tls_cert and tls_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(tls_cert, tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
