-- The household walk, the CLI roster, the identity registry list, and
-- core's session_order/session_detail hooks. main.lua passes its locals in
-- (the mail.lua pattern) and binds registry_list from the exported table.
local config = assert(remuda._butler_sessions_config)
local bus = assert(config.bus)
local mail = assert(config.mail)
local identity_path = config.identity_path
local json_field = assert(config.json_field)

-- The household as a leader -> member walk: parents first, siblings sorted
-- by display name, then orphans (missing or cyclic leaders) at depth 0. One
-- walk feeds both the CLI roster and the client pane's `session_order` hook,
-- so its `indent` is the single view policy for both: butler may parent
-- everything, so a root and its direct children share the margin and
-- indentation starts at grandchildren.
local MAX_TREE_INDENT_DEPTH = 20
-- The marker `remuda.new` writes when the returned id is a proven launch
-- identity. A listed row may only stand in for the agent when it is that exact
-- instance: a bare name, a reused name, and an unavailable row are unknown.
local BOUND_INSTANCE = 1
local function instance_row(agent, session)
  if type(agent) ~= "table" or agent.instance_binding ~= BOUND_INSTANCE then return nil end
  if type(agent.instance_id) ~= "string" or agent.instance_id == "" then return nil end
  if type(session) ~= "table" or session.unavailable == true then return nil end
  if session.instance_id ~= agent.instance_id then return nil end
  return session
end
local function display_name(id)
  local agent = bus.agents[id]
  return agent.alias or agent.session_name or id
end
local function team_order()
  local ids, order, visited = {}, {}, {}
  for id in pairs(bus.agents) do ids[#ids + 1] = id end
  local function sort_ids(list)
    table.sort(list, function(left, right)
      local left_name, right_name = display_name(left), display_name(right)
      if left_name == right_name then return left < right end
      return left_name < right_name
    end)
  end
  local function children_of(parent)
    local children = {}
    for id, agent in pairs(bus.agents) do
      if agent.parent == parent then children[#children + 1] = id end
    end
    sort_ids(children)
    return children
  end
  local function walk(root, orphan)
    local stack = { { id = root, depth = 0, orphan = orphan } }
    while #stack > 0 do
      local item = table.remove(stack)
      if not visited[item.id] then
        visited[item.id] = true
        order[#order + 1] = { id = item.id, orphan = item.orphan, depth = item.depth,
          indent = math.min(math.max(0, item.depth - 1), MAX_TREE_INDENT_DEPTH) }
        local children = children_of(item.id)
        for index = #children, 1, -1 do
          stack[#stack + 1] = { id = children[index], depth = item.depth + 1, orphan = false }
        end
      end
    end
  end

  sort_ids(ids)
  for _, id in ipairs(ids) do
    if not bus.agents[id].parent then walk(id, false) end
  end
  for _, id in ipairs(ids) do
    local parent = bus.agents[id].parent
    if parent and not bus.agents[parent] then walk(id, true) end
  end
  for _, id in ipairs(ids) do
    if not visited[id] then walk(id, true) end
  end
  return order
end

-- A lead that exits hands its live members to its own leader (the root when
-- that leader is gone too), so someone can still close them (#230).
function remuda._butler_adopt_members(name, exited)
  -- Only a recorded generation that still matches is rebound; a mismatch (a retained
  -- edge from before an alias was reused) is neither adopted nor stamped.
  local function current(parent, parent_id)
    local row = parent and bus.agents[parent]
    return row and (parent_id == nil or parent_id == row.id)
  end
  local heir = current(exited.parent, exited.parent_id) and exited.parent
    or (bus.agents.butler and "butler") or nil
  for alias, agent in pairs(bus.agents) do
    if agent.parent == name and (agent.parent_id == nil or agent.parent_id == exited.id) then
      agent.parent, agent.parent_id = heir, heir and bus.agents[heir].id
      if heir then table.insert(bus.agents[heir].children, alias) end
    end
  end
end

function remuda._butler_sessions()
  -- main.lua reassigns its butler_attempts with this global; read it late.
  local butler_attempts = remuda._butler_attempts or {}
  -- One list read keeps the ACTIVITY column and the session detail on the same
  -- snapshot. Without the row's instance_id, a reused name is not enriched.
  local live = {}
  local listed = remuda.session and remuda.session.list
  if type(listed) == "function" then
    local ok, sessions = pcall(listed)
    if ok and type(sessions) == "table" then
      for _, session in ipairs(sessions) do live[session.name] = session end
    end
  end
  local rows = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    local row = live[item.id]
    -- A row for another instance must not be merged with this member's
    -- identity; the detail then falls back to the current-by-name probe.
    local session = row and instance_row(agent, row) or { name = item.id }
    local activity = "other"
    if type(remuda.session_detail) == "function" then
      local ok, detail = pcall(remuda.session_detail, session)
      if ok and type(detail) == "string" then
        local word = detail:match("^(.-) · ")
        if word == "working" or word == "idle" or word == "other" then activity = word end
        if word == "needs you" then activity = "needs you" end
      end
    end
    rows[#rows + 1] = string.rep(" ", item.indent * 2) .. (item.orphan and "[orphan] " or "")
      .. display_name(item.id) .. "\t" .. tostring(agent.kind or "") .. "\t"
      .. tostring(agent.parent or "-") .. "\t" .. activity
  end
  local out = #rows == 0 and "no Butler agents"
    or "SESSION\tAGENT\tLEADER\tACTIVITY\n" .. table.concat(rows, "\n")
  if bus.agents.butler and #butler_attempts > 0 then
    local details = {}
    for _, attempt in ipairs(butler_attempts) do
      details[#details + 1] = attempt.kind .. ": " .. attempt.reason
        .. (attempt.detail and (" (" .. attempt.detail:gsub("\n", " ") .. ")") or "")
    end
    out = out .. "\nBUTLER ATTEMPTS\n" .. table.concat(details, "\n")
  end
  local member_attempts = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    if item.id ~= "butler" and agent.launch_attempts then
      local failed = {}
      for _, attempt in ipairs(agent.launch_attempts) do
        if attempt.reason ~= "ready" then failed[#failed + 1] = attempt.kind .. ": " .. attempt.reason end
      end
      if #failed > 0 then member_attempts[#member_attempts + 1] = display_name(item.id) .. ": " .. table.concat(failed, ", ") end
    end
  end
  if #member_attempts > 0 then out = out .. "\nMEMBER ATTEMPTS\n" .. table.concat(member_attempts, "\n") end
  local profiles = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    local summary = remuda._butler_sandbox.summary(remuda._butler_sandbox.of(agent))
    if summary then profiles[#profiles + 1] = display_name(item.id) .. ": " .. summary end
  end
  if #profiles > 0 then out = out .. "\nSANDBOX\n" .. table.concat(profiles, "\n") end
  -- Read-only native state for bound/adopted sessions. Never a path, nonce,
  -- socket or token: those stay in the private binding files.
  local natives = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    local native = type(agent.native) == "table" and agent.native or nil
    if native and (native.mode == "native" or native.mode == "disabled") then
      local detail = native.reason and tostring(native.reason):gsub("%c+", " "):sub(1, 120) or "-"
      if native.generation then
        detail = detail .. "\tgeneration=" .. tostring(native.generation):sub(1, 12)
      end
      natives[#natives + 1] = display_name(item.id) .. "\t"
        .. tostring(native.kind or "opencode") .. "\t" .. native.mode .. "\t" .. detail
    end
  end
  if #natives > 0 then
    out = out .. "\nNATIVE\nALIAS\tKIND\tSTATE\tDETAIL\n" .. table.concat(natives, "\n")
  end
  local failed_names = {}
  for name in pairs(bus.launch_failures or {}) do failed_names[#failed_names + 1] = name end
  table.sort(failed_names)
  if #failed_names > 0 then
    local failed = {}
    for _, name in ipairs(failed_names) do
      local report = bus.launch_failures[name]
      local details = {}
      for _, attempt in ipairs(report.attempts or {}) do
        details[#details + 1] = attempt.kind .. ": " .. attempt.reason
          .. (attempt.detail and (" (" .. attempt.detail:gsub("\n", " ") .. ")") or "")
      end
      failed[#failed + 1] = name .. ": " .. (#details > 0 and table.concat(details, ", ") or report.error)
    end
    out = out .. "\nFAILED LAUNCHES\n" .. table.concat(failed, "\n")
  end
  return out
end

local function registry_list(include_ended)
  local latest, first_created = {}, {}
  if identity_path then
    local file = io.open(identity_path, "r")
    if file then
      for line in file:lines() do
        local id, alias = json_field(line, "id"), json_field(line, "alias")
        if id and alias then
          local created_at, ended_at = json_field(line, "created_at"), json_field(line, "ended_at")
          local state = json_field(line, "state")
          local unknown = line:match('"created_at_unknown":true') ~= nil
            or not created_at or (ended_at and created_at == ended_at)
          if first_created[id] == nil and latest[id] == nil and not unknown then
            first_created[id] = created_at
          end
          local shown_created = created_at
          if unknown then shown_created = first_created[id] end
          latest[id] = {
            id = id, alias = alias, kind = json_field(line, "kind") or "",
            leader = json_field(line, "leader_id") or "",
            state = state or (ended_at and "ended" or "running"),
            reason = json_field(line, "reason") or "",
            created = shown_created or "?",
            ended = ended_at or "",
          }
        end
      end
      file:close()
    end
  end
  local records = {}
  for _, record in pairs(latest) do
    if include_ended or record.state == "running" then records[#records + 1] = record end
  end
  table.sort(records, function(a, b)
    if a.alias ~= b.alias then return a.alias < b.alias end
    return a.id < b.id
  end)
  local lines = { "ID\tALIAS\tKIND\tLEADER\tSTATE\tREASON\tCREATED\tENDED" }
  for _, record in ipairs(records) do
    lines[#lines + 1] = table.concat({ record.id, record.alias, record.kind, record.leader,
      record.state, record.reason, record.created, record.ended }, "\t")
  end
  return table.concat(lines, "\n")
end

-- Core's client pane asks this for its row order and indentation; sessions
-- Butler does not manage are left for core to append in its own order.
function remuda.session_order()
  local order = {}
  for _, item in ipairs(team_order()) do
    order[#order + 1] = { name = item.id, depth = item.indent }
  end
  return order
end

-- Agent-specific screen interpretation lives in lazily loaded modules under
-- session_status/. The host keeps capture, hook precedence and cache policy.
local STATUS_TTL_SECONDS = 2
local status_cache = {}
local detector_cache = {}
local function status_detector(kind)
  -- Kinds are also used as module path components; reject anything that is not
  -- a simple identifier before asking the host loader to resolve it.
  if type(kind) ~= "string" or not kind:match("^[%w_-]+$") then return nil end
  local cached = detector_cache[kind]
  if cached ~= nil then return cached or nil end
  local load_detector = config.load_status_detector
  if type(load_detector) ~= "function" then
    detector_cache[kind] = false
    return nil
  end
  local ok = pcall(load_detector, kind)
  local registry = remuda._butler_session_status_detectors
  local detector = ok and type(registry) == "table" and registry[kind] or nil
  detector_cache[kind] = type(detector) == "function" and detector or false
  return type(detector) == "function" and detector or nil
end
local function probe_status(name, agent)
  local detector = status_detector(agent.kind)
  if not detector then return "other" end
  local captured, screen = pcall(remuda.capture, name)
  if not captured or type(screen) ~= "string" then return "other" end
  local ok, status = pcall(detector, screen, agent, config)
  if not ok or (status ~= "needs you" and status ~= "working" and status ~= "idle") then return "other" end
  return status
end
-- A hook word (Claude Code hooks, see status_hook.lua) beats the screen while
-- fresh: "working" for 10 minutes (a Stop that never came means a crash or an
-- interrupt, so later the screen decides), "idle"/"needs you" for an hour. For
-- those two the screen is still probed and a "working" screen wins, because
-- resuming after a permission prompt fires no hook.
local HOOK_MAX_AGE = { working = 600, idle = 3600, ["needs you"] = 3600 }
-- OSC 7501 is a display hint, not a safety fact. `done` reads as idle in the
-- roster; `error` stays visible as other instead of being erased to idle.
-- The limits are display heuristics: the protocol has no heartbeat, so a
-- long silent working/blocked report must not be destroyed, only demoted.
local OSC_ACTIVITY = {
  working = "working", idle = "idle", blocked = "needs you",
  done = "idle", error = "other",
}
local OSC_ACTIVITY_MAX_AGE = {
  working = 600, idle = 3600, blocked = 3600, done = 3600, error = 3600,
}
local function osc_activity(session)
  local status = type(session) == "table" and session.program_status
  if type(status) ~= "table" then return nil end
  local state = status.state
  local activity = OSC_ACTIVITY[state]
  local limit = OSC_ACTIVITY_MAX_AGE[state]
  -- Missing or malformed age is unknown, never fresh. NaN and infinities must
  -- not slip through the comparisons.
  if not activity or not limit then return nil end
  local age = session.program_status_age
  if type(age) ~= "number" or age ~= age or age == math.huge or age < 0 or age > limit then
    return nil
  end
  return activity
end
-- `remuda.session_detail` is also called with just {name=...}; find the live
-- row then, but never invent a status for a missing session.
local function status_row(agent, session)
  if type(session) ~= "table" then return nil end
  -- A caller-supplied row must prove the agent's bound instance before its
  -- OSC status is trusted; program_status alone does not identify the process.
  if type(session.program_status) == "table" then return instance_row(agent, session) end
  if type(session.instance_id) ~= "string" or session.instance_id == "" then
    -- A bare name has no instance, so resolve the live row first instead of
    -- attaching a listed status directly.
  else
    return instance_row(agent, session)
  end
  local listed = remuda.session and remuda.session.list
  if type(listed) ~= "function" then return nil end
  local ok, rows = pcall(listed)
  if not ok or type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do
    if row.name == session.name and type(row.instance_id) == "string"
      and row.instance_id ~= "" and row.unavailable ~= true then
      return instance_row(agent, row)
    end
  end
  return nil
end
local function session_status(name, agent, telemetry, session)
  local now = (remuda._butler_status_now or os.time)()
  local row = status_row(agent, session)
  -- A closed session or a replaced instance is a new process: never reuse the
  -- previous instance's cached status for the same name.
  local resolved = type(row) == "table" and row.instance_id or nil
  local cached = status_cache[name]
  if cached and cached.agent == agent and cached.id == agent.id
    and cached.instance == agent.instance_id and cached.resolved == resolved
    and now - cached.at < STATUS_TTL_SECONDS then
    return cached.status
  end
  local hook, hook_at = telemetry.hook_state, tonumber(telemetry.hook_at)
  local fresh = hook and hook_at and now >= hook_at and now - hook_at < (HOOK_MAX_AGE[hook] or 0)
  local status = osc_activity(row)
  if not status then
    if fresh and hook == "working" then
      status = hook
    else
      local ok, probed = pcall(probe_status, name, agent)
      status = ok and probed or "other"
      if fresh and status ~= "working" then status = hook end
    end
  end
  for key, value in pairs(status_cache) do -- entries of closed sessions expire with the window
    if key ~= name and now - value.at >= STATUS_TTL_SECONDS then status_cache[key] = nil end
  end
  status_cache[name] = { at = now, status = status, agent = agent, id = agent.id,
    instance = agent.instance_id, resolved = resolved }
  return status
end

function remuda.session_detail(session)
  local agent = bus.agents[session.name]
  if not agent then return nil end
  local telemetry = remuda._butler_telemetry_for(agent)
  local detail = session_status(session.name, agent, telemetry, session) .. " · " .. (agent.kind or "agent") .. " · " .. telemetry.model
  local profile = remuda._butler_sandbox.summary(remuda._butler_sandbox.of(agent))
  if profile then detail = detail .. " · " .. profile end
  -- Keep context compact while showing the percentage that makes sessions comparable.
  local used = tonumber(telemetry.context_used)
  local pct = tonumber(telemetry.context_pct or telemetry.context_percent)
  local window = tonumber(telemetry.context_window)
  if pct and (pct ~= pct or pct < 0 or pct > 1000) then pct = nil end -- same sanity range as status_command
  local derived = not used and pct and window and window > 0
  if derived then used = pct * window / 100 end
  if used then
    local context = string.format("%s%.0fK", derived and "~" or "", used / 1000)
    if pct then context = context .. string.format(" %.0f%%", pct) end
    detail = detail .. " · " .. context
  elseif pct then
    detail = detail .. " · " .. string.format("%.0f%%", pct)
  end
  local unread = agent.id and agent.id ~= "" and mail.unread(agent.id) or 0
  if unread > 0 then detail = detail .. " · ✉" .. unread end
  local attempts = agent.launch_attempts or (session.name == "butler" and remuda._butler_attempts)
  if attempts then
    local skipped = {}
    for _, attempt in ipairs(attempts) do
      if attempt.reason ~= "ready" then skipped[#skipped + 1] = attempt.kind .. " " .. attempt.reason end
    end
    if #skipped > 0 then detail = detail .. " · skipped " .. table.concat(skipped, ", ") end
  end
  return detail
end

-- Core's session-list decorator is a typed presentation contract. Activity is
-- advisory status only; it says nothing about whether input is safe or ready.
-- Keep this beside the detail API so older core versions keep the same detail.
function remuda.session_list_decorate(session)
  local agent = type(session) == "table" and bus.agents[session.name]
  if not agent then return nil end
  local detail = remuda.session_detail(session)
  local activity = type(detail) == "string" and detail:match("^(.-) · ") or nil
  if activity ~= "working" and activity ~= "idle" and activity ~= "needs you" then
    activity = "other"
  end
  local prefix = activity .. " · " .. (agent.kind or "agent") .. " · "
  local description = type(detail) == "string" and detail:sub(1, #prefix) == prefix
    and detail:sub(#prefix + 1) or detail
  return {
    activity = activity,
    agent_kind = agent.kind or "agent",
    description = description,
    -- The Butler pane opts into the one-line layout; core keeps its default
    -- stacked layout for extensions without a preference.
    layout = "compact",
  }
end

remuda._butler_sessions_impl = { registry_list = registry_list }
