# Native OpenCode integration — phase 2 seam plan

Phase 2 is wired, default off, uncommitted pending review. Companion-only;
core wrapper/helper is `native-delivery-code`.

## Selection (sticky per launch)

- Private config `<config>/remuda/butler/native.json` (`version:1`,
  `opencode.enabled`, default false), read once per launch. No mutating
  `native on|off` CLI in this slice; read-only status only. The switch selects
  only a NEW OpenCode launch; the decision is stored as `native` or `pty`.
- A bound native launch never becomes PTY. Sticky is the protocol/target
  lifetime: typed helper/manifest loss => in-memory `disabled` + alert (image
  lifetime); untyped runner/spawn failure => `uncertain` (no retry, no PTY).
  Mail stays queued; only new launches read the toggle; unbound legacy is the
  only PTY path.

## Launch seams

- `agents/opencode.lua` `builders.opencode(spec)`: with `spec.native` return
  `{ "remuda", "_opencode_tui", "--binding", spec.native.binding, "--cwd",
  spec.cwd }`; else today's `opencode --standalone`.
- `launch.lua`: before `remuda.new`, the plan creates the private nonce dir
  with `remuda.fs.mkdir_new` (nonce = hex of `remuda.random_bytes(n)`) and
  passes `<dir>/manifest.json` as `--binding`; the wrapper creates that file.
  Never `REMUDA_SESSION_ID`: the core assigns Session.id; env carries the nonce.
- Join uses what Butler owns: fresh `row.id` (core-assigned session), opaque
  `instance_id` and our nonce. Butler does NOT parse the manifest from Lua: it
  contains `auth.password`, so reading it would materialize the secret.
  `generation`/`conversation` are correlation-only.
- New `native_config.lua` (pure): config read; one capability probe per boot
  (`remuda _opencode_tui --capability`); require protocol `opencode-http-v1` and
  a usable binary.
- If Butler needs a filesystem property Lua does not expose (0700 owner, 0600
  no-follow), report the missing seam instead of guessing; the core helper
  stays the authoritative validator.

## Roster / join

- `roster.lua` row gains `native = { path, nonce }` only. Adoption needs the
  exact live `instance_id` AND fresh `row.id`, then performs one fresh helper
  validation against that same target. Missing identity is refused, never a new
  target and never PTY. No native block is unbound/PTY legacy.

## Delivery seams

- `notice.lua`: native mode selects the native dispatcher, else today's PTY
  capability. Journal `begin` runs before any yield (`protocol="native"`, frozen
  canonical text) and DISPATCHING reserves the IDs. One request/body and one
  `request_id` are frozen at DISPATCHING; a re-show is a new dispatch with a new
  request_id; unknown is never retried, so it never gets a new id.
- New `native_dispatch.lua` (pure): one stdin JSON to `remuda _agent_notice`
  via `remuda.process.run{stdin=..., timeout=15}` (no temp file/shell).
  Immediately before spawn revalidate the frozen decision and generation fence;
  no intervening yield.
- Outcomes: `accepted_queue` -> journal `accepted_unread`, no reminder until
  canonical read; `definitely_not_written` on a LIVE binding -> retire
  reservation, bounded retry only after fresh validation; `definitely_not_written`
  on a DEAD binding -> `disabled` + alert, preserve mail, no replay, never PTY;
  `uncertain`/transport/400/409/5xx/receipt_mismatch -> journal `uncertain`,
  never retried. Disabled and UNCERTAIN are distinct states.
- Text is the core's canonical pointer exactly (single: no sender detail; multi:
  count only). A re-show uses the same single pointer with the original ID and a
  new request_id. PTY text is unchanged.

## Read-only status

- `delivery_journal.status()`: counts by state, oldest age, recipient/message
  IDs, reason, corrupt/blocked/full/unverified.
- `packages/butler/delivery_status.lua` + `remuda butler doctor`: one
  `Automatic delivery` block (no secrets, paths or bodies).

## Tests (injected seams; no real agent in units)

- Config: default/on/invalid => off; a toggle after launch changes nothing.
- Capability: exact protocol/missing/timeout; false affects new launches only.
- Launch argv/env: native wrapper argv + nonce env only; no invented session id;
  absent decision => unchanged PTY argv.
- Join: fresh row.id+instance+nonce; wrong/missing => no binding; a fresh launch
  is a new decision.
- Sticky: helper/manifest gone => disabled + alert, zero PTY; adoption of the
  same fixed binding may re-probe once but never invents a target; uncertain/
  dispatching/accepted IDs stay journal-suppressed.
- Delivery: accepted_queue => accepted_unread until read; live refusal => safe
  retry; dead-binding refusal => disabled, no replay, no PTY; uncertain/HTTP =>
  uncertain survives read/restart.
- Fence: reload during persist/any yield => zero transport; an old generation
  cannot mutate the replacement journal.
- Journal: one request/body frozen at DISPATCHING; re-entry is one request;
  crash before/after ack is uncertain.
