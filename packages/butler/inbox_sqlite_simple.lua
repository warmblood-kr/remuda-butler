-- One-time import of legacy inbox logs and their message files.
-- The caller owns the database connection and decides when to switch readers.
local M = {}

-- Newest inbox migration this module's queries require. Keep it in step with
-- packages/butler/migrations/inbox: a reload can hand this module a database
-- that an older build opened, and every query below assumes the newest shape.
M.SCHEMA_VERSION = 5

-- True only when the connection carries at least the schema this module reads.
-- A caller that is about to swap in this module after a reload checks first, so
-- new queries never run against an old database.
function M.ready(db)
  local rows, err = db:query('PRAGMA user_version')
  if not rows then return false, tostring(err or 'schema version unavailable') end
  local version = tonumber(rows[1] and rows[1].user_version) or 0
  if version < M.SCHEMA_VERSION then
    return false, 'schema v' .. tostring(version) .. ' is older than v' .. tostring(M.SCHEMA_VERSION)
  end
  return true
end

local function checked(db, method, sql, args)
  local result, err = db[method](db, sql, args or {})
  if result == nil then error(tostring(err or 'sqlite operation failed'), 0) end
  return result
end

local function read_file(path, optional)
  local f, err, code = io.open(path, 'rb')
  if not f then
    if optional and (code == 2 or tostring(err):find('No such file', 1, true)) then return '' end
    error('cannot read ' .. path .. ': ' .. tostring(err), 0)
  end
  local data = assert(f:read('*a'))
  f:close()
  return data
end

local function safe_component(value)
  return type(value) == 'string' and value ~= '' and not value:find('[/\\]')
    and not value:find('..', 1, true)
end

local function insert_legacy(db, root, recipient, line, read, json)
  local delivery = assert(json.decode(line), 'invalid inbox JSON')
  local id = delivery.message_id
  assert(safe_component(id), 'invalid message ID')
  local envelope = read_file(root .. '/messages/' .. id .. '.json')
  local message = assert(json.decode(envelope), 'invalid message envelope')
  local object_id = message.body and message.body.object_id
  assert(safe_component(object_id), 'invalid object ID')
  local body = read_file(root .. '/objects/' .. object_id)
  local note_id = delivery.resent and delivery.resent.note_object_id
  local note
  if note_id then
    assert(safe_component(note_id), 'invalid note object ID')
    note = read_file(root .. '/objects/' .. note_id)
  end
  checked(db, 'exec', [[INSERT OR IGNORE INTO simple_inbox
    (recipient, message_id, envelope, body, delivery, note, is_read)
    VALUES (?, ?, ?, ?, ?, ?, ?)]], {recipient, id, envelope, body, line, note or "", read[id] and 1 or 0})
end

-- The inbox directory uses hex-encoded recipient names. Import all logs once;
-- the SQLite transaction commits both the data and the completion marker.
function M.import(db, root, filenames, json)
  local ok, result = pcall(function()
    checked(db, 'exec', 'BEGIN IMMEDIATE')
    checked(db, 'exec', [[CREATE TABLE IF NOT EXISTS simple_inbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL,
      message_id TEXT NOT NULL, envelope TEXT NOT NULL, body TEXT NOT NULL,
      delivery TEXT NOT NULL, note TEXT, is_read INTEGER NOT NULL DEFAULT 0,
      UNIQUE(recipient, message_id))]])
    checked(db, 'exec', 'CREATE TABLE IF NOT EXISTS simple_inbox_meta (key TEXT PRIMARY KEY)')
    local done = checked(db, 'query', "SELECT key FROM simple_inbox_meta WHERE key = 'imported'")
    if #done == 0 then
      for _, filename in ipairs(filenames) do
        local recipient = filename:match('^([0-9a-f]+)%.jsonl$')
        if recipient then
          local reads = read_file(root .. '/read/' .. filename, true)
          local read = {}; for id in reads:gmatch('[^\r\n]+') do read[id] = true end
          local deliveries = read_file(root .. '/inboxes/' .. filename)
          for line in deliveries:gmatch('[^\r\n]+') do
            insert_legacy(db, root, recipient, line, read, json)
          end
        end
      end
      checked(db, 'exec', "INSERT INTO simple_inbox_meta (key) VALUES ('imported')")
    end
    checked(db, 'exec', 'COMMIT')
    return true
  end)
  if ok then return result end
  pcall(db.exec, db, 'ROLLBACK')
  return nil, tostring(result)
end

function M.unread(db, recipient)
  return db:query('SELECT message_id, envelope, body, delivery, note FROM simple_inbox WHERE recipient = ? AND is_read = 0 ORDER BY seq', {recipient})
end

function M.deliver(db, recipient, id, envelope, body, delivery, note)
  return db:exec([[INSERT INTO simple_inbox
    (recipient, message_id, envelope, body, delivery, note, is_read)
    VALUES (?, ?, ?, ?, ?, ?, 0)]], {recipient, id, envelope, body, delivery, note or ''})
end

-- The caller owns the transaction: a caller that reads messages opens one
-- BEGIN IMMEDIATE and commits the whole batch. Both statements below run in
-- that transaction, so an intent never commits without the read and a failed
-- read leaves no receipt intent.
--
-- `receipt` is the caller-provenance decision made by mail.inbox: only the
-- mailbox owner reading their own inbox passes true. An operator or another
-- member reading the same mailbox passes false, so the read state is still
-- saved but no agent receipt intent is created. Direct callers that omit the
-- flag keep the old behavior (an agent read).
--
-- The intent insert is conditional on is_read = 0 and runs before the update.
-- That is the "new read" test: an already-read row (including one imported from
-- a legacy read log) inserts nothing, and a second read of the same message
-- finds no unread row. The primary key is a second guard against duplicates.
-- `receipt_id` is a normal Butler ULID generated by the reader and committed
-- with the intent. It is the stable identity of the receipt message; a retry
-- never invents a new one. Callers that omit it (or rows created before 0003)
-- store NULL, not an empty string, so the partial unique index does not treat
-- two unidentified intents as a collision. The first drain claims one.
function M.mark_read(db, recipient, id, receipt, receipt_id)
  if receipt ~= false then
    local inserted, insert_err = db:exec([[INSERT OR IGNORE INTO read_receipt_intents
      (recipient, message_id, read_at, receipt_id)
      SELECT recipient, message_id, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), NULLIF(?, '')
      FROM simple_inbox
      WHERE recipient = ? AND message_id = ? AND is_read = 0]], {receipt_id or "", recipient, id})
    if inserted == nil then return nil, insert_err end
  end
  return db:exec('UPDATE simple_inbox SET is_read = 1 WHERE recipient = ? AND message_id = ? AND is_read = 0',
    {recipient, id})
end

-- Delivery scan. `recipient` is the hex-encoded mailbox component stored by
-- mark_read. The original envelope is joined rather than copied into the
-- intent, so the sender and route come from the durable delivered row.
function M.pending_intents(db, recipient)
  return db:query([[SELECT recipient, message_id, read_at
    FROM read_receipt_intents
    WHERE recipient = ? AND status = 'pending'
    ORDER BY read_at, message_id]], {recipient})
end

function M.pending_recipients(db)
  return db:query([[SELECT recipient FROM read_receipt_intents
    WHERE status = 'pending'
    GROUP BY recipient
    ORDER BY MIN(CASE WHEN deferred_at IS NULL THEN 0 ELSE 1 END),
      MIN(CASE WHEN attempt_seq IS NULL THEN -1 ELSE attempt_seq END), recipient]])
end

-- Local delivery never needs the Matrix projection, and the A2 schema (a
-- rolled-back v4 database) does not have those columns. Keeping this query
-- matrix-free lets a downgraded database still drain local receipts.
function M.pending_local_intent_details(db, recipient)
  return db:query([[SELECT i.recipient AS recipient, i.message_id AS message_id,
      i.read_at AS read_at, i.receipt_id AS receipt_id, i.receipt_body AS receipt_body,
      s.envelope AS envelope
    FROM read_receipt_intents i
    LEFT JOIN simple_inbox s
      ON s.recipient = i.recipient AND s.message_id = i.message_id
    WHERE i.recipient = ? AND i.status = 'pending'
    ORDER BY (i.deferred_at IS NOT NULL),
      CASE WHEN i.attempt_seq IS NULL THEN -1 ELSE i.attempt_seq END,
      i.read_at, i.message_id]], {recipient})
end

function M.pending_intent_details(db, recipient)
  return db:query([[SELECT i.recipient AS recipient, i.message_id AS message_id,
      i.read_at AS read_at, i.receipt_id AS receipt_id, i.receipt_body AS receipt_body,
      i.matrix_state AS matrix_state, i.matrix_txn_id AS matrix_txn_id,
      i.matrix_event_id AS matrix_event_id, s.envelope AS envelope
    FROM read_receipt_intents i
    LEFT JOIN simple_inbox s
      ON s.recipient = i.recipient AND s.message_id = i.message_id
    WHERE i.recipient = ? AND i.status = 'pending'
    ORDER BY (i.deferred_at IS NOT NULL),
      CASE WHEN i.attempt_seq IS NULL THEN -1 ELSE i.attempt_seq END,
      i.read_at, i.message_id]], {recipient})
end

-- Claim the receipt identity and body exactly once. Each UPDATE only fills an
-- empty field; a later or concurrent scan reads back the winner's values
-- instead of overwriting them. This keeps the retry body independent of any
-- later alias/profile change.
function M.claim_receipt(db, recipient, message_id, candidate_id, candidate_body)
  if type(candidate_id) ~= "string" or candidate_id == "" then return nil, "invalid receipt id" end
  if type(candidate_body) ~= "string" or candidate_body == "" then return nil, "invalid receipt body" end
  local changed, err = db:exec([[UPDATE read_receipt_intents
    SET receipt_id = CASE WHEN receipt_id IS NULL OR receipt_id = '' THEN ? ELSE receipt_id END,
        receipt_body = CASE WHEN receipt_body IS NULL OR receipt_body = '' THEN ? ELSE receipt_body END
    WHERE recipient = ? AND message_id = ? AND status = 'pending']],
    {candidate_id, candidate_body, recipient, message_id})
  if changed == nil then return nil, err end
  local rows, query_err = db:query([[SELECT receipt_id, receipt_body FROM read_receipt_intents
    WHERE recipient = ? AND message_id = ?]], {recipient, message_id})
  if rows == nil then return nil, query_err end
  local row = rows[1]
  if row and type(row.receipt_id) == "string" and row.receipt_id ~= ""
      and type(row.receipt_body) == "string" and row.receipt_body ~= "" then
    return row.receipt_id, row.receipt_body
  end
  return nil, "receipt identity was not stored"
end

-- Mark a Matrix (or otherwise temporarily undeliverable) intent as deferred.
-- It remains pending but sorts after local work on the next scan.
function M.defer_intent(db, recipient, message_id)
  return db:exec([[UPDATE read_receipt_intents
    SET deferred_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE recipient = ? AND message_id = ? AND status = 'pending' AND deferred_at IS NULL]],
    {recipient, message_id})
end

-- Pending rows rotate by a persisted sequence, not by wall-clock time, so
-- equal timestamps, a restart or more than 100 rows cannot pin the first page.
-- NULL is "not tried yet" and sorts first; each attempt takes the next number.
-- This runs before eligibility, so a row deferred by this same attempt is
-- still moved behind the unattempted rows.
function M.note_intent_attempt(db, recipient, message_id)
  local bumped, bump_err = db:exec(
    "UPDATE receipt_attempt_seq SET value = value + 1 WHERE id = 1")
  if bumped == nil then return nil, bump_err end
  return db:exec([[UPDATE read_receipt_intents
    SET attempt_seq = (SELECT value FROM receipt_attempt_seq WHERE id = 1)
    WHERE recipient = ? AND message_id = ? AND status = 'pending']],
    {recipient, message_id})
end

-- The completion mark. It is written only after the local receipt is durable;
-- a crash before this update is safe because the persisted receipt ID and body
-- are reused on the next scan. 0 changed rows means another scan already
-- completed it, which is also success.
function M.mark_intent_status(db, recipient, message_id, status)
  return db:exec([[UPDATE read_receipt_intents SET status = ?
    WHERE recipient = ? AND message_id = ? AND status = 'pending']],
    {status, recipient, message_id})
end

-- A permanent failure (an identity collision or unreadable stored receipt) is
-- marked `failed` so it stops occupying the pending page. A retryable failure
-- stays pending but gets a durable `deferred_at`, which sorts it behind new
-- work; it is retried later without blocking normal receipts. No schema
-- change: `status` and `deferred_at` already exist.
function M.record_intent_failure(db, recipient, message_id, permanent)
  if permanent then
    return db:exec([[UPDATE read_receipt_intents SET status = 'failed'
      WHERE recipient = ? AND message_id = ? AND status = 'pending']],
      {recipient, message_id})
  end
  return db:exec([[UPDATE read_receipt_intents
    SET deferred_at = COALESCE(deferred_at, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    WHERE recipient = ? AND message_id = ? AND status = 'pending']],
    {recipient, message_id})
end

-- Durable projection of the relay write for a Matrix intent. The intent stays
-- `pending` until the receipt is confirmed; `matrix_state` is what makes a
-- restart or an uncertain send visible instead of re-dispatching it.
function M.record_matrix_state(db, recipient, message_id, state, txn_id, event_id, err)
  return db:exec([[UPDATE read_receipt_intents
    SET matrix_state = ?, matrix_txn_id = COALESCE(?, matrix_txn_id),
        matrix_event_id = COALESCE(?, matrix_event_id), matrix_error = ?,
        matrix_updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE recipient = ? AND message_id = ? AND status = 'pending']],
    {state, txn_id, event_id, err, recipient, message_id})
end

function M.rows(db, recipient)
  return db:query('SELECT message_id, delivery, note, is_read FROM simple_inbox WHERE recipient = ? ORDER BY seq', {recipient})
end

function M.has(db, recipient, id)
  local rows, err = db:query('SELECT message_id FROM simple_inbox WHERE recipient = ? AND message_id = ?', {recipient, id})
  if not rows then return nil, err end
  return #rows > 0
end

function M.migrate_alias(db, source, target)
  local ok, err = pcall(function()
    checked(db, 'exec', 'BEGIN IMMEDIATE')
    checked(db, 'exec', [[INSERT OR IGNORE INTO simple_inbox
      (recipient,message_id,envelope,body,delivery,note,is_read)
      SELECT ?,message_id,envelope,body,delivery,note,0
      FROM simple_inbox WHERE recipient=? AND is_read=0 ORDER BY seq]], {target,source})
    checked(db, 'exec', 'UPDATE simple_inbox SET is_read=1 WHERE recipient=? AND is_read=0', {source})
    checked(db, 'exec', 'COMMIT')
  end)
  if ok then return true end
  pcall(db.exec, db, 'ROLLBACK')
  return nil, tostring(err)
end

if remuda then remuda._butler_simple_inbox_module = M end

return M
