-- Reusable async-shaped remuda.http fake for Butler Matrix tests.
-- Calls are recorded without touching the network; callbacks run on tick.
remuda.http = { calls = {}, pending = {}, responses = {}, response_prefixes = {}, holds = {} }
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
  local entry = { spec = spec, callback = spec.callback, completed = false, cancelled = false,
    key = spec.method .. " " .. spec.url }
  table.insert(remuda.http.calls, spec)
  table.insert(remuda.http.pending, entry)
  if remuda.http.holds[entry.key] then entry.held = true end
  return { cancel = function()
    if not entry.completed then
      entry.cancelled = true
      entry.held = false
      entry.result = { error = "cancelled" }
    end
  end }
end

function remuda.http.respond(method, url, result)
  local key = method .. " " .. url
  remuda.http.responses[key] = remuda.http.responses[key] or {}
  table.insert(remuda.http.responses[key], result)
end

function remuda.http.respond_prefix(method, url_prefix, result)
  table.insert(remuda.http.response_prefixes, { method = method, prefix = url_prefix, result = result })
end

function remuda.http.hold(method, url)
  remuda.http.holds[method .. " " .. url] = true
end

function remuda.http.release(method, url, result)
  local key = method .. " " .. url
  for _, entry in ipairs(remuda.http.pending) do
    if entry.held and entry.key == key then
      entry.held, entry.result = false, result
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
    if not entry.completed and not entry.held and not entry.result then
      local script = remuda.http.responses[entry.key]
      if script and #script > 0 then entry.result = table.remove(script, 1) end
      if not entry.result then
        local best
        for _, route in ipairs(remuda.http.response_prefixes) do
          if route.method == entry.spec.method and entry.spec.url:sub(1, #route.prefix) == route.prefix
            and (not best or #route.prefix > #best.prefix) then best = route end
        end
        if best then entry.result = best.result end
      end
      if not entry.result then entry.result = { error = "no scripted fake HTTP response for " .. entry.key } end
    end
    if not entry.completed and not entry.held then
      if entry.result then
        entry.completed = true
        entry.callback(entry.result)
      end
    end
  end
end
