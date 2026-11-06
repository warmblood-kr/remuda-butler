-- Task-independent Codex startup controls: update, skip and restart only.
--
-- #579 routes every known kind to durable Task mail, so the typed first-task
-- block (and the Codex update state machine nested in it) no longer runs.
-- This owner keeps the update lifecycle alive with an empty task: it never
-- types, never presses Return into a composer and never touches trust (the
-- launch chooser remains the trust owner). It stops as soon as the pane is
-- ready. One capture per tick is shared through agent.last_screen.
local M = {}

local function chooser() return remuda._butler_chooser end
local function startup_for(kind)
  return (remuda._butler_agent_startup or {})[kind] or {}
end
local function trace(event, detail)
  local fn = remuda._butler_session_trace or _G._butler_session_trace
  if type(fn) == "function" then pcall(fn, event, detail) end
end
local function safe(name)
  local notice = remuda._butler_notice
  local fn = notice and notice.startup_action_safe
  if type(fn) ~= "function" then return false end
  local ok, allowed = pcall(fn, name)
  return ok and allowed == true
end

local active = {}
-- One quiet-stop handoff: the observer may take the controller's last captured
-- frame once instead of capturing again (which could both advance a scripted
-- pane and lose the model-rejection evidence).
local recent = {}

local function remember(state, screen)
  if state.agent and screen ~= nil then
    recent[state.name] = { agent = state.agent, marker = state.marker,
      instance = state.instance, screen = screen, at = os.time() }
  end
end

local function stop(name, reason)
  local state = active[name]
  if not state then return false end
  active[name] = nil
  if state.last_screen ~= nil then remember(state, state.last_screen) end
  if state.handle then pcall(remuda.cancel, state.handle) end
  if state.wait_timer then pcall(remuda.cancel, state.wait_timer) end
  trace("startup_control_stop", name .. " " .. tostring(reason or "stopped"))
  return true
end

local function active_count()
  local n = 0
  for _ in pairs(active) do n = n + 1 end
  return n
end

local function fenced(state)
  local bus = remuda._butler_bus
  local agent = bus and bus.agents and bus.agents[state.name]
  if not agent or agent ~= state.agent then return false end
  if agent.session_start_marker ~= state.marker then return false end
  if state.instance and agent.instance_id and agent.instance_id ~= state.instance then return false end
  local c = chooser()
  if c and type(c.instance_live) == "function" then
    local ok, live = pcall(c.instance_live, state.name, state.instance)
    return ok and live == true
  end
  for _, row in ipairs(remuda.ls()) do
    if row.name == state.name then
      return row.alive == true and (not state.instance or row.instance_id == state.instance)
    end
  end
  return false
end

-- Revalidate the exact launch and the human-safe gate immediately before any
-- key or close; a capture yields, so the tick-start fence is not enough.
local function may_act(state)
  return fenced(state) and safe(state.name)
end

local function say(parent, text)
  pcall(remuda._butler_send, "butler", parent or "butler", text)
end

local function clear_waiting(state)
  local update = remuda._butler_bus.codex_update_state
  if update.waiting then update.waiting[state.name] = nil end
  if update.restart_waiting then update.restart_waiting[state.name] = nil end
end

local function fail(state, reason, keep_claims)
  if state.finished then return end
  state.finished = true
  stop(state.name, "failed")
  -- A still-updating timeout keeps its in-flight owner/restart record for the
  -- eventual exit; only an abort clears this member's waiting claims.
  if not keep_claims then clear_waiting(state) end
  local text
  if state.saved_id and state.task_supplied then
    text = "startup control failed for " .. state.name .. "; task saved " .. state.saved_id
      .. "; read the existing inbox. Do not resend the body."
  elseif state.task_supplied and state.awaiting_saved then
    text = "startup control failed for " .. state.name
      .. "; its task routing outcome was still pending and the brief is retained."
  elseif state.task_supplied then
    text = "startup control failed for " .. state.name
      .. "; the task was not saved and its brief is retained."
  else
    text = "startup control failed for " .. state.name .. "; no task was supplied."
  end
  trace("startup_control_failed", state.name .. ": " .. tostring(reason))
  say(state.parent, text)
end

local function ready(state, screen)
  local c = chooser()
  local startup = startup_for(state.kind)
  if screen and c and startup.ready and startup.ready(screen) then return true end
  return false
end

local function restart_record(state, version)
  local agent = (remuda._butler_bus.agents or {})[state.name] or {}
  return {
    kind = state.kind, name = state.name, cwd = state.cwd, model = state.model,
    parent = state.parent, task = "", task_supplied = state.task_supplied,
    saved_task_id = state.saved_id, original_task = state.original_task,
    identity = state.identity, profile = state.profile,
    update_pressed = false, last_screen = agent.last_screen, version = version,
  }
end

local function relaunch(state, version)
  local record = remuda._butler_bus.codex_update_relaunches[state.name]
  if record and record.relaunched then stop(state.name, "relaunched"); return true end
  if not may_act(state) then return false end
  local fresh = restart_record(state, version)
  fresh.expected_close = true
  remuda._butler_bus.codex_update_relaunches[state.name] = fresh
  clear_waiting(state)
  local closed, result = pcall(remuda.close, state.name)
  if not closed or result == false then
    remuda._butler_bus.codex_update_relaunches[state.name] = nil
    return false
  end
  stop(state.name, "relaunch")
  return true
end

local function finish_update(state, version)
  local update = remuda._butler_bus.codex_update_state
  update.done, update.claimed, update.done_version, update.owner = true, false, version, nil
  update.restart_waiting = update.restart_waiting or {}
  for member in pairs(update.waiting or {}) do update.restart_waiting[member] = true end
  update.waiting = {}
end

local function wait_deadline(state)
  if state.deadline == 0 then
    state.deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
  end
  return os.time() >= state.deadline
end

local function expired(state, screen)
  state.modal_since = state.modal_since or os.time()
  local c = chooser()
  local budget = c and c.startup_modal_timeout_seconds and c.startup_modal_timeout_seconds()
    or (tonumber(remuda._butler_modal_timeout or remuda._butler_task_poke_attempts) or 60)
  return os.time() - state.modal_since >= budget
end

local function skip_update(state, region, strict, reason)
  local c = chooser()
  local option = strict and c and c.skip_option_number and c.skip_option_number(region)
  if option and may_act(state) then
    local pressed, result = pcall(remuda.key, state.name, option)
    if pressed and result ~= false then
      state.settle = state.ticks + 3
      return true
    end
    fail(state, "skip key was not accepted")
    return false
  end
  if expired(state, region) then fail(state, reason) end
  return false
end

local function update_version(state, region)
  local c = chooser()
  local update = remuda._butler_bus.codex_update_state
  local version = c and c.codex_update_version and c.codex_update_version(region) or "unknown"
  if version ~= "unknown" then
    if update.version and update.version ~= version and not update.claimed then
      update.done, update.done_version = false, nil
      update.waiting, update.restart_waiting = {}, {}
    end
    update.version = version
    state.version = version
  end
  return version
end

local function waiting_owner_tick(state, region, version, strict)
  local update = remuda._butler_bus.codex_update_state
  if update.done and update.done_version == version then
    if relaunch(state, version) then return true end
    if expired(state, region) then fail(state, "update completed while waiting") end
    return true
  end
  if wait_deadline(state) then skip_update(state, region, strict, "waiting for Codex update") end
  if expired(state, region) then fail(state, "waiting for Codex update") end
  return true
end

local function join_waiting(state, region, version, strict)
  local update = remuda._butler_bus.codex_update_state
  update.waiting = update.waiting or {}
  update.waiting[state.name] = true
  if update.done and update.done_version == version then
    if relaunch(state, version) then return end
    if expired(state, region) then fail(state, "update completed while waiting") end
    return
  end
  if wait_deadline(state) then skip_update(state, region, strict, "waiting for Codex update") end
end

local function claim_update(state, region, version, strict)
  local c = chooser()
  local update = remuda._butler_bus.codex_update_state
  if update.claimed or not strict then return false end
  local option = c.option_number(region, function(label)
    return label:lower():find("update now", 1, true) ~= nil
  end)
  if not (option and may_act(state)) then return false end
  update.claimed, update.owner = true, state.name
  state.deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
  update.waiting = update.waiting or {}
  local record = restart_record(state, version)
  record.update_pressed = true
  remuda._butler_bus.codex_update_relaunches[state.name] = record
  local pressed, result = pcall(remuda.key, state.name, option)
  if pressed and result ~= false then return true end
  -- The key may have started the update even though its result was unknown:
  -- keep the claim/record and never send the opposite choice this tick.
  state.update_uncertain = true
  trace("startup_control_uncertain", state.name .. " update key not confirmed")
  return true
end

local function update_tick(state, screen, region, strict)
  local c = chooser()
  if not (c and c.option_number and c.skip_option_number) then return end
  local update = remuda._butler_bus.codex_update_state
  local name = state.name
  -- Version metadata comes from the full captured screen; the current region
  -- is only the key-authorization source.
  local version = update_version(state, screen)
  if state.update_uncertain then
    if expired(state, region) then
      trace("codex_update_timeout", name .. " update key outcome uncertain")
      fail(state, "the Codex update key outcome was uncertain", true)
    end
    return
  end
  if update.claimed and update.owner ~= name and update.waiting and update.waiting[name] then
    if waiting_owner_tick(state, region, version, strict) then return end
  end
  if update.done and update.restart_waiting and update.restart_waiting[name] then
    if relaunch(state, update.done_version) then return end
    if expired(state, region) then fail(state, "update completed while relaunching") end
    return
  end
  if update.claimed and update.owner ~= name then
    join_waiting(state, region, version, strict)
    return
  end
  if update.aborted_version == version or (update.done and update.done_version == version) then
    if strict then
      skip_update(state, region, strict, "update dialog did not clear")
    elseif expired(state, region) then
      fail(state, "update dialog") -- unparseable menu: report, press nothing
    end
    return
  end
  if claim_update(state, region, version, strict) then return end
  if strict then
    skip_update(state, region, strict, "update dialog")
  elseif expired(state, region) then
    fail(state, "update dialog") -- unparseable menu: report, press nothing
  end
end

local function working_now(screen)
  local startup = startup_for("codex")
  if type(startup.working) ~= "function" then return false end
  local checked, working = pcall(startup.working, screen)
  return checked and working == true
end

local function owned_update(state)
  local update = remuda._butler_bus.codex_update_state
  local name = state.name
  return (update.claimed and update.owner == name)
    or (update.waiting and update.waiting[name])
    or (update.done and update.restart_waiting and update.restart_waiting[name])
end

local function no_modal_tick(state, screen)
  local update = remuda._butler_bus.codex_update_state
  local name = state.name
  local restarting = update.done and update.restart_waiting and update.restart_waiting[name]
  local waiting_peer = update.waiting and update.waiting[name]
    and not (update.claimed and update.owner == name)
  if restarting then
    state.modal_since = state.modal_since or os.time()
    if relaunch(state, update.done_version) then return end
    if expired(state, screen) then
      trace("codex_update_timeout", name .. " update completed while relaunching")
      fail(state, "the Codex update completed but the pane could not be relaunched", true)
    end
    return
  end
  if waiting_peer then
    if wait_deadline(state) then fail(state, "waiting for Codex update") end
    return
  end
  if update.claimed and update.owner == name then
    if ready(state, screen) then
      state.modal_since = nil
      local version = update.version or state.version or "unknown"
      finish_update(state, version)
      if relaunch(state, version) then return end
      update.restart_waiting = update.restart_waiting or {}
      update.restart_waiting[name] = true
      state.modal_since = os.time()
      if expired(state, screen) then
        trace("codex_update_timeout", name .. " update completed while relaunching")
        fail(state, "the Codex update completed but the pane could not be relaunched", true)
      end
      return
    end
    if state.deadline ~= 0 and os.time() >= state.deadline then
      trace("codex_update_timeout", name .. " update did not finish")
      fail(state, "the Codex update did not finish", true)
    end
    return
  end
  if ready(state, screen) then
    state.modal_since = nil
    stop(name, "ready")
    return
  end
  state.modal_since = state.modal_since or os.time()
  if expired(state, screen) then stop(name, "startup unresolved") end
end

local function tick(state)
  if active[state.name] ~= state then return end
  if not fenced(state) then stop(state.name, "launch replaced"); return end
  state.ticks = state.ticks + 1
  local captured, screen = pcall(remuda.capture, state.name)
  if not captured or type(screen) ~= "string" then stop(state.name, "capture failed"); return end
  if not fenced(state) then stop(state.name, "launch replaced"); return end
  state.last_screen = screen
  remember(state, screen)
  local agent = remuda._butler_bus.agents[state.name]
  if agent then agent.last_screen = screen end
  if state.ticks < state.settle then return end
  -- No owned update/restart claim plus a working pane: a native-delivered Task
  -- is already admitted, even if its output quotes update-like text.
  if working_now(screen) and not owned_update(state) then stop(state.name, "busy"); return end
  local c = chooser()
  local modal = c and c.startup_modal and c.startup_modal(startup_for(state.kind), screen)
  if modal and modal.trust then
    state.modal_since = state.modal_since or os.time()
    if expired(state, screen) then stop(state.name, "trust unresolved") end
    return
  end
  if not modal then no_modal_tick(state, screen); return end
  if modal.update then
    local dialogs = remuda.butler and remuda.butler.dialogs
    local region = dialogs and dialogs.live_update_region and dialogs.live_update_region(agent, screen)
    local strict = dialogs and dialogs.live_update_choice and dialogs.live_update_choice(agent, screen)
    state.modal_since = state.modal_since or os.time()
    if region then update_tick(state, screen, region, strict == true); return end
    -- Broad marker without a current choice: report and expire, never press.
    if expired(state, screen) then fail(state, "update dialog") end
    return
  end
  state.modal_since = state.modal_since or os.time()
  if expired(state, screen) then fail(state, "modal did not clear") end
end

-- opts: name, kind, parent, identity, agent, marker, instance, model, cwd,
-- profile, saved_id, task_supplied, original_task.
function M.start(opts)
  opts = opts or {}
  if opts.kind ~= "codex" then return nil, "not_codex" end
  local bus = remuda._butler_bus
  local agent = bus and bus.agents and bus.agents[opts.name]
  if not agent then return nil, "unknown_session" end
  stop(opts.name, "replaced")
  local state = {
    name = opts.name, kind = "codex", parent = opts.parent,
    identity = opts.identity or agent.id, agent = agent,
    marker = agent.session_start_marker, instance = agent.instance_id,
    model = opts.model or agent.model, cwd = opts.cwd or agent.cwd,
    profile = opts.profile, saved_id = opts.saved_id,
    task_supplied = opts.task_supplied == true,
    awaiting_saved = opts.task_supplied == true and opts.saved_id == nil,
    original_task = opts.original_task,
    ticks = 0, settle = 1, deadline = 0,
  }
  active[state.name] = state
  state.handle = remuda.schedule({ every = 0.5, run = function() tick(state) end })
  trace("startup_control_start", state.name .. " task=" .. tostring(state.task_supplied)
    .. " saved=" .. tostring(state.saved_id))
  return state
end

local function matches(name, agent)
  local state = active[name]
  if not state then return nil end
  if agent ~= nil then
    if state.agent ~= agent then return nil end
    if agent.session_start_marker ~= state.marker then return nil end
    if state.instance and agent.instance_id and state.instance ~= agent.instance_id then return nil end
  end
  return state
end

-- Stop only the exact record handed out by start(): a name-only stop could
-- cancel a replacement controller for the same alias.
function M.stop(name, token)
  if token == nil or active[name] ~= token then return false end
  return stop(name, "stopped")
end
function M.active(name, agent) return matches(name, agent) end
-- Fill the durable id only into the exact controller record returned by
-- start(). A yielding queue must never write into a replacement controller.
function M.set_saved(name, id, token)
  local state = active[name]
  if not state or token == nil or state ~= token then return false end
  if not fenced(state) then return false end
  -- The queue outcome is now settled either way: a nil id means the durable
  -- save failed and must report the retained brief, not "routing pending".
  state.awaiting_saved = false
  if type(id) ~= "string" or id == "" then
    state.saved_id = nil
    return false
  end
  state.saved_id = id
  return true
end
function M.active_count() return active_count() end
-- Take the exact launch's last captured frame after a quiet stop. Matching the
-- agent object, marker and instance keeps a replacement's frame out.
function M.take_evidence(name, agent)
  local entry = recent[name]
  if not entry then return nil end
  recent[name] = nil
  if not agent or entry.agent ~= agent then return nil end
  if agent.session_start_marker ~= entry.marker then return nil end
  if entry.instance and agent.instance_id and entry.instance ~= agent.instance_id then return nil end
  if entry.at and os.time() - entry.at > 10 then return nil end
  return entry.screen
end
-- Explicit stop/reload: cancel only the timers this module owns. The shared
-- update claims, the pane and its restart record are left for the exit path.
function M.stop_all()
  local names = {}
  for name in pairs(active) do names[#names + 1] = name end
  for _, name in ipairs(names) do stop(name, "butler stopped") end
end

remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.startup_controls = M
return M
