"""The single authenticated HTTP client for Butler's Matrix adapter."""
import contextlib
import hashlib
import hmac
import http.client
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class MatrixError(RuntimeError):
    pass


def json_out(value):
    """Emit stable machine-readable JSON for CLI commands."""
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def _config(config_path):
    lines = Path(config_path).read_text(encoding="utf-8").splitlines()
    if len(lines) < 3 or not lines[0].strip():
        raise MatrixError("Matrix config requires homeserver, room ID, and user ID")
    options = {}
    if len(lines) > 3 and lines[3].strip():
        options["allowed_senders"] = {x.strip() for x in lines[3].split(",") if x.strip()}
    for line in lines[4:]:
        if "=" in line:
            key, value = line.split("=", 1)
            options[key.strip()] = value.strip()
    return lines[0].strip().rstrip("/"), lines[1].strip(), options


@contextlib.contextmanager
def _locked(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+", encoding="ascii") as lock:
        if os.name == "nt":
            import msvcrt
            lock.seek(0)
            if lock.read(1) == "":
                lock.write("0")
                lock.flush()
            lock.seek(0)
            msvcrt.locking(lock.fileno(), msvcrt.LK_LOCK, 1)
            try:
                yield lock
            finally:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield lock
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, pin, **kwargs):
        self.pin = pin.lower().replace(":", "")
        super().__init__(*args, **kwargs)

    def connect(self):
        super().connect()
        cert = self.sock.getpeercert(binary_form=True)
        actual = hashlib.sha256(cert).hexdigest()
        if not hmac.compare_digest(actual, self.pin):
            self.close()
            raise ssl.SSLError("Matrix TLS certificate pin mismatch")


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, pin):
        super().__init__(context=ssl._create_unverified_context())
        self.pin = pin

    def https_open(self, req):
        return self.do_open(lambda host, **kw: _PinnedHTTPSConnection(host, pin=self.pin, **kw),
                            req, context=self._context)


class Client:
    def __init__(self, token_path, config_path, state_dir=None, interval=None):
        self.base, self.room, self.options = _config(config_path)
        self.token = Path(token_path).read_text(encoding="utf-8").strip()
        if not self.token:
            raise MatrixError("Matrix token is empty")
        self.state_dir = Path(state_dir or (str(config_path) + ".state"))
        self.interval = float(interval if interval is not None else
                               os.environ.get("REMUDA_BUTLER_MATRIX_RATE_INTERVAL", "0.25"))
        self.ca_file = self.options.get("ca_file")
        self.pin = self.options.get("pin_sha256")
        if self.base.startswith("https://") and not self.ca_file and not self.pin:
            raise MatrixError("HTTPS Matrix homeserver requires ca_file=PATH or pin_sha256=HEX")
        if self.ca_file and self.pin:
            raise MatrixError("configure only one of ca_file or pin_sha256")

    def _rate_limit(self):
        self.state_dir.mkdir(parents=True, exist_ok=True)
        path = self.state_dir / "matrix-rate.lock"
        with _locked(path) as lock:
            lock.seek(0)
            raw = lock.read().strip()
            prior = float(raw or "0")
            now = time.time()
            wait = max(0.0, prior + self.interval - now)
            if wait:
                time.sleep(wait)
            lock.seek(0)
            lock.truncate()
            lock.write("%.9f" % time.time())
            lock.flush()

    def _opener(self):
        if self.pin:
            return urllib.request.build_opener(_PinnedHTTPSHandler(self.pin))
        if self.ca_file:
            context = ssl.create_default_context(cafile=self.ca_file)
            return urllib.request.build_opener(urllib.request.HTTPSHandler(context=context))
        return urllib.request.build_opener()

    def request_raw(self, method, path, data, content_type, room=None):
        """Make one authenticated request and preserve its response bytes."""
        if room is not None and room != self.room:
            raise MatrixError("room is outside the configured Matrix allowlist")
        url = urllib.parse.urljoin(self.base + "/", path.lstrip("/"))
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        self._rate_limit()
        req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
        try:
            with self._opener().open(req, timeout=30) as response:
                return response.status, dict(response.headers.items()), response.read()
        except urllib.error.HTTPError as exc:
            raw = exc.read(4096).decode("utf-8", "replace")
            raise MatrixError("Matrix HTTP %d: %s" % (exc.code, raw)) from exc
        except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
            raise MatrixError("Matrix request failed: %s" % exc) from exc

    def request(self, method, path, body=None, room=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        _, _, raw = self.request_raw(
            method, path, data, "application/json" if data is not None else None, room=room)
        if len(raw) > 1024 * 1024:
            raise MatrixError("Matrix response exceeded 1 MiB")
        return json.loads(raw.decode("utf-8")) if raw else {}

    def get(self, path, params=None, room=None):
        if params:
            path += "?" + urllib.parse.urlencode(params, doseq=True)
        return self.request("GET", path, room=room)

    def put(self, path, body, room=None):
        return self.request("PUT", path, body, room)

    def post(self, path, body, room=None):
        return self.request("POST", path, body, room)

    def context_same_room(self, room, event_id):
        return context_same_room(self, room, event_id)


def context_same_room(client, room, event_id):
    encoded_room = urllib.parse.quote(room, safe="")
    encoded_event = urllib.parse.quote(event_id, safe="")
    result = client.get("/_matrix/client/v3/rooms/%s/context/%s" % (encoded_room, encoded_event), room=room)
    return result.get("event", {}).get("room_id") == room


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 4:
        raise SystemExit("usage: matrix_http.py TOKEN CONFIG METHOD PATH [JSON_BODY]")
    token_path, config_path, method, path = argv[:4]
    body = json.loads(argv[4]) if len(argv) > 4 else None
    print(json.dumps(Client(token_path, config_path).request(method, path, body), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except MatrixError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
