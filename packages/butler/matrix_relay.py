import json
import sys
import time
from datetime import datetime, timezone
import urllib.parse
import urllib.request
from pathlib import Path

TOKEN_PATH, CONFIG_PATH = sys.argv[1], sys.argv[2]
TOKEN = Path(TOKEN_PATH).read_text().strip()
_lines = Path(CONFIG_PATH).read_text().splitlines()
HOMESERVER, ROOM_ID, SELF_MXID = _lines[0].strip(), _lines[1].strip(), _lines[2].strip()
ALLOWED_SENDERS = set()
if len(_lines) > 3 and _lines[3].strip():
    ALLOWED_SENDERS = {s.strip() for s in _lines[3].split(",") if s.strip()}
USE_MESSAGES_POLLING = len(_lines) > 4 and _lines[4].strip().lower() in ("1", "true", "messages", "fallback")

SYNC_TIMEOUT_MS = int(_lines[5].strip()) if len(_lines) > 5 and _lines[5].strip() else 30000
MAX_PROCESSED_EVENT_IDS = 5000
MAX_BODY_BYTES = 64 * 1024
STATE_FILE = Path(CONFIG_PATH + ".since")
ACK_FILE = Path(CONFIG_PATH + ".acks")


def add_processed(processed, event_id):
    processed.pop(event_id, None)
    processed[event_id] = None
    while len(processed) > MAX_PROCESSED_EVENT_IDS:
        processed.pop(next(iter(processed)))


def cap_body(body):
    raw = str(body).encode("utf-8")
    if len(raw) <= MAX_BODY_BYTES:
        return raw.decode("utf-8")
    keep = MAX_BODY_BYTES
    while True:
        prefix = raw[:keep].decode("utf-8", "ignore")
        removed = len(raw) - len(prefix.encode("utf-8"))
        suffix = f"[truncated {removed} bytes]"
        next_keep = MAX_BODY_BYTES - len(suffix.encode("utf-8"))
        if next_keep == keep:
            return prefix + suffix
        keep = next_keep


def load_state():
    if STATE_FILE.exists():
        try:
            state = json.loads(STATE_FILE.read_text())
            if not isinstance(state, dict):
                raise ValueError("state root must be an object")
            since = state.get("since")
            messages_since = state.get("messages_since")
            processed_ids = state.get("processed_event_ids", [])
            pending = state.get("pending_events", {})
            if since is not None and not isinstance(since, str):
                raise ValueError("since must be a string or null")
            if messages_since is not None and not isinstance(messages_since, str):
                raise ValueError("messages_since must be a string or null")
            if not isinstance(processed_ids, list) or not all(
                isinstance(event_id, str) for event_id in processed_ids
            ):
                raise ValueError("processed_event_ids must be a string list")
            if not isinstance(pending, dict):
                raise ValueError("pending_events must be an object")
            pending = {
                event_id: event for event_id, event in pending.items()
                if isinstance(event_id, str) and isinstance(event, dict)
                and all(isinstance(event.get(key), str)
                        for key in ("sender", "room_id", "created_at", "body"))
            }
            # Read the old cursor-only format so upgrades resume in place.
            processed = {}
            for event_id in processed_ids:
                if isinstance(event_id, str) and event_id:
                    add_processed(processed, event_id)
            return since, processed, messages_since, pending
        except (ValueError, AttributeError, TypeError):
            return None, {}, None, {}
    return None, {}, None, {}


def save_state(token, processed, messages_since=None, pending=None):
    tmp = STATE_FILE.with_name(STATE_FILE.name + ".tmp")
    tmp.write_text(json.dumps({"since": token, "processed_event_ids": list(processed),
                               "messages_since": messages_since, "pending_events": pending or {}}))
    tmp.replace(STATE_FILE)


def reconcile_acks(since, processed, messages_since, pending):
    drain = ACK_FILE.with_name(ACK_FILE.name + ".drain")

    def apply(path):
        changed = False
        for event_id in path.read_text().splitlines():
            if event_id in pending:
                add_processed(processed, event_id)
                pending.pop(event_id, None)
                changed = True
        if changed:
            save_state(since, processed, messages_since, pending)
        path.unlink()

    if drain.exists():
        apply(drain)
    if ACK_FILE.exists():
        # Rename before reading so concurrent acknowledgements create a fresh
        # ACK_FILE and cannot be lost while this batch is drained.
        ACK_FILE.replace(drain)
        apply(drain)


def matrix_get(path, params=None):
    url = HOMESERVER + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=(SYNC_TIMEOUT_MS / 1000) + 10) as resp:
        return json.loads(resp.read())


def messages_path():
    room = urllib.parse.quote(ROOM_ID, safe="")
    return "/_matrix/client/v3/rooms/" + room + "/messages"


def emit(sender, room, event_id, timestamp, body):
    # Escape backslashes first so tabs/newlines stay on one pipe line.
    def escaped(value):
        return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")
    values = (sender, room, event_id, timestamp, body)
    sys.stdout.write("\t".join(escaped(value) for value in values) + "\n")
    sys.stdout.flush()


def emit_pending(pending, event_ids=None):
    for event_id in event_ids if event_ids is not None else sorted(pending):
        event = pending[event_id]
        if event:
            emit(event["sender"], event["room_id"], event_id,
                 event["created_at"], event["body"])


def handle_events(events, since, processed, messages_since=None, pending=None):
    pending = pending if pending is not None else {}
    added = []
    for ev in events:
        if ev.get("type") != "m.room.message":
            continue
        sender = ev.get("sender")
        event_id = ev.get("event_id")
        if not event_id or event_id in processed or event_id in pending:
            continue
        if sender == SELF_MXID:
            continue
        # Sender allowlist: only a configured human account may reach the
        # session. `--permission-mode auto` gives that session shell access
        # with no per-call confirmation, so anyone else in the room must
        # never be able to feed it input.
        if sender not in ALLOWED_SENDERS:
            continue
        content = ev.get("content", {})
        if content.get("msgtype") not in ("m.text", "m.notice", "m.emote"):
            continue
        try:
            timestamp = datetime.fromtimestamp(
                int(ev["origin_server_ts"]) / 1000, timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
        except (KeyError, TypeError, ValueError, OverflowError):
            timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        pending[event_id] = {"sender": sender, "room_id": ROOM_ID,
                             "created_at": timestamp, "body": cap_body(content.get("body", ""))}
        added.append(event_id)
        # Persist the mail envelope before advancing the sync cursor. The
        # relay retries pending envelopes until Lua acknowledges delivery.
        save_state(since, processed, messages_since, pending)
    return added


def handle_room(room, since, processed, messages_since, pending):
    return handle_events(room.get("timeline", {}).get("events", []), since, processed,
                         messages_since, pending)


def main():
    since, processed, messages_since, pending = load_state()
    reconcile_acks(since, processed, messages_since, pending)
    if USE_MESSAGES_POLLING:
        while True:
            reconcile_acks(since, processed, messages_since, pending)
            try:
                if messages_since is None:
                    # Establish a forward cursor without replaying history.
                    baseline = matrix_get(messages_path(), {"dir": "b", "limit": "1"})
                    messages_since = baseline.get("start") or baseline.get("end")
                    for event in baseline.get("chunk", []):
                        event_id = event.get("event_id")
                        if event_id:
                            add_processed(processed, event_id)
                    save_state(since, processed, messages_since, pending)
                    emit_pending(pending)
                    time.sleep(3)
                    continue
                resp = matrix_get(messages_path(), {
                    "from": messages_since, "dir": "f", "limit": "100",
                })
            except Exception:
                time.sleep(5)
                continue
            new_ids = handle_events(resp.get("chunk", []), since, processed,
                                    messages_since, pending)
            messages_since = resp.get("end", messages_since)
            save_state(since, processed, messages_since, pending)
            emit_pending(pending, new_ids)
            time.sleep(3)
    if since is None:
        # First run: establish a baseline without replaying room history.
        while since is None:
            try:
                resp = matrix_get("/_matrix/client/v3/sync", {"timeout": "0"})
                since = resp["next_batch"]
                save_state(since, processed, messages_since, pending)
            except Exception:
                time.sleep(5)

    emit_pending(pending)
    healthy_reported = False
    while True:
        reconcile_acks(since, processed, messages_since, pending)
        try:
            resp = matrix_get(
                "/_matrix/client/v3/sync",
                {"since": since, "timeout": str(SYNC_TIMEOUT_MS)},
            )
        # Deliberately broad: a relay must outlive every transport failure,
        # not just urllib.error.URLError (a killed connection mid-request
        # raises ConnectionResetError/RemoteDisconnected, which is not one).
        except Exception:
            time.sleep(5)
            continue

        # Allowlist: only ever look at the one configured room. Never
        # iterate any other key of resp["rooms"]["join"].
        room = resp.get("rooms", {}).get("join", {}).get(ROOM_ID)
        if room:
            new_ids = handle_room(room, since, processed, messages_since, pending)
        else:
            new_ids = []

        since = resp["next_batch"]
        save_state(since, processed, messages_since, pending)
        emit_pending(pending, new_ids)
        if room:
            healthy_reported = True
        elif not healthy_reported:
            print("__REMUDA_MATRIX_HEALTHY__", flush=True)
            healthy_reported = True


if __name__ == "__main__":
    main()
