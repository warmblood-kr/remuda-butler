# Wire contract reference and provenance limits

The SINGLE source of truth is [Final A/B/C seams v1.4](inbox-authority-final-seams.md).
This note defines NO alternate domain, marker protocol, tuple or proof hash.
It supersedes/withdraws the earlier wire proposal and its transition P tuple.

Implementations and QA must read the exact final-seams document for:
- byte framing/canonical JSON/SHA adapter rules;
- butler-external-key-v1 and butler-external-payload-v1 domains;
- external-v1- operation id;
- marker `<root>/authority.json`, `format_version=1`, tracked-file-v1 and
  sql-inbox-v1 state-specific fields and target epoch;
- B-produced persisted certificate/base/tail/proof_hash and C's CAS consumption.

No source-progress-v2 or synchronous source-v1 change is introduced here.
A helper shared by product and adapters should implement the final byte rules;
QA retains independent fixed vectors rather than regenerating all expected
values from that same helper. Unknown prepared transition reconciles its
original identity; no fresh opid to bypass ambiguity.

## Legacy provenance limitation

Imported legacy envelopes may lack stable receiving account identity or original
raw-event payload/canonical preallocation metadata. Rendered inbox text, fetched
context, allocated id or current device/epoch cannot manufacture that evidence.
Do not invent a historical input hash or new receipt and claim it matches a
future same-source retry. Preserve original mail id/read state and report
unproven provenance/unknown or conflict without duplicate insertion. Any policy
for adopting legacy external keys needs explicit source evidence and QA cases.
This limitation does not authorize replay of uncertain external writes.

Design role remains documentation/independent review only; no executable code
or product implementation authored by this note.
