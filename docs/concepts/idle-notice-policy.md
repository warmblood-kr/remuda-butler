# Idle notice admission

Owner failure trace, 2026-10-16: is_busy=false with a garbled NON-EMPTY
composer caused notice probe/fallback to re-enter the EMPTY-only policy,
20-second timeouts/backoff and four queued notices.

This supersedes earlier notes that unsolicited notice policy is unchanged.
Notice admission now treats explicit is_busy=false as eligible subject to the
composer rule below. It preserves live-session, attached-human pause, shared
known-modal and instance guards. Busy-client queuing still requires EMPTY;
no agent kind waits for idle (see the 2026-10-19 decision below). Unknown busy
telemetry does not gain the new idle admission. Explicit idle runs the same styled-aware
composer decision as the busy path (a dim ghost suggestion reads EMPTY, #137)
and admits an EMPTY or UNPARSEABLE composer. UNPARSEABLE is refused when the
core reports a cursor row (styled capture) with no composer glyph, or when the
screen looks like a dialog (numbered choices, y/n, confirm/cancel hints); on
cores without styled capture unlisted dialogs remain the residual risk. The same policy gates Matrix owner
lines and first-task delivery. is_busy can differ from the pane's prompt
state, so the composer is still checked. Refusals are traced as
notice_prompt (idle ...) and diagnosed. A parseable NON-EMPTY composer (real draft or the
garbled fixture) keeps probe/backoff, since type_text inserts at the cursor.
Distinguishing the owner's real garbled trace is follow-up warmblood-kr/remuda-butler#520. Approved prepared text retains
its separate draft-ownership restrictions.

Submission uses existing type_text and verification. It never clears, deletes,
or probes composer contents. Ambiguous failed writes retain the fresh-composer
retry guard to avoid duplicating partially submitted notices. Expired probes
may fall back once per message through the ordinary admission/write path.

Synthetic tests cover idle garbled/nonempty/unparseable input for both agent
kinds, four queued notices and expired probe fallback, human/modal/instance/live
restrictions and unavailable/malformed capture. Existing real classifier tests
preserve known picker recovery. No running target session was modified.

Leader failure trace, 2026-10-17: the owner's Matrix mail reached the leader's
inbox at once, but its notice waited through 20/60/300/900-second backoff and
was dropped at the retry limit. Two false positives: the retry probe and the
failed-write recheck read the raw screen, so Claude's dim ghost suggestion was
NON-EMPTY (they now use the same styled-aware decision as the policy); and the
known-modal check matched the leader's own report quoting the Teach title. For
notices only, a Claude modal whose last match is followed by transcript rows
(⏺, ✻, ⎿) is a quote, not a live modal. First-task delivery keeps the
fail-closed matcher. Test: tests/butler_notice_ghost_and_quoted_modal.lua.

Owner decision, 2026-10-19: Claude Code and Codex both queue text typed while
they work, so a notice never waits for idle. The Codex-only busy defer (it
was thought to steer typed text into the running task) is gone, and the
recovery probe no longer waits on is_busy for any kind. Busy only pauses the
verification check count. The one exception is an open dialog: the known-modal,
dialog-classifier and composer checks refuse it busy or idle, since typed text
would be taken as a choice. A core "input write already in flight" refusal
still defers and escalates after the busy cap. Test:
tests/butler_notice_no_idle_wait.lua.
