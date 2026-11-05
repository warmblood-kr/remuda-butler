# Native automatic notices — final plan

Wave 1: OpenCode native only. Butler 8f8cfc7/core 65ebf812. No merge/rollout.

## Contract

- Fixed launch-owned conversation (new launch = new ID); never UI selection.
- Delivery never creates/resumes an engine/session or seeds a model; no retarget.
- Attachment/busy/composer never block admission; no empty predicate.
- Bound: no PTY fallback. First-task/startup/owner-input/general send unchanged.

## Scope

- OpenCode: actual 2.2.5+model mock A/B/C passed. Owned launcher/fixed session; core `_opencode_tui` + constrained `_agent_notice` OpenCode protocol.
- Codex: existing-target native queue is proven on a running TUI (exact
  socket+UUID, no `--resume`, one queue consumed in the same PID with the exact
  draft preserved). The blank pre-created-thread bootstrap is one failed path,
  superseded; resume is a new process. Adoption needs fresh explicit authority
  (injecting `/status` into a draft is unsafe). Parser/tunnel contract is pending
  design/QA; the current wave stays unbound PTY.
- Claude: official fakechat proved one same-TUI inbound event in the original
  process; a correlated model reply/consumption is blocked by the actual account
  hold, and unopted late adoption is unestablished. Contract pending design/QA;
  the current wave stays unbound PTY.
- Common ledger/read-only status/attach-gate removal apply all three; native only OpenCode.

## Core PR

- `_opencode_tui`: protected loopback HTTP server; fixed session created before TUI attaches via --server/--session; no guessing/adoption; private 0600 manifest.
- Descriptor: schema/version, nonce, Session.id, wrapper/server pid/generation, endpoint, fixed conversation, auth ref. Manifest never asserts instance; Session.id != instance_id.
- Secret only 0600 manifest/owned server/TUI env; never Butler bus/journal/argv/output.
- Validate ownership/no symlink, pid/generation, auth, target; remove manifest/stop owned children; keep parent-death; no agent restart on delivery.
- `_agent_notice`: frozen request + expected nonce/session + binding path via stdin; typed JSON; no arbitrary endpoint/model.
- OpenCode POST fixed session: delivery=queue; resume only schedules the existing loop; never create/resume; validate grammar/IDs/ownership/server/target; timeout/unknown -> uncertain.
- Only a Lua `row.id` projection: add the existing `SessionSummary.id` in `Response::Sessions` plus fixtures; `native/tests/api/v13.lua` + api_versions entry; v5 frozen, v12/889 gap documented, no cherry-pick; nil -> unbound/PTY.
- Avoid codex_tui.rs changes; preserve PR889 .observed ordering named regression.
- Nonce join: path/nonce before remuda.new; finish joins the returned instance + current row; roster path/nonce; adoption same live instance; each write fresh row.id+instance+nonce.

## Butler PR

- Default-off; probe capability before launches.
- Roster path/nonce only; adoption exact instance + row.id.
- Unbound one atomic PTY; bound no PTY fallback; pre-write refusal alert/defer/uncertain, no retarget.
- Remove the attached-only refusal/PTY fallback; keep identity/live/instance/binding; no composer predicate.
- Journal DISPATCHING and UNCERTAIN persist for all automatic PTY/native attempts, crash-safe: recipient/message IDs, instance, row.id, nonce/generation, frozen request/body, state; no endpoint/auth secret.
- UNCERTAIN tombstones never release on inbox read, compaction, reshow, stuck closure, reload or full restart (556 regression). Native accepted_unread releases only on canonical read; uncertainty stays bounded fail-closed. PTY accepted keeps legacy reminders and may retire a known-successful entry; native accepted suppresses duplicate/reminders until read.
- Cap full/save failure blocks ANY write requiring the journal and alerts; no silent PTY bypass.
- Restart dispatching -> uncertain before unread seeding.
- No lost-ack retry either protocol; only proven pre-write refusal may retry/fallback after fresh validation.
- Read-only status/doctor: accepted_unread/uncertain with recipient/message IDs, age, reason; no endpoints/secrets.
- Recovery: inspect target + operator NEW explicit Butler mail; no mutating reconcile CLI; no automatic original-ID release.

## Verification

- Design/QA first; 2–20-line composed functions; injected boundaries; unit tests.
- Negative: no new session/resume, immutable request, one dispatch, crash before/after ACK (native+PTY), persistent uncertainty across read/reload/restart, cap/save failure, symlink/permission/stale generation/pid/target, manifest instance claim, wrong auth, untrusted nonce/path, nil row.id.
- Real wrapper: disposable OpenCode 2.2.5+mock model; attached idle/busy/draft; fixed A after UI B (B zero); bound refusal not PTY; Codex/Claude current-wave unbound PTY; PTY accepted reminders unchanged.
- No production writes/config; regressions+review; separate core/Butler PRs; no merge/rollout.
- Core first coding may start after final AGREE; contract is shared.
