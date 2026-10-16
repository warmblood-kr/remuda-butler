# Recent Lua diagnostics: first slice

`remuda butler diagnostics` shows the node-local `*diagnostics*` text buffer in
the existing Remuda TUI preview. `remuda butler diagnostics --page N` selects
an older page of up to twelve events. `remuda butler diagnostics-list` prints the
bounded snapshot for inspecting records that do not fit on screen; add
`--json` for structured output. Both commands accept `--subsystem`
(`mail`, `matrix`, `notice`, `control`) and `--severity` (`info`, `warn`, `error`).
The buffer refreshes as new events arrive. Pages select newest records first;
each page stays small enough to inspect in the existing text preview.

Example (illustrative IDs and timestamps):

```text
Lua diagnostics | local node | memory | 3/200 retained | 0 evicted
TIME (UTC)           LEVEL SUBSYSTEM OUTCOME   REASON / CORRELATION
2026-10-14T04:00:02Z warn  control stopped   heuristic_unknown_choice c-42d1830e679abe22
2026-10-14T04:00:01Z warn  matrix  deferred  delivery_deferred c-70c24d2b8a17cd99
2026-10-14T04:00:00Z error mail    error     inbox_append c-f190abc25e91dc11
Read-only | local node | page 1/1 (newest first)
Heuristic control stop is not agent state. Restart clears history.
```

Time, severity, subsystem, opaque correlation/session ID, outcome and fixed
reason codes answer “what happened?” without retaining message bodies, shell
commands, arguments, credentials, transcripts or raw exception strings.
Retention is bounded and daemon-local; restart clears recent diagnostics.
Absence of records means no retained observation, not proof of healthy delivery.
No historical inbox bodies are scanned to populate the viewer.

## Subsystem success semantics

Success labels describe the subsystem boundary, never agent receipt or consumption:

- `mail delivered/delivery_ok` means inbox acceptance. With disk storage configured,
  body/envelope writes and inbox-log append succeeded; without disk paths it is
  in-memory acceptance. The durable inbox deposit is separate from typing a notice.
  This event does not promise fsync durability or that an agent read the message.
- `matrix delivered/delivery_ok` means the configured delivery callback returned
  a non-nil result without throwing. It establishes callback acceptance, not
  downstream agent receipt, consumption, or a Matrix read acknowledgment.
- `notice observed/heuristic_completion` means the existing composer/screen/busy
  checks completed notice recovery. In particular, `verify_existing` accepts an
  EMPTY composer alone. This is heuristic observed completion/submission, not
  proof the notice reached or was consumed by an agent. The same labels appear
  in the TUI, text CLI and JSON. Notice queue/retry behavior is unchanged.
- `control submitted/write_returned` means the core write returned, not consumption.

The `heuristic_unknown_choice` record means the Lua control heuristic stopped acting. It
does not mean the agent process exited, finished work, or is safe to resume.
Actual process liveness continues to come from the existing session registry.
Correlation tokens group observations within this daemon image; they hide raw
identifiers but are not cryptographic anonymization or authentication tokens.
The ring holds at most 200 events, with an eviction counter. A module reload
retains that ring; a daemon restart clears it.
Module reload also preserves the selected preview page and filters.
These are recent observations, not a durable approval/session lifecycle audit.

The diagnostics command only displays observations. It offers no resume,
approve, retry, delivery or configuration operations. The surrounding existing
TUI still has its ordinary session controls: these are not diagnostics actions.
The owner should leave keyboard focus on the session list while viewing.
Moving the session selection restores that session's preview; `q` exits the
TUI and `l` toggles the list to give diagnostics more horizontal space.

## Existing core constraints

The implementation reuses `remuda.buffer.new`, `Buffer:set`, and
`remuda.window.current():show(buffer)`. Core `native/src/tui.rs` reads plain text
through `capture_buffer`; `_sync_window_shown` preserves an explicitly shown
buffer across refresh ticks. No Rust changes are needed for this first slice.

This core has no arbitrary-buffer picker or Lua TUI key registration API.
PageUp/PageDown operate session scrollback; they do not scroll a shown text
buffer. Therefore this slice promises a live recent tail and the CLI snapshot,
not a complete scrollable diagnostics browser. A later core change can add a
dedicated buffer viewport and explicit diagnostics navigation.
Short terminals bottom-align text and may hide rows; use the CLI listing there.

## Cluster stage

Cluster aggregation is deferred. Existing authenticated cluster transport
rejects arbitrary Lua Eval and has no diagnostics read operation. A later
read-only bounded protocol request should reuse the existing cluster client,
membership authentication and remote polling; it must label each node and
show unavailable/stale plus the last successful observation age. Missing peers
must never be represented as an empty healthy event list. No second transport,
remote execution, state changes or new listener configuration is proposed.
