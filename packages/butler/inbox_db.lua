-- Shadow inbox index in the mod's private SQLite database.
--
-- Files stay authoritative in this phase: every write below happens only after
-- the matching file commit, and every failure is reported as degraded while
-- mail continues on the file path. There is no read switch yet.
local config = assert(remuda._butler_inbox_db_config)

local M = {}
local handle
local failure

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

local function opened()
  if handle then return handle end
  if failure then return nil, failure end
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

local function rollback(db)
  pcall(db.exec, db, "ROLLBACK")
end

local function commit(db)
  local ok, why = pcall(db.exec, db, "COMMIT")
  if ok then return true end
  rollback(db)
  return nil, "commit: " .. tostring(why)
end

local function transaction(db, work)
  local began, why = pcall(db.exec, db, "BEGIN IMMEDIATE")
  if not began then return nil, "begin: " .. tostring(why) end
  local ok, result, extra = pcall(work, db)
  if not ok or result == nil then
    rollback(db)
    return nil, tostring(not ok and result or extra or "transaction body failed")
  end
  local done, commit_err = commit(db)
  if not done then return nil, commit_err end
  return result
end

local function insert_delivery(db, recipient, id)
  return db:exec(
    "INSERT OR IGNORE INTO deliveries (recipient, message_id, seq) " ..
      "VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM deliveries WHERE recipient = ?))",
    { recipient, id, recipient })
end

local function insert_read(db, recipient, id)
  return db:exec("INSERT OR IGNORE INTO reads (recipient, message_id) VALUES (?, ?)",
    { recipient, id })
end

local function id_from_json(line)
  return line:match('"message_id":"([^"]+)"')
end

local function id_from_read(line)
  local id = line:match("^%s*(.-)%s*$")
  if id == "" then return nil end
  return id
end

-- One boot imports at most this many remaining bytes per log. A larger file
-- is finished on the next boot; delivery hooks keep new mail indexed meanwhile.
local MAX_IMPORT_BYTES = 8 * 1024 * 1024

local function offset_for(db, recipient, kind)
  local ok, rows = pcall(db.query, db,
    "SELECT offset FROM import_state WHERE recipient = ? AND kind = ?", { recipient, kind })
  if not ok or type(rows) ~= "table" or not rows[1] then return 0 end
  return tonumber(rows[1].offset) or 0
end

local function save_offset(db, recipient, kind, offset)
  return db:exec(
    "INSERT OR REPLACE INTO import_state (recipient, kind, offset) VALUES (?, ?, ?)",
    { recipient, kind, offset })
end

local function import_path(db, path, recipient, kind, parse, insert)
  local file = io.open(path, "r")
  if not file then return true end
  local offset = offset_for(db, recipient, kind)
  local size = file:seek("end") or 0
  if offset > size then offset = 0 end
  file:seek("set", offset)
  local chunk = file:read(MAX_IMPORT_BYTES)
  file:close()
  if not chunk or chunk == "" then return true end
  -- Only complete lines advance the offset, so a torn tail is retried.
  local consumed = 0
  for line in chunk:gmatch("([^\n]*)\n") do
    consumed = consumed + #line + 1
    local id = parse(line)
    if id then insert(db, recipient, id) end
  end
  if consumed == 0 then return true end
  return save_offset(db, recipient, kind, offset + consumed)
end

local function import_recipient(db, root, file)
  local recipient = file:match("^(.+)%.jsonl$")
  if not recipient then return true end
  return transaction(db, function(active)
    local inbox, inbox_err = import_path(active, root .. "/inboxes/" .. file, recipient,
      "inbox", id_from_json, insert_delivery)
    if not inbox then return nil, inbox_err end
    local read, read_err = import_path(active, root .. "/read/" .. file, recipient,
      "read", id_from_read, insert_read)
    if not read then return nil, read_err end
    return true
  end)
end

-- Import is idempotent and only runs when the DB opens. A file that changed
-- after an earlier import is appended by the normal delivery/read hooks.
function M.import_all()
  local root = config.root
  if type(root) ~= "string" or root == "" then return true end
  local db, why = opened()
  if not db then return nil, why end
  local listed, names = pcall(remuda.list_dir, root .. "/inboxes")
  if not listed or type(names) ~= "table" then return true end
  local first_error
  for _, file in ipairs(names) do
    local ok, err = import_recipient(db, root, file)
    if not ok then
      first_error = first_error or err
      report("error", "import_failed", file)
    end
  end
  if first_error then return nil, first_error end
  return true
end

function M.deliver(recipient, id)
  local db, why = opened()
  if not db then return nil, why end
  local ok, err = pcall(insert_delivery, db, component(recipient), id)
  if not ok then
    report("error", "delivery_write", id)
    return nil, tostring(err)
  end
  return true
end

function M.read(recipient, id)
  local db, why = opened()
  if not db then return nil, why end
  local ok, err = pcall(insert_read, db, component(recipient), id)
  if not ok then
    report("error", "read_write", id)
    return nil, tostring(err)
  end
  return true
end

function M.count(recipient, kind)
  local db, why = opened()
  if not db then return nil, why end
  local table_name = kind == "read" and "reads" or "deliveries"
  local ok, rows = pcall(db.query, db,
    "SELECT COUNT(*) AS n FROM " .. table_name .. " WHERE recipient = ?", { component(recipient) })
  if not ok then return nil, tostring(rows) end
  return tonumber(rows[1] and rows[1].n) or 0
end

function M.available()
  return opened() ~= nil
end

remuda._butler_inbox_db = M
