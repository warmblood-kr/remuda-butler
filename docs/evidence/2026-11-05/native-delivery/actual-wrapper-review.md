# Independent actual-wrapper QA — 2026-11-05

Candidate: native-core feat/native-session-binding, baseline65ebf812 plus
uncommitted checkpoint#3. Binary /private/tmp/native-delivery-core-target/debug/remuda
SHA256 c85e0ae86194054dfe0936f307a40fc1e5f8e7ba895a481c8c114ebaaccf03c3.
At start no reviewed source mtime exceeded binary. No QA product edits/builds.
Programmer test claims are distinct from the independent results below.

## Isolation and model

Probe scripts d/e/f/g in child workspace use private0700 disposable roots,
0600 config/manifests, isolated XDG/config, disabled project/Claude config,
allowlisted env without copied credentials, installed real OpenCode2.2.5,
loopback bounded Chat SSE mock with synthetic token. Actual original TUI,
not a shim. Explicit inherited conflicting primary password exercises override.
No HOME override or production session/input; no global egress fence claimed.
Roots removed; only owned handles/PIDs stopped. No active probe remains.

First attempt stopped before prompting because new session.model was unset.
Pinned config/model.ts supports model='qa/qa-model'. Verified effective model
via GET /api/model/default?location[directory]=OWNED_WORKSPACE: data.providerID
qa, data.id qa-model. No session-model override or arbitrary fallback used.

## Delivery proof and limits

probe-d-result.json: wrapper85306/server85317/originalTUI85322, all started
19:30:22KST, generation65f84fba4c59c-65f84fba4e8fb,
session ses_4ae021d7b1a0e0b64c571541599e5afd. Those identities are expired.

- Actual helper accepted canonical notice, saved it, original TUI rendered it
  (strip terminal CSI and await render; immediate raw byte lookup was too early).
- Busy queue: during held A only A mock call, one pending B; after release B
  starts after A DONE. Both helper calls accepted_queue.
- Seeded idle/busy draft text later submitted exactly once each; native text
  saved separately. This is preservation evidence, never an admission gate.
- Original TUI/server start identities and wrapper unchanged throughout cases.
- Caller intentionally discarded one helper ACK, invoked helper once, observed
  one saved message without retry. This is caller ACK uncertainty evidence;
  not a forced HTTP-response loss or proof of Butler tombstone persistence.
- Fixed A/UI B passed in final focused E: activate owned B, supported ctrl+o
  recent switcher/highlight/Enter. PTY sentinel saved only B proves selection;
  subsequent actual helper native notice A1/B0, wrong nonce invalid_binding,
  zero PTY writes during native/refusal. Earlier picker attempts failed proof,
  no targeting failure inferred. Final probe-e-result.json passed=true.
- Ctrl+x q did not exit TUI; D aggregate passed=false reflects this unresolved
  keyboard cleanup check plus then-pending UI navigation, not failed
  admission/busy/draft cases. No repeated delivery beyond needed cases planned.

## Lifecycle proof

probe-f-result.json passed=true:
- Preexisting manifest startup failure exit1, original content preserved,
  three observed owned children stopped.
- Stop owned server early, observe watcher, kill wrapper before manifest:
  server stopped; manifest absent. Covers watcher-fenced startup only.
- Published wrapper killed: server stopped; stale manifest helper refused
  definitely_not_written/wrapper_gone. Zero model calls in these cases.

probe-g-result.json passed=true: real wrapper85704/server85715/TUI85720,
generation65f85058aa9dd-65f85058ac8c7. Owned TUI SIGTERM -> wrapper exit130,
manifest removed; original TUI, server and watcher stopped. This is normal
wrapper teardown after its TUI terminates, not keyboard quit evidence.

## Security review and remaining gate

Checkpoint#3 adds owned private pinned dir, fd-relative nofollow/nonblocking
leaf operations, own-inode partial-write cleanup, both auth env overrides,
live PPID/start identity, exact target token, typed receipt validation and
macOS/Linux-only capability. Controlled probe source gates cleared.
No same-UID hostile mutation isolation claimed: canonicalization/ancestor
check and inode-check/unlink are not atomic against a same-UID adversary.
Real macOS server-spawn BEFORE watcher-spawn death window remains uncovered;
watcher's first parent check cannot help when watcher was never spawned.
No zero-window lifecycle claim. Final E wrapper87271/server87283,
generation65f851c5d6ba3-65f851c5e1552, session
ses_3d4968e83ce5e1cb4387f1788b53784a; teardown130/manifest removed/server
stopped, full cleanup. No core functional blockers remain in planned matrix;
QA supports progression with stated limits. Leader/programmer notified
01M6NMQDB02305V7XT6YWP4APA / 01M6NMQG8RC9PAMQCEFM2TE2AJ.
Butler journal and integration have separate review gates; see companion tests and PR status.
