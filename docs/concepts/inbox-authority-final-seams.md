# Final A/B/C seams v1.4 (exact shared QA input)

Exact shared encoding; existing method shapes unchanged.
A=marker/open/status+accept_external+SQLpage/hydrate/reconcile;
B=sealed source/tail/advance/barrier; C=transition/callers. Reverse export is not automatic or a gate on A/B slices.

## Shared encoding/config

F(s1,...,sn) = concatenate decimal BYTE length + ':' + exact bytes for each
string; no separators/count/Unicode normalization. Integers are nonnegative
base10, no leading zeros except '0'. SHA(s) is real SHA256 lower64hex.
M.open config uses root, db=borrowed actual inbox handle,
json={encode,decode,canonical}, sha256, marker, content, writer, progress,
migration. Functions in adapter tables use DOT calls. sha256(bytes)->lower64hex;
json functions dot(value)->value|nil,error. canonical preserves null/arrays,
sorts object keys and rejects ambiguous/nonfinite values; A/B/QA inject SAME
canonical function. encode is bounded SQL record transport, not hash encoding.
Object metadata already canonical strings must not be encoded again for hash.
Inject tested SHA, no invented native binding.

## External acceptance exact protocol

key fields account,room,event,destination are nonempty strings; destination
lowercase evenlength recipienthex. account is caller's stable canonical Matrix
account identity; no epoch/device/store/process alias substituted on restart.
K=F('butler-external-key-v1',account,room,event,destination).
opid='external-v1-'..SHA(K). SQL unique key is exact tuple (or K bytes with exact
equality), not an unverified hash-only equality. payload is
{content=exactBytes,metadata=canonicalJSON,payload_hash=lower64hex}.
metadata is stable PREallocation envelope input: original sender/recipient,
subject/date/thread/refs/Matrix data; no allocated mailid/bodyref/storeepoch.
P=F('butler-external-payload-v1',content,metadata).
Require payload_hash==SHA(P) AND canonical(decode(metadata))==metadata.
Same exact key + same SHA(P) => original opid/receipt/mail_id; changed hash =>
operation_conflict. Content+SQL metadata are built from verified input. Same
transaction inserts dedup+metadata+membership/order+receipt. Return standard
committed {operation_id=opid,result={message_id,recipients={destination},
receipt_id=opid}}. Unknown returns opid; no second id/new transport dispatch.
SQL dedup receipt survives reads and relay rebuild. Hash collision is not claimed
impossible; exact key is still compared. Vectors use F. SQLpage never reads archive envelopes.

## Marker exact on-disk format

Path `<root>/authority.json`, one JSON object newline optional, format_version=1.
Required `{format_version=1,state,root,epoch}`; root canonical actual root.
States FILE, FILE_TRACKED, CUTOVER_PREPARED, SQL_ACTIVE, RECOVERY_REQUIRED.
FILE epoch0 may be represented by definitive missing marker ONLY before any
transition gate; unreadable/malformed/unsupported format never means FILE.
FILE_TRACKED adds protocol='tracked-file-v1',generation, tracking_epoch=epoch.
CUTOVER_PREPARED/SQL_ACTIVE add protocol='sql-inbox-v1',generation,
operation_id,proof_hash,tail_watermark; epoch is TARGET epoch, never old epoch.
RECOVERY_REQUIRED retains available transition identity and reason; no fallback.
SQL has matching root/epoch/generation/transitionopid/proof_hash authority row.
Atomic native publication is not CAS: valid actualroot owner+serializer performs
expected compare then publish. After-rename errors unknown, reread/reconcile.
FILE_TRACKED DBdown refuses; prepared/active never legacyJSON/log fallback.

## B-produced proof consumed by C (A status)

B runs exact prefix certification outside barrier and persists bounded cert rows
per recipient. For each row C={recipient,source_witness,prefix_revision,
stage_revision,complete=true}, c=SHA(F('prefix-cert-v1',canonical(C))).
Exact certifier equality is PRECONDITION for storing C, not inferred from hash.
Sort recipients; base chain H0=SHA(F('prefix-set-v1',root,generation,epoch));
Hi=SHA(F(Hi-1,recipient,c)). Persist final base_hash; whole scan outside barrier.
Verified ordered tail records append Q0=SHA(F('tail-v1',base_hash));
Qi=SHA(F(Qi-1,decimal(sequence),canonical(verifiedDeltaEvidence))). Evidence has original mutationid/opid/recipient/source range+hash/affected canonical
row hashes and read/resent facts. SQL atomically updates rows+Q+resolved watermark.
No gaps/unresolved/dirty revisions allowed. Final proof_hash=
SHA(F('ready-v1',root,generation,decimal(target_epoch),base_hash,
decimal(tail_watermark),tail_hash,decimal(stage_revision))).
B stores ready row {certificate_id,certificate_revision,proof_hash,generation,
root,target_epoch,base_hash,tail_hash,tail_watermark,stage_revision,complete=true}.
C loads this SAME DB row and CASes revisions/epoch under current owner; no caller
booleans. Final turn handles bounded verified tail only, never recertifies base.
Excess/dirty => backlog beforeprepared. See owner-reconcile/barrier docs.
