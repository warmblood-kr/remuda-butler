-- Common notification admission (phase 1: canonical mail/report/reply/forward/
-- schedule/reminder/seed/recovery/reshow all converge here through `_butler_notify`).
--
-- One OODA pass, executed by this module, not labelled:
--   observe  fresh live agent + recorded native decision, never cached authority
--   decide   native | legacy_transition | disabled | unavailable
--   construct one typed agent adapter (OpenCodeAgent/CodexAgent/ClaudeCodeAgent,
--             or LegacyAgent) with kind and incarnation frozen before the
--             journal reservation and its first yield
--   reserve  the existing notice journal attempt (injected seam)
--   act      one bounded transport action
--   resolve  the existing notice outcome seam
--
-- The delivery journal, its generation fence and its outcome policy stay in
-- notice.lua; this module never journals, retries or writes mail. The mail is
-- already durable before admission; a missing adapter leaves it durable and
-- unread. This is a product-path guard, not same-account security isolation.
local M = {}
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.send_policy = M

-- One-shot binding of the genuine notice owner image. The seam factory is a
-- closure over the live notice module's journal/current/outcome functions; it
-- is never accepted from a caller and never persisted.
local bound_owner, bound_make_seam

local NATIVE_KINDS = { opencode = true, codex = true, claude = true }
local DEAD_BUILD_REASONS = { invalid_binding = true, invalid_nonce = true,
  invalid_session = true, invalid_instance = true }

local function notice_bus()
  return remuda._butler_bus
    or (remuda._butler_notice_config and remuda._butler_notice_config.bus) or {}
end

local function frozen_native(native)
  if type(native) ~= "table" then return nil end
  return { mode = native.mode, kind = native.kind, path = native.path,
    nonce = native.nonce, session_token = native.session_token,
    row_id = native.row_id, instance = native.instance,
    reason = native.reason, awaiting_publication = native.awaiting_publication,
    awaiting_since = native.awaiting_since }
end

local function same_binding(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then return left == right end
  return left.mode == right.mode and left.path == right.path
    and left.nonce == right.nonce and left.row_id == right.row_id
    and left.instance == right.instance and left.kind == right.kind
    and left.session_token == right.session_token
end

-- Observe only: no kind switch is stored, no method is attached to the agent.
local function observe(session)
  local bus = notice_bus()
  local agent = type(bus.agents) == "table" and bus.agents[session] or nil
  if type(agent) ~= "table" then
    return { session = session, mode = "unavailable", reason = "session_unknown" }
  end
  local native = type(agent.native) == "table" and agent.native or nil
  local mode = "legacy"
  if native then
    if native.mode == "native" then mode = "native"
    elseif native.mode == "disabled" then mode = "disabled"
    else mode = "unavailable" end
  end
  return { session = session, agent = agent, id = agent.id, kind = agent.kind,
    instance = agent.instance_id, generation = remuda._butler_notice,
    native = native, mode = mode, reason = native and native.reason }
end

-- Decide: only a recorded native binding may use a helper; a disabled or
-- unknown record never falls back to a PTY, and an unbound member keeps the
-- existing audited legacy wakeup during the staged transition.
local function decide(observed, intent)
  if type(observed) ~= "table" then return nil, "native_state_unavailable" end
  if intent ~= "mail_notice" then return nil, "unsupported_intent" end
  if observed.mode == "native" then
    local kind = (observed.native and observed.native.kind) or observed.kind
    if NATIVE_KINDS[kind] then return "native" end
    return nil, "native_kind_unavailable"
  elseif observed.mode == "legacy" then
    return "legacy"
  elseif observed.mode == "disabled" then
    return nil, "native_disabled"
  end
  return nil, "native_state_unavailable"
end

local function live_agent(adapter)
  local bus = notice_bus()
  return bus.agents and bus.agents[adapter.session] or nil
end

-- The constructed adapter is the frozen incarnation for this attempt: replacing
-- the agent, kind, instance, module image or binding invalidates it.
local function current(adapter)
  local agent = live_agent(adapter)
  if agent == nil or agent ~= adapter.agent then return false end
  if agent.id ~= adapter.id then return false end
  if agent.instance_id ~= adapter.instance then return false end
  if remuda._butler_notice ~= adapter.generation then return false end
  if adapter.route == "native" then
    return same_binding(agent.native, adapter.native)
  end
  return agent.native == nil and adapter.native == nil
end

-- Fixed transport factory, consumed synchronously below at module load from
-- native_dispatch's one-shot handoff. No caller-supplied runner, verb or
-- options reach it, and the public install door is gone after this module is
-- initialized.
local make_channel
local function channel_for(kind)
  if not make_channel then return nil, "native_transport_unavailable" end
  return make_channel(kind)
end

local function native_agent(observed, kind)
  if not NATIVE_KINDS[kind] then return nil, "native_kind_unavailable" end
  local adapter = { route = "native", kind = kind, session = observed.session,
    agent = observed.agent, id = observed.id, instance = observed.instance,
    generation = observed.generation, native = frozen_native(observed.native) }
  function adapter.send(attempt)
    if not attempt.still_current() then return nil, "journal_generation_changed" end
    if not current(adapter) then
      return nil, "native_not_written: stale_attempt"
    end
    local row, target_why = attempt.target(adapter)
    if not row then return nil, target_why end
    if type(attempt.request_id) ~= "string" or attempt.request_id == "" then
      return nil, "native_not_written: request_id_unavailable"
    end
    local channel, channel_why = channel_for(kind)
    if not channel then
      return nil, "native_not_written: " .. tostring(channel_why)
    end
    local claim, build_why = channel.prepare({ binding = adapter.native.path,
      nonce = adapter.native.nonce,
      session = adapter.native.session_token or adapter.native.row_id,
      instance = adapter.native.instance, request_id = attempt.request_id,
      text = attempt.text, message_ids = attempt.ids })
    if not claim then
      if DEAD_BUILD_REASONS[build_why] then
        return nil, "native_dead: " .. tostring(build_why)
      end
      return nil, "native_not_written: " .. tostring(build_why)
    end
    return channel.send(claim, function()
      return attempt.still_current() and current(adapter)
    end)
  end
  return adapter
end

local function legacy_agent(observed)
  local dialogs = remuda.butler and remuda.butler.dialogs
  local send = dialogs and dialogs.automatic_notice_send
  if type(send) ~= "function" then return nil, "legacy_adapter_unavailable" end
  local adapter = { route = "legacy", kind = observed.kind,
    session = observed.session, agent = observed.agent, id = observed.id,
    instance = observed.instance, generation = observed.generation,
    native = observed.native }
  function adapter.send(attempt)
    -- The audited dialogs preflight runs first (live row/instance), then this
    -- generation-fenced guard immediately before its raw write.
    local function guard(observed)
      return current(adapter) and attempt.still_current(observed) == true
    end
    local ok, sent, reason = pcall(send, adapter.session, attempt.text,
      attempt.ids, guard)
    if not ok then return false, tostring(sent) end
    return sent == true, reason
  end
  return adapter
end

-- Three thin typed constructors share one implementation; the registry is
-- closed, so no observed kind can select an unregistered adapter.
local function OpenCodeAgent(observed) return native_agent(observed, "opencode") end
local function CodexAgent(observed) return native_agent(observed, "codex") end
local function ClaudeCodeAgent(observed) return native_agent(observed, "claude") end
local function LegacyAgent(observed) return legacy_agent(observed) end
local AGENTS = { opencode = OpenCodeAgent, codex = CodexAgent,
  claude = ClaudeCodeAgent, legacy = LegacyAgent }

local function construct(observed, route)
  if type(observed) ~= "table" then return nil, "observe_unavailable" end
  local key = route
  if route == "native" then
    local kind = (observed.native and observed.native.kind) or observed.kind
    if not NATIVE_KINDS[kind] then return nil, "native_kind_unavailable" end
    key = kind
  end
  local build = AGENTS[key]
  if not build then return nil, "route_unavailable" end
  return build(observed)
end

-- Typed internal result. Never persisted and never a new journal.
local function typed_result(fields)
  fields = fields or {}
  return { mail_id = fields.mail_id,
    persistence = fields.persistence or "durable",
    delivery = { status = fields.status or "unknown",
      reason = fields.reason, route = fields.route or "none" } }
end

-- Bind once, from the current notice image only. A stale or wrong owner, or a
-- second binding, is refused; a refreshed module builds its own closure.
function M.bind(owner, make_seam)
  if bound_make_seam then return false, "already_bound" end
  if owner == nil or owner ~= remuda._butler_notice then return false, "wrong_owner" end
  if type(make_seam) ~= "function" then return false, "invalid_seam" end
  bound_owner, bound_make_seam = owner, make_seam
  return true
end

-- Read-only lifecycle readiness. The private factory and its seam stay closed;
-- callers learn only whether the current notice owner is bound and a factory is
-- held. A consumed `native_dispatch.install` is the normal handoff state and is
-- deliberately not consulted here.
function M.readiness()
  return { owner = bound_owner, bound = bound_make_seam ~= nil,
    transport_acquired = make_channel ~= nil }
end

-- Classify the existing notice outcome for the transient typed result only;
-- the journal/retry decisions remain the sealed notice seam's.
local function status_of(sent, why)
  if sent then return "accepted" end
  local text = tostring(why or ""):lower()
  if text:find("uncertain", 1, true) or text:find("send_refused", 1, true)
      or text:find("journal_generation_changed", 1, true) then
    return "uncertain"
  end
  if text:find("native_pending", 1, true) or text:find("busy", 1, true)
      or text:find("rate_limit", 1, true) or text:find("dialog", 1, true) then
    return "deferred"
  end
  if text:find("native_dead", 1, true) then return "dead" end
  return "not_written"
end

-- Public admission is data-only. The genuine journal/current/outcome seams are
-- the one-shot binding; caller callbacks, runners and guards cannot substitute
-- for them.
function M.send_message(session, intent)
  if not bound_make_seam then return false end
  if type(session) ~= "string" then return false end
  if intent == nil then intent = "mail_notice" end
  local seam = bound_make_seam(session)
  if not seam then return true end
  local observed = observe(session)
  local route, decide_why = decide(observed, intent)
  if not route then
    return seam.unavailable(decide_why, observed.reason or decide_why)
  end
  if seam.blocked and seam.blocked(route, observed) then return false end
  local adapter, construct_why = construct(observed, route)
  if not adapter then
    return seam.unavailable("native_not_written", construct_why)
  end
  if route == "legacy" then
    if type(seam.prepare) ~= "function" then
      return seam.unavailable("refresh_unavailable", "refresh_unavailable")
    end
    if seam.prepare(adapter) ~= "ready" then return false end
    if not current(adapter) then return false end
  end
  local attempt, reserve_why = seam.reserve(adapter)
  if not attempt then return seam.unavailable("journal", reserve_why) end
  local first, second = adapter.send(attempt)
  local sent, why
  if adapter.route == "native" then
    if first == nil then
      sent, why = false, second
    else
      sent, why = seam.native_outcome(first, adapter)
    end
  else
    sent, why = first, second
  end
  attempt.result = typed_result({ mail_id = attempt.ids and attempt.ids[1],
    status = status_of(sent, why), reason = why, route = adapter.route })
  return seam.resolve(sent, why, adapter, attempt)
end

-- Consume the transport factory now, before the finished admission surface is
-- observable: a caller can never take the factory later and bypass the journal.
do
  local transport = remuda.butler.native_dispatch
  if transport and type(transport.install) == "function" then
    make_channel = transport.install(M)
  end
end

remuda.butler.send_policy = M
return M
