-- Executable design reference ONLY; daemon must not load this module.
-- One bounded driver seam for Source:seal; Store persists returned cursor.
local M = {}
local names = { "inbox", "read" }
local function failure(code, field)
  return nil, { code = code, field = field }
end
local function integer(n)
  return type(n) == "number" and n >= 0 and n % 1 == 0
end
local function observed(fs, path)
  local size, err = fs.size(path)
  if size == nil then
    if type(err) == "table" and err.code == "not_found" then return false, 0 end
    return nil, err or { code = "source_unreadable" }
  end
  if not integer(size) then return nil, { code = "source_unreadable" } end
  return true, size
end
local function copy_log(old)
  if not old then return nil end
  local new = {}
  for k, v in pairs(old) do new[k] = v end
  return new
end
local function next_chunk(fs, path, log, remaining)
  local want = math.min(65536, log.offset, remaining)
  local start = log.offset - want
  local chunk, err = fs.read_range(path, start, want)
  if type(chunk) ~= "table" or type(chunk.bytes) ~= "string"
    or #chunk.bytes ~= want then
    return nil, err or { code = "source_unreadable", field = "short_read" }
  end
  local finish
  for i = #chunk.bytes, 1, -1 do
    if chunk.bytes:byte(i) == 10 then finish = start + i; break end
  end
  log.offset = start
  if finish then
    log.done, log.end_offset = true, finish
    log.torn = finish < log.captured_size and 1 or 0
  elseif start == 0 then
    log.done, log.end_offset, log.torn = true, 0, 1
  end
  return want
end
function M.step(previous, budget, config)
  budget = budget or { max_bytes = 65536 }
  if not integer(budget.max_bytes) or budget.max_bytes > 1048576 then return failure("invalid_snapshot", "budget") end
  local cursor = { version = 1, root = config.root, generation = config.generation,
    recipient = config.recipient, logs = {} }
  if previous and (previous.version ~= 1 or previous.root ~= config.root
    or previous.generation ~= config.generation
    or previous.recipient ~= config.recipient) then
    return failure("stale_generation", "cursor_identity")
  end
  -- Always inspect BOTH log metadata, even with zero aggregate read allowance.
  for _, name in ipairs(names) do
    local present, size = observed(config.fs, config.paths[name])
    if present == nil then return failure("source_unreadable", name) end
    local log = copy_log(previous and previous.logs[name])
    if previous and not log then return failure("invalid_snapshot", "cursor") end
    if log then
      if not integer(log.captured_size) or not integer(log.offset)
        or log.offset > log.captured_size then
        return failure("invalid_snapshot", "cursor")
      end
      if log.present and (not present or size < log.captured_size) then
        return failure("stale_generation", name)
      end
    else
      log = { present = present, captured_size = size, offset = size,
        done = size == 0, end_offset = size == 0 and 0 or nil,
        torn = size == 0 and 0 or nil }
    end
    cursor.logs[name] = log
  end
  local used = 0
  for _, name in ipairs(names) do
    local log = cursor.logs[name]
    while not log.done and used < budget.max_bytes do
      local n, err = next_chunk(config.fs, config.paths[name], log, budget.max_bytes - used)
      if not n then return nil, err end
      used = used + n
    end
  end
  return { cursor = cursor, bytes_read = used,
    partial = not (cursor.logs.inbox.done and cursor.logs.read.done) }
end
return M
