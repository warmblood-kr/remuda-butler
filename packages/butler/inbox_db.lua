-- Shadow inbox index in the mod's private SQLite database.
--
-- Files stay authoritative in this phase: every write below happens only after
-- the matching file commit, and every failure is reported as degraded while
-- mail continues on the file path. There is no read switch yet.
local config = assert(remuda._butler_inbox_db_config)

local M = {}
local handle
local failure
local stats = { imported = 0, skipped = 0, partial = false, error = nil }

-- One boot imports at most this much per log and in total. A larger file or
-- remaining backlog finishes on a later boot; delivery hooks keep new mail
-- indexed meanwhile.
local MAX_LOG_BYTES = 8 * 1024 * 1024
local MAX_BOOT_BYTES = 32 * 1024 * 1024
local MAX_BOOT_STATEMENTS = 50000
local MAX_BOOT_SECONDS = 2
local HEAD_BYTES = 64

local function report(outcome, reason, correlation)
  local diagnostics = remuda._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "inbox_db", outcome, reason, correlation)
  end
end

-- The recipient file name is a stable hex encoding of the mailbox name; using
-- it as the row key avoids re-encoding or trusting a decoded path component.
local function component(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

-- The native handle answers SQL failures as `nil, reason`, not a raise. A
-- checked call treats both forms as failure, while 0 changes is still success.
local function checked(call, ...)
  local ok, value, why = pcall(call, ...)
  if not ok then return nil, tostring(value) end
  if value == nil then return nil, tostring(why or "database call failed") end
  return value
end

local function opened()
  if failure then return nil, failure end
  if handle then return handle end
  local opener = config.open
  if type(opener) ~= "function" then
    failure = "unavailable: remuda.db.open is missing"
    return nil, failure
  end
  local ok, db, why = pcall(opener, "inbox", { migrations = true })
  if not ok then
    failure = "open: " .. tostring(db)
  elseif db == nil then
    failure = tostring(why or "open: unknown failure")
  else
    handle = db
  end
  if not handle then report("error", "open_failed", nil) end
  return handle, failure
end

-- A failed rollback means the handle cannot be trusted for later writes.
local function dispose(reason)
  if handle then pcall(handle.close, handle) end
  handle = nil
  failure = "degraded: " .. reason
  report("error", "disposed", reason)
end

local function rollback(db)
  local ok, why = checked(db.exec, db, "ROLLBACK")
  if not ok then dispose("rollback: " .. tostring(why)) end
  return ok
end

local function commit(db)
  local ok, why = checked(db.exec, db, "COMMIT")
  if ok then return true end
  rollback(db)
  return nil, "commit: " .. tostring(why)
end

local function transaction(db, work)
  local began, why = checked(db.exec, db, "BEGIN IMMEDIATE")
  if not began then return nil, "begin: " .. tostring(why) end
  local ok, result, extra = pcall(work, db)
  if not ok then
    rollback(db)
    return nil, tostring(result)
  end
  if result == nil then
    rollback(db)
    return nil, tostring(extra or "transaction body failed")
  end
  local done, commit_err = commit(db)
  if not done then return nil, commit_err end
  return result
end

local function execute(db, sql, params)
  return checked(db.exec, db, sql, params)
end

local function insert_delivery(db, recipient, id)
  return execute(db,
    "INSERT OR IGNORE INTO deliveries (recipient, message_id, seq) " ..
      "VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM deliveries WHERE recipient = ?))",
    { recipient, id, recipient })
end

local function insert_read(db, recipient, id)
  return execute(db, "INSERT OR IGNORE INTO reads (recipient, message_id) VALUES (?, ?)",
    { recipient, id })
end

local function id_from_json(line)
  return line:match('"message_id":"([^"]+)"')
end

local function id_from_read(line)
  local id = line:match("^%s*(.-)%s*$"):gsub("\r$", "")
  if id == "" then return nil end
  return id
end

local function missing_file(reason, errno)
  return errno == 2 or tostring(reason):find("No such file", 1, true) ~= nil
    or tostring(reason):find("os error 2", 1, true) ~= nil
end

local function head_hash(file, size)
  file:seek("set", 0)
  local head = file:read(math.min(size, HEAD_BYTES)) or ""
  local hash = 0
  for index = 1, #head do
    hash = (hash * 31 + head:byte(index)) % 4294967296
  end
  return hash
end

local function offset_for(db, recipient, kind)
  local rows, why = checked(db.query, db,
    "SELECT offset, head FROM import_state WHERE recipient = ? AND kind = ?", { recipient, kind })
  if rows == nil then return nil, why end
  if not rows[1] then return 0, nil end
  return tonumber(rows[1].offset) or 0, tonumber(rows[1].head)
end

local function save_offset(db, recipient, kind, offset, head)
  return execute(db,
    "INSERT OR REPLACE INTO import_state (recipient, kind, offset, head) VALUES (?, ?, ?, ?)",
    { recipient, kind, offset, head })
end

local function clear_kind(db, recipient, kind)
  local table_name = kind == "read" and "reads" or "deliveries"
  return execute(db, "DELETE FROM " .. table_name .. " WHERE recipient = ?", { recipient })
end

local function budget_left(budget)
  return budget.bytes < MAX_BOOT_BYTES
    and budget.statements < MAX_BOOT_STATEMENTS
    and budget.clock() - budget.started < MAX_BOOT_SECONDS
end

local function read_chunk(file, offset, size, budget)
  local left = MAX_BOOT_BYTES - budget.bytes
  if left <= 0 then return nil, "budget" end
  local positioned, seek_err = file:seek("set", offset)
  if not positioned then return nil, "seek: " .. tostring(seek_err) end
  local want = math.min(MAX_LOG_BYTES, math.min(size - offset, left))
  if want <= 0 then return "" end
  local chunk = file:read(want)
  if chunk == nil then return nil, "read" end
  return chunk
end

local function import_lines(db, chunk, recipient, parse, insert, budget)
  local consumed = 0
  for line in chunk:gmatch("([^\n]*)\n") do
    consumed = consumed + #line + 1
    local id = parse(line)
    if id then
      local ok, why = insert(db, recipient, id)
      if not ok then return nil, why, consumed end
    else
      stats.skipped = stats.skipped + 1
    end
    budget.statements = budget.statements + 1
    if budget.statements >= MAX_BOOT_STATEMENTS then
      stats.partial = true
      break
    end
  end
  return true, nil, consumed
end

local function import_path(db, path, recipient, kind, parse, insert, budget)
  local file, open_err, open_errno = io.open(path, "rb")
  if not file then
    if missing_file(open_err, open_errno) then return true end
    return nil, "open " .. path .. ": " .. tostring(open_err)
  end
  local size, seek_err = file:seek("end")
  if not size then
    file:close()
    return nil, "seek " .. path .. ": " .. tostring(seek_err)
  end
  local offset, stored_head = offset_for(db, recipient, kind)
  if offset == nil then
    file:close()
    return nil, stored_head
  end
  -- A short log has no stable fingerprint: appending can change its first 64
  -- bytes. Only logs at least HEAD_BYTES long use replacement detection.
  local head = size >= HEAD_BYTES and head_hash(file, size) or 0
  local changed = stored_head ~= nil and stored_head ~= 0 and head ~= 0 and stored_head ~= head
  if offset > size or changed then
    local cleared, clear_err = clear_kind(db, recipient, kind)
    if not cleared then
      file:close()
      return nil, "clear " .. path .. ": " .. tostring(clear_err)
    end
    offset = 0
  end
  local chunk, read_err = read_chunk(file, offset, size, budget)
  if chunk == nil then
    file:close()
    if read_err == "budget" then
      stats.partial = true
      return true
    end
    return nil, "read " .. path .. ": " .. tostring(read_err)
  end
  if chunk == "" then
    file:close()
    return true
  end
  local ok, why, consumed = import_lines(db, chunk, recipient, parse, insert, budget)
  if not ok then
    file:close()
    return nil, why
  end
  if consumed == 0 then
    file:close()
    stats.partial = true
    stats.error = stats.error or ("line exceeds " .. MAX_LOG_BYTES .. " bytes: " .. path)
    return true
  end
  local saved, save_err = save_offset(db, recipient, kind, offset + consumed, head)
  file:close()
  if not saved then return nil, save_err end
  budget.bytes = budget.bytes + consumed
  stats.imported = stats.imported + consumed
  if offset + consumed < size then stats.partial = true end
  return true
end

local function import_recipient(db, root, file, budget)
  local recipient = file:match("^(.+)%.jsonl$")
  if not recipient then return true end
  return transaction(db, function(active)
    local ok, why = import_path(active, root .. "/inboxes/" .. file, recipient,
      "inbox", id_from_json, insert_delivery, budget)
    if not ok then return nil, why end
    ok, why = import_path(active, root .. "/read/" .. file, recipient,
      "read", id_from_read, insert_read, budget)
    if not ok then return nil, why end
    return true
  end)
end

-- Import is idempotent and only runs when the DB opens. A file that changed
-- after an earlier import is appended by the normal delivery/read hooks.
function M.import_all()
  stats = { imported = 0, skipped = 0, partial = false, error = nil }
  local root = config.root
  if type(root) ~= "string" or root == "" then return true end
  local db, why = opened()
  if not db then return nil, why end
  local listed, names = pcall(remuda.list_dir, root .. "/inboxes")
  if not listed then
    if missing_file(names) then return true end
    stats.error = "list inboxes: " .. tostring(names)
    report("error", "list_failed", nil)
    return nil, stats.error
  end
  if type(names) ~= "table" then return true end
  local budget = {
    bytes = 0,
    statements = 0,
    started = os.clock(),
    clock = os.clock,
  }
  local first_error
  for _, file in ipairs(names) do
    if not budget_left(budget) then
      stats.partial = true
      break
    end
    local ok, err = import_recipient(db, root, file, budget)
    if not ok then
      first_error = err
      stats.error = err
      report("error", "import_failed", file)
      break
    end
  end
  if first_error then
    stats.partial = true
    stats.error = first_error
    report("degraded", "import_incomplete", first_error)
    return nil, first_error
  end
  if stats.partial then
    stats.error = stats.error or "partial import; backlog remains"
    report("degraded", "import_incomplete", stats.error)
  end
  return true
end

function M.deliver(recipient, id)
  local db, why = opened()
  if not db then return nil, why end
  local ok, err = insert_delivery(db, component(recipient), id)
  if not ok then
    report("error", "delivery_write", id)
    return nil, err
  end
  return true
end

function M.read(recipient, id)
  local db, why = opened()
  if not db then return nil, why end
  local ok, err = insert_read(db, component(recipient), id)
  if not ok then
    report("error", "read_write", id)
    return nil, err
  end
  return true
end

function M.count(recipient, kind)
  local db, why = opened()
  if not db then return nil, why end
  local table_name = kind == "read" and "reads" or "deliveries"
  local rows, err = checked(db.query, db,
    "SELECT COUNT(*) AS n FROM " .. table_name .. " WHERE recipient = ?", { component(recipient) })
  if rows == nil then return nil, err end
  return tonumber(rows[1] and rows[1].n) or 0
end

function M.status()
  return {
    available = handle ~= nil and failure == nil,
    imported_bytes = stats.imported,
    skipped_lines = stats.skipped,
    partial = stats.partial,
    error = failure or stats.error,
  }
end

function M.available()
  return opened() ~= nil
end

remuda._butler_inbox_db = M
