-- Internal inbound Matrix channel. main.lua enters through this one package
-- seam; packages/butler/init.lua owns the stable hook ids.
local config = remuda._butler_matrix_config
local data_home = os.getenv("XDG_DATA_HOME")
if not data_home or data_home == "" then data_home = (os.getenv("HOME") or "") .. "/.local/share" end
local relay_path = data_home .. "/remuda/mods/butler/packages/butler/matrix_relay.py"
local file = io.open(relay_path, "r")
local helper_src
if file then
  helper_src = file:read("*a")
  file:close()
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
  local relay = remuda._butler_matrix_relay
  if relay then pcall(remuda.kill, relay) end
  remuda._butler_matrix_relay = nil
end

if config and config.token_path and config.config_path and helper_src
  and not remuda._butler_skip_relay then
  local running = false
  for _, id in ipairs(remuda.processes()) do
    if id == remuda._butler_matrix_relay then running = true end
    -- A pre-extraction Butler kept its process in this root-owned slot. Stop
    -- that worker before starting the new protocol so the first upgrade does
    -- not leave two relays polling the same room.
    if id == remuda._butler_relay then
      pcall(remuda.kill, id)
      remuda._butler_relay = nil
    end
  end
  if not running then
    remuda._butler_matrix_relay = remuda.process{
      argv = { "python3", "-c", helper_src, config.token_path, config.config_path },
      on_line = "butler-matrix-line",
      on_exit = "butler-matrix-sync-exit",
    }
  end
end
