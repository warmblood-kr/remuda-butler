# Idle notice admission

Owner failure trace, 2026-10-16: is_busy=false with a garbled NON-EMPTY
composer caused notice probe/fallback to re-enter the EMPTY-only policy,
20-second timeouts/backoff and four queued notices.

This supersedes earlier notes that unsolicited notice policy is unchanged.
Notice admission now treats explicit is_busy=false as eligible regardless of
composer rendering. It preserves live-session, attached-human pause, shared
known-modal and instance guards. Busy-client queuing still requires EMPTY;
Codex still requires explicit idle before actual notice typing. Unknown busy
telemetry does not gain the new idle admission. Approved prepared text retains
its separate draft-ownership restrictions.

Submission uses existing type_text and verification. It never clears, deletes,
or probes composer contents. Ambiguous failed writes retain the fresh-composer
retry guard to avoid duplicating partially submitted notices. Expired probes
may fall back once per message through the ordinary admission/write path.

Synthetic tests cover idle garbled/nonempty/unparseable input for both agent
kinds, four queued notices and expired probe fallback, human/modal/instance/live
restrictions and unavailable/malformed capture. Existing real classifier tests
preserve known picker recovery. No running target session was modified.
