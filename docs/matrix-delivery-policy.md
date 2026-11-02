# Matrix delivery policy composition

`butler/matrix_delivery_policy` publishes `matrix.delivery_policy` before the
relay module loads. `accept_received` and `accept_pending` compose the same
notification-mode selector with mention and followed-thread eligibility.
`followed` and `accept_mode` are the constituent policy functions. The module
does not change subscriptions, issue requests, write relay state, or deliver mail.

The relay uses `accept_received` for ordinary receive eligibility and typed-line
room eligibility, and `accept_pending` immediately before context/delivery work.
Receive-time validation, trusted-mention auto-follow, per-room rate limiting,
context fetches, routes, acknowledgments, dead-letter/retry handling, cursor
persistence and lifecycle cancellation stay with the relay.

Modes retain their existing defaults and behavior: HOME defaults to `all`,
additional rooms to `mentions-followed`, and `none` suppresses all notifications.
Only `m.thread` roots confer followed-thread eligibility; an `in_reply_to` link
alone does not. A trusted mention still auto-follows even in `none` mode. Pending
mail is checked against current mode and follows: removing a recorded
`mention_follow_root` revokes that pending mention's eligibility, unless its
thread is independently still followed. Historical pending entries without that
field keep the original mention rule. Suppressed pending mail is durably marked
processed; changing policy later does not resurrect it. Policy functions are
not an authorization boundary: sender validation and command gates remain in
their existing modules.

## Reevaluation and restart boundaries

The refactored relay resolves `matrix.delivery_policy.accept_received` or
`accept_pending` at each decision, rather than capturing their functions when
the relay instance is created. The policy module builds a complete new table
and then publishes it on the retained Matrix table. Reevaluating **only that
module** can therefore affect subsequent policy calls in an instance created
with this refactor, including events waiting for context or a retry. It does
not run an immediate pending sweep; the next existing callback/poll does that.
It does not replay processed events or retroactively alter completed deliveries.

This is explicit late binding, not general hot reload. Merely moving code into
a helper does not replace a function captured by an already-running closure.
In particular:

- Installing this initial refactor requires loading the new policy module and
  restarting the relay with the new factory. An instance created from the old
  inline implementation never consults this interface.
- Reevaluating `butler/matrix_relay` changes its public factory and entry points,
  but preserves `relay.instance`. Its existing receive/delivery/retry/context
  closures keep their old code. After relay implementation changes, reevaluate
  the modules and stop/start the relay. Stop invalidates callback generations
  and cancels owned requests/timers; start reloads durable state.
- The relay's config reader and injected transport/delivery functions are
  captured at module or instance construction. Changes to those bindings need
  module reevaluation and/or a new relay instance, respectively. Policy-only
  reevaluation does not rebuild configuration, transport or delivery closures.
- Both relay and policy retain the original Matrix table. Replacing
  `remuda.butler.matrix` with a different table is outside this contract; create
  a new relay from modules evaluated against the replacement table.
- Lua source edits on disk alone do nothing. `remuda.exec` is the package loader;
  an explicit reevaluation or lifecycle activation must execute the new source.
  Policy evaluation does not use `require` or `package.loaded` caching.
- On pinned core `97d79d2`, executing a Lua leaf (`butler/...`) reads/evaluates
  its source, while top-level `remuda.exec("butler")` leaves an already-active
  lifecycle module alone. Top-level lifecycle reload is a distinct operation;
  `remuda.reload` requires a lifecycle module. Do not infer that executing the
  active top-level module restarted the relay. These loader boundaries were
  inspected in core `native/src/script.rs` (`load_package`/`activate_package`)
  and `native/src/packages.rs`, not exercised on the installed Butler.
- Normal Butler lifecycle activation stops the old relay in `main.lua` and
  starts the configured new relay in `init.lua`; this differs from directly
  reevaluating the Matrix leaf modules. Existing documented startup-only config
  fields still require restart; this refactor does not broaden live config reload.

No installed package or live relay was updated/reloaded while preparing this
change. Any later installation or activation remains an owner operation.

## Regression evidence

Run from the repository root with the pinned core:

```sh
REMUDA_BIN=/private/tmp/remuda-notify-policy/target/release/remuda bash tests/butler_matrix_relay.sh
luajit tests/butler_approve_text_syntax.lua
git diff --check
```

The relay suite uses a temporary HOME/state and scripted HTTP, not a homeserver.
Its existing coverage includes notification switches during context waits,
unfollow during pending delivery, follows and mail routes across restart,
durable acknowledgments, retries, context cancellation and lifecycle behavior.
Three additional registered tests cover the policy mode/mention/follow table,
composed pending suppression persisted across restart, and reevaluation on a
retained instance. They demonstrate that factory/closure identity remains
unchanged for existing instances while future policy lookups see a new table;
a separately captured old function remains old. Reevaluation is tested with
worktree `dofile` under the pinned core, not installed-mod lifecycle activation.
