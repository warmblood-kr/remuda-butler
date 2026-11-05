# Explicit-server OpenCode adoption (Butler slice)

2026-11-05. Thin owner wiring for PR #896 (`opencode-http-adopt-v1`); the
core helper owns every proof. Default off: `opencode.enabled`.

## Owner action

`remuda butler native adopt-opencode ALIAS --endpoint http://127.0.0.1:PORT
--conversation ses_... --password-stdin`. The password is read from stdin
(redirect a 0600 file) and never appears in argv, the report, the agent or the
roster. Codex keeps its separate `adopt-codex` verb.

## Frozen request

One strict stdin object: `{version:1,binding,nonce,session,endpoint,
conversation,auth{scheme:"basic",user:"opencode",password}}`. `session` is the
actual live `row.id` and `binding` the private `<dir>/manifest.json`. Endpoint
is exactly `http://127.0.0.1:PORT` (port 1..65535, no path/query/userinfo);
conversation is `ses_` + `[A-Za-z0-9_-]`, total <=128, covering the 2.2.5
default 30-char and synthetic `ses_`+32hex forms. Nothing is normalized.

## Outcomes

`_opencode_adopt` exits 0 for both answers: `{"outcome":"adopted",
"generation":"<server start hex>"}` or `{"outcome":"unavailable","reason":...}`
(`auth`, `target_missing`, `already_adopted`, `stale_binding`, ...). The
generation is short lowercase hex (<=16), unlike Codex's 64 hex. Anything else
is uncertain and never binds; no automatic retry. Adoption makes only two GETs
and never POSTs, spawns, resumes or kills.

## Fencing and delivery

Butler fences the fresh `row.id` + opaque instance before and after the helper
yield; a replaced row refuses with `session_replaced_during_adopt`. On
`adopted` it stores only kind/path/nonce/row_id/instance/session_token/
generation and flushes queued mail through `native_publication`. The endpoint,
conversation and credential live only in the 0600 manifest.

`_agent_notice` Request1 is unchanged; the manifest protocol selects the
adopted schema and supplies endpoint/A/auth. Delivery rechecks nonce/session,
pid/start, `/api/info`, exact GET A and the generation immediately before one
`delivery:"queue",resume:true` POST.
