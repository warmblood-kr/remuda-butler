-- Report-only owner notice for a recognised Codex approval dialog. The leader
-- report in dialogs.lua can sit unread behind a blocked pane; the owner should
-- learn from Matrix that an exact session waits for a decision. This module only
-- posts a plain notice to the owner's home room. It never answers, approves,
-- denies, selects an option, types or runs a key.
--
-- One notice per pending dialog (session, instance, state id, choice block):
-- only the periodic dialog tick considers it, after `debounce_seconds`; a
-- delivered receipt is not repeated across a reload or restart and is cleared
-- when the dialog resolves; a session gets at most one notice per
-- `session_seconds`; an offline or failed post retries no sooner than
-- `retry_seconds`; a receipt older than `remember_seconds` cannot suppress one.
-- If the daemon dies after a post but before its callback, the next start posts
-- once more: for a notice a duplicate is better than silence, and a receipt is
-- never written without an event id. The text carries only the session alias
-- and the recognised state id, never screen text, commands, paths or files.
local butler = assert(remuda.butler)
local bus = assert(remuda._butler_bus)
local M = {}
butler.dialog_owner_notice = M

M.debounce_seconds = 3
M.retry_seconds = 30
M.session_seconds = 30
M.remember_seconds = 3600
M.max_remembered = 50
M.seen_retain_seconds = 600
M.clock = os.time

local function bounded(value, limit)
  return type(value) == 'string' and value ~= '' and #value <= limit and not value:find('%c')
end

-- A stable, short identity. The guard digest is preferred; the fallback only
-- needs to separate keys, never to be a security hash.
local function hash(value)
  local guard = butler.guard_approval
  if guard and type(guard.sha256) == 'function' then
    local ok, digest = pcall(guard.sha256, value)
    if ok and type(digest) == 'string' and digest:match('^%x+$') then return digest end
  end
  local h = 5381
  for i = 1, #value do h = (h * 33 + value:byte(i)) % 4294967296 end
  return string.format('%08x', h)
end

local function state_path()
  local policy = butler.guard_policy
  if not policy or type(policy.dir) ~= 'function' then return nil end
  local ok, dir = pcall(policy.dir)
  if not ok or type(dir) ~= 'string' or dir == '' then return nil end
  return dir .. '/dialog-owner-notice'
end

-- Survives a package reload; a daemon restart rebuilds the receipts from file.
local S = bus.dialog_owner_notice_state
if type(S) ~= 'table' then S = {} end
S.delivered = type(S.delivered) == 'table' and S.delivered or {}
S.index = type(S.index) == 'table' and S.index or {}
S.session_keys = type(S.session_keys) == 'table' and S.session_keys or {}
S.seen = type(S.seen) == 'table' and S.seen or {}
S.next_at = type(S.next_at) == 'table' and S.next_at or {}
S.session_at = type(S.session_at) == 'table' and S.session_at or {}
bus.dialog_owner_notice_state = S
local loaded = false

local function expire(now)
  local kept = {}
  for _, item in ipairs(S.delivered) do
    if now - item.at < M.remember_seconds then kept[#kept + 1] = item
    else
      S.index[item.key] = nil
      local keys = item.session and S.session_keys[item.session]
      if keys then keys[item.key] = nil end
    end
  end
  S.delivered = kept
  for key, seen in pairs(S.seen) do
    if now - seen >= M.seen_retain_seconds then S.seen[key] = nil end
  end
  for name, at in pairs(S.next_at) do
    if now - at >= M.remember_seconds then S.next_at[name] = nil end
  end
end

local function load()
  if loaded then return end
  loaded = true
  local file = state_path()
  local handle = file and io.open(file, 'r')
  if not handle then return end
  for line in (handle:read('a') or ''):gmatch('[^\n]+') do
    local at, session, key = line:match('^(%d+) (%x+) (%x+)$')
    if at and session and key and not S.index[key] then
      S.delivered[#S.delivered + 1] = { key = key, at = tonumber(at), session = session }
      S.index[key] = true
      S.session_keys[session] = S.session_keys[session] or {}
      S.session_keys[session][key] = true
    end
  end
  handle:close()
  expire(M.clock())
end

local function save()
  local file = state_path()
  local fs = remuda.fs
  if not file or type(fs) ~= 'table' or type(fs.write_atomic) ~= 'function' then return false end
  local lines = {}
  for _, item in ipairs(S.delivered) do
    lines[#lines + 1] = tostring(item.at) .. ' ' .. item.session .. ' ' .. item.key
  end
  local called, wrote = pcall(fs.write_atomic, file, table.concat(lines, '\n') .. '\n', { private = true })
  return called and wrote == true
end

local function remember(session, key, now)
  if S.index[key] then return true end
  S.index[key] = true
  S.delivered[#S.delivered + 1] = { key = key, at = now, session = session }
  S.session_keys[session] = S.session_keys[session] or {}
  S.session_keys[session][key] = true
  while #S.delivered > M.max_remembered do
    local dropped = table.remove(S.delivered, 1)
    if dropped then
      S.index[dropped.key] = nil
      local keys = dropped.session and S.session_keys[dropped.session]
      if keys then keys[dropped.key] = nil end
    end
  end
  return save()
end

-- The session's dialog is gone: the next identical approval is a new request.
-- Called by dialogs.lua only after the resolution audit succeeded.
function M.resolved(name, instance)
  if not bounded(name, 128) or not bounded(instance, 256) then return false end
  load()
  local session = hash(name .. '\0' .. instance)
  local keys = S.session_keys[session]
  S.session_at[session] = nil
  if keys then
    for key in pairs(keys) do
      S.index[key] = nil
      S.seen[key] = nil
      S.next_at[key] = nil
    end
    S.session_keys[session] = nil
  end
  local kept = {}
  for _, item in ipairs(S.delivered) do
    if not (keys and keys[item.key]) then kept[#kept + 1] = item end
  end
  S.delivered = kept
  return save()
end

local function text_for(name, id)
  local what = id == 'codex_auto_review_refused'
    and 'Codex automatic approval review rejected further approval requests and interrupted the turn'
    or 'Codex is waiting for an approval decision'
  return 'Butler notice: ' .. what .. ' in session ' .. name .. ' (' .. id .. '). '
    .. 'Report only: Butler sent no input and chooses no option. Answer it in that pane.'
end

-- Called from the periodic dialog tick for a stable recognised state. Returns
-- true only when a post was started; every outcome stays report-only.
function M.consider(name, agent, state)
  if type(agent) ~= 'table' or agent.kind ~= 'codex' then return false, 'not_codex' end
  if type(state) ~= 'table' or type(state.entry) ~= 'table'
      or state.entry.response ~= 'approval' then return false, 'not_approval' end
  if not bounded(name, 128) or not bounded(state.id, 64)
      or not bounded(state.instance, 256) then return false, 'unfenced' end
  load()
  local now = M.clock()
  expire(now)
  local session = hash(name .. '\0' .. state.instance)
  local key = hash(session .. '\0' .. state.id .. '\0'
    .. hash(type(state.signature) == 'string' and state.signature or ''))
  if S.index[key] then return false, 'already_delivered' end
  local first = S.seen[key]
  if not first then
    S.seen[key] = now
    return false, 'debouncing'
  end
  if now - first < M.debounce_seconds then return false, 'debouncing' end
  local retry_at = S.next_at[key]
  if retry_at and now < retry_at then return false, 'retrying' end
  local recent = S.session_at[session]
  if recent and now - recent < M.session_seconds then return false, 'session_window' end
  local approval = butler.approval
  if not approval or type(approval.notify) ~= 'function' then return false, 'relay_unavailable' end
  -- Record the attempt before the post: a second tick or a reload must not
  -- start a parallel post for the same dialog while one is in flight.
  S.next_at[key] = now + M.retry_seconds
  S.session_at[session] = now
  local called, handle, why = pcall(approval.notify, text_for(name, state.id), function(result)
    if type(result) == 'table' and type(result.event_id) == 'string' and result.event_id ~= '' then
      S.next_at[key] = nil
      remember(session, key, M.clock())
    end
    -- No event id means an uncertain or failed post: the deadline above
    -- retries the notice later, never silently.
  end)
  if not called then return false, tostring(handle) end
  if handle == nil then return false, tostring(why or 'relay_unavailable') end
  return true
end

return M
