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
  local heir = exited.parent and bus.agents[exited.parent] and exited.parent
    or (bus.agents.butler and "butler") or nil
  for alias, agent in pairs(bus.agents) do
    if agent.parent == name then
      agent.parent = heir
      if heir then table.insert(bus.agents[heir].children, alias) end
    end
  end
end

function remuda._butler_sessions()
  -- main.lua reassigns its butler_attempts with this global; read it late.
  local butler_attempts = remuda._butler_attempts or {}
  local rows = {}
  for _, item in ipairs(team_order()) do
    local agent = bus.agents[item.id]
    rows[#rows + 1] = string.rep(" ", item.indent * 2) .. (item.orphan and "[orphan] " or "")
      .. display_name(item.id) .. "\t" .. tostring(agent.kind or "") .. "\t"
      .. tostring(agent.parent or "-") .. "\t"
      .. (bus.notices and bus.notices[item.id] and "queued" or "-")
  end
  local out = #rows == 0 and "no Butler agents"
    or "SESSION\tAGENT\tLEADER\tNOTICE\n" .. table.concat(rows, "\n")
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

-- Per-session status from the agent's own screen probes: "needs you" (a
-- startup/trust/update dialog), "working", "idle" or "other". Only kinds whose
-- ready/working probes are meaningful are probed (monocle's "working" means
-- "not ready"). Any failure is "other"; the screen itself is never shown.
local STATUS_KINDS = { claude = true, codex = true }
local STATUS_TTL_SECONDS = 2
local status_cache = {}
local function probe_status(name, agent)
  if not STATUS_KINDS[agent.kind] then return "other" end
  local entry = config.registered_agent_kind(agent.kind)
  if not (entry and type(entry.ready) == "function" and type(entry.working) == "function") then return "other" end
  local captured, screen = pcall(remuda.capture, name)
  if not captured or type(screen) ~= "string" then return "other" end
  local startup = remuda._butler_agent_startup[agent.kind] or {}
  local modal_ok, modal = pcall(remuda._butler_chooser.known_startup_modal, startup, screen)
  if modal_ok and modal then return "needs you" end
  local working_ok, working = config.call_callback(entry.working, screen)
  if not working_ok then return "other" end
  if working then return "working" end
  local ready_ok, ready = config.call_callback(entry.ready, screen)
  return ready_ok and ready and "idle" or "other"
end
-- A hook word (Claude Code hooks, see status_hook.lua) beats the screen while
-- fresh: "working" for 10 minutes (a Stop that never came means a crash or an
-- interrupt, so later the screen decides), "idle"/"needs you" for an hour. For
-- those two the screen is still probed and a "working" screen wins, because
-- resuming after a permission prompt fires no hook.
local HOOK_MAX_AGE = { working = 600, idle = 3600, ["needs you"] = 3600 }
local function session_status(name, agent, telemetry)
  local now = (remuda._butler_status_now or os.time)()
  local cached = status_cache[name]
  -- A closed session whose name is reused is a new agent: never show its status.
  if cached and cached.agent == agent and cached.id == agent.id and now - cached.at < STATUS_TTL_SECONDS then
    return cached.status
  end
  local hook, hook_at = telemetry.hook_state, tonumber(telemetry.hook_at)
  local fresh = hook and hook_at and now >= hook_at and now - hook_at < (HOOK_MAX_AGE[hook] or 0)
  local status
  if fresh and hook == "working" then
    status = hook
  else
    local ok, probed = pcall(probe_status, name, agent)
    status = ok and probed or "other"
    if fresh and status ~= "working" then status = hook end
  end
  for key, value in pairs(status_cache) do -- entries of closed sessions expire with the window
    if key ~= name and now - value.at >= STATUS_TTL_SECONDS then status_cache[key] = nil end
  end
  status_cache[name] = { at = now, status = status, agent = agent, id = agent.id }
  return status
end

function remuda.session_detail(session)
  local agent = bus.agents[session.name]
  if not agent then return nil end
  local telemetry = remuda._butler_telemetry_for(agent)
  local detail = session_status(session.name, agent, telemetry) .. " · " .. (agent.kind or "agent") .. " · " .. telemetry.model
  -- Current usage only: the window and percent cost width and rarely change.
  local used = tonumber(telemetry.context_used)
  if used then detail = detail .. " · " .. string.format("%.0fK", used / 1000) end
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

remuda._butler_sessions_impl = { registry_list = registry_list }
