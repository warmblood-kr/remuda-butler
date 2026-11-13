-- Durable, idempotent LOCAL delivery of read receipts.
--
-- A1 records a `pending` intent in the same transaction as the inbox read.
-- This module drains those intents: it joins the delivered row for the
-- original envelope, decides eligibility, and delivers one local mailbox
-- message to the original sender. Matrix items are deliberately left pending
-- for the later relay slice; this module performs no Matrix I/O.
--
-- Crash safety rests on the receipt ULID that was committed with the intent
-- plus the completion status. The ID is reused on every scan, so a crash after
-- local acceptance is a verified retry, not a duplicate. An unrelated message
-- already using that ID is a collision: it is terminally failed and surfaced,
-- never reported as a success, so it cannot starve later receipts.
local config = assert(remuda._butler_read_receipts_config or {})
local M = {}

-- Bound one tick so a large backlog cannot stretch the 30 s schedule. Permanent
-- failures are additionally capped but do not consume the delivery budget, so
-- a page of failed intents cannot starve a later normal receipt.
local MAX_PER_TICK = 50
local MAX_FAILURES_PER_TICK = 100

local function report(outcome, reason, correlation)
  local diagnostics = config.diagnostics or remuda._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "read_receipts", outcome, reason, correlation)
  end
end

local function unhex(value)
  if type(value) ~= "string" or value == "" or #value % 2 ~= 0
      or not value:match("^[0-9a-fA-F]+$") then
    return nil
  end
  return (value:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function decode_envelope(text)
  if type(text) ~= "string" or text == "" then return nil end
  local json = config.json or (type(remuda.json) == "table" and remuda.json or nil)
  if not (json and type(json.decode) == "function") then return nil end
  local ok, value = pcall(json.decode, text)
  if ok and type(value) == "table" then return value end
  return nil
end

-- The reader address for the receipt's `from`. The intent recipient is the
-- hex mailbox component that the caller actually read; the envelope's `to`
-- only supplies display fields, so a legacy alias row cannot spoof the reader
-- identity.
local function reader_address(reader_id, envelope)
  -- Prefer the live/durable identity for the canonical reader id. A forwarded
  -- mail or an alias rename must not make the receipt name the original
  -- envelope's `to` alias instead of the member that actually read it.
  if type(config.reader_address) == "function" then
    local ok, resolved = pcall(config.reader_address, reader_id)
    if ok and type(resolved) == "table" and resolved.id == reader_id then return resolved end
  end
  -- Unresolved identity: the canonical reader id is the only trustworthy
  -- fallback. The original `to` alias may name a different member after a
  -- forward or reuse.
  local to = type(envelope.to) == "table" and envelope.to[1] or nil
  return { host = "local", id = reader_id, alias = reader_id,
    session = reader_id,
    kind = type(to) == "table" and (to.kind or "") or "",
    leader = type(to) == "table" and (to.leader or "") or "" }
end

-- `defer` leaves the intent pending (Matrix and transiently unreadable input);
-- `skip` is a durable exclusion; `eligible` returns the original sender.
local function classify(reader_id, envelope)
  if type(envelope) ~= "table" then return "defer", "envelope_unreadable" end
  local sender = envelope.from
  if type(sender) ~= "table" then return "skip", "sender_missing" end
  -- Structured identity, never the content text, is the recursion guard.
  if type(envelope.receipt_of) == "string" and envelope.receipt_of ~= "" then
    return "skip", "receipt_message"
  end
  local matrix = envelope.matrix
  if sender.host == "matrix"
      or (type(matrix) == "table" and (matrix.event_id or matrix.room_id)) then
    return "defer", "matrix"
  end
  local alias = sender.alias or sender.session
  if alias == "schedule" or sender.session == "schedule" then
    return "skip", "schedule_sender"
  end
  if sender.kind == "system" or alias == "system" then
    return "skip", "system_sender"
  end
  if type(sender.id) ~= "string" or sender.id == "" then
    return "skip", "unaddressable"
  end
  if sender.id == reader_id then return "skip", "self" end
  if sender.host ~= nil and sender.host ~= "local" then
    return "skip", "remote_sender"
  end
  return "eligible", sender
end

local function mark(store, db, intent, status)
  local changed, err = store.mark_intent_status(db, intent.recipient, intent.message_id, status)
  if changed == nil then
    report("error", "intent_status_write", intent.message_id)
    return nil, err
  end
  return true
end

local function receipt_ulid()
  local generator = config.new_ulid or remuda._butler_new_ulid
  if type(generator) ~= "function" then return nil end
  local ok, value = pcall(generator)
  if ok and type(value) == "string" and value ~= "" then return value end
  return nil
end

-- Claim the receipt ULID and exact body once. Intents created by the current
-- read path already carry the ULID; a pre-0003 row (or a direct store caller)
-- gets one on the first drain. The body is fixed in the same durable UPDATE so
-- a retry cannot compute a different text after an alias change.
local function stable_receipt(store, db, intent, candidate_body)
  local candidate_id = intent.receipt_id
  if type(candidate_id) ~= "string" or candidate_id == "" then
    candidate_id = receipt_ulid()
    if not candidate_id then return nil, nil, "ulid_unavailable" end
  end
  if type(intent.receipt_body) == "string" and intent.receipt_body ~= "" then
    candidate_body = intent.receipt_body
  end
  local claimed_id, claimed_body = store.claim_receipt(db, intent.recipient,
    intent.message_id, candidate_id, candidate_body)
  if not claimed_id then
    report("error", "receipt_id_claim", intent.message_id)
    return nil, nil, claimed_body
  end
  return claimed_id, claimed_body
end

-- Errors that cannot heal by retrying: an identity/content collision or an
-- unreadable stored receipt. They are terminally `failed` so they do not
-- occupy the pending page. Storage/DB errors stay pending and sort last.
local PERMANENT_ERRORS = {
  collision = true, content_conflict = true, body_conflict = true,
  body_missing = true, envelope_missing = true, envelope_unreadable = true,
  invalid_id = true,
}

-- Deliver one intent. Returns an outcome, an optional reason, and whether an
-- error is permanent.
function M.deliver_intent(intent)
  local simple = config.simple
  local mail = config.mail
  if not (simple and simple.db and simple.store) then return "unavailable", "sqlite_inactive", false end
  if not (mail and type(mail.queue_receipt) == "function") then return "error", "mail_unavailable", false end
  local reader_id = unhex(intent.recipient)
  if not reader_id then
    mark(simple.store, simple.db, intent, "skipped")
    return "skipped", "invalid_recipient", false
  end
  local envelope = decode_envelope(intent.envelope)
  local verdict, detail = classify(reader_id, envelope)
  if verdict == "defer" then
    -- Keep it pending for A3 but record that it is deferred so a Matrix
    -- backlog cannot keep taking this tick's budget ahead of local work.
    local deferred, defer_err = simple.store.defer_intent(simple.db, intent.recipient, intent.message_id)
    if deferred == nil then report("error", "intent_defer", defer_err) end
    return "deferred", detail, false
  end
  if verdict == "skip" then
    local marked, mark_err = mark(simple.store, simple.db, intent, "skipped")
    if not marked then return "error", mark_err, false end
    return "skipped", detail, false
  end
  local sender = detail
  local reader = reader_address(reader_id, envelope)
  local candidate_body = "Read receipt: " .. tostring(reader.alias)
    .. " fetched message " .. tostring(intent.message_id) .. " from the Butler inbox."
  local rid, text, rid_err = stable_receipt(simple.store, simple.db, intent, candidate_body)
  if not rid then return "error", rid_err, false end
  -- `read_at` is committed with the intent, so a retry produces the same
  -- envelope bytes even if the retry happens on a later date.
  local called, message, why, _to, already, code = pcall(mail.queue_receipt, reader, sender, text,
    "Read receipt", intent.message_id, rid, intent.read_at)
  if not called then
    report("error", "receipt_delivery", tostring(message))
    return "error", tostring(message), false
  end
  if not message then
    report("error", "receipt_delivery", intent.message_id)
    return "error", why, PERMANENT_ERRORS[code] == true
  end
  -- Ask the existing notice policy on every durable acceptance, including an
  -- accepted-but-unmarked retry. That policy dedupes by message ID and skips
  -- mail the sender already read, so this closes the crash window between the
  -- inbox commit and the notice without typing it twice in the same runtime.
  -- After a daemon restart, unread mail is reseeded by the same policy.
  if type(config.notify) == "function" then
    local notified, notice_err = pcall(config.notify, message, sender)
    if not notified then report("error", "receipt_notice", tostring(notice_err)) end
  end
  local marked, mark_err = mark(simple.store, simple.db, intent, "delivered")
  if not marked then return "error", mark_err, false end
  return "delivered", already and "already_accepted" or nil, false
end

function M.drain()
  local simple = config.simple
  if not (simple and simple.db and simple.store) then
    return { available = false, delivered = 0, skipped = 0, deferred = 0, failed = 0, errors = 0 }
  end
  local store, db = simple.store, simple.db
  local recipients, err = store.pending_recipients(db)
  if recipients == nil then
    report("error", "pending_recipients", err)
    return { available = true, delivered = 0, skipped = 0, deferred = 0, failed = 0, errors = 1 }
  end
  local counts = { available = true, delivered = 0, skipped = 0, deferred = 0, failed = 0, errors = 0 }
  local processed, failures = 0, 0
  local function budget_done()
    return processed >= MAX_PER_TICK or failures >= MAX_FAILURES_PER_TICK
  end
  for _, row in ipairs(recipients) do
    if budget_done() then break end
    local intents, detail_err = store.pending_intent_details(db, row.recipient)
    if intents == nil then
      report("error", "pending_intent_details", detail_err)
      counts.errors = counts.errors + 1
    else
      for _, intent in ipairs(intents) do
        if budget_done() then break end
        -- Rotate a deferred row behind untried ones. Best-effort: a failed
        -- timestamp write must not stop the delivery attempt itself.
        if type(store.note_intent_attempt) == "function" then
          store.note_intent_attempt(db, intent.recipient, intent.message_id)
        end
        local outcome, reason, permanent = M.deliver_intent(intent)
        if outcome == "error" then
          counts.errors = counts.errors + 1
          if permanent then counts.failed = counts.failed + 1 end
          -- A permanent collision is terminally failed; a retryable error is
          -- durably deferred so newer receipts stay ahead of it.
          local recorded, record_err = store.record_intent_failure(db, intent.recipient,
            intent.message_id, permanent)
          if recorded == nil then
            report("error", "intent_failure_record", record_err)
          end
          if permanent then failures = failures + 1 else processed = processed + 1 end
          report("error", "intent_delivery", reason or intent.message_id)
        else
          processed = processed + 1
          if counts[outcome] then counts[outcome] = counts[outcome] + 1 end
        end
      end
    end
  end
  return counts
end

function M.tick()
  local counts = M.drain()
  if counts.errors and counts.errors > 0 then
    report("degraded", "tick_errors", tostring(counts.errors))
  end
  return counts
end

remuda._butler_read_receipts = M
return M
