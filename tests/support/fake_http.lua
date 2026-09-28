-- Reusable async-shaped remuda.http fake for Butler Matrix tests.
-- Calls are recorded without touching the network; callbacks run on tick.
remuda.http = { calls = {}, pending = {}, responses = {}, response_prefixes = {}, holds = {} }
remuda._fake_http_timers = {}

local MAX_BYTES = 20 * 1024 * 1024
local DEFAULT_MAX_BYTES = 1024 * 1024

local function valid_token(value)
  return type(value) == "string" and value ~= "" and not value:find("[^%w!#$%%&'*+%.%-%^_`|~]")
end

local function validate(spec)
  if type(spec) ~= "table" or not valid_token(spec.method) then return "invalid HTTP method" end
  if type(spec.url) ~= "string" or not spec.url:match("^https?://[^/%?#]+") then
    return "invalid HTTP URL"
  end
  if type(spec.callback) ~= "function" then return "http.request requires callback" end
  if type(spec.timeout) ~= "number" or spec.timeout ~= spec.timeout
    or spec.timeout <= 0 or spec.timeout > 3600 then
    return "http.request timeout must be between 0 and 3600 seconds"
  end
  local connect_timeout = spec.connect_timeout or math.min(spec.timeout, 10)
  if type(connect_timeout) ~= "number" or connect_timeout ~= connect_timeout
    or connect_timeout <= 0 or connect_timeout > 3600 then
    return "http.request connect_timeout must be between 0 and 3600 seconds"
  end
  if connect_timeout > spec.timeout then return "invalid HTTP timeout bounds" end
  if spec.body ~= nil and type(spec.body) ~= "string" then return "HTTP body must be a byte string" end
  local max_bytes = spec.max_bytes == nil and DEFAULT_MAX_BYTES or spec.max_bytes
  if type(max_bytes) ~= "number" or max_bytes < 0 or max_bytes % 1 ~= 0 then
    return "invalid max_bytes"
  end
  if max_bytes > MAX_BYTES then return "max_bytes exceeds 20 MiB" end
  for name, value in pairs(spec.headers or {}) do
    if not valid_token(name) or type(value) ~= "string" or value:find("[\r\n]") then
      return "invalid HTTP header"
    end
  end
end

local function normalize_headers(headers)
  local result = {}
  for name, value in pairs(headers or {}) do
    local key = name:lower()
    local values = type(value) == "table" and value or { value }
    if key == "set-cookie" then
      if #values == 1 then
        if result[key] == nil then result[key] = values[1]
        elseif type(result[key]) == "table" then table.insert(result[key], values[1])
        else result[key] = { result[key], values[1] } end
      else
        result[key] = values
      end
    elseif result[key] == nil then
      result[key] = table.concat(values, ", ")
    else
      result[key] = result[key] .. ", " .. table.concat(values, ", ")
    end
  end
  return result
end

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
  entry.validation_error = validate(spec)
  entry.max_bytes = spec.max_bytes == nil and DEFAULT_MAX_BYTES or spec.max_bytes
  table.insert(remuda.http.calls, spec)
  table.insert(remuda.http.pending, entry)
  if remuda.http.holds[entry.key] then entry.held = true end
  return { cancel = function()
    if not entry.completed then entry.cancelled = true end
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
    if not entry.completed then
      if entry.cancelled then
        entry.completed = true
        entry.callback({ error = "request cancelled" })
      elseif entry.held then
        -- The transport result is supplied by release().
      elseif entry.validation_error then
        entry.completed = true
        entry.callback({ error = entry.validation_error })
      elseif entry.result then
        if not entry.result.error and type(entry.result.body) == "string"
          and #entry.result.body > entry.max_bytes then
          entry.result = { error = "response exceeds max_bytes" }
        elseif not entry.result.error then
          entry.result.headers = normalize_headers(entry.result.headers)
        end
        entry.completed = true
        entry.callback(entry.result)
      end
    end
  end
end
