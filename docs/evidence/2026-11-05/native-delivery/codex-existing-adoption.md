# Codex existing-session adoption QA — 2026-11-05

Scope: installed Codex 0.166.0, gpt-6.1-sol identifier, original TUI, private no-auth local Responses mock, read-only/on-request. No account auth/keychain copy, production input, product changes, model seed, queue retry, or operational adapter. Lead authorized the status experiment and one harmless queue after exact target proof.

## Separate trials

Status-only trial: server PID90799, TUI PID90880 (11:03:08Z), private server.sock. Fresh explicit /status resolved UUID 01a1ab60-77c9-7de3-bc53-ad564e8821f1. Provider initially pointed at closed port9; user bind denied, no queue attempted. A private draft followed by typing /status appended literal text; it was never submitted. Trial ended. This is NOT PID/thread continuity evidence for the next trial.

Mock-ready trial: server PID91439 started11:05:18Z; original TUI PID91522 started11:05:32Z BEFORE adoption acquisition. Fresh explicit /status at approximately11:06:04Z resolved:

- unix:///private/tmp/codex-adoption-design.csf5ip_a/server2.sock
- UUID 01a1ab62-aa88-7da2-b941-6e15a8c6021c
- localprobe, Read Only (Ask for approval), zero initial tokens.

Typed private draft DRAFT_ADOPT_6021. ONE codex queue --remote exact-socket --thread exact-UUID, without --resume, accepted ID01a1ab63-689c-7862-aa26-0c48f50c53a0. Original TUI displayed ADOPTION_MOCK_CONFIRMED. Ctrl-L redraw afterward showed exact DRAFT_ADOPT_6021. ps confirmed unchanged PID91522/start and serverPID91439. This proves existing TUI consumption and draft preservation through native queue; synthetic response is not a live model capability test.

Route log contains TWO /v1/responses entries. Exactly ONE CLI queue was invoked; route-to-turn attribution was not captured. Do not equate HTTP count to queue duplication or assert the second was a title helper. Mock logged no bodies/auth. No retry.

## Transitions and resume

After preserving draft evidence, cleared only our synthetic draft. Same original TUI /new followed by fresh /status showed B=01a1ab64-780c-7aa2-acf0-79c3f4d07d22, same endpoint. This demonstrates why old screen UUID cannot track current selection; adoption must not silently retarget A to B.

Exited TUI, launched explicit resume of persisted A through the same private server, and fresh /status again showed A with prior reply history. This is a NEW TUI process, not uninterrupted PID continuity. No second queue. One successful local resume is not general restart/reconnect reliability proof.

## Proposed adoption trust contract (agreement before implementation)

Owner explicitly requests adoption/refresh and invokes /status in the intended TUI. Acquire only a new complete status block after that request in the same terminal/session generation; render ANSI screen state, join wrapped endpoint/UUID fields, reject truncation/ambiguity/stale blocks. Exact socket+UUID is a declared fixed target, not an idle/composer-empty assertion. This trial used human inspection, not an implemented parser.

Corroborate local endpoint ownership and generation independently: absolute local UDS; secure owner/private directory chain and socket; exact peer PID+UID, process start generation, server identity and accessible target UUID. Pin terminal incarnation and fixed thread at adoption; revoke on endpoint/process replacement or reconnect ambiguity. Our probe corroborated private creation, ps identities, and successful exact-target receipt; it did NOT implement adversarial peer/generation verification. Current source labels such as vscode are not causal authority.

Automatic /status injection is unsafe: with a draft it appends; submitting could send human text. Empty-looking composer or quiet screen cannot resolve concurrent typing. Never clear/save/restore arbitrary human input or auto-press Enter. Use explicit owner action; if a draft exists, owner may preserve it through supported UI before invoking status. A future typed side channel would need actual installed support, not passive UUID inference. Native queue itself needs no empty-composer admission gate once binding is valid.

On /new, resume, restart, stale/ambiguous capture: do not infer current selection or auto-retarget. Preserve durable inbox, accepted/uncertain journal semantics and no blind retries; obtain fresh explicit authority when rebinding is requested. Automated parser, busy acquisition, adversarial wrapping/staleness, peer spoofing and crash boundaries remain untested here.

Evidence: adoption-{status,draft-status,mock-status,mock-draft-before,mock-queue,mock-draft-after,new-status,resume-status}.ansi.txt and adoption-mock-routes.txt.

Cleanup: all owned TUIs/server/mock stopped; ps confirmed PIDs91391/91439/91522 absent. Exact /private/tmp/codex-adoption-design.csf5ip_a removed, including home/state/socket/config/fixture. Evidence retained. Default/production runtime untouched.
