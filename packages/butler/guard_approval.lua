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

M.ALLOW = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
M.DENY = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":'
  .. '{"behavior":"deny","message":"Denied by the owner via Butler"}}}'

-- Request id -> the hook's deferred reply, while its hook process waits.
local waiting = {}
local counter = 0

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

-- The exact text the hash covers: only stored, sanitized fields.
local function canonical(data)
  return table.concat({ "tool=" .. tostring(data.tool), "class=" .. tostring(data.class),
    "cwd=" .. tostring(data.cwd), "session=" .. tostring(data.session),
    "agent=" .. tostring(data.agent), "text=" .. tostring(data.text) }, "\n")
end

local function audit(event, rec, summary)
  local data = type(rec.data) == "table" and rec.data or {}
  policy.append({ session = data.session or rec.asker, kind = data.agent or "claude", event = event,
    tool = data.tool, class = data.class, summary = summary or "", id = rec.id,
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
  return table.concat({
    "[Butler approval " .. rec.id .. "] " .. shown(data.agent) .. " session " .. shown(data.session)
      .. " asks to run a guarded action",
    "  tool:     " .. shown(data.tool),
    "  class:    " .. shown(data.class),
    "  cwd:      " .. shown(data.cwd),
    "  command:  " .. shown(summary),
    "  hash:     sha256 " .. data.hash:sub(1, 12) .. " (tool, class, cwd, session, text)",
    "  expires:  " .. os.date("!%Y-%m-%dT%H:%M:%SZ", expires) .. " (about " .. math.ceil(TTL_S / 60) .. " min)",
    "React ✅ to allow this one call, ❌ to deny. Reply \"yes " .. rec.id .. "\" / \"no " .. rec.id
      .. "\" (승인 / 거부) also works.",
    "No answer: the agent shows its own prompt.",
  }, "\n"), nil, summary_cut and { display_cut = true } or nil
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
  counter = counter + 1
  local request_id, ended
  local reply = remuda.pending({ timeout = REPLY_TIMEOUT_S, on_cancel = function()
    -- The hook process ended (Claude answered natively or gave up): the request is spent.
    ended = true
    local rec = request_id and approval.for_id(request_id)
    if rec and rec.status == "open" then rec.expires_at = 0; approval.sweep() end
  end })
  if type(reply) ~= "table" then return nil end
  local started = pcall(approval.request, { kind = "guard_action", key = tostring(os.time()) .. ":" .. counter,
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
      else
        settle(rec.id, M.ALLOW)
        audit("approval_approved", rec, "")
        thread_note(rec, "Allowed this one call.")
        complete(true)
      end
    end,
    deny = function(rec)
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
end

M.configure()
return M
