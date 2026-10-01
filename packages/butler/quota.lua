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

local months = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

local function days_from_civil(year, month, day)
  year = year - (month <= 2 and 1 or 0)
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local month_prime = month + (month > 2 and -3 or 9)
  local day_of_year = math.floor((153 * month_prime + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

local function civil_year_from_days(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local day_of_era = z - era * 146097
  local year_of_era = math.floor((day_of_era - math.floor(day_of_era / 1460)
    + math.floor(day_of_era / 36524) - math.floor(day_of_era / 146096)) / 365)
  local year = year_of_era + era * 400
  local day_of_year = day_of_era - (365 * year_of_era
    + math.floor(year_of_era / 4) - math.floor(year_of_era / 100))
  local month_prime = math.floor((5 * day_of_year + 2) / 153)
  local month = month_prime + (month_prime < 10 and 3 or -9)
  year = year + (month <= 2 and 1 or 0)
  return year
end

local function leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function valid_day(year, month, day)
  local last = ({ 31, leap_year(year) and 29 or 28, 31, 30, 31, 30,
    31, 31, 30, 31, 30, 31 })[month]
  return last ~= nil and day >= 1 and day <= last
end

local function reset_epoch(reset_text, utc_offset_seconds, now)
  local hour_text, minute_text, meridiem, day_text, month_text = reset_text:match(
    "^resets (%d%d?):(%d%d) ([AP]M) on (%d%d?) (%a%a%a)$")
  local month = months[month_text]
  local hour, minute, day = tonumber(hour_text), tonumber(minute_text), tonumber(day_text)
  if not month or not hour or hour < 1 or hour > 12 or not minute or minute > 59
      or not day or not finite_number(utc_offset_seconds) or not finite_number(now) then
    return nil
  end
  if meridiem == "AM" then
    if hour == 12 then hour = 0 end
  elseif hour ~= 12 then
    hour = hour + 12
  end

  local year = civil_year_from_days(math.floor(now / 86400))
  if not valid_day(year, month, day) then return nil end
  local epoch = days_from_civil(year, month, day) * 86400
    + hour * 3600 + minute * 60 - utc_offset_seconds
  if epoch < now - 86400 then
    year = year + 1
    if not valid_day(year, month, day) then return nil end
    epoch = days_from_civil(year, month, day) * 86400
      + hour * 3600 + minute * 60 - utc_offset_seconds
  end
  return epoch
end

local function reset_phrase(line)
  if type(line) ~= "string" then return nil end
  return line:match("%((resets.-)%)")
end

local function parse_reset(line, next_line, utc_offset_seconds, now)
  local phrase = reset_phrase(line) or reset_phrase(next_line)
  if not phrase then return { resets_text = "unknown" } end
  local text = phrase:match("^resets%s+(.+)$") or phrase
  local epoch = reset_epoch(phrase, utc_offset_seconds, now)
  if epoch then return { resets_at = epoch } end
  return { resets_text = text }
end

function quota.parse_codex_status(screen, utc_offset_seconds, now)
  if type(screen) ~= "string" then return nil end
  local lines = {}
  for line in (screen .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end

  local plan, limits = nil, {}
  for i, line in ipairs(lines) do
    if plan == nil then
      local account = line:match("^%s*Account:%s*(.-)%s*$")
      if account and account ~= "" then plan = account end
    end
    local name, left = line:match("^%s*(.-):%s+%[.-%]%s+(%d+)%% left%s*.*$")
    if name then
      name = name:gsub("^%s+", ""):gsub("%s+$", "")
      if #name <= 40 and name:match("^[%w][%w %-]*$") then
        local limit = { name = name, used = 100 - tonumber(left) }
        local reset = parse_reset(line, lines[i + 1], utc_offset_seconds, now)
        for key, value in pairs(reset) do limit[key] = value end
        limits[#limits + 1] = limit
      end
    end
  end
  if #limits == 0 then return nil end
  return { plan = plan, limits = limits }
end

local function utc_text(epoch)
  return os.date("!%Y-%m-%d %H:%MZ", epoch)
end

local function clean(text)
  return (tostring(text):gsub("%c", " ")):sub(1, 80)
end

local function format_percent(value)
  if finite_number(value) then return tostring(rounded(value)) end
  return "0"
end

local function agent_lines(name, agent, report_at, near_limits)
  agent = type(agent) == "table" and agent or {}
  local lines = {}
  if agent.mode == "subscription" then
    if name == "claude" then
      lines[1] = "claude: subscription (" .. clean(agent.plan or "unknown")
        .. "), " .. clean(agent.email or "unknown")
    elseif agent.plan ~= nil and agent.plan ~= "" then
      lines[1] = "codex: subscription (" .. clean(agent.plan)
        .. "), account: not exposed by codex"
    else
      lines[1] = "codex: subscription, account: not exposed by codex"
    end
    local limits = type(agent.limits) == "table" and agent.limits or {}
    if #limits == 0 then
      lines[#lines + 1] = "  quota: unknown (" .. tostring(agent.unknown_reason or "unknown") .. ")"
    else
      for _, limit in ipairs(limits) do
        local used = format_percent(limit.used)
        local reset
        if finite_number(limit.resets_at) then
          reset = "resets " .. utc_text(limit.resets_at)
        else
          reset = "resets " .. clean(limit.resets_text or "unknown") .. " (local time)"
        end
        lines[#lines + 1] = "  " .. clean(limit.name or "unknown limit") .. ": "
          .. used .. "% used, " .. reset
        if finite_number(limit.used) and limit.used >= 80 then
          near_limits[#near_limits + 1] = name .. " " .. clean(limit.name or "unknown limit")
            .. " (" .. used .. "%)"
        end
      end
      if finite_number(agent.read_at) and finite_number(report_at)
          and report_at - agent.read_at > 600 then
        lines[#lines + 1] = "  as of " .. utc_text(agent.read_at)
      end
    end
  elseif agent.mode == "api_key" then
    lines[1] = name .. ": API key (no subscription, no quota to report)"
  elseif agent.mode == "not_logged_in" then
    lines[1] = name .. ": not logged in"
  elseif agent.mode == "not_installed" then
    lines[1] = name .. ": not installed"
  else
    lines[1] = name .. ": unknown (unrecognised status output)"
  end
  return lines
end

function quota.render(report)
  report = type(report) == "table" and report or {}
  local at = finite_number(report.at) and report.at or 0
  local near_limits = {}
  local lines = { "Agent accounts, " .. utc_text(at) }
  for _, name in ipairs({ "claude", "codex" }) do
    local block = agent_lines(name, report[name], at, near_limits)
    for _, line in ipairs(block) do lines[#lines + 1] = line end
  end

  if #near_limits > 0 then
    lines[#lines + 1] = "Near limit: " .. table.concat(near_limits, ", ") .. "."
  end
  local not_logged_in = {}
  for _, name in ipairs({ "claude", "codex" }) do
    local agent = report[name]
    if type(agent) == "table" and agent.mode == "not_logged_in" then
      not_logged_in[#not_logged_in + 1] = name
    end
  end
  if #not_logged_in > 0 then
    lines[#lines + 1] = "Not logged in: " .. table.concat(not_logged_in, ", ") .. "."
  end
  if #near_limits > 0 or #not_logged_in > 0 then
    lines[1] = "⚠️ " .. lines[1]
  end
  return table.concat(lines, "\n")
end

function quota.terminal(report, outcome)
  local lines = { quota.render(report) }
  outcome = type(outcome) == "table" and outcome or nil
  if outcome and outcome.failed ~= nil then
    lines[#lines + 1] = "Could not post to Matrix: " .. tostring(outcome.failed)
    lines[#lines + 1] = "Next: remuda butler doctor"
    return table.concat(lines, "\n")
  end

  if outcome and outcome.sent == true then
    lines[#lines + 1] = "Sent to the Matrix home room."
  end
  local claude = type(report) == "table" and report.claude or nil
  local codex = type(report) == "table" and report.codex or nil
  if type(claude) == "table" and claude.mode == "not_logged_in" then
    lines[#lines + 1] = "Next: log in with `claude auth login`, then run `remuda butler quota` again."
  elseif type(codex) == "table" and codex.mode == "not_logged_in" then
    lines[#lines + 1] = "Next: log in with `codex login`, then run `remuda butler quota` again."
  elseif type(codex) == "table" and codex.unknown_reason == "no idle codex session to ask" then
    lines[#lines + 1] = "Next: start a codex member with `remuda butler launch codex` (or wait until one is idle), then run `remuda butler quota` again."
  elseif outcome and outcome.sent == true then
    lines[#lines + 1] = "Next: run `remuda butler quota` any time for a fresh reading."
  else
    lines[#lines + 1] = "Next: run `remuda butler quota --report` to send this to Matrix."
  end
  return table.concat(lines, "\n")
end

function quota.usage()
  return "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report"
end

if type(remuda) == "table" then
  remuda._butler_quota = quota

  function quota.accounts()
    local probes = remuda._butler_doctor.probe()
    local function account_for(name, parser)
      local probe = type(probes) == "table" and probes[name] or nil
      if type(probe) == "table" and probe.installed == false then
        return { mode = "not_installed" }
      end
      local stdout = type(probe) == "table" and probe.stdout or nil
      if name == "claude" then
        local decoded, auth = pcall(remuda.json.decode, stdout)
        if not decoded then return { mode = "unknown" } end
        return parser(auth)
      end
      return parser(stdout)
    end
    return {
      claude = account_for("claude", quota.claude_account),
      codex = account_for("codex", quota.codex_account),
    }
  end

  function quota.claude_reading()
    local bus = remuda._butler_bus or {}
    local agents = type(bus.agents) == "table" and bus.agents or {}
    local newest
    for _, agent in pairs(agents) do
      if type(agent) == "table" and agent.kind == "claude" then
        local telemetry = remuda._butler_telemetry_for(agent)
        local reading = type(telemetry) == "table" and telemetry.rate_limits or nil
        if type(reading) == "table" and finite_number(reading.at)
            and (not newest or reading.at > newest.at) then
          newest = reading
        end
      end
    end
    return newest
  end

  function quota.codex_read(done)
    local bus = remuda._butler_bus or {}
    local agents = type(bus.agents) == "table" and bus.agents or {}
    local selected, alias
    for name, agent in pairs(agents) do
      if name ~= "butler" and type(agent) == "table" and agent.kind == "codex" then
        local session = agent.session_name or name
        if remuda.butler.is_idle(name) == true
            and remuda._butler_notify_policy(session) == true then
          selected, alias = agent, name
          break
        end
      end
    end
    if not selected then
      done(nil, "no idle codex session to ask")
      return
    end

    local session = selected.session_name or alias
    local utc_offset_seconds = os.time() - os.time(os.date("!*t"))
    local typed = pcall(remuda.type_text, session, "/status", 0.1)
    if not typed then
      done(nil, "codex did not show its limits in time")
      return
    end

    local poll, ticks, finished = nil, 0, false
    local function finish(result, reason)
      if finished then return end
      finished = true
      if poll then remuda.cancel(poll) end
      done(result, reason)
    end
    local scheduled, handle = pcall(remuda.schedule, { every = 0.5, run = function()
      ticks = ticks + 1
      local captured, screen = pcall(remuda.capture, session)
      if captured and type(screen) == "string" then
        local parsed = quota.parse_codex_status(screen, utc_offset_seconds, os.time())
        if parsed and #parsed.limits > 0 then
          finish(parsed, nil)
          return
        end
      end
      if ticks >= 20 then
        finish(nil, "codex did not show its limits in time")
      end
    end })
    if not scheduled then
      finish(nil, "codex did not show its limits in time")
    else
      poll = handle
    end
  end

  function quota.collect(done)
    local report = { at = os.time() }
    local accounts = quota.accounts()
    report.claude = accounts.claude
    report.codex = accounts.codex

    if report.claude.mode == "subscription" then
      local reading = quota.claude_reading()
      if reading then
        report.claude.limits = reading.limits
        report.claude.read_at = reading.at
      else
        report.claude.unknown_reason = "no reading yet; it appears after a claude session's first reply"
      end
    end

    if report.codex.mode == "subscription" then
      quota.codex_read(function(reading, reason)
        if reading then
          report.codex.plan = reading.plan
          report.codex.limits = reading.limits
        else
          report.codex.unknown_reason = reason
        end
        done(report)
      end)
    else
      done(report)
    end
  end
end

return quota
