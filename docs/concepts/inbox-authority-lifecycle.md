# Store lifecycle and real-SQL QA bootstrap v1.4

Additive `Store:close() -> true | nil,error`. First successful close releases
opaque process registry entry and owned guard only if THIS capability still
owns them. Idempotent subsequent close returns true, cannot evict newer owner.
Borrowed inbox DB never closed. All methods except close/status on closed Store
return writer_conflict; status reports closed=true, no false authority claim.
Paused pre-close finalize resumed after close/new Store acquisition revalidates
capability and refuses writer_conflict before publishing/committing. Module
reload uses daemon-owned shared registry; close is not GC-dependent ownership.

Marker uses exact `format_version=1` (not `format`), state and fields frozen in
inbox-authority-final-seams.md. Unknown/newer version => schema_too_new or
unsupported_protocol, zero mutation, never old marker compatibility guesses.

Preferred positive SQL_ACTIVE QA bootstrap is public FILE_TRACKED migration
through Store:advance/transition with actual valid B proof then reopen A. Phase
A alone cannot pretend it has implemented B/C. To test A reads/accept separately,
allow an EXPLICIT test fixture module in tests/ that creates native inbox via
shipped versioned migrations and constructs a REAL matching authority row,
operation receipt and atomic marker by SAME schema adapter C will use. This is
internal fixture setup ONLY: no production config test_mode, no public bypass
or unchecked proof flag, no monkeypatched fabricated query results. Fixture
returns initialized root/db/expected_epoch and records that B/C transition was
not exercised. QA must inspect actual persisted rows through native SQL/reopen.
Physical schema adapter/initializer is writer-owned alongside its versioned
migration; publish its exact fixture entrypoint before binding tests. This note
does not prescribe guessed SQL table names. Any A positive bootstrap lacking
real matching epoch row+receipt+marker is invalid evidence, not a PhaseA pass.
Full transition crash/ready-proof tests remain mandatory in integrated B/C.

Frozen fixture entrypoint proposal: tests/support/inbox_authority_fixture.lua
returns F; `F.create({db,root,json,marker,epoch,generation,operation_id,
proof_hash,tail_watermark=0}) -> {root,db,epoch,generation,operation_id} | nil,error`.
All fields required except watermark default0. Temp EMPTY fixture root only;
refuse existing authority/source state. Writes matching transition committed
receipt+epoch in actual SQL transaction, then supplied atomic marker adapter.
No mail rows invented; tests call real accept_external/deliver to populate.
This initializes SQL read/write prerequisites, NOT evidence of valid promotion.
