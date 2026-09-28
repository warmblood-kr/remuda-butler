-- Reusable async-shaped remuda.http fake for Butler Matrix tests.
-- Calls are recorded without touching the network; tests complete them explicitly.
remuda.http = { calls = {}, pending = {}, responses = {}, holds = {} }
remuda._fake_http_timers = {}

remuda.schedule = function(spec)
  local timer = { spec = spec, cancelled = false }
  table.insert(remuda._fake_http_timers, timer)
  return timer
end

remuda.cancel = function(timer)
  if timer then timer.cancelled = true end
end

function remuda.http.request(spec)
  local index = #remuda.http.calls + 1
  local entry = { spec = spec, callback = spec.callback, completed = false, cancelled = false }
  remuda.http.calls[index] = spec
  remuda.http.pending[index] = entry
  local key = spec.method .. " " .. spec.url
  local script = remuda.http.responses[key]
  if remuda.http.holds[key] then entry.held = true
  elseif script and #script > 0 then entry.result = table.remove(script, 1)
  else entry.result = { error = "no scripted fake HTTP response for " .. key } end
  return {
    cancel = function()
      if not entry.completed then entry.cancelled = true end
    end,
  }
end

function remuda.http.respond(method, url, result)
  local key = method .. " " .. url
  remuda.http.responses[key] = remuda.http.responses[key] or {}
  table.insert(remuda.http.responses[key], result)
end

-- Keep a selected request pending across ticks to model a held /sync long poll.
-- Releasing it only makes its result eligible for the next daemon tick.
function remuda.http.hold(method, url)
  remuda.http.holds[method .. " " .. url] = true
end

function remuda.http.release(method, url, result)
  local key = method .. " " .. url
  for _, entry in ipairs(remuda.http.pending) do
    local spec = entry.spec
    if entry.held and spec.method .. " " .. spec.url == key then
      entry.held = false
      entry.result = result
      remuda.http.holds[key] = nil
      return true
    end
  end
  return false
end

function remuda.http.tick()
  for _, timer in ipairs(remuda._fake_http_timers) do
    if not timer.cancelled then timer.spec.run() end
  end
  for _, entry in ipairs(remuda.http.pending) do
    if not entry.completed and not entry.held and entry.result then
      entry.completed = true
      entry.callback(entry.result)
    end
  end
end
