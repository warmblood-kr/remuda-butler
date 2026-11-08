# Full authority integration QA RED and caller map v1.2

Use actual native inbox SQLite/schema plus real isolated source/content files;
DB-capable661+ core. No fakeSQL result establishes transactional correctness.
Every negative pairs a positive and asserts classified failure or unknown, not
simply any rejection. Existing pure/source/backend tests remain separate gates.
No live reload/send/replay/session operation required by these isolated tests.

Public Store gates for next QA:
1. M.open FILE with legacy source and actual DB -> status FILE, staged progress;
reopen SQL_ACTIVE marker+matching SQL epoch -> SQL status. Marker schema newer,
root mismatch, SQL epoch mismatch, corrupt/missing DB under prepared/active ->
refusal; zero legacy metadata/log opens after SQL_REQUIRED, including errors.
2. deliver intent -> same id/fanout/read defaults/first order; duplicate opid
same hash -> original result after reopen; altered hash -> operation_conflict.
SQL statement failure before commit -> original state; real COMMIT forwarded
then wrapper loses return -> unknown, reopen reconcile original result. No new
ULID/log append/fallback to resolve ambiguity. Fanout rows+receipt all or none.
3. accept_external account/room/event/destination + exact payload -> one original
receipt/mail id. Retry after mark_read, process restart and simulated relaystore
rebuild/device/epoch change -> same result, no unread resurrection. Different
payload same stable key conflicts. Different account/room/event/destination is
independent. Concurrent duplicate SQL uniqueness still returns original id.
Hash checked, not caller-controlled overwrite. No transport is dispatched.
4. page keyset upper_seq fences late delivery. Rendering A succeeds/B object
missing => ack only A; B stays unread. mark_read from wrong epoch/recipient or
id outside captured upper_seq refuses. Page SQL failure returns no fake empty
and no ack. SQL metadata changes while archive JSON stale -> SQL value shown;
corrupt archive envelope never affects SQL render. Corrupt body fails locally.
5. transition exact certified staged prefix+tail -> prepared marker/SQL epoch+
receipt/final marker same opid. Inject crash before/after every atomic publish
and COMMIT; restart converges same epoch or reports unknown. Native publication
error AFTER rename rereads identity, never selects old FILE. Unsupported marker
protocol refuses before source mutation; cooperating second writer lock refused.
6. Many-message sealed-prefix migration max_tasks1; append new deliveries and
readB/resent changes BETWEEN EVERY call; reopen between calls. Prefix cursor
monotonic despite growing EOF; source+tail canonical A(R),Aplain retainsR;
R2 replaces. Some arrival follows an intent and precedes tail-stage commit:
restart adopts actual bytes once. Intent before append crash invents nothing.
New recipient/read-only orphan discovered while migrating. Continuous arrivals
never reset whole prefix. At finite catchup capacity pump finishes; short final
barrier captures T and routes next callback to SQL. No broad human-input pause.
Damaged torn line returns unresolved/backlog, never ready or drop. Hard overload
is backlog with evidence, not a false unconditional fairness guarantee.
7. Reverse/export preserves SQL-only deliveries+read+refs/order before FILE;
failure leaves SQL-required, no marker deletion or starting unsupported old code.

Caller integration map (repository current entrypoints):
- main.lua: open authority BEFORE mail loading/import selection; every inbox
and explicit message command uses centralized selection. Post-inbox notice
clearing only numeric proven unread==0; unknown never clears marks.
- mail.lua: delivered/reply/forward authorization from SQL membership under SQL;
queue/send/read/legacy-alias paths invoke Store mutation or migration live hook.
load_inbox/page/hydrate reads SQL metadata after preparation, body files only.
No stale bus.messages/mail_read cache can override epoch/SQL facts.
- commands.lua close/autoclose: unknown unread errors/refuses, no close.
Explicit operator force retains existing meaning; no migration auto-force.
- compaction.lua: unknown lookup defers with lookup_failed, no compaction.
- sessions.lua: unknown renders mail marker ?, never absent/0.
- schedule.lua: last mail status must prove read before another reminder;
unknown skips, no extra send.
- notice.lua: admission requires is_unread==true; unknown skips and retries
later. Prune accepted/clear seen only on ==false. Stuck uncertainty retains
records; reminders retain sent_at to avoid storm. No unknown->false coercion.

One actual error injection per caller proves no close/compaction/prune/send or
stuck clearing. SQL_REQUIRED DB-down remains unknown through all wrappers; a
pcall success containing nil is not a proven empty inbox. Lifecycle pump owns
round-robin fairness and reloads pending migration/operation identities.
