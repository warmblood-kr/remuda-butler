-- Internal inbound Matrix channel. main.lua enters through this one package
-- seam; packages/butler/init.lua owns the stable hook ids.
local data_home = os.getenv("XDG_DATA_HOME")
if not data_home or data_home == "" then data_home = (os.getenv("HOME") or "") .. "/.local/share" end
local config = remuda._butler_matrix_config
local relay_path = data_home .. "/remuda/mods/butler/packages/butler/matrix_relay.py"
local helper_src = remuda._butler_helper_src_override
if not helper_src then
  local file = io.open(relay_path, "r")
  if file then
    helper_src = file:read("*a")
    file:close()
  end
end
remuda._butler_helper_src = helper_src

local function unescape(value)
  return (value:gsub("\\(.)", function(c)
    if c == "n" then return "\n" end
    if c == "r" then return "\r" end
    if c == "t" then return "\t" end
    return c
  end))
end

function remuda._butler_matrix_line(line)
  if line == "__REMUDA_MATRIX_HEALTHY__" then
    remuda._butler_matrix_restart_attempts = 0
    return
  end
  local sender, room_id, event_id, created_at, body = line:match(
    "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$"
  )
  if not body then return end
  sender, room_id, event_id, created_at, body = unescape(sender), unescape(room_id),
    unescape(event_id), unescape(created_at), unescape(body)
  local matrix = { sender = sender, room_id = room_id, event_id = event_id, created_at = created_at }
  local delivered = remuda.emit_until_success("butler/deliver", {
    from = { host = "matrix", id = "", alias = sender, session = sender, kind = "matrix", leader = "" },
    to = "butler", text = body, subject = "Matrix message from " .. sender,
    created_at = created_at, matrix = matrix,
  })
  if delivered == nil then error("no Butler mail channel accepted Matrix event " .. event_id, 0) end
  remuda._butler_matrix_restart_attempts = 0
  if config and config.config_path then
    local ack = assert(io.open(config.config_path .. ".acks", "a"))
    assert(ack:write(event_id, "\n"))
    assert(ack:close())
  end
  return delivered
end

function remuda._butler_matrix_submit()
  remuda.send("butler", "")
end

function remuda._butler_matrix_stop()
  local retry = remuda._butler_matrix_restart_schedule
  if retry then pcall(remuda.cancel, retry) end
  remuda._butler_matrix_restart_schedule = nil
  remuda._butler_matrix_restart_after_stop = false
  if remuda._butler_matrix_stopping then
    for _, id in ipairs(remuda.processes()) do
      if id == remuda._butler_matrix_relay or id == remuda._butler_relay then
        pcall(remuda.kill, id)
      end
    end
    return
  end

  local active, found = {}, {}
  for _, id in ipairs(remuda.processes()) do
    if (id == remuda._butler_matrix_relay or id == remuda._butler_relay) and not found[id] then
      active[#active + 1] = id
      found[id] = true
    end
  end
  local waiting = remuda._butler_matrix_legacy_exit_pending or 0
  remuda._butler_matrix_legacy_exit_pending = 0
  if #active > 0 then
    remuda._butler_matrix_relay = active[1]
    remuda._butler_relay = nil
    waiting = waiting + #active
    remuda._butler_matrix_stopping = true
    remuda._butler_matrix_stop_exit_count = waiting
    for _, id in ipairs(active) do pcall(remuda.kill, id) end
  elseif waiting > 0 then
    remuda._butler_matrix_stopping = true
    remuda._butler_matrix_stop_exit_count = waiting
  else
    remuda._butler_matrix_relay = nil
    remuda._butler_relay = nil
    remuda._butler_matrix_stopping = false
    remuda._butler_matrix_stop_exit_count = nil
  end
end

local function matrix_trace(event, detail)
  local config = remuda._butler_matrix_config
  local path = remuda._butler_matrix_trace_path
    or (config and config.config_path and (config.config_path .. ".trace"))
  if not path then return end
  pcall(function()
    local f = assert(io.open(path, "a"))
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"), "\t", event, "\t", tostring(detail or ""), "\n")
    f:close()
  end)
end

function remuda._butler_matrix_start()
  local config = remuda._butler_matrix_config
  local source = remuda._butler_helper_src_override or remuda._butler_helper_src
  if not config or not config.token_path or not config.config_path or not source
    or remuda._butler_skip_relay then return false end
  if remuda._butler_matrix_stopping then
    remuda._butler_matrix_restart_after_stop = true
    return false
  end
  local running = false
  local legacy
  for _, id in ipairs(remuda.processes()) do
    if id == remuda._butler_matrix_relay then running = true end
    -- A pre-extraction Butler kept its process in this root-owned slot. Stop
    -- that worker before starting the new protocol so the first upgrade does
    -- not leave two relays polling the same room.
    if id == remuda._butler_relay then
      legacy = id
    end
  end
  if legacy then
    remuda._butler_relay = nil
    if not running then
      -- The legacy worker uses the same exit event. Keep its id in the new
      -- slot and start the replacement only after the core reports it dead.
      remuda._butler_matrix_relay = legacy
      remuda._butler_matrix_stopping = true
      remuda._butler_matrix_restart_after_stop = true
      remuda._butler_matrix_stop_exit_count = 1
      matrix_trace("relay_stop", "legacy worker during upgrade")
      pcall(remuda.kill, legacy)
      return false
    end
    remuda._butler_matrix_legacy_exit_pending = (remuda._butler_matrix_legacy_exit_pending or 0) + 1
    pcall(remuda.kill, legacy)
    remuda._butler_relay = nil
  end
  if not running then
    local attempt = remuda._butler_matrix_restart_attempts or 0
    if attempt > 0 then matrix_trace("relay_restart", "attempt=" .. attempt .. " backoff=" .. math.min(60, 2 ^ math.min(6, attempt - 1)))
    else matrix_trace("relay_start", "initial") end
    remuda._butler_matrix_relay = remuda.process{
      argv = { "python3", "-c", source, config.token_path, config.config_path },
      on_line = "butler-matrix-line",
      on_exit = "butler-matrix-sync-exit",
    }
    return true
  end
  return true
end

function remuda._butler_matrix_sync_exit(code)
  local waiting = remuda._butler_matrix_stop_exit_count or 0
  if waiting > 0 then
    waiting = waiting - 1
    remuda._butler_matrix_stop_exit_count = waiting > 0 and waiting or nil
    if waiting > 0 then return end
    remuda._butler_matrix_relay = nil
    remuda._butler_relay = nil
    remuda._butler_matrix_stopping = false
    if remuda._butler_matrix_restart_after_stop then
      remuda._butler_matrix_restart_after_stop = false
      remuda._butler_matrix_start()
    end
    return
  end
  local ignored = remuda._butler_matrix_legacy_exit_pending or 0
  if ignored > 0 then
    remuda._butler_matrix_legacy_exit_pending = ignored - 1
    return
  end
  remuda._butler_matrix_relay = nil
  if remuda._butler_matrix_stopping then
    remuda._butler_matrix_stopping = false
    if remuda._butler_matrix_restart_after_stop then
      remuda._butler_matrix_restart_after_stop = false
      remuda._butler_matrix_start()
    end
    return
  end

  local config = remuda._butler_matrix_config
  if not config or remuda._butler_skip_relay then return end
  local attempts = (remuda._butler_matrix_restart_attempts or 0) + 1
  remuda._butler_matrix_restart_attempts = attempts
  local delay = math.min(60, 2 ^ math.min(6, attempts - 1))
  matrix_trace("relay_exit", "code=" .. tostring(code) .. " attempt=" .. attempts .. " backoff=" .. delay)
  local due = os.time() + delay
  local old = remuda._butler_matrix_restart_schedule
  if old then pcall(remuda.cancel, old) end
  local handle
  handle = remuda.schedule({ name = "butler-matrix-restart", every = 1, run = function()
    if remuda._butler_matrix_restart_schedule == handle then
      if os.time() < due then return end
      remuda.cancel(handle)
      remuda._butler_matrix_restart_schedule = nil
      remuda._butler_matrix_start()
    end
  end })
  remuda._butler_matrix_restart_schedule = handle
end

remuda._butler_matrix_start()
