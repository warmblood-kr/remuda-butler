"""Short Matrix verb composites over the shared authenticated HTTP client."""
import argparse
import json
import mimetypes
import os
from pathlib import Path
import secrets
import sys
import urllib.parse

from matrix_http import Client, MatrixError, json_out


MAX_CHUNK_BYTES = 4000
MAX_UPLOAD_BYTES = 20 * 1024 * 1024


def _path(room, suffix):
    return "/_matrix/client/v3/rooms/%s/%s" % (urllib.parse.quote(room, safe=""), suffix)


def _txn():
    return secrets.token_urlsafe(18)


def _chunks(text):
    chunk = []
    size = 0
    for char in text:
        width = len(char.encode("utf-8"))
        if chunk and size + width > MAX_CHUNK_BYTES:
            yield "".join(chunk)
            chunk, size = [], 0
        chunk.append(char)
        size += width
    if chunk or not text:
        yield "".join(chunk)


def _send(client, room, body, relation=None):
    event_ids = []
    for chunk in _chunks(body):
        content = {"msgtype": "m.text", "body": chunk}
        if relation:
            content["m.relates_to"] = relation
        result = client.put(_path(room, "send/m.room.message/" + _txn()), content, room=room)
        event_ids.append(result.get("event_id", ""))
    return {"sent": len(event_ids), "event_ids": event_ids}


def send(client, text, room=None):
    return _send(client, room or client.room, text)


def _same_room(client, room, event_id):
    if not client.context_same_room(room, event_id):
        raise MatrixError("event is outside the configured Matrix room")


def reply(client, event_id, text, room=None):
    room = room or client.room
    _same_room(client, room, event_id)
    return _send(client, room, text, {"m.in_reply_to": {"event_id": event_id}})


def react(client, event_id, key, room=None):
    room = room or client.room
    _same_room(client, room, event_id)
    if not key:
        raise MatrixError("reaction key must not be empty")
    content = {"m.relates_to": {"rel_type": "m.annotation", "event_id": event_id, "key": key}}
    result = client.put(_path(room, "send/m.reaction/" + _txn()), content, room=room)
    return {"event_id": result.get("event_id", "")}


def redact(client, event_id, reason=None, room=None):
    room = room or client.room
    body = {} if reason is None else {"reason": reason}
    result = client.put(_path(room, "redact/%s/%s" % (urllib.parse.quote(event_id, safe=""), _txn())),
                        body, room=room)
    return {"event_id": result.get("event_id", "")}


def join(client, room):
    return client.post("/_matrix/client/v3/rooms/%s/join" % urllib.parse.quote(room, safe=""), {}, room=room)


def leave(client, room):
    return client.post("/_matrix/client/v3/rooms/%s/leave" % urllib.parse.quote(room, safe=""), {}, room=room)


def upload(client, file_path, room=None):
    room = room or client.room
    path = Path(file_path)
    size = path.stat().st_size
    if size > MAX_UPLOAD_BYTES:
        raise MatrixError("upload exceeds 20 MiB limit")
    media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    with path.open("rb") as source:
        data = source.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise MatrixError("upload exceeds 20 MiB limit")
    query = urllib.parse.urlencode({"filename": path.name})
    _, _, raw = client.request_raw("POST", "/_matrix/media/v3/upload?" + query,
                                   data, media_type, room=room)
    try:
        content_uri = json.loads(raw.decode("utf-8"))["content_uri"]
    except (ValueError, KeyError, UnicodeDecodeError) as exc:
        raise MatrixError("Matrix media upload response omitted content_uri") from exc
    msgtype = "m.image" if media_type.startswith("image/") else "m.file"
    content = {"msgtype": msgtype, "body": path.name, "url": content_uri,
               "info": {"mimetype": media_type, "size": size}}
    result = client.put(_path(room, "send/%s/%s" % (msgtype, _txn())), content, room=room)
    return {"event_id": result.get("event_id", ""), "content_uri": content_uri}


def status(client):
    who = client.get("/_matrix/client/v3/account/whoami")
    joined = client.get("/_matrix/client/v3/joined_rooms").get("joined_rooms", [])
    cursor = {}
    state_path = Path(str(client.config_path) + ".since")
    try:
        saved = json.loads(state_path.read_text(encoding="utf-8"))
        if isinstance(saved, dict):
            cursor = {key: saved.get(key) for key in ("since", "messages_since")}
    except (OSError, ValueError):
        pass
    return {"user_id": who.get("user_id"), "device_id": who.get("device_id"),
            "joined_rooms": joined, "sync_cursor": cursor.get("since"),
            "fallback_cursor": cursor.get("messages_since")}


def history(client, room=None, count=20):
    room = room or client.room
    count = int(count)
    if count < 1 or count > 1000:
        raise MatrixError("history count must be between 1 and 1000")
    path = _path(room, "messages")
    result = client.get(path, {"dir": "b", "limit": str(count)}, room=room)
    return {"room_id": room, "chunk": result.get("chunk", []),
            "start": result.get("start"), "end": result.get("end")}


def rooms(client):
    return {"joined_rooms": client.get("/_matrix/client/v3/joined_rooms").get("joined_rooms", [])}


def thread(client, room, event_id):
    path = "/_matrix/client/v1/rooms/%s/relations/%s/m.thread" % (
        urllib.parse.quote(room, safe=""), urllib.parse.quote(event_id, safe=""))
    events, cursor, seen = [], None, set()
    for _ in range(1000):
        params = {"dir": "b", "limit": "100"}
        if cursor:
            params["from"] = cursor
        page = client.get(path, params, room=room)
        events.extend(page.get("chunk", []))
        next_cursor = page.get("next_batch")
        if not next_cursor or next_cursor == cursor or next_cursor in seen:
            break
        seen.add(next_cursor)
        cursor = next_cursor
    return {"room_id": room, "event_id": event_id, "chunk": events, "next_batch": cursor}


def event(client, room, event_id):
    path = _path(room, "event/" + urllib.parse.quote(event_id, safe=""))
    return client.get(path, room=room)


def download(client, mxc, output_path=None):
    parsed = urllib.parse.urlsplit(mxc)
    media_id = parsed.path.lstrip("/")
    if parsed.scheme != "mxc" or not parsed.netloc or not media_id or "/" in media_id:
        raise MatrixError("download expects an mxc://server/media_id URL")
    server = urllib.parse.quote(parsed.netloc, safe="")
    media = urllib.parse.quote(media_id, safe="")
    v1 = "/_matrix/client/v1/media/download/%s/%s" % (server, media)
    try:
        _, headers, body = client.request_raw("GET", v1, None, None)
    except MatrixError as exc:
        message = str(exc)
        if "Matrix HTTP 404" not in message and "M_UNRECOGNIZED" not in message:
            raise
        legacy = "/_matrix/media/v3/download/%s/%s" % (server, media)
        _, headers, body = client.request_raw("GET", legacy, None, None)
    target = Path(output_path) if output_path else Path("matrix-" + Path(media_id).name)
    target.write_bytes(body)
    return {"mxc": mxc, "path": str(target), "bytes": len(body),
            "content_type": headers.get("Content-Type", "application/octet-stream")}


def _event_line(item):
    event_content = item.get("content", {})
    sender = item.get("sender", "?")
    body = event_content.get("body", "") if isinstance(event_content, dict) else ""
    if not body and isinstance(event_content, dict):
        file_content = event_content.get("file")
        if not isinstance(file_content, dict):
            file_content = {}
        body = event_content.get("url", file_content.get("url", ""))
    return "%s %s: %s" % (item.get("event_id", ""), sender, body)


def _render_read(value, machine, verb):
    if machine:
        json_out(value)
    elif verb == "status":
        print("%s · joined %d room(s) · sync %s · fallback %s" % (
            value.get("user_id") or "unknown user", len(value["joined_rooms"]),
            value.get("sync_cursor") or "baseline pending", value.get("fallback_cursor") or "inactive"))
    elif verb == "rooms":
        print("\n".join(value["joined_rooms"]) or "No joined rooms")
    elif verb == "download":
        print("Downloaded %d bytes to %s" % (value["bytes"], value["path"]))
    elif verb in ("history", "thread"):
        print("\n".join(_event_line(item) for item in value["chunk"]) or "No events")
    else:
        print(_event_line(value))


def _render(value, machine):
    if machine:
        json_out(value)
    elif "sent" in value:
        print("Sent %d message chunk(s)" % value["sent"])
    elif value.get("event_id"):
        print("Sent " + value["event_id"])
    else:
        print("OK")


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="matrix_cli.py")
    parser.add_argument("token")
    parser.add_argument("config")
    parser.add_argument("state_dir")
    parser.add_argument("verb", choices=("send", "reply", "react", "upload", "redact", "join", "leave",
                                          "status", "history", "rooms", "thread", "event", "get", "download"))
    parser.add_argument("--json", action="store_true", dest="machine")
    parser.add_argument("--room")
    parser.add_argument("-n", type=int, default=20, dest="count")
    parser.add_argument("-o", dest="output_path")
    parser.add_argument("values", nargs="*")
    args = parser.parse_args(argv)
    client = Client(args.token, args.config, state_dir=args.state_dir)
    room = args.room or client.room
    if args.verb == "status" and not args.values:
        result = status(client)
    elif args.verb == "rooms" and not args.values:
        result = rooms(client)
    elif args.verb == "history" and not args.values:
        result = history(client, args.room, args.count)
    elif args.verb == "thread" and len(args.values) == 1:
        result = thread(client, room, args.values[0])
    elif args.verb in ("event", "get") and len(args.values) == 1:
        result = event(client, room, args.values[0])
    elif args.verb == "download" and len(args.values) == 1:
        result = download(client, args.values[0], args.output_path)
    elif args.verb == "send":
        text = " ".join(args.values)
        if text == "-":
            text = sys.stdin.read()
        result = send(client, text, room)
    elif args.verb == "reply" and len(args.values) >= 2:
        result = reply(client, args.values[0], " ".join(args.values[1:]), room)
    elif args.verb == "react" and len(args.values) == 2:
        result = react(client, args.values[0], args.values[1], room)
    elif args.verb == "upload" and len(args.values) == 1:
        result = upload(client, args.values[0], room)
    elif args.verb == "redact" and args.values:
        result = redact(client, args.values[0], " ".join(args.values[1:]) or None, room)
    elif args.verb in ("join", "leave") and len(args.values) == 1:
        result = globals()[args.verb](client, args.values[0])
    else:
        parser.error("invalid arguments for %s" % args.verb)
    if args.verb in ("status", "rooms", "history", "thread", "event", "get", "download"):
        _render_read(result, args.machine, args.verb)
    else:
        _render(result, args.machine)


if __name__ == "__main__":
    try:
        main()
    except (MatrixError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
