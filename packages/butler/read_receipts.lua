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
    local details = store.pending_local_intent_details or store.pending_intent_details
    local intents, detail_err = details(db, row.recipient)
    if intents == nil then
      report("error", "pending_intent_details", detail_err)
      counts.errors = counts.errors + 1
    else
      for _, intent in ipairs(intents) do
        if budget_done() then break end
        -- Rotate a deferred row behind untried ones. Best-effort: a failed
        -- timestamp write must not stop the delivery attempt itself.
        if type(store.note_intent_attempt) == "function" then
          local noted, note_err = store.note_intent_attempt(db, intent.recipient,
            intent.message_id)
          if noted == nil then
            -- Delivery still proceeds: rotation is an ordering aid, but a
            -- failed write must be visible because it weakens fairness.
            report("error", "intent_attempt_record", note_err or intent.message_id)
          end
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
  local matrix_counts = M.drain_matrix()
  if config.matrix then counts.matrix = matrix_counts end
  if counts.errors and counts.errors > 0 then
    report("degraded", "tick_errors", tostring(counts.errors))
  end
  if matrix_counts.errors and matrix_counts.errors > 0 then
    report("degraded", "matrix_tick_errors", tostring(matrix_counts.errors))
  end
  return counts
end

-- A Matrix-origin intent is deferred by the local drain. This second drain
-- delivers it as a threaded reply from the Butler bot to the original event.
-- It is not allowed to run in the local path's place: the A2 notice and file
-- mailbox are never used here.
local MATRIX_MAX_PER_TICK = 20
local MATRIX_SCAN_MAX = 200

local function matrix_envelope(envelope)
  local matrix = type(envelope) == "table" and envelope.matrix or nil
  if type(matrix) ~= "table" then return nil end
  if type(matrix.event_id) ~= "string" or matrix.event_id == "" then return nil end
  if type(matrix.room_id) ~= "string" or matrix.room_id == "" then return nil end
  return matrix
end

-- Only a route the relay proved came from an allowlisted human is eligible.
-- The durable envelope copy is the fallback for a trimmed route; anything
-- else fails closed instead of auto-acknowledging a stranger.
local function matrix_allowed(route, envelope_matrix)
  if type(route) == "table" and route.allowlisted_human == true then return true end
  return envelope_matrix.from_agent == false and envelope_matrix.allowlisted_human == true
end

function M.drain_matrix()
  local simple, matrix = config.simple, config.matrix
  local counts = { available = false, queued = 0, delivered = 0, skipped = 0,
    uncertain = 0, failed = 0, errors = 0 }
  if not (simple and simple.db and simple.store and matrix) then return counts end
  if type(matrix.available) == "function" then
    local ok, live = pcall(matrix.available)
    if not ok or not live then return counts end
  end
  local function call(name, ...)
    local fn = matrix[name]
    if type(fn) ~= "function" then return nil, "matrix_" .. name .. "_unavailable" end
    local ok, first, second = pcall(fn, ...)
    if not ok then return nil, tostring(first), true end
    return first, second
  end
  counts.available = true
  local store, db = simple.store, simple.db
  local recipients, err = store.pending_recipients(db)
  if recipients == nil then
    report("error", "matrix_pending_recipients", err)
    counts.errors = 1
    return counts
  end
  local processed, scanned = 0, 0
  for _, row in ipairs(recipients) do
    if processed >= MATRIX_MAX_PER_TICK or scanned >= MATRIX_SCAN_MAX then break end
    -- The Matrix drain must read the full projection (matrix_state/txn/event),
    -- never the local query: durable queued/uncertain evidence is what stops a
    -- resend when the relay result is missing.
    local intents, detail_err = store.pending_intent_details(db, row.recipient)
    if intents == nil then
      report("error", "matrix_pending_intents", detail_err)
      counts.errors = counts.errors + 1
    else
      for _, intent in ipairs(intents) do
        if processed >= MATRIX_MAX_PER_TICK or scanned >= MATRIX_SCAN_MAX then break end
        scanned = scanned + 1
        local reader_id = unhex(intent.recipient)
        local envelope = reader_id and decode_envelope(intent.envelope) or nil
        local matrix_meta = matrix_envelope(envelope)
        if reader_id and matrix_meta then
          processed = processed + 1
          -- After the A2 rotation column lands, every examined Matrix intent
          -- moves behind the untried ones too, so a long queued backlog cannot
          -- pin the scan to the same first page.
          if type(store.note_intent_attempt) == "function" then
            local noted, note_err = store.note_intent_attempt(db, intent.recipient,
              intent.message_id)
            if noted == nil then
              report("error", "matrix_intent_attempt_record", note_err or intent.message_id)
            end
          end
          if type(envelope.receipt_of) == "string" and envelope.receipt_of ~= "" then
            if mark(store, db, intent, "skipped") then counts.skipped = counts.skipped + 1 end
          else
            local verdict = classify(reader_id, envelope)
            if verdict ~= "defer" then
              -- Not a Matrix sender (or unreadable): the local drain owns it.
              counts.skipped = counts.skipped + 1
            else
              local route = call("route", intent.message_id)
              if type(route) ~= "table" then
                -- A trimmed route falls back to the durable envelope flags,
                -- but only when they prove an allowlisted human sender.
                if matrix_meta.from_agent == false and matrix_meta.allowlisted_human == true then
                  route = { room_id = matrix_meta.room_id, event_id = matrix_meta.event_id,
                    thread_root = matrix_meta.thread_root, from_agent = false,
                    allowlisted_human = true, room_kind = matrix_meta.room_kind }
                else
                  route = nil
                end
              end
              if not matrix_allowed(route, matrix_meta) then
                if mark(store, db, intent, "skipped") then counts.skipped = counts.skipped + 1 end
              else
                local reader = reader_address(reader_id, envelope)
                local body = "Read receipt: " .. tostring(reader.alias)
                  .. " fetched message " .. tostring(intent.message_id)
                  .. " from the Butler inbox."
                local rid, text, rid_err = stable_receipt(store, db, intent, body)
                if not rid then
                  counts.errors = counts.errors + 1
                  report("error", "matrix_receipt_id", rid_err)
                else
                  local durable = intent.matrix_state
                  local status, status_detail = call("status", rid)
                  local query_failed = status == nil and status_detail ~= nil
                  local function project(state, event, err)
                    local saved = store.record_matrix_state(db, intent.recipient,
                      intent.message_id, state,
                      state == "queued" and ("butler_" .. rid) or nil, event, err)
                    if saved == nil then
                      report("error", "matrix_state_write", intent.message_id)
                      return false
                    end
                    return true
                  end
                  if durable == "delivered" or status == "delivered" then
                    -- A durable result wins even after the relay result was
                    -- trimmed: it is proof this receipt was sent once.
                    project("delivered", type(status_detail) == "string" and status_detail or nil)
                    if mark(store, db, intent, "delivered") then counts.delivered = counts.delivered + 1 end
                  elseif durable == "failed" or status == "failed" then
                    project("failed", nil, status_detail or "relay reported no delivery")
                    if mark(store, db, intent, "failed") then counts.failed = counts.failed + 1 end
                  elseif durable == "uncertain" or status == "uncertain" then
                    project("uncertain", nil, "previous dispatch outcome unknown")
                    counts.uncertain = counts.uncertain + 1
                  elseif status == "queued" then
                    project("queued")
                    counts.queued = counts.queued + 1
                  elseif durable == "queued" then
                    -- We durably recorded the dispatch but the relay has no
                    -- outbox/result (state lost, trimmed or restarted). The
                    -- write may have happened; never send a second time.
                    project("uncertain", nil, "relay outcome unavailable")
                    counts.uncertain = counts.uncertain + 1
                  elseif query_failed then
                    counts.errors = counts.errors + 1
                    report("degraded", "matrix_status", status_detail)
                  else
                    -- Record the dispatch before the relay call. If this write
                    -- fails, refuse to send: an unrecorded send could be
                    -- repeated after a restart.
                    if not project("queued") then
                      counts.errors = counts.errors + 1
                    else
                      local ok, queue_err, raised = call("mail_reply", {
                        mail_id = intent.message_id, reply_mail_id = rid, text = text,
                        route = route, txn_id = "butler_" .. rid,
                        receipt_of = intent.message_id, machine = true,
                        content_extra = { ["io.butler.receipt_of"] = intent.message_id,
                          ["io.butler.receipt"] = true },
                      })
                      if ok then
                        counts.queued = counts.queued + 1
                      elseif raised then
                        -- The call threw: the outbox item may already exist or
                        -- the send may have happened. Never treat this as a
                        -- clean pre-send refusal.
                        project("uncertain", nil, "dispatch raised: " .. tostring(queue_err))
                        counts.uncertain = counts.uncertain + 1
                        report("error", "matrix_receipt_exception", queue_err)
                      else
                        local reason = tostring(queue_err or "matrix_reply_failed")
                        local permanent = reason:find("route", 1, true) ~= nil
                          or reason:find("non%-allowlisted") ~= nil
                        project(permanent and "failed" or "deferred", nil, reason)
                        store.record_intent_failure(db, intent.recipient, intent.message_id, permanent)
                        counts.errors = counts.errors + 1
                        if permanent then
                          if mark(store, db, intent, "failed") then counts.failed = counts.failed + 1 end
                        end
                        report(permanent and "error" or "degraded", "matrix_receipt_queue", reason)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return counts
end

remuda._butler_read_receipts = M
return M
