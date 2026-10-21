-- Node-local, bounded observations. Never accept payloads or raw exception text.
-- This is independent of mail storage, audit policy and agent lifecycle state.
local M = {}
local CAPACITY, PAGE_SIZE = 200, 12
local subsystems = { mail = true, matrix = true, notice = true, control = true }
local levels = { error = 'error', delivered = 'info', filtered = 'info', deferred = 'warn',
  retry = 'warn', converted = 'info', routed = 'info', stopped = 'warn', submitted = 'info', observed = 'info' }
local reasons = {}
for word in ('storage_prepare body_write envelope_write inbox_append envelope_read read_state_write '
  .. 'conversion_failed conversion_ok routing_failed routing_accepted delivery_failed delivery_ok '
  .. 'delivery_deferred filter_policy retry_scheduled prompt_busy prompt_policy heuristic_unknown_choice '
  .. 'heuristic_dialog heuristic_completion capture_unavailable session_unavailable session_replaced detection_unavailable write_returned '
  .. 'room_mention_denied_stale room_mention_denied_no_state room_mention_denied_power room_mention_denied_malformed room_mention_denied_unusable'):gmatch('%S+') do
  reasons[word] = true
end
local state = remuda._butler_diagnostics_state or {
  rows = {}, start = 1, count = 0, dropped = 0, sequence = 0,
  salt = tostring({}) .. tostring(os.time()),
}
remuda._butler_diagnostics_state = state
remuda._butler_diagnostics = M
local page, opened, filters = state.page or 1, state.opened or false, state.filters or {}

-- A process-local opaque grouping token, not a security/anonymization primitive.
-- Raw identifiers never enter the ring or a lookup table; work is bounded too.
local function token(value, sequence)
  if type(value) ~= 'string' or #value == 0 or #value > 256 then return 'event-' .. sequence end
  local a, b = 5381, 52711
  local input = state.salt .. value
  for i = 1, #input do
    local byte = input:byte(i)
    a = (a * 33 + byte) % 4294967296
    b = (b * 65599 + byte) % 4294967296
  end
  return string.format('c-%08x%08x', a, b)
end
function M.record(subsystem, outcome, reason, correlation)
  if not subsystems[subsystem] or not levels[outcome] or not reasons[reason] then return false end
  state.sequence = state.sequence + 1
  local row = { time = os.date('!%Y-%m-%dT%H:%M:%SZ'), severity = levels[outcome],
    subsystem = subsystem, correlation = token(correlation, state.sequence), outcome = outcome, reason = reason }
  local index
  if state.count < CAPACITY then
    index = ((state.start + state.count - 1) % CAPACITY) + 1
    state.count = state.count + 1
  else
    index = state.start
    state.start = state.start % CAPACITY + 1
    state.dropped = state.dropped + 1
  end
  state.rows[index] = row
  -- Presentation failure cannot affect control flow or recursively record errors.
  if opened then pcall(M.refresh) end
  return true
end
function M.snapshot(selection)
  selection = selection or {}
  local events = {}
  for i = 1, state.count do
    local source = state.rows[((state.start + i - 2) % CAPACITY) + 1]
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    if (not selection.subsystem or copy.subsystem == selection.subsystem)
      and (not selection.severity or copy.severity == selection.severity) then
      events[#events + 1] = copy
    end
  end
  return { events = events, capacity = CAPACITY, dropped = state.dropped,
    scope = 'node-local', node = 'local', retention = 'memory', total = state.count }
end
function M.valid_filters(selection)
  return (not selection.subsystem or subsystems[selection.subsystem] == true)
    and (not selection.severity or selection.severity == 'info' or selection.severity == 'warn'
      or selection.severity == 'error')
end
local function line(row)
  return string.format('%s %-5s %-7s %-9s %s %s', row.time, row.severity,
    row.subsystem, row.outcome, row.reason, row.correlation)
end
local function heading(snapshot)
  return 'Lua diagnostics | local node | memory | ' .. #snapshot.events .. '/' .. CAPACITY
    .. ' retained | ' .. snapshot.dropped .. ' evicted'
end
function M.format(snapshot, requested_page)
  snapshot = snapshot or M.snapshot(filters)
  local pages = math.max(1, math.ceil(#snapshot.events / PAGE_SIZE))
  local selected = math.max(1, math.min(pages, math.floor(tonumber(requested_page) or page)))
  local lines = { heading(snapshot), 'TIME (UTC)           LEVEL SUBSYSTEM OUTCOME   REASON / CORRELATION' }
  local newest = #snapshot.events - (selected - 1) * PAGE_SIZE
  for i = newest, math.max(1, newest - PAGE_SIZE + 1), -1 do lines[#lines + 1] = line(snapshot.events[i]) end
  if #snapshot.events == 0 then lines[#lines + 1] = 'No retained observations; health is unknown.' end
  lines[#lines + 1] = 'Read-only | local node | page ' .. selected .. '/' .. pages .. ' (newest first)'
  lines[#lines + 1] = 'Heuristic control stop is not agent state. Restart clears history.'
  return table.concat(lines, '\n')
end
function M.format_all(snapshot)
  snapshot = snapshot or M.snapshot()
  local lines = { heading(snapshot), 'TIME (UTC)           LEVEL SUBSYSTEM OUTCOME   REASON / CORRELATION' }
  for _, row in ipairs(snapshot.events) do lines[#lines + 1] = line(row) end
  if #snapshot.events == 0 then lines[#lines + 1] = 'No retained observations; health is unknown.' end
  lines[#lines + 1] = 'Read-only | heuristic control stop is not agent state.'
  return table.concat(lines, '\n')
end
function M.refresh()
  if opened then remuda.buffer.new('*diagnostics*'):set(M.format(nil, page)) end
end
function M.show(requested_page, selection)
  if type(remuda.buffer) ~= 'table' or type(remuda.window) ~= 'table' then
    return nil, 'Diagnostics preview unavailable; use remuda butler diagnostics-list.'
  end
  page = math.max(1, math.floor(tonumber(requested_page) or 1))
  filters = { subsystem = selection and selection.subsystem, severity = selection and selection.severity }
  opened = true
  state.page, state.opened, state.filters = page, opened, filters
  M.refresh()
  remuda.window.current():show(remuda.buffer.new('*diagnostics*'))
  return true
end
local options = {
  { long = 'page', value = 'N', help = 'Twelve-event preview page, newest first' },
  { long = 'subsystem', value = 'SUBSYSTEM', help = 'mail, matrix, notice or control' },
  { long = 'severity', value = 'LEVEL', help = 'info, warn or error' },
}
local list_options = { options[2], options[3], { long = 'json', help = 'Structured bounded snapshot' } }
local spec = { name = 'remuda butler', verbs = {
  diagnostics = { about = 'Show read-only local Lua diagnostics', options = options,
    next = 'remuda butler diagnostics-list' },
  ['diagnostics-list'] = { about = 'Read local Lua diagnostics', options = list_options,
    next = 'remuda butler diagnostics' },
} }
local usage = 'Usage: remuda butler diagnostics [--page N] [--subsystem mail|matrix|notice|control] [--severity info|warn|error]\n'
  .. '       remuda butler diagnostics-list [--json] [--subsystem mail|matrix|notice|control] [--severity info|warn|error]'
function M.command(args)
  local values = {}
  if type(remuda.cli) == 'table' and type(remuda.cli.parse) == 'function' then
    local report = remuda.cli.parse(spec, args)
    if report.kind == 'help' then return report.text end
    if not report.ok then return nil, usage end
    values = report.values
  else
    -- Compatibility for cores predating the declarative parser.
    local i = 2
    while i <= #args do
      local flag = args[i]
      if flag == '--help' and #args == 2 then return usage end
      if flag == '--json' and args[1] == 'diagnostics-list' and not values.json then
        values.json, i = true, i + 1
      elseif (flag == '--subsystem' or flag == '--severity'
          or (flag == '--page' and args[1] == 'diagnostics')) and args[i + 1] then
        local key = flag:sub(3)
        if values[key] then return nil, usage end
        values[key], i = args[i + 1], i + 2
      else return nil, usage end
    end
  end
  if not M.valid_filters(values) then return nil, usage end
  local requested = values.page and tonumber(values.page) or 1
  if values.page and (not tostring(values.page):match('^%d+$') or not requested
      or requested < 1 or requested > math.ceil(CAPACITY / PAGE_SIZE)) then return nil, usage end
  local selection = { subsystem = values.subsystem, severity = values.severity }
  if args[1] == 'diagnostics-list' then
    local snapshot = M.snapshot(selection)
    if values.json then
      if type(remuda.json) ~= 'table' or type(remuda.json.encode) ~= 'function'
          or type(remuda.json.array) ~= 'function' then
        return nil, 'JSON unavailable on this core; use remuda butler diagnostics-list.'
      end
      -- Empty arrays need the core's explicit JSON array marker.
      snapshot.events = remuda.json.array(snapshot.events)
      return remuda.json.encode(snapshot)
    end
    return M.format_all(snapshot)
  end
  local ok, why = M.show(requested, selection)
  if not ok then return nil, why end
  return 'Showing *diagnostics* (local node, memory-only, read-only).'
end
if opened then pcall(M.refresh) end
return M
