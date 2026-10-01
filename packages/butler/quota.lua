-- Pure helpers for building a Butler quota report.
local quota = {}

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function plain_word(value)
  return type(value) == "string" and #value <= 40
    and value:match("^[%w][%w %-]*$") ~= nil
end

local function email_address(value)
  return type(value) == "string" and #value <= 80
    and value:match("^[%w%._%+%-]+@[%w][%w%.%-]*$") ~= nil
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
      plan = plain_word(auth.subscriptionType) and auth.subscriptionType or nil,
      email = email_address(auth.email) and auth.email or nil,
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
  return line:match("%((resets %d%d?:%d%d [AP]M on %d%d? %a%a%a)%)")
end

local function parse_reset(line, next_line, utc_offset_seconds, now)
  local phrase = reset_phrase(line) or reset_phrase(next_line)
  if not phrase then return {} end
  local epoch = reset_epoch(phrase, utc_offset_seconds, now)
  if epoch then return { resets_at = epoch } end
  return {}
end

function quota.parse_codex_status(screen, utc_offset_seconds, now)
  if type(screen) ~= "string" then return nil end
  local lines = {}
  for line in (screen .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end

  local status_start = 1
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$") or ""
    if trimmed:sub(1, 3) == "›" or trimmed:sub(1, 1) == ">"
        or trimmed:sub(1, 3) == "❯" then
      local glyph_length = (trimmed:sub(1, 3) == "›" or trimmed:sub(1, 3) == "❯") and 3 or 1
      trimmed = trimmed:sub(glyph_length + 1)
      trimmed = trimmed:match("^%s*(.-)%s*$") or ""
    end
    if trimmed == "/status" then status_start = i + 1 end
  end

  local last_account
  for i = status_start, #lines do
    if lines[i]:match("^%s*Account:") then last_account = i end
  end
  local plan
  if last_account then
    local account = lines[last_account]:match("^%s*Account:%s*(.-)%s*$")
    if plain_word(account) then plan = account end
  end

  local occurrences, last_occurrence = {}, {}
  for i = status_start, #lines do
    local line = lines[i]
    local name, left = line:match("^%s*(.-):%s+%[.-%]%s+(%d+)%% left%s*.*$")
    if name and (not last_account or i > last_account) then
      name = name:gsub("^%s+", ""):gsub("%s+$", "")
      if plain_word(name) then
        local remaining = tonumber(left)
        local used = remaining >= 0 and remaining <= 100 and 100 - remaining or nil
        local limit = { name = name, used = used }
        local reset = parse_reset(line, lines[i + 1], utc_offset_seconds, now)
        for key, value in pairs(reset) do limit[key] = value end
        occurrences[#occurrences + 1] = limit
        last_occurrence[name] = #occurrences
      end
    end
  end
  local limits = {}
  for i, limit in ipairs(occurrences) do
    if last_occurrence[limit.name] == i then limits[#limits + 1] = limit end
  end
  if #limits == 0 then return nil end
  return { plan = plan, limits = limits }
end

function quota.parse_codex_rate_limits(result)
  local by_id = type(result) == "table" and result.rateLimitsByLimitId or nil
  if type(by_id) ~= "table" then return nil end

  local codex = by_id.codex
  local plan = type(codex) == "table" and codex.planType or nil
  if not plain_word(plan) then plan = nil end

  local function weekly_limit(entry, name)
    if type(entry) ~= "table" or type(entry.primary) ~= "table" then return nil end
    local primary = entry.primary
    if primary.windowDurationMins ~= 10080 or not finite_number(primary.resetsAt)
        or primary.resetsAt <= 0 or primary.resetsAt >= 4000000000 then
      return nil
    end
    local used = finite_number(primary.usedPercent)
        and primary.usedPercent >= 0 and primary.usedPercent <= 100
        and primary.usedPercent or nil
    return { name = name, used = used, resets_at = primary.resetsAt }
  end

  local limits = {}
  local weekly = weekly_limit(codex, "Weekly limit")
  if weekly then limits[#limits + 1] = weekly end
  local reserve = by_id.base_model_inference
  if type(reserve) == "table" and reserve.limitName == "gpt-reserve" then
    local reserve_weekly = weekly_limit(reserve, "Luna Reserve Weekly limit")
    if reserve_weekly then limits[#limits + 1] = reserve_weekly end
  end
  if #limits == 0 then return nil end
  return { plan = plan, limits = limits }
end

local function utc_text(epoch)
  return os.date("!%Y-%m-%d %H:%MZ", epoch)
end

function quota.safe_text(value)
  return (tostring(value):gsub("[^\032-\126]", "?")):sub(1, 200)
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
      local plan = plain_word(agent.plan) and agent.plan or nil
      local email = email_address(agent.email) and agent.email or nil
      lines[1] = "claude: subscription"
      if plan then lines[1] = lines[1] .. " (" .. plan .. ")" end
      lines[1] = lines[1] .. ", " .. (email or "account unknown")
    elseif plain_word(agent.plan) then
      lines[1] = "codex: subscription (" .. agent.plan
        .. "), account: not exposed by codex"
    else
      lines[1] = "codex: subscription, account: not exposed by codex"
    end
    local limits = type(agent.limits) == "table" and agent.limits or {}
    if #limits == 0 then
      local reasons = {
        ["no reading yet; it appears after a claude session's first reply"] = true,
        ["codex did not show its limits in time"] = true,
        ["codex limits need core nightly d47a845 or newer"] = true,
      }
      local reason = reasons[agent.unknown_reason] and agent.unknown_reason or "could not be read"
      lines[#lines + 1] = "  quota: unknown (" .. reason .. ")"
    else
      for _, limit in ipairs(limits) do
        local limit_name = type(limit) == "table" and limit.name or nil
        limit_name = plain_word(limit_name) and limit_name or "unknown"
        local used_value = type(limit) == "table" and limit.used or nil
        if not finite_number(used_value) then
          lines[#lines + 1] = "  " .. limit_name .. ": unknown"
        else
          local used = format_percent(used_value)
          local reset = finite_number(limit.resets_at)
            and ("resets " .. utc_text(limit.resets_at)) or "resets unknown"
          lines[#lines + 1] = "  " .. limit_name .. ": " .. used .. "% used, " .. reset
          if used_value >= 80 then
            near_limits[#near_limits + 1] = name .. " " .. limit_name .. " (" .. used .. "%)"
          end
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
    local command = name == "claude" and "claude auth status" or "codex login status"
    lines[1] = name .. ": unknown (could not understand what `" .. command .. "` answered)"
  end
  return lines
end

function quota.render(report)
  report = type(report) == "table" and report or {}
  local at = finite_number(report.at) and report.at or 0
  local near_limits = {}
  local header = report.reused == true and "Agent accounts, as of " .. utc_text(at)
    or "Agent accounts, " .. utc_text(at)
  local lines = { header }
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
  if outcome and outcome.sent == true then
    lines[#lines + 1] = "Sent to the Matrix home room."
  end
  local claude = type(report) == "table" and report.claude or nil
  local codex = type(report) == "table" and report.codex or nil
  local next_line
  if outcome and outcome.failed ~= nil then
    lines[#lines + 1] = "Could not post to Matrix: " .. quota.safe_text(outcome.failed)
    next_line = "Next: remuda butler matrix setup"
  elseif type(claude) == "table" and claude.mode == "not_logged_in"
      and type(codex) == "table" and codex.mode == "not_logged_in" then
    next_line = "Next: log in with `claude auth login` and `codex login`, then run `remuda butler quota` again."
  elseif type(claude) == "table" and claude.mode == "not_logged_in" then
    next_line = "Next: log in with `claude auth login`, then run `remuda butler quota` again."
  elseif type(codex) == "table" and codex.mode == "not_logged_in" then
    next_line = "Next: log in with `codex login`, then run `remuda butler quota` again."
  elseif type(claude) == "table" and claude.mode == "unknown"
      or type(codex) == "table" and codex.mode == "unknown" then
    local command = type(claude) == "table" and claude.mode == "unknown"
      and "claude auth status" or "codex login status"
    next_line = "Next: run `" .. command .. "` yourself to see what it answers, then `remuda butler doctor`."
  elseif type(codex) == "table" and codex.unknown_reason == "codex limits need core nightly d47a845 or newer" then
    next_line = "Next: update Remuda core to nightly d47a845 or newer, then run `remuda butler quota` again."
  elseif type(codex) == "table" and codex.unknown_reason == "codex did not show its limits in time" then
    next_line = "Next: run `remuda butler quota` again in a minute."
  elseif type(claude) == "table" and claude.mode == "subscription"
      and (type(claude.limits) ~= "table" or #claude.limits == 0) then
    next_line = "Next: let a claude session answer once, then run `remuda butler quota` again."
  elseif outcome and outcome.sent == true then
    next_line = "Next: run `remuda butler quota` any time for a fresh reading."
  else
    next_line = "Next: run `remuda butler quota --report` to send this to Matrix."
  end
  lines[#lines + 1] = next_line
  return table.concat(lines, "\n")
end

function quota.usage()
  return "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report"
end

local USAGE_NEXT = "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix."

function quota.help()
  return "remuda butler quota reports, for claude and codex, how each is logged in, the subscription account and how much of each limit is used.\n"
    .. "With --report it also posts the report to this Butler's Matrix home room.\n"
    .. quota.usage() .. "\n" .. USAGE_NEXT
end

function quota.usage_error(argument)
  local arg = quota.safe_text(argument):sub(1, 40)
  local message = arg:sub(1, 1) == "-" and "unknown option: " or "unexpected argument: "
  return message .. arg .. "\n" .. quota.usage() .. "\n" .. USAGE_NEXT
end

function quota.report_denied()
  return "only the Butler itself or a person at the terminal can send the report to Matrix.\n"
    .. "Next: ask the Butler to run `remuda butler quota --report`, or run `remuda butler quota` to read it here."
end

function quota.unavailable(reason)
  return "quota is unavailable: " .. quota.safe_text(reason)
    .. "\nNext: remuda butler doctor"
end

if type(remuda) == "table" then
  remuda._butler_quota = quota
  local quota_state = remuda._butler_quota_state
  if type(quota_state) ~= "table" then
    quota_state = { report = nil, at = nil, waiting = nil }
    remuda._butler_quota_state = quota_state
  else
    quota_state.report = type(quota_state.report) == "table" and quota_state.report or nil
    quota_state.at = finite_number(quota_state.at) and quota_state.at or nil
    quota_state.waiting = type(quota_state.waiting) == "table" and quota_state.waiting or nil
  end

  local function finish_collect(report)
    local callbacks = quota_state.waiting or {}
    local finished_at = os.time()
    quota_state.report = report
    quota_state.at = finished_at
    quota_state.waiting = nil

    for _, callback in ipairs(callbacks) do pcall(callback, report) end
  end

  local function fail_collect(reason)
    local callbacks = quota_state.waiting or {}
    quota_state.waiting = nil
    quota_state.report = nil
    quota_state.at = nil
    local message = tostring(reason)
    for _, callback in ipairs(callbacks) do pcall(callback, nil, message) end
  end

  function quota.accounts()
    local probes = remuda._butler_doctor.probe()
    local function account_for(name, parser)
      local probe = type(probes) == "table" and probes[name] or nil
      if type(probe) == "table" and probe.installed == false then
        return { mode = "not_installed" }
      end
      local stdout = type(probe) == "table" and probe.stdout or nil
      local stderr = type(probe) == "table" and probe.stderr or nil
      if name == "claude" then
        local decoded, auth = pcall(remuda.json.decode, stdout)
        if not decoded then return { mode = "unknown" } end
        return parser(auth)
      end
      -- codex-cli 0.159.3 prints `codex login status` on stderr.
      return parser(tostring(stdout or "") .. "\n" .. tostring(stderr or ""))
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
    local function unavailable()
      done(nil, "codex did not show its limits in time")
    end
    local function needs_newer_core()
      done(nil, "codex limits need core nightly d47a845 or newer")
    end
    local process = remuda.process
    if type(process) ~= "table" or type(process.run) ~= "function" then
      unavailable()
      return
    end

    -- Four output lines were measured on Codex 0.159.3: initialize result, two notifications, rateLimits reply.
    local input = table.concat({
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"remuda","version":"1.0.0"}}}',
      '{"jsonrpc":"2.0","method":"initialized"}',
      '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}',
    }, "\n") .. "\n"
    local ran, result = pcall(process.run, {
      argv = { "codex", "app-server" },
      stdin = input,
      timeout = 5,
      stdin_hold_until_lines = 4,
    })
    if not ran or type(result) ~= "table" or type(result.stdout) ~= "string" then
      unavailable()
      return
    end
    local decoder = type(remuda.json) == "table" and remuda.json.decode or nil
    if type(decoder) ~= "function" then
      unavailable()
      return
    end

    local output_lines = {}
    for line in (result.stdout .. "\n"):gmatch("([^\n]*)\n") do
      line = line:gsub("\r$", "")
      if line ~= "" then output_lines[#output_lines + 1] = line end
      local decoded, response = pcall(decoder, line)
      if decoded and type(response) == "table" and response.id == 2 then
        local parsed = quota.parse_codex_rate_limits(response.result)
        if parsed then
          done(parsed)
          return
        end
        unavailable()
        return
      end
    end
    if result.timed_out == true or #output_lines < 2 then
      needs_newer_core()
      return
    end
    unavailable()
  end

  function quota.collect(done)
    if quota_state.waiting then
      quota_state.waiting[#quota_state.waiting + 1] = done
      return
    end
    local now = os.time()
    if quota_state.report and quota_state.at and now - quota_state.at >= 0
        and now - quota_state.at < 60 then
      local reused = {}
      for key, value in pairs(quota_state.report) do reused[key] = value end
      reused.reused = true
      done(reused)
      return
    end
    if quota_state.report then
      quota_state.report = nil
      quota_state.at = nil
    end
    quota_state.waiting = { done }
    local ok, err = pcall(function()
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
          local callback_ok, callback_err = pcall(function()
            if reading then
              report.codex.plan = reading.plan
              report.codex.limits = reading.limits
            else
              report.codex.unknown_reason = reason
            end
            finish_collect(report)
          end)
          if not callback_ok then fail_collect(callback_err) end
        end)
      else
        finish_collect(report)
      end
    end)
    if not ok then
      fail_collect(err)
    end
  end
end

return quota
