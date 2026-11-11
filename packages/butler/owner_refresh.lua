-- A short pause lets the TUI redraw after resize; it is not a guarantee that
-- all applications have finished drawing. No PTY-output polling is required.
local M, states = {}, {}
local WAIT_MS, ABANDON_MS = 300, 5000
local function sample(session, expected)
  if type(remuda.clock) ~= 'function' or type(remuda.ls) ~= 'function' then
    return nil, 'refresh_observation_unavailable'
  end
  local ok, now = pcall(remuda.clock)
  local listed, rows = pcall(remuda.ls)
  if not ok or type(now) ~= 'number' or now ~= now or now == math.huge
      or not listed or type(rows) ~= 'table' then return nil, 'refresh_observation_unavailable' end
  for _, row in ipairs(rows) do
    if row.name == session and row.alive then
      if row.instance_id ~= expected then return nil, 'session_changed' end
      return {now=now}
    end
  end
  return nil, 'session_unavailable'
end
function M.finish(session, attempt)
  local state = states[session]
  if state and state.attempt == attempt then states[session] = nil end
end
function M.step(session, attempt, instance)
  local state = states[session]
  if not state and type(remuda._session_refresh) ~= 'function' then
    -- Older cores cannot refresh; retain the old delivery path until upgraded.
    return 'ready', 'refresh_unsupported'
  end
  local point, why = sample(session, instance)
  if not point then return 'failed', why end
  if state and state.attempt ~= attempt then
    if point.now >= state.start and point.now - state.start < ABANDON_MS then
      return 'pending', 'refresh_busy'
    end
    states[session], state = nil, nil
  end
  if not state then
    state = {attempt=attempt, instance=instance, start=point.now}
    states[session] = state
    local called, result = pcall(remuda._session_refresh, session, instance)
    if not called or result ~= true then return 'failed', 'refresh_request_failed' end
    return 'pending'
  end
  if state.instance ~= instance or point.now < state.start then return 'failed', 'session_changed' end
  if point.now - state.start < WAIT_MS then return 'pending' end
  if type(remuda.capture) ~= 'function' then return 'failed', 'refresh_capture_unavailable' end
  local captured, screen = pcall(remuda.capture, session)
  if not captured or type(screen) ~= 'string' then return 'failed', 'refresh_capture_unavailable' end
  local after, sample_why = sample(session, instance)
  if not after then return 'failed', sample_why end
  return 'ready', 'bounded_redraw_wait'
end
remuda._butler_owner_refresh = M
return M
