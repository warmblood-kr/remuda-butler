-- A quiet window after observed PTY bytes is a heuristic, not proof that a TUI
-- has redrawn. Bytes may have been buffered before the request or unrelated.
local M, states = {}, {}
local MIN_WAIT_MS, QUIET_MS, TIMEOUT_MS = 300, 200, 5000
local function sample(session, expected)
  if type(remuda.clock) ~= 'function' or type(remuda.ls) ~= 'function'
      or type(remuda._session_pty_output_sequence) ~= 'function' then
    return nil, 'refresh_observation_unavailable'
  end
  local ok, now = pcall(remuda.clock)
  local listed, rows = pcall(remuda.ls)
  if not ok or type(now) ~= 'number' or now ~= now or now == math.huge
      or not listed or type(rows) ~= 'table' then return nil, 'refresh_observation_unavailable' end
  local found
  for _, row in ipairs(rows) do
    if row.name == session and row.alive then found = row; break end
  end
  if not found then return nil, 'session_unavailable' end
  if found.instance_id ~= expected then return nil, 'session_changed' end
  local got, seq = pcall(remuda._session_pty_output_sequence, session, expected)
  if not got or type(seq) ~= 'string' or not seq:match('^%d+$') then
    return nil, 'refresh_observation_unavailable'
  end
  return {now=now, seq=seq}
end
function M.finish(session, attempt)
  local state = states[session]
  if state and state.attempt == attempt then states[session] = nil end
end
function M.step(session, attempt, instance)
  local state = states[session]
  if state and state.attempt ~= attempt then states[session], state = nil, nil end
  if state and state.failed then return 'failed', state.failed end
  local point, why = sample(session, instance)
  if not point then if state then state.failed = why end; return 'failed', why end
  if not state then
    if type(remuda._session_refresh) ~= 'function' then return 'failed', 'refresh_unsupported' end
    state = {attempt=attempt, instance=instance, start=point.now, seq=point.seq}
    states[session] = state
    local called, result = pcall(remuda._session_refresh, session, instance)
    if not called or result ~= true then state.failed='refresh_request_failed'; return 'failed', state.failed end
    return 'pending'
  end
  if state.instance ~= instance or point.now < state.start then why='session_changed'
  elseif point.now - state.start >= TIMEOUT_MS then why='refresh_unconfirmed'
  else
    if point.seq ~= state.seq then state.seq, state.last_output = point.seq, point.now end
    if not state.last_output or point.now - state.start < MIN_WAIT_MS
        or point.now - state.last_output < QUIET_MS then return 'pending' end
    if type(remuda.capture) ~= 'function' then why='refresh_capture_unavailable'
    else
      local captured, screen = pcall(remuda.capture, session)
      if not captured or type(screen) ~= 'string' then why='refresh_capture_unavailable'
      else
        local after, sample_why = sample(session, instance)
        if not after then why=sample_why
        elseif after.seq ~= state.seq then
          state.seq, state.last_output = after.seq, after.now
          return 'pending'
        else return 'ready', 'output_quiet_heuristic' end
      end
    end
  end
  state.failed=why
  return 'failed', why
end
remuda._butler_owner_refresh = M
return M
