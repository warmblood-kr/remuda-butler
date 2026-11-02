# Codex model picker and input recovery

Codex compaction keeps the session's current model and effort. It sends
`/compact` directly and never opens `/model` to save compaction cost. This can
use a more expensive model than the old temporary Luna switch, but avoids
picker failures and restoration drift. Explicit user model changes remain Codex's.

The old helper opened Luna's effort picker before applying any model change.
Seeing Luna in its title did not establish that Luna was the active model.
Codex 0.162.1 adds descriptions and `More reasoning…` (Max/Ultra), which the old
ownership validator rejected; the same gate then rejected cleanup ESC. Baseline
abort could discard the prior settings, so they cannot always be reconstructed.

## Recover an existing stranded picker from Matrix

After updating/reloading Butler, the configured allowlisted human owner can send
this plain single-line message in HOME:

```
!recover-input SESSION
```

This code route works with typed-lines off and while the agent's pane is blocked.
It is unavailable to agent Matrix accounts, other rooms, backfill, edits, stale
messages and replays. It does not create a general terminal-key channel.

The event must be durably consumed before recovery begins. A complete known
Codex model/effort picker, a live instance ID, an unchanged agent registration,
and a successful audit are required. A running compaction workflow keeps its own
bounded cleanup; owner recovery refuses to race it. Every ESC is checked against
the same instance and exact observed dialog again after audit. At most two ESCs
are sent, with a five-second observation timeout after each. No model row, `s`,
Return or prepared text is sent. Unknown menus and ambiguous repaint stop safely.

The Matrix thread reports completion only after the picker is gone and the
composer is verified empty with a model/effort footer. It reports initial actual
model metadata when available, initial effort as unknown, candidate picker model,
and resulting model/effort. It does not infer or restore lost intended settings.
If the reported current settings differ from the owner's intent, resolve that
explicitly before normal work; do not equate the picker title with actual model.
Queued inbox mail remains durable and its notice resumes when the modal resolves.
An extended modal wait opens the existing stuck record after 15 minutes; it does
not spend the text-delivery retry budget. Existing submission verification pauses
through the modal and resumes afterward, preventing a second automatic submission.

A crash after durable consumption can leave the action or reply uncertain. There
is no automatic replay: review the result and send a fresh command if necessary.
A refusal/timeout is not successful recovery. No full screen, prompt or prepared
text is included in recovery audit/reporting.

## Configuration and validation

`model_reasoning_effort` is the supported Codex config key. Remuda `_codex_tui`
forwards `-c KEY=VALUE` to its app-server and the requested model to both server
and TUI client; setting a default is not a structured update of an existing TUI
picker. This fix preserves `gpt-6.1-sol` / `low` instead of rewriting config or
adding another live model-switch mechanism.

Private real Codex 0.162.1 validation used a blank isolated CODEX_HOME: Sol low
footer -> model picker -> Luna effort -> ESC -> model picker -> ESC -> Sol low
empty composer. No model turn was submitted and the private config stayed unchanged.
Regression fixtures exercise current-model success/failure, legacy restore,
strict menu recognition, audited bounded cancellation, Matrix owner admission,
queue retention through owned/unowned modals, and resumption without duplication.
