# Source adapter v1: no promotion slice

Abstract inbox_source_contract.lua; proposed product
packages/butler/inbox_source.lua. M.open(config) -> Source | nil,error.
Source uses COLON calls :recipients(root), :snapshot(root,recipienthex),
:witness(root,recipienthex). Existing Store config.source uses DOT calls bound
by wrappers e.g. snapshot=function(r,p) return source:snapshot(r,p) end.
No SQL, delivery, read receipt, promotion or source mutation in this module.

Config `{root,fs={list=fn,read=fn},json={decode=fn,canonical=fn},sha256=fn}`.
All injected functions use DOT calls. fs.list(absolute_dir) -> dense array of
basename strings | nil,error. fs.read(absolute_path) -> exact binary string |
nil,error. Errors are `{code="not_found"|"denied"|"io",...}`. Missing directories
or log files are empty only on explicit not_found; denied/io never means empty.
Paths bind exact canonical root; reject other root, nonhex recipient (lowercase
even-length nonempty), unsafe id/path traversal, malformed filenames. JSON
functions return decoded value/canonical string or nil,error. Decode consumes
ONE whole JSON value, rejects trailing garbage and ambiguous duplicate keys;
canonical sorts object keys, preserves array order/null/numeric values and
unknown envelope fields. JSON and sha256 mandatory; absent capabilities error
unavailable. sha256(bytes) -> lowercase 64 hex, real SHA-256, never short hash.

:recipients(root) -> `{recipients={hex,...},complete=true}` lexicographically
sorted unique union of `inboxes/*.jsonl` AND `read/*.jsonl`; validate filenames,
no mailbox-name decoding. Root mismatch => invalid_snapshot; malformed entries
=> source_unreadable; list failure => source_unreadable. No partial success.

:snapshot(root,hex) -> `{deliveries={row,...},reads={[id]=true,...},
recipient=hex,complete=true,witness=token,source_before=token,source_after=token}`
or nil,error. Row is unchanged certifier v1 shape: message_id, seq, resent,
envelope_ref, object_ref, metadata. Refs are root-relative `messages/id.json`
and `objects/objectid`, never new ids. Envelope id must equal delivered id;
body.object_id must be safe and exist; bytes (when declared) must match actual.
metadata = canonical({envelope=FULLdecodedEnvelope,
object={id=objectid,bytes=actualLength,sha256=actualDigest}}).
Absent old content_hash stays null/absent inside original envelope; do not
rewrite historical metadata. This wrapper gives exact address/aliases/thread/
refs/Matrix preservation and body identity; same encoder must feed SQL rows.

Read inbox as strict newline-terminated JSONL objects with nonempty safe
message_id; no regex extraction or skip. Complete duplicate rows collapse at
first distinct appearance into dense seq1..N. Only PRESENT resent OBJECT
replaces prior resent; absent resent retains prior; explicit null/nonobject
is source_unreadable. resent=canonical(full resent object). Retained
note_object_id refs must be safe and readable; include those bytes in witness.
Read file is newline-terminated raw ids, preserving exact legacy line values
(CR is data, not silently trimmed); duplicate ids collapse; blank/unsafe line
is source_unreadable. Whole read set includes ids absent from inbox, no envelope
needed for orphan reads. Empty file valid; nonempty unterminated tail => partial.
Missing/corrupt envelope/object/required metadata => source_unreadable, never
complete or empty. Error shape `{code,field,path?,line?}` omits payloads.

Full generation witness is two equal full passes over sorted root-relative
path+presence+EXACT bytes records: inbox/read logs plus each delivered envelope,
body object and retained resent note object. Length-frame every path and value
before SHA-256; include protocol version/root/recipient and absence records.
Token `source-v1:sha256:<hex>`; :witness repeats the dependency traversal and
returns token | nil,error without exposing bodies. Snapshot reads before and
after its canonical construction; differing tokens => stale_generation.
Torn input => partial; malformed/IO => source_unreadable.
Callers cannot use partial output. No head/size/count proof. Supported root
writer guard prevents concurrent cooperating writers; immutable content files
and no hostile edits during snapshot are assumptions. No hostile ABA guarantee.

This is migration-time full-content verification; payload reads allowed here.
Hot Matrix lookup remains metadata-only. Reuse #585 import_all/staged cursor in
later Store:advance; this adapter validates source, does not replace importer.
QA pairs exact positives with duplicate/resent/read-orphan fixtures; same-size
middle change, missing metadata, torn line, denied list/read, changed root and
before/after mutation each assert the specific error. No promotion. Bounded migration uses inbox-source-progress.md, not snapshot.

SHA provider: existing guard_approval.sha256 is pure Lua (guard_approval.lua:65).
Inject explicitly; generic native SHA binding not established.
