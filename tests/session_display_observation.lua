-- Exercise the production adapters with controlled concurrent-file observations.
remuda = { _butler_agent_builders = {}, _butler_telemetry_adapters = {},
  _butler_agent_support = {}, _butler_agent_startup = { claude = { modals = {} }, codex = { modals = {} } },
  _butler_state = {}, _butler_compaction_state = {} }
dofile("packages/butler/agents/codex.lua")
dofile("packages/butler/agents/claudecode.lua")
local original_open = io.open
local old = "MODEL:old CTX:42 CTXWIN:100 CTXPCT:42"
local new = "MODEL:new CTX:50 CTXWIN:100 CTXPCT:50"
local records = {}
io.open = function(path)
  local value = records[path]
  if value == nil then return nil end
  return { read = function(_, amount)
    if type(amount) == "number" then return value:sub(1, amount) end
    return value:match("([^\n]*)")
  end, close = function() end }
end
for _, kind in ipairs({ "codex", "claude" }) do
  local read = remuda._butler_telemetry_adapters[kind].read
  local binding = kind == "claude" and "instance-1\n" or ""
  records = { status = old, ["status.observed"] = "1000\n" .. binding .. old }
  assert(read({ status_path = "status" }, "instance-1").observed_at == 1000)
  -- Reader got old payload, writer completed new payload+timestamp before
  -- the independent sidecar read: old bytes must not become fresh.
  records["status.observed"] = "1001\n" .. binding .. new
  assert(read({ status_path = "status" }, "instance-1").observed_at == nil)
  records.status = new
  assert(read({ status_path = "status" }, "instance-1").observed_at == 1001)
  records["status.observed"] = "1001\n" .. binding .. new .. string.rep("x", 513)
  assert(read({ status_path = "status" }, "instance-1").observed_at == nil)
  records["status.observed"] = "1001\nMODEL:truncated"
  assert(read({ status_path = "status" }, "instance-1").observed_at == nil)
  if kind == "claude" then
    records["status.observed"] = "1001\ninstance-previous\n" .. new
    assert(read({ status_path = "status" }, "instance-1").observed_at == nil, "new instance inherited old source")
    records["status.observed"] = "1001\ninstance-1\n" .. new
    assert(read({ status_path = "status" }, "instance-1").observed_at == 1001, "same-instance adoption loses source")
  end
  records["status.observed"] = nil
  assert(read({ status_path = "status" }, "instance-1").observed_at == nil, "old observers have no proven source age")
end
io.open = original_open
print("session display observation binding: ok")
