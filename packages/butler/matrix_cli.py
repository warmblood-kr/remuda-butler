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
    data = path.read_bytes()
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
    parser.add_argument("verb", choices=("send", "reply", "react", "upload", "redact", "join", "leave"))
    parser.add_argument("--json", action="store_true", dest="machine")
    parser.add_argument("--room")
    parser.add_argument("values", nargs="*")
    args = parser.parse_args(argv)
    client = Client(args.token, args.config, state_dir=args.state_dir)
    room = args.room or client.room
    if args.verb == "send":
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
    _render(result, args.machine)


if __name__ == "__main__":
    try:
        main()
    except (MatrixError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
