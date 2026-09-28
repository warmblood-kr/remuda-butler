-- Optional inbound Matrix channel for remuda-butler.
local host = getmetatable(_G).__index.remuda

local function unescape(value)
  return (value:gsub("\\(.)", function(c)
    if c == "n" then return "\n" end
    if c == "r" then return "\r" end
    if c == "t" then return "\t" end
    return c
  end))
end

local function deliver(line)
  local sender, room_id, event_id, created_at, body = line:match(
    "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$"
  )
  if not body then return end
  sender, room_id, event_id, created_at, body = unescape(sender), unescape(room_id),
    unescape(event_id), unescape(created_at), unescape(body)
  local matrix = { sender = sender, room_id = room_id, event_id = event_id, created_at = created_at }
  local delivered = host.emit_until_success("butler/deliver", {
    from = { host = "matrix", id = "", alias = sender, session = sender, kind = "matrix", leader = "" },
    to = "butler", text = body, subject = "Matrix message from " .. sender,
    created_at = created_at, matrix = matrix,
  })
  if delivered == nil then error("no Butler mail channel accepted Matrix event " .. event_id, 0) end
  local config = host._butler_matrix_config
  if config and config.config_path then
    local ack = assert(io.open(config.config_path .. ".acks", "a"))
    assert(ack:write(event_id, "\n"))
    assert(ack:close())
  end
  return delivered
end

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = function(state)
    local config = host._butler_matrix_config
    if not config or not config.token_path or not config.config_path then return end
    state.relay = host.process({
      argv = { "python3", "-c", host._butler_helper_src, config.token_path, config.config_path },
      on_line = "butler-matrix-line",
    })
    host._butler_matrix_relay = state.relay
  end,
  stop = function(state)
    if state.relay then pcall(host.kill, state.relay) end
    state.relay = nil
    host._butler_matrix_relay = nil
  end,
  hooks = {
    { event = "butler-matrix-line", id = "line", run = function(_, line) return deliver(line) end },
  },
  contributes = {
    ["butler.guidance"] = {
      { id = "matrix", order = 80,
        agents_md = function() return "- The owner may reach you over Matrix; these messages arrive in your Butler inbox.\n" end,
        prompt = function() return "The owner may also reach you over Matrix; those messages arrive in your Butler inbox. " end },
    },
  },
}
