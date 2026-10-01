-- Single-instance guard (#195): one Remuda daemon owns a Butler home. The
-- owner holds an OS advisory lock (core's remuda.fs.lock) for its whole life,
-- so there is no stale lock: the kernel drops it when the owner dies. A second
-- daemon on the same home loads none of Butler's shared-state code.
local guard = {}

-- ponytail: placeholder until the core release that ships remuda.fs.lock is
-- known (#195); replace with that version.
guard.CORE_WITH_LOCK = "a core release with remuda.fs.lock"

-- The lock sits next to agents.jsonl: the same data home the registry uses.
function guard.lock_path(paths)
  return paths.data_home and (paths.data_home .. "/remuda/butler/lock") or nil
end

-- Returns a state table: { owner = boolean, guarded = boolean, holder = text|nil,
-- reason = text|nil }. The handle lives in a host slot so a mod reload in the
-- same daemon keeps ownership without asking again.
function guard.claim(path)
  local held = remuda._butler_owner_lock
  if held and held.path == path then return { owner = true, guarded = true } end
  if not (remuda.fs and type(remuda.fs.lock) == "function") then
    if not remuda._butler_guard_warned then
      remuda._butler_guard_warned = true
      io.stderr:write("butler: this remuda core cannot lock the Butler home, so a second daemon on it is not refused;"
        .. " upgrade to " .. guard.CORE_WITH_LOCK .. " -- run `remuda upgrade`\n")
    end
    return { owner = true, guarded = false }
  end
  if not path then return { owner = false, guarded = true, reason = "no data home" } end
  local ok, handle, why, info = pcall(remuda.fs.lock, path)
  if ok and handle then
    remuda._butler_owner_lock = { path = path, handle = handle }
    return { owner = true, guarded = true }
  end
  if ok and why == "held" then
    return { owner = false, guarded = true, holder = type(info) == "string" and info or nil }
  end
  -- Any other failure fails closed: this daemon is not the owner.
  return { owner = false, guarded = true, reason = tostring(ok and why or handle) }
end

local function safe(text)
  return (tostring(text):gsub("[%c]", " "))
end

-- One line plus one Next: for a daemon that is not the owner.
function guard.refusal(state)
  if state.holder then
    local session = state.holder:match("^(%S+)")
    return "Butler for this home is already running in another Remuda daemon (" .. safe(state.holder)
      .. "). Nothing was changed.\nNext: remuda -s " .. safe(session or "NAME") .. " butler status"
  end
  return "Butler could not take the owner lock for this home (" .. safe(state.reason or "unknown reason")
    .. "). Nothing was changed.\nNext: remuda butler doctor"
end

-- Every Butler verb is refused in a daemon that is not the owner. doctor is
-- the one exception (pure probes, no shared state); its first line says so.
function guard.standby(state)
  remuda._butler_standby = state
  local refusal = guard.refusal(state)
  local function run(args)
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
  local path = guard.lock_path(paths)
  if path and remuda.fs and type(remuda.fs.lock) == "function" and type(remuda.mkdir) == "function" then
    pcall(remuda.mkdir, path:match("^(.*)/[^/]+$"))
  end
  local state = guard.claim(path)
  if state.owner then
    remuda._butler_standby = nil
    return true
  end
  guard.standby(state)
  return false
end

remuda.butler = remuda.butler or {}
remuda.butler.guard = guard
