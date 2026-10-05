-- Guard slice 1: owner approval for the permission prompts of Claude members.
-- With `guard on` and `guard approvals on`, the PermissionRequest hook registers
-- one request, posts it to the configured approval room, and waits for the
-- verified owner's answer (approval.lua and the relay's owner gate). Allow and
-- deny are printed as Claude's PermissionRequest decision; every other outcome
-- (no Matrix, a cap, expiry, an error) prints nothing, so Claude shows its own
-- prompt and the agent is never worse off. A request is one-shot, bound to the
-- sha256 of its stored text, and ends at a daemon restart. This is a cooperative
-- guardrail, not a boundary: a same-user agent can bypass or edit it.
local butler = assert(remuda.butler, "load butler/matrix before butler/guard_approval")
local approval = assert(butler.approval, "load butler/approval before butler/guard_approval")
local policy = assert(butler.guard_policy, "load butler/guard_policy before butler/guard_approval")
local approve_text = assert(butler.approve_text, "load butler/approve_text before butler/guard_approval")
local M = butler.guard_approval or {}
butler.guard_approval = M

-- Core caps a deferred reply at 300 s; the request always ends before its reply does.
local TTL_S = 290
local REPLY_TIMEOUT_S = 300
local MAX_TEXT = 1000
-- Only tools whose whole action the post shows: their one field is the action. Write, Edit and
-- the like carry content the post would not show, so they stay with Claude's own prompt.
local ROUTED_TOOLS = { Bash = true, Read = true, Glob = true, Grep = true, WebFetch = true, WebSearch = true }
local MAX_OPEN = 20
local MAX_OPEN_PER_SESSION = 5
local RATE_PER_10_MIN = 30
-- With grants on (documented in docs/butler.md "Request limits"): posts per scope per hour and overall per hour,
-- how long an owner's cross is remembered for the same scope, and a per-session-name bucket as an extra. The agent
-- names its own session (data.session), so only the scope limits and the remembered cross are keyed without it.
-- A request over a limit gets no post, so Claude shows its own prompt; a remembered cross answers deny at once.
local PER_AGENT_PER_MIN, PER_SCOPE_PER_HOUR, GLOBAL_PER_HOUR, DENY_MEMORY_S = 5, 10, 30, 600
local EXPIRY_NOTICE_WAIT_S, EXPIRY_SCAN_S, NOTE_MAX = 60, 5, 200
local grants = butler.guard_grants

-- Survives a live reload: limits and the expiry tracker belong to the daemon, not to one load of this file.
M._limits = M._limits or { agent = {}, hour = {}, denies = {} }
M._exp = M._exp or { tracked = {}, due = {}, checked = 0 }

local function clock() return grants and grants.time() or os.time() end
local function grants_on() return grants ~= nil and policy.grants_enabled() end

M.ALLOW = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
M.DENY = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":'
  .. '{"behavior":"deny","message":"Denied by the owner via Butler"}}}'

-- Request id -> the hook's deferred reply, while its hook process waits.
local waiting = {}
-- Survives a live reload, so a request key is never reused within a second.
M._counter = M._counter or 0

-- SHA-256 (FIPS 180-4) over a byte string; lowercase hex.
local K = {}
do
  local found, n = 0, 2
  while found < 64 do
    local prime = true
    for d = 2, math.floor(math.sqrt(n)) do if n % d == 0 then prime = false; break end end
    if prime then
      found = found + 1
      K[found] = math.floor((n ^ (1 / 3) % 1) * 4294967296)
    end
    n = n + 1
  end
end
local function sha256(message)
  local function rotr(x, n) return ((x >> n) | (x << (32 - n))) & 0xffffffff end
  local h = {}
  do
    local found, n = 0, 2
    while found < 8 do
      local prime = true
      for d = 2, math.floor(math.sqrt(n)) do if n % d == 0 then prime = false; break end end
      if prime then found = found + 1; h[found] = math.floor((n ^ 0.5 % 1) * 4294967296) end
      n = n + 1
    end
  end
  local len = #message
  message = message .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I8", len * 8)
  for chunk = 1, #message, 64 do
    local w = { string.unpack(">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4", message, chunk) }
    for i = 17, 64 do
      local s0 = rotr(w[i - 15], 7) ~ rotr(w[i - 15], 18) ~ (w[i - 15] >> 3)
      local s1 = rotr(w[i - 2], 17) ~ rotr(w[i - 2], 19) ~ (w[i - 2] >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 1, 64 do
      local t1 = hh + (rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)) + ((e & f) ~ (~e & g)) + K[i] + w[i]
      local t2 = (rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)) + ((a & b) ~ (a & c) ~ (b & c))
      hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff
    end
    h[1], h[2], h[3], h[4] = (h[1] + a) & 0xffffffff, (h[2] + b) & 0xffffffff, (h[3] + c) & 0xffffffff, (h[4] + d) & 0xffffffff
    h[5], h[6], h[7], h[8] = (h[5] + e) & 0xffffffff, (h[6] + f) & 0xffffffff, (h[7] + g) & 0xffffffff, (h[8] + hh) & 0xffffffff
  end
  return string.format(string.rep("%08x", 8), table.unpack(h))
end
M.sha256 = sha256

function M.enabled() return policy.approvals_enabled() end

-- The standing grant the post offers (class, resolved scope, ceiling, absolute expiry); part of what the hash covers.
local function offer_text(o)
  if type(o) ~= "table" then return "-" end
  return table.concat({ tostring(o.class), tostring(o.scope), tostring(o.ceiling), string.format("%d", o.expires or 0) }, "|")
end

-- The exact text the hash covers: only stored, sanitized fields.
local function canonical(data)
  return table.concat({ "tool=" .. tostring(data.tool), "class=" .. tostring(data.class),
    "cwd=" .. tostring(data.cwd), "session=" .. tostring(data.session),
    "agent=" .. tostring(data.agent), "text=" .. tostring(data.text), "grant=" .. offer_text(data.offer) }, "\n")
end

local function audit(event, rec, summary, grant_id)
  local data = type(rec.data) == "table" and rec.data or {}
  policy.append({ session = data.session or rec.asker, kind = data.agent or "claude", event = event,
    tool = data.tool, class = data.class, summary = summary or "", id = rec.id, grant_id = grant_id,
    hash = type(data.hash) == "string" and data.hash:sub(1, 12) or "" })
end

-- Resolve the waiting hook (once). Empty stdout means "no decision".
local function settle(id, stdout)
  local reply = waiting[id]
  waiting[id] = nil
  if reply then pcall(function() reply:resolve(0, stdout or "", "") end) end
  return reply ~= nil
end

local function thread_note(rec, text) pcall(approval.reply, rec, text) end

local function cap_summary(text, limit)
  if #text <= limit then return text, false end
  local at, finish = 1, 0
  while at <= #text do
    local first = text:byte(at)
    local width = first < 0x80 and 1 or first < 0xe0 and 2 or first < 0xf0 and 3 or 4
    if at + width - 1 > limit - 3 then break end
    finish, at = at + width - 1, at + width
  end
  return text:sub(1, finish) .. "...", true
end

local function render(rec, display)
  local data = rec.data
  data.id, data.nonce = rec.id, rec.nonce
  data.hash = sha256(canonical(data))
  local shown = approve_text.display_inline
  local summary, summary_cut = data.text, false
  if display and display.lounge then summary, summary_cut = cap_summary(data.text, 200) end
  local expires = math.floor((tonumber(rec.expires_at) or 0) / 1000)
  local offer = data.offer
  local lines = {
    "[Butler approval " .. rec.id .. "] " .. shown(data.agent) .. " session " .. shown(data.session)
      .. " asks to run a guarded action",
    "  tool:     " .. shown(data.tool),
    "  class:    " .. shown(data.class),
    "  cwd:      " .. shown(data.cwd),
    "  command:  " .. shown(summary),
  }
  if offer then
    -- Butler's own resolved scope and absolute expiry, never agent text.
    lines[#lines + 1] = "  grant:    " .. shown(offer.class) .. " " .. shown(offer.scope) .. " until "
      .. os.date("!%Y-%m-%dT%H:%M:%SZ", offer.expires) .. " (about " .. math.ceil((offer.expires - clock()) / 60)
      .. " min), ceiling " .. shown(offer.ceiling)
  end
  lines[#lines + 1] = "  hash:     sha256 " .. data.hash:sub(1, 12) .. " (tool, class, cwd, session, text)"
  lines[#lines + 1] = "  expires:  " .. os.date("!%Y-%m-%dT%H:%M:%SZ", expires) .. " (about " .. math.ceil(TTL_S / 60) .. " min)"
  lines[#lines + 1] = (offer and "React ✅ to allow this one call, 🔄 to allow it and record a grant for the scope; calls still ask in this version, ❌ to deny."
    or "React ✅ to allow this one call, ❌ to deny.") .. " Reply \"yes " .. rec.id .. "\" / \"no " .. rec.id
    .. "\" (승인 / 거부) also works."
  lines[#lines + 1] = "No answer: the agent shows its own prompt."
  -- Agent text: one labelled, quoted line, last, after Butler's own lines.
  if data.note then lines[#lines + 1] = "agent-supplied: \"" .. shown(data.note) .. "\"" end
  return table.concat(lines, "\n"), nil, summary_cut and { display_cut = true } or nil
end

-- Agent text for the post: one line of at most NOTE_MAX bytes. Control and direction characters are escaped by
-- display_inline when shown; markup, links and mentions are removed here. nil when there is none.
local function note_line(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("%c+", " "):gsub("%a[%w+.-]*://%S*", "[link]"):gsub("[`*<>@]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return (cap_summary(text, NOTE_MAX))
end

-- Limits and remembered crosses (grants on only). nil = go ahead; "denied" = the owner already said no to this
-- scope (key, not session); "limited" = too many posts. Denied requests do not count against the limits.
local function admit(session, key, scope_key)
  local L, t = M._limits, clock()
  L.scope = L.scope or {}
  for k, until_ in pairs(L.denies) do if until_ <= t then L.denies[k] = nil end end
  if L.denies[key] then return "denied" end
  local function recent(list, span)
    for i = #list, 1, -1 do if list[i] <= t - span then table.remove(list, i) end end
    return #list
  end
  for s, list in pairs(L.agent) do if recent(list, 60) == 0 then L.agent[s] = nil end end
  for k, list in pairs(L.scope) do if recent(list, 3600) == 0 then L.scope[k] = nil end end
  local mine, theirs = L.agent[session] or {}, L.scope[scope_key] or {}
  L.agent[session], L.scope[scope_key] = mine, theirs
  if recent(mine, 60) >= PER_AGENT_PER_MIN or recent(theirs, 3600) >= PER_SCOPE_PER_HOUR
      or recent(L.hour, 3600) >= GLOBAL_PER_HOUR then return "limited" end
  mine[#mine + 1], theirs[#theirs + 1], L.hour[#L.hour + 1] = t, t, t
end

local function audit_refusal(record, data, verdict)
  policy.append({ session = data.session, kind = data.agent, event = verdict == "denied" and "approval_denied" or "approval_limited",
    tool = data.tool, class = data.class, summary = verdict == "denied" and "remembered deny" or "rate limit" })
end

-- Returns the deferred reply for the hook, or nil when the hook should print nothing.
function M.maybe_request(record, hook_json)
  if not (M.enabled() and policy.enabled()) then return nil end
  if record.event ~= "PermissionRequest" or record.kind ~= "claude" or type(hook_json) ~= "table" then return nil end
  if type(remuda.pending) ~= "function" or record.class == "script" or not ROUTED_TOOLS[record.tool] then return nil end
  -- A command the owner cannot see in full is not routed; Claude's own prompt shows it whole.
  -- Redaction reads a bounded prefix, so the raw field is measured as well.
  local input = type(hook_json.tool_input) == "table" and hook_json.tool_input or {}
  local raw = input.command or input.file_path or input.notebook_path or input.url or input.query or input.pattern
  local text = policy.summary(record.tool, input, MAX_TEXT)
  if #text > MAX_TEXT or (type(raw) == "string" and #raw > MAX_TEXT) then return nil end
  -- Redaction rewrites text it masks; the owner must approve exactly what would run, so a call
  -- the redaction changed keeps Claude's own prompt.
  if type(raw) == "string" and (raw:find("%c") or text ~= raw) then return nil end
  local session = record.session ~= "" and record.session or "unknown"
  local data = { tool = policy.redact(record.tool, 120), class = record.class, agent = record.kind,
    cwd = policy.redact(hook_json.cwd, 300), session = policy.redact(session, 120), text = text }
  if grants_on() then
    -- Frozen: no standing grant is offered (the owner's reaction would make none).
    data.offer = not grants.frozen() and grants.offer(record.tool, input, hook_json.cwd) or nil
    if data.offer then data.offer.expires = grants.time() + grants.DEFAULT_TTL end
    data.note = note_line(input.description)
    -- The post limit never keys on command text (a trailing space or `; :` would dodge it); only the remembered
    -- deny keeps the exact text.
    local scope_key = data.offer and (data.offer.class .. " " .. data.offer.scope)
      or (data.tool .. " " .. data.class .. " " .. data.cwd)
    data.deny_key = data.offer and scope_key or (scope_key .. " " .. data.text)
    local verdict = admit(data.session, data.deny_key, scope_key)
    if verdict then
      audit_refusal(record, data, verdict)
      if verdict == "denied" then
        local reply = remuda.pending({ timeout = REPLY_TIMEOUT_S })
        if type(reply) ~= "table" then return nil end
        pcall(function() reply:resolve(0, M.DENY, "") end)
        return reply
      end
      return nil
    end
  end
  M._counter = M._counter + 1
  local request_id, ended
  local reply = remuda.pending({ timeout = REPLY_TIMEOUT_S, on_cancel = function()
    -- The hook process ended (Claude answered natively or gave up): the request is spent.
    ended = true
    local rec = request_id and approval.for_id(request_id)
    if rec and rec.status == "open" then rec.expires_at = 0; approval.sweep() end
  end })
  if type(reply) ~= "table" then return nil end
  local started = pcall(approval.request, { kind = "guard_action", key = tostring(os.time()) .. ":" .. M._counter,
    asker = session, summary = "allow " .. data.tool .. " for " .. data.session, ttl_s = TTL_S, data = data,
    rate_limit_per_window = RATE_PER_10_MIN, rate_window_s = 600,
    max_open_for_asker = MAX_OPEN_PER_SESSION, max_open_total = MAX_OPEN, render = render,
  }, function(id)
    if not id then pcall(function() reply:resolve(0, "", "") end); return end
    request_id = id
    waiting[id] = reply
    local rec = approval.for_id(id)
    if rec then audit("approval_requested", rec, data.text) end
    if ended and rec then rec.expires_at = 0; approval.sweep() end
  end)
  if not started then pcall(function() reply:resolve(0, "", "") end) end
  return reply
end

-- The private grant-store add is handed here, once, by the module's own load: nothing else holds it. A refusal
-- means a grant module that already handed it out (or none), so no reaction can create a grant: say so loudly.
local add_grant, grant_controls
if grants then
  local ok, why = grants.register(function(add, controls) add_grant, grant_controls = add, controls end)
  if not ok then
    local msg = "guard grants: the owner-reaction handler could not register (" .. tostring(why)
      .. "); no reaction creates a grant until Butler reloads"
    io.stderr:write("butler: " .. msg .. "\n")
    if type(remuda.log) == "function" then pcall(remuda.log, "error", msg) end
    policy.observe("grant_register_refused", "butler", "butler", msg)
  end
end

-- Owner audit lines (freeze, revoke, lift) carry the grant id where there is one, and who asked: the sender and the
-- Matrix event of the line (or of the answer) are in every summary. Returns true, or nil and why.
local function by_text(who, event_id)
  return " (by " .. policy.redact(tostring(who or "-"), 120) .. ", event " .. policy.redact(tostring(event_id or "-"), 120) .. ")"
end
local function owner_audit(event, summary, grant_id, by)
  local ok, done, why = pcall(policy.append, { session = "owner", kind = "owner", event = event, tool = "", class = "other",
    summary = summary .. (by or ""), grant_id = grant_id })
  if ok and done then return true end
  return nil, tostring(ok and why or done)
end
-- A line that narrows (freeze, revoke) still acts when its audit line cannot be written, but never silently.
local function audit_narrowing(event, summary, grant_id, by)
  local ok, why = owner_audit(event, summary, grant_id, by)
  if not ok then
    local msg = "guard grants: the audit line for " .. event .. " could not be written (" .. tostring(why) .. ")"
    io.stderr:write("butler: " .. msg .. "\n")
    if type(remuda.log) == "function" then pcall(remuda.log, "error", msg) end
  end
end
-- Error text for a room reply: escaped, no mention or markup.
local function plain(text) return (grants.show(tostring(text), 120):gsub("[@`]", "")) end

-- Bumped by every owner `guard freeze`: an unfreeze request remembers the one it was made under, so a post that
-- is older than the latest freeze cannot lift it (the open ones are also expired, this covers one still posting).
M._freeze_gen = M._freeze_gen or 0

-- The owner's Matrix lines `guard freeze`, `guard unfreeze` and `guard revoke gNNN`. The relay calls this only for
-- a line that passed its owner gate (allowlisted human, live sync, not edited, in the room); there is no CLI or
-- agent path to it. Cooperative like approval.answer: Lua inside the daemon can call it. Returns the reply text, or
-- nil when the line is not one of these verbs. Every line that starts with one of them is answered, so the
-- relay never hands it on as mail. Freeze and revoke only narrow, so they use the grant store's public functions when
-- the private handoff is missing; unfreeze needs the private one.
function M.owner_command(line, who, event_id)
  if type(line) ~= "string" or not grants then return nil end
  local text = line:match("^%s*(.-)%s*$"):lower()
  local verb, rest = text:match("^guard%s+(%a+)(.*)$")
  if verb ~= "freeze" and verb ~= "unfreeze" and verb ~= "revoke" then return nil end
  local by = by_text(who, event_id)
  local args = {}
  for word in rest:gmatch("%S+") do args[#args + 1] = word end
  if rest ~= "" and not rest:match("^%s") then args[1] = rest end -- `guard freeze-now`: extra text, not the bare verb
  local id = args[1]
  if (verb == "revoke" and (#args ~= 1 or not id:match("^g%d%d%d+$"))) or (verb ~= "revoke" and #args > 0) then
    owner_audit("owner_line_refused", "usage: " .. policy.redact(text, 80), nil, by)
    return verb == "revoke" and "Usage: guard revoke gNNN (the id from `remuda butler guard grants`)."
      or "Usage: guard " .. verb .. " (no arguments)."
  end
  local narrow = grant_controls or grants
  if verb == "revoke" then
    local done, why = narrow.revoke(id)
    if done == "revoked" then
      audit_narrowing("grant_revoked", "revoked", id, by)
      return "Revoked " .. id .. ". It stops matching on the next call."
    elseif done == "already" then return id .. " is already revoked."
    elseif done == "expired" then return id .. " has already expired."
    elseif done == "unknown" then return "No grant " .. id .. "."
    end
    audit_narrowing("grant_revoke_unsaved", plain(why), id, by)
    return "Revoke of " .. id .. " could not be saved (" .. plain(why) .. "). It is off until Butler restarts; try again."
  elseif verb == "freeze" then
    M._freeze_gen = M._freeze_gen + 1
    approval.expire_open("guard_unfreeze") -- an older ask to lift must not outlive this freeze
    local done, why = narrow.freeze()
    if done == "already" then return "Grants are already frozen." end
    audit_narrowing("grants_frozen", done and "frozen" or plain(why), nil, by)
    if not done then
      return "Grants are frozen in memory only: the marker could not be saved (" .. plain(why)
        .. "). The freeze ends if Butler restarts; try again."
    end
    return "Grants are frozen: none matches and none is made until you lift it (guard unfreeze, then react on the post)."
  end
  if not grants.frozen() then return "Grants are not frozen." end
  if not grant_controls then return "Grant controls are not available: Butler has not registered them. Reload Butler." end
  local fresh, sent, asked_id, asked_why = false, false, nil, nil
  local started, err = pcall(approval.request, { kind = "guard_unfreeze", key = "unfreeze", asker = "owner",
    summary = "lift the guard grant freeze", ttl_s = 600, max_open_for_asker = 1, max_open_total = 1,
    data = { gen = M._freeze_gen }, on_id = function() fresh = true end,
    render = function(rec)
      return "[Butler approval " .. rec.id .. "] Lift the guard grant freeze\n"
        .. "React ✅ to lift it: grants match again until they expire. Reply \"yes " .. rec.id .. "\" also works.\n"
        .. "❌ or no keeps grants frozen. Only the owner in Matrix can lift it."
    end }, function(rid, why)
      if sent then
        -- the post finished after this reply went out: only a failure still needs telling
        if not rid then pcall(approval.notify, "The unfreeze request could not be posted: " .. plain(why) .. ". Grants stay frozen.") end
      else
        asked_id, asked_why = rid, why
      end
    end)
  sent = true
  if not started then asked_why = err end
  if asked_id then
    if fresh then return "To lift the freeze, react ✅ on the post I just made (or reply yes)." end
    return "An unfreeze request is already open (" .. plain(asked_id) .. "): react ✅ on its post (or reply yes)."
  elseif asked_why then
    return "Could not ask to lift the freeze: " .. plain(asked_why) .. " Grants stay frozen."
  end
  return "To lift the freeze, react ✅ on the post I am making (or reply yes)."
end

function M.configure()
  approval.handler("guard_action", {
    approve = function(rec, complete)
      local data = type(rec.data) == "table" and rec.data or {}
      local intact = data.id == rec.id and data.nonce == rec.nonce and type(data.hash) == "string"
        and data.hash == sha256(canonical(data))
      if not intact then
        settle(rec.id, "")
        audit("approval_failed", rec, "text_changed")
        thread_note(rec, "refused: text_changed")
        complete(false, "text_changed")
      elseif not waiting[rec.id] then
        thread_note(rec, "Expired.")
        complete(false, "no_waiting_hook")
      elseif rec.answer_verdict == "grant" then
        -- The owner's cycle reaction: Butler records the grant (private add), then the reaction is on record
        -- (rec.grant) for the store's cross-check; the call itself is allowed too.
        local offer = data.offer
        local id, why
        if not (grants_on() and add_grant and type(offer) == "table") then
          why = "standing grants are not available"
        else
          id, why = add_grant({ class = offer.class, scope = offer.scope, ceiling = offer.ceiling,
            holder = data.session, event = rec.answer_event_id, ttl = offer.expires - grants.time() })
        end
        if not id then
          settle(rec.id, "")
          audit("grant_refused", rec, tostring(why))
          thread_note(rec, "No grant: " .. tostring(why) .. ". The agent shows its own prompt.")
          complete(false, "grant_refused")
        else
          rec.grant = { id = id, class = offer.class, scope = offer.scope }
          settle(rec.id, M.ALLOW)
          audit("grant_created", rec, offer.class .. " " .. offer.scope, id)
          -- a path may hold @ (a mention) or a backtick (markup): the note is plain text
          thread_note(rec, "Standing grant " .. id .. ": " .. grants.show(offer.class .. " " .. offer.scope, 200):gsub("[@`]", "")
            .. " until " .. os.date("!%Y-%m-%dT%H:%M:%SZ", offer.expires) .. ". Allowed this call.")
          complete(true)
        end
      else
        settle(rec.id, M.ALLOW)
        audit("approval_approved", rec, "")
        thread_note(rec, "Allowed this one call.")
        complete(true)
      end
    end,
    -- Asked before a cycle reaction counts: nil to go ahead, or why not (the request stays open).
    grant_check = function(rec)
      if not grants_on() then return "Standing grants are off." end
      if grants.frozen() then return "Standing grants are frozen." end
      if type(rec.data) ~= "table" or type(rec.data.offer) ~= "table" then
        return "No standing grant is offered for this request."
      end
      if not add_grant then return "Standing grants cannot be created: the reaction handler is not registered." end
    end,
    deny = function(rec)
      local data = type(rec.data) == "table" and rec.data or {}
      if grants_on() and type(data.deny_key) == "string" then M._limits.denies[data.deny_key] = clock() + DENY_MEMORY_S end
      settle(rec.id, M.DENY)
      audit("approval_denied", rec, "")
      thread_note(rec, "Denied.")
    end,
    expire = function(rec)
      settle(rec.id, "")
      audit("approval_expired", rec, "")
      thread_note(rec, "Expired. The agent shows its own prompt.")
    end,
  })
  -- Lifting a freeze: the owner's answer (reaction or "yes ID", through the relay's owner gate) on Butler's post.
  approval.handler("guard_unfreeze", {
    approve = function(rec, complete)
      local function stay(why, code)
        thread_note(rec, "Freeze not lifted: " .. plain(why) .. ". Grants stay frozen.")
        complete(false, code)
      end
      local by = by_text(rec.answered_by, rec.answer_event_id)
      if type(rec.data) ~= "table" or rec.data.gen ~= M._freeze_gen then
        return stay("a newer freeze replaced this request", "stale_unfreeze")
      end
      if not grant_controls then return stay("grant controls are not available", "unfreeze_failed") end
      -- Lifting widens: the audit line comes first, and without it the freeze stays (the safe side).
      local logged, why = owner_audit("grants_unfrozen", "freeze lifted", nil, by)
      if not logged then return stay("the audit line could not be written (" .. tostring(why) .. ")", "audit_failed") end
      local done, lift_why = grant_controls.unfreeze()
      if done == "lifted" or done == "not frozen" then
        thread_note(rec, "Freeze lifted. Grants match again until they expire.")
        complete(true)
      else
        owner_audit("grants_unfreeze_failed", plain(lift_why), nil, by)
        stay(lift_why, "unfreeze_failed")
      end
    end,
    deny = function(rec) thread_note(rec, "Grants stay frozen.") end,
    expire = function(rec) thread_note(rec, "Expired. Grants stay frozen.") end,
  })
end

-- One notice for the grants that expired within EXPIRY_NOTICE_WAIT_S of the first one, posted to the owner's room.
-- Only grants this daemon saw active are announced (the tracker is in memory).
local function expiry_tick()
  local E = M._exp
  if not grants_on() then E.tracked, E.due, E.first = {}, {}, nil; return end
  local t = clock()
  if t - E.checked >= EXPIRY_SCAN_S then
    E.checked = t
    local active = {}
    for _, g in ipairs(grants.held()) do active[g.id] = g end
    for id, g in pairs(E.tracked) do
      if not active[id] then
        if t >= g.expires and #E.due < 200 then E.due[#E.due + 1] = g; E.first = E.first or t end
        E.tracked[id] = nil
      end
    end
    for id, g in pairs(active) do E.tracked[id] = g end
  end
  if #E.due > 0 and t - E.first >= EXPIRY_NOTICE_WAIT_S then
    table.sort(E.due, function(a, b) return a.id < b.id end)
    local names = {}
    for i, g in ipairs(E.due) do
      if i > 10 then names[#names + 1] = "and " .. (#E.due - 10) .. " more"; break end
      -- a path may hold @ (a mention) or a backtick (markup): the notice is plain text
      names[#names + 1] = g.id .. " " .. g.class .. " " .. grants.show(g.scope, 80):gsub("[@`]", "")
    end
    if approval.notify("Standing grants expired: " .. table.concat(names, ", ")
        .. ". The agent asks again if it still needs them. Next: remuda butler guard grants") then
      E.due, E.first = {}, nil
    end
  end
end
approval.tick("guard_grants_expiry", expiry_tick)

M.configure()
return M
