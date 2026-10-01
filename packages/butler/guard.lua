-- Single-instance guard (#195): one Remuda daemon owns a Butler home. The
-- owner holds two OS advisory locks (core's remuda.fs.lock) for its whole
-- life, so there is no stale lock: the kernel drops them when the owner dies.
-- A daemon without both loads none of Butler's shared-state code.
local guard = {}

-- The first core release that has remuda.fs.lock (#195).
guard.CORE_WITH_LOCK = "remuda 0.1.0-nightly.20261001062057.499b8b9 or later"

-- Two locks, because Butler's shared files live in two places: the data lock
-- sits next to agents.jsonl (the data home the registry uses), the config lock
-- next to the config file that config.mcp.json and the relay's .since/.acks
-- are named after. The config lock uses the RESOLVED config path, which is
-- known whether or not Matrix is set up (paths.config_path is nil until both
-- Matrix files exist). Always asked in this order: data, then config.
function guard.lock_paths(paths)
  local data = paths.data_home and (paths.data_home .. "/remuda/butler/lock") or nil
  local config = paths.resolved_config_path and (paths.resolved_config_path .. ".lock") or nil
  return data, config
end

-- The one line shown on a core that cannot lock; nil on a core that can.
function guard.unguarded_line()
  if remuda.fs and type(remuda.fs.lock) == "function" then return nil end
  return "Butler home: not guarded. This remuda core cannot lock it, so a second daemon on this home"
    .. " is not refused; upgrade to " .. guard.CORE_WITH_LOCK .. " with `remuda upgrade`."
end

-- One lock: the handle, or nil plus why not.
local function ask(path)
  local ok, handle, why, info = pcall(remuda.fs.lock, path)
  if ok and handle then return handle end
  if ok and why == "held" then
    -- Core's info line: remuda-lock session=NAME pid=N since=UNIX_SECONDS. It is
    -- display only; keep a field only when it is plainly a name or a number, so
    -- forged text never reaches the Next: command.
    info = type(info) == "string" and (" " .. info .. " ") or ""
    return nil, { held = true, session = info:match(" session=([%w._-]+) "), pid = info:match(" pid=(%d+) ") }
  end
  -- Any other failure fails closed: this daemon is not the owner.
  return nil, { reason = tostring(ok and why or handle) }
end

local function release(handle)
  pcall(function() handle:release() end)
end

-- Returns a state table: { owner = boolean, guarded = boolean, handles = {..}|nil,
-- held = true|nil, session = name|nil, pid = digits|nil, reason = text|nil }.
-- The owner has BOTH locks. A daemon that gets only the first gives it back, so
-- a daemon that is not the owner never holds a lock.
function guard.claim(paths)
  if not (remuda.fs and type(remuda.fs.lock) == "function") then
    return { owner = true, guarded = false }
  end
  local data_path, config_path = guard.lock_paths(paths)
  if not (data_path and config_path) then
    return { owner = false, guarded = true, reason = "no data home or config path" }
  end
  local data, config, why
  data, why = ask(data_path)
  if data then
    config, why = ask(config_path)
    if config then return { owner = true, guarded = true, handles = { data, config } } end
    release(data)
  end
  why.owner, why.guarded = false, true
  return why
end

-- Same rule as matrix_cli's terminal_safe (C0 and C1 controls); that helper is
-- not loaded in a refused daemon.
local function safe(text)
  return (tostring(text):gsub("[%c]", " "):gsub("\194[\128-\159]", " "))
end

-- One line plus one Next: for a daemon that is not the owner.
function guard.refusal(state)
  if state.gone then
    return "The Butler daemon that owned this home is gone. This daemon has not taken over.\n"
      .. "Next: remuda exec butler  (reloads Butler in this daemon; add your -s NAME)"
  end
  if state.held then
    local running = "Butler for this home is already running in another Remuda daemon"
    if not state.session then return running .. ". Nothing was changed.\nNext: remuda butler doctor" end
    return running .. " (session " .. state.session .. (state.pid and (", pid " .. state.pid) or "")
      .. "). Nothing was changed.\nNext: remuda -s " .. state.session .. " butler status"
  end
  return "Butler could not take the owner lock for this home (" .. safe(state.reason or "unknown reason")
    .. "). Nothing was changed.\nNext: remuda butler doctor"
end

-- Every Butler verb is refused in a daemon that is not the owner. doctor is
-- the one exception (pure probes, no shared state); its first line says so.
-- Each verb asks the locks again, so the answer names the current owner, or
-- says that it is gone. A refused daemon never promotes itself: what the
-- probe took is given back at once.
function guard.standby(state, paths)
  remuda._butler_standby = state
  local function run(args)
    local now = guard.claim(paths)
    if now.owner then
      for _, handle in ipairs(now.handles or {}) do release(handle) end
      now = { owner = false, guarded = true, gone = true }
    end
    remuda._butler_standby = now
    local refusal = guard.refusal(now)
    if type(args) == "table" and args[1] == "doctor" and #args == 1 then
      remuda.exec("butler/doctor")
      local doctor = remuda._butler_doctor
      return "Not the owning daemon: " .. refusal:match("^[^\n]*") .. "\n"
        .. table.concat(doctor.render(doctor.probe()), "\n")
    end
    if type(remuda.fail) == "function" then return remuda.fail(refusal, 1) end
    error(refusal, 0)
  end
  remuda._butler_command_run = function(_, args) return run(args) end
  if type(remuda.extension_command) == "function" then
    remuda.extension_command("butler", function(args) return run(args) end)
  end
end

-- main.lua calls this before it touches any shared state. True = carry on.
function guard.boot(paths)
  -- This daemon already owns the home (a mod reload): the locks are held until
  -- it exits, so do not ask again. Asking could only lose them: core hands the
  -- same daemon the same handle, and a failed second call would release it.
  if remuda._butler_owner_lock then
    remuda._butler_standby = nil
    return true
  end
  local unguarded = guard.unguarded_line()
  if unguarded and not remuda._butler_guard_warned then
    remuda._butler_guard_warned = true
    io.stderr:write("butler: " .. unguarded .. "\n")
  end
  if not unguarded then
    local data_path, config_path = guard.lock_paths(paths)
    local function parent(path) return path:match("^(.*)/[^/]+$") end
    if data_path then pcall(remuda.mkdir, parent(data_path)) end
    if config_path then
      -- Matrix setup later puts the token and config in this directory, and it
      -- accepts one that exists: create it private (0700), as setup would.
      pcall(remuda.mkdir, parent(parent(config_path)))
      pcall(remuda.fs.mkdir_new, parent(config_path))
    end
  end
  local state = guard.claim(paths)
  if state.owner then
    -- Core keeps the handles alive; this slot only keeps them reachable from Lua.
    remuda._butler_owner_lock, remuda._butler_standby = state.handles, nil
    return true
  end
  guard.standby(state, paths)
  return false
end

-- Owner-only (0600) write for a file that carries a capability. Only a core
-- without remuda.fs.write_atomic gets the plain write; when the word exists and
-- fails, the error is raised: never a silent non-private fallback.
function guard.write_private(path, text)
  if remuda.fs and type(remuda.fs.write_atomic) == "function" then
    local ok, why = remuda.fs.write_atomic(path, text, { private = true })
    if not ok then error("cannot write " .. tostring(path) .. ": " .. tostring(why), 0) end
    return
  end
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

remuda.butler = remuda.butler or {}
remuda.butler.guard = guard
