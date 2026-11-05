# Fixed-thread bootstrap probe — 2026-11-05

Lead approved disposable follow-up in mail 01M6NHAMW0WG66WNBNCN3C0ZKD.
Installed Codex 0.166.0; private home with model gpt-6.1-sol, read-only,
on-request. Private0700 root /private/tmp/native-codex-launch.c42wpd4g;
auth copy0600. Own app-server PID74993, exec session29843. No production
configuration, daemon or input touched. No model turn or build performed.

Used generated installed experimental JSON schema and WebSocket-over-UDS RPC.
1. thread/start model=gpt-6.1-sol, cwd=private/work, sandbox=read-only,
   approvalPolicy=on-request returned idle thread
   01a1ab16-b733-7212-9fb4-7df3dab1983d.
2. Original TUI `codex resume UUID --remote unix://OWNED_SOCKET` with explicit
   --sandbox read-only --ask-for-approval on-request failed exit1:
   `Permission overrides are not supported when resuming a remote task.`
   Trusted only the empty private work folder before this failure.
3. Repeated launch without those permission overrides failed exit1:
   `thread/resume failed during TUI bootstrap: thread/resume failed: no rollout
   found for thread id 01a1ab16-b733-7212-9fb4-7df3dab1983d (code -32600)`.
4. Created separate explicitly persisted legacy-mode control with same model,
   cwd and permissions plus historyMode=legacy, ephemeral=false. Returned idle
   thread 01a1ab17-9840-76f0-a7a8-9c28bfed217d.
5. Exact-UUID remote TUI launch without permission/model overrides again exit1:
   `thread/resume failed during TUI bootstrap: thread/resume failed: no rollout
   found for thread id 01a1ab17-9840-76f0-a7a8-9c28bfed217d (code -32600)`.

No successful original TUI attachment; no queue-consumption or UI-switch claim.
No model seed sent and no retries of potentially admitted model input. Empty
thread creation alone did not establish a resumable launch in these modes.
A further design must prove an explicit persistence/attachment mechanism or use
registered-member exact task-thread attestation; do not infer first thread from
thread/started, or silently introduce a synthetic model turn to persist history.
Remote-resume permissions must be established server-side rather than supplied
as CLI overrides.

Cleanup: all three TUI invocations exited1. Verified exact server executable
and private socket args before SIGTERM; PID74993 absent afterward. Removed
entire private root including auth/home/state/schema/RPC helper, plus own root
pointer file. Sanitized results only retained here; no credentials preserved.
