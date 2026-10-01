-- Pure helpers for building a Butler quota report.
local quota = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function rounded(value)
  return math.floor(value + 0.5)
end

function quota.claude_account(auth)
  if type(auth) ~= "table" then return { mode = "unknown" } end
  if auth.loggedIn == false then return { mode = "not_logged_in" } end
  if auth.loggedIn ~= true then return { mode = "unknown" } end
  if auth.authMethod == "claude.ai" then
    return {
      mode = "subscription",
      plan = auth.subscriptionType,
      email = auth.email,
    }
  end
  if type(auth.authMethod) == "string"
      and auth.authMethod:lower():match("api[_ %-]?key") then
    return { mode = "api_key" }
  end
  return { mode = "unknown" }
end

function quota.codex_account(stdout)
  if type(stdout) ~= "string" then return { mode = "unknown" } end
  if stdout:find("Logged in using ChatGPT", 1, true) then
    return { mode = "subscription" }
  end
  if stdout:find("Logged in using an API key", 1, true) then
    return { mode = "api_key" }
  end
  if stdout:find("Not logged in", 1, true) then
    return { mode = "not_logged_in" }
  end
  return { mode = "unknown" }
end

local function rate_limit_part(name, window)
  if type(window) ~= "table"
      or not finite_number(window.used_percentage)
      or not finite_number(window.resets_at) then
    return nil
  end
  return name .. "=" .. tostring(rounded(window.used_percentage))
    .. "@" .. tostring(rounded(window.resets_at))
end

function quota.rate_limits_line(snapshot, now)
  if type(snapshot) ~= "table" or type(snapshot.rate_limits) ~= "table"
      or not finite_number(now) then
    return nil
  end
  local limits = snapshot.rate_limits
  local parts = {}
  local five_hour = rate_limit_part("five_hour", limits.five_hour)
  local seven_day = rate_limit_part("seven_day", limits.seven_day)
  if five_hour then parts[#parts + 1] = five_hour end
  if seven_day then parts[#parts + 1] = seven_day end
  if #parts == 0 then return nil end
  return "RL:" .. tostring(rounded(now)) .. " " .. table.concat(parts, " ")
end

local function parse_limit_part(part)
  local key, used, resets = part:match("^(five_hour)=(%d+)@(%d+)$")
  if not key then key, used, resets = part:match("^(seven_day)=(%d+)@(%d+)$") end
  if not key then return nil end
  used, resets = tonumber(used), tonumber(resets)
  if not finite_number(used) or not finite_number(resets) then return nil end
  return {
    key = key,
    limit = {
      name = key == "five_hour" and "5-hour limit" or "Weekly limit",
      used = used,
      resets_at = resets,
    },
  }
end

function quota.parse_rate_limits_line(line)
  if type(line) ~= "string" then return nil end
  local at, rest = line:match("^RL:(%d+) (.+)$")
  if not at or rest:find("  ", 1, true) then return nil end
  at = tonumber(at)
  if not finite_number(at) then return nil end

  local first, second = rest:match("^([^ ]+) ([^ ]+)$")
  if not first then first = rest:match("^([^ ]+)$") end
  if not first then return nil end
  local parsed_first = parse_limit_part(first)
  if not parsed_first then return nil end
  local limits = { parsed_first.limit }
  if second then
    local parsed_second = parse_limit_part(second)
    if not parsed_second or parsed_second.key == parsed_first.key then return nil end
    limits[#limits + 1] = parsed_second.limit
  end
  return { at = at, limits = limits }
end

function quota.usage()
  return "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report"
end

if type(remuda) == "table" then
  remuda._butler_quota = quota
end

return quota
