-- Private, durable, bounded journal for automatic mailbox delivery attempts
-- (owner decision 2026-11-05; plan docs/concepts/native-notice-plan.md).
--
-- Every automatic PTY or native dispatch is journaled as DISPATCHING *before*
-- any bytes are written. A dispatch whose outcome is unknown becomes
-- UNCERTAIN and stays suppressed across inbox reads, stuck-record closure,
-- compaction re-shows, mod reloads, a full daemon restart and a new session
-- instance/nonce. The journal is the authority; the in-memory notice maps are
-- only a cache for the current image.
--
-- Fail-closed rules:
-- - A full journal, a failed save, a corrupt file or a replaced module blocks
--   every automatic dispatch that needs the journal. There is no eviction of
--   an UNCERTAIN entry to make room and no PTY fallback.
-- - DISPATCHING -> UNCERTAIN conversion at load is itself a write. If it
--   cannot persist, the journal is globally blocked before any unread seed.
--
-- Storage is the core's existing JSON codec (`remuda.json`, injected here so
-- unit tests can supply their own) with a strict versioned schema. The file is
-- written 0600 and atomically. Bodies are bounded; endpoints, tokens and auth
-- references are never journaled.
local M = {}

local VERSION = 1
local DEFAULT_CAP_BYTES = 512 * 1024
local MAX_BODY_BYTES = 2048
local MAX_REASON_BYTES = 200
local MAX_STATUS_ITEMS = 20
local STATES = { dispatching = true, uncertain = true, accepted_unread = true }
local PROTOCOLS = { pty = true, native = true }

local MAX_ID_BYTES = 128
local function valid_message_id(value)
  if type(value) ~= "string" or #value < 1 or #value > MAX_ID_BYTES then return false end
  return value:match("^[%w_%-]+$") ~= nil
end

local function trim_reason(reason)
  local text = tostring(reason or ""):gsub("[\r\n]+", " ")
  if #text > MAX_REASON_BYTES then text = text:sub(1, MAX_REASON_BYTES) end
  return text
end

-- A dense array only: no map keys, no holes. A hidden object of tombstones
-- must never decode as an empty entry list.
local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then
      return false
    end
  end
  for index = 1, count do
    if value[index] == nil then return false end
  end
  return true
end

-- No count cap: a backlog burst or a reseed can name hundreds of IDs, and the
-- 556 regression removed an arbitrary 16. The global serialized byte cap is
-- the real bound. Identical IDs are deduplicated; each must be a plain token.
local function validate_message_ids(ids)
  if type(ids) ~= "table" or #ids < 1 then return nil, "no_message_ids" end
  if not dense_array(ids) then return nil, "message_ids_schema" end
  local order, seen = {}, {}
  for _, id in ipairs(ids) do
    if not valid_message_id(id) then return nil, "invalid_message_id" end
    if not seen[id] then
      seen[id] = true
      order[#order + 1] = id
    end
  end
  return order
end

-- One validator for both a fresh dispatch and a decoded entry, so the parse
-- path enforces exactly the same constraints as the write path.
local function validate_entry(value)
  if type(value) ~= "table" then return nil, "entry_not_object" end
  if not STATES[value.state] then return nil, "state" end
  if not PROTOCOLS[value.protocol] then return nil, "protocol" end
  if not valid_message_id(value.recipient_id) then return nil, "recipient" end
  local ids, ids_err = validate_message_ids(value.message_ids)
  if not ids then return nil, ids_err end
  local body = value.body
  if type(body) ~= "string" or body == "" then return nil, "body" end
  if #body > MAX_BODY_BYTES then return nil, "body_too_large" end
  local digest = value.body_sha256 or ""
  if type(digest) ~= "string" or (digest ~= "" and not digest:match("^[0-9a-f]+$")) then
    return nil, "body_sha256"
  end
  local created, updated = tonumber(value.created), tonumber(value.updated)
  if not created or not updated then return nil, "timestamps" end
  return { state = value.state, protocol = value.protocol,
    recipient_id = value.recipient_id, message_ids = ids,
    instance = tostring(value.instance or ""), row_id = tostring(value.row_id or ""),
    nonce = tostring(value.nonce or ""), generation = tostring(value.generation or ""),
    reason = trim_reason(value.reason), body = body, body_sha256 = digest,
    created = created, updated = updated }
end

local function json_codec(journal)
  local codec = journal.json
  if type(codec) ~= "table" or type(codec.encode) ~= "function"
      or type(codec.decode) ~= "function" then
    return nil, "codec_unavailable"
  end
  return codec
end

local function encode_state(journal)
  local codec, why = json_codec(journal)
  if not codec then return nil, why end
  local entries = type(codec.array) == "function" and codec.array(journal.entries)
    or journal.entries
  local root = { version = VERSION, entries = entries }
  if type(codec.object) == "function" then root = codec.object(root) end
  local ok, text = pcall(codec.encode, root)
  if not ok or type(text) ~= "string" then return nil, "codec_unavailable" end
  return text
end

local function finite_number(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local ROOT_KEYS = { version = true, entries = true }
local ENTRY_KEYS = { state = true, protocol = true, recipient_id = true,
  message_ids = true, instance = true, row_id = true, nonce = true,
  generation = true, reason = true, body = true, body_sha256 = true,
  created = true, updated = true }

local function strict_object(value, allowed)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then return false end
  end
  return true
end

local function hash_available(journal)
  if type(journal.hash) ~= "function" then return false end
  local ok, digest = pcall(journal.hash, "")
  return ok and type(digest) == "string" and digest ~= ""
end

local function verify_digest(journal, entry)
  if type(journal.hash) ~= "function" then return false end
  local ok, digest = pcall(journal.hash, entry.body)
  return ok and type(digest) == "string" and digest ~= ""
    and digest == entry.body_sha256
end

-- The hash module (guard_approval) loads later in main.lua than this journal.
-- A persisted journal must therefore load without pretending its digests are
-- corrupt: verification is deferred, and the first dispatch is blocked until
-- the hash is available and every entry verifies.
local function verify_digests(journal)
  if not journal.digests_unverified then return true end
  if not hash_available(journal) then return false, "hash_unavailable" end
  for _, entry in ipairs(journal.entries) do
    if not verify_digest(journal, entry) then
      journal.corrupt = "journal_corrupt: body_digest"
      journal.digests_unverified = false
      return false, journal.corrupt
    end
  end
  journal.digests_unverified = false
  return true
end

local function decode_state(journal, text)
  local codec, why = json_codec(journal)
  if not codec then return nil, why end
  local ok, value = pcall(codec.decode, text)
  if not ok or type(value) ~= "table" then return nil, "invalid_json" end
  if not strict_object(value, ROOT_KEYS) then return nil, "root_schema" end
  if tonumber(value.version) ~= VERSION then return nil, "version" end
  if not dense_array(value.entries) then return nil, "entries_schema" end
  local entries, seen = {}, {}
  for _, item in ipairs(value.entries) do
    if not strict_object(item, ENTRY_KEYS) then return nil, "entry_schema" end
    local entry, err = validate_entry(item)
    if not entry then return nil, tostring(err) end
    if not finite_number(entry.created) or not finite_number(entry.updated) then
      return nil, "timestamps"
    end
    if hash_available(journal) then
      if not verify_digest(journal, entry) then return nil, "body_digest" end
    else
      journal.digests_unverified = true
    end
    for _, id in ipairs(entry.message_ids) do
      local key = entry.recipient_id .. "\0" .. id
      if seen[key] then return nil, "duplicate_message_id" end
      seen[key] = true
    end
    entries[#entries + 1] = entry
  end
  return entries
end

local function journal_read(journal)
  local ok, text, err = pcall(journal.read, journal.path, journal.cap_bytes)
  if not ok then return nil, "read_failed: " .. tostring(text) end
  if text == nil then
    if err == "missing" then return {} end
    if err == "too_large" then return nil, "file_too_large" end
    return nil, "read_failed: " .. tostring(err or "unknown")
  end
  if #text > journal.cap_bytes then return nil, "file_too_large" end
  return decode_state(journal, text)
end

local function journal_save(journal)
  if journal.is_current and not journal.is_current() then
    journal.blocked = "journal_replaced"
    return false, journal.blocked
  end
  local text, err = encode_state(journal)
  if not text then
    journal.blocked = "encode_failed: " .. tostring(err)
    return false, journal.blocked
  end
  if #text > journal.cap_bytes then
    journal.full = true
    return false, "journal_full"
  end
  local ok, result, detail = pcall(journal.write, journal.path, text)
  -- The writer seam can yield (a reload may replace this module while the write
  -- is in flight). Fence again AFTER persisting: a stale callback must not send
  -- on the replacement generation, and must not retire/replace its entries. The
  -- old write may have landed; the replacement journal's DISPATCHING recovery
  -- keeps that attempt reserved as UNCERTAIN, which is fail-closed.
  if ok and result == true and journal.is_current and not journal.is_current() then
    journal.blocked = "journal_replaced"
    return false, journal.blocked
  end
  -- The writer seam must acknowledge with an explicit true. A nil/false result
  -- (even without an error string) proves nothing was durably written.
  if not ok or result ~= true then
    journal.blocked = "save_failed: "
      .. tostring(ok and (detail or tostring(result) .. " (no explicit acknowledgement)"
        ) or result)
    return false, journal.blocked
  end
  journal.blocked = nil
  return true
end

local function journal_find(journal, recipient_id, message_id)
  if not recipient_id or not message_id then return nil end
  for _, entry in ipairs(journal.entries) do
    if entry.recipient_id == recipient_id then
      for _, id in ipairs(entry.message_ids) do
        if id == message_id then return entry end
      end
    end
  end
end

local function journal_load(journal)
  local entries, err = journal_read(journal)
  if not entries then
    journal.corrupt = "journal_corrupt: " .. tostring(err)
    journal.loaded = true
    return false, journal.corrupt
  end
  journal.entries, journal.loaded = entries, true
  journal.full = false
  local recovered = 0
  for _, entry in ipairs(entries) do
    if entry.state == "dispatching" then
      entry.state, entry.reason, entry.updated = "uncertain", "restart_before_ack", journal.now()
      recovered = recovered + 1
    end
  end
  if recovered > 0 then
    local saved, save_err = journal_save(journal)
    if not saved then
      journal.blocked = "boot_recovery_save_failed: " .. tostring(save_err)
      return false, journal.blocked
    end
  end
  return true
end

local function recheck_full(journal)
  local text = encode_state(journal)
  if text and #text <= journal.cap_bytes then journal.full = false end
end

local function ensure_loaded(journal)
  if journal.loaded then return true end
  return journal_load(journal)
end

local function journal_is_current(journal)
  return not journal.is_current or journal.is_current() == true
end

local function journal_begin(journal, record)
  local loaded, load_err = ensure_loaded(journal)
  if not loaded then return nil, load_err end
  if journal.corrupt then return nil, journal.corrupt end
  -- A full journal fails closed globally until entries are retired or pruned.
  -- A smaller dispatch must not slip past the gate.
  if journal.full then return nil, "journal_full" end
  if journal.blocked then
    local saved = journal_save(journal)
    if not saved then return nil, journal.blocked end
  end
  local verified, verify_err = verify_digests(journal)
  if not verified then return nil, verify_err end
  if type(record) ~= "table" then return nil, "invalid_record" end
  local hashed, digest = pcall(journal.hash, tostring(record.body or ""))
  if not hashed or type(digest) ~= "string" or digest == "" then
    return nil, "hash_unavailable"
  end
  local now = journal.now()
  local entry, why = validate_entry({ state = "dispatching", protocol = record.protocol,
    recipient_id = record.recipient_id, message_ids = record.message_ids,
    instance = record.instance, row_id = record.row_id, nonce = record.nonce,
    generation = record.generation, reason = "", body = record.body,
    body_sha256 = digest, created = now, updated = now })
  if not entry then return nil, tostring(why) end
  -- Reservation: DISPATCHING itself suppresses admission and re-entry, so two
  -- callbacks or a reload can never create a second attempt for the same mail.
  for _, id in ipairs(entry.message_ids) do
    local existing = journal_find(journal, entry.recipient_id, id)
    if existing then return nil, "already_reserved: " .. existing.state end
  end
  journal.entries[#journal.entries + 1] = entry
  local text, encode_err = encode_state(journal)
  if not text then
    journal.entries[#journal.entries] = nil
    return nil, encode_err
  end
  if #text > journal.cap_bytes then
    journal.entries[#journal.entries] = nil
    journal.full = true
    return nil, "journal_full"
  end
  local saved, save_err = journal_save(journal)
  if not saved then
    journal.entries[#journal.entries] = nil
    return nil, save_err
  end
  if not journal_is_current(journal) then return nil, "journal_replaced" end
  return entry
end

local function journal_mark(journal, entry, state, reason)
  if not journal_is_current(journal) then return false, "journal_replaced" end
  if type(entry) ~= "table" or not STATES[state] then return false, "invalid_state" end
  entry.state, entry.reason, entry.updated = state, trim_reason(reason), journal.now()
  return journal_save(journal)
end

local function journal_retire(journal, entry, options)
  if not journal_is_current(journal) then return false, "journal_replaced" end
  for index, candidate in ipairs(journal.entries) do
    if candidate == entry then
      table.remove(journal.entries, index)
      local saved, err = journal_save(journal)
      -- A release that did not persist must not silently free the reservation:
      -- restore it when the caller asked for a conservative failure.
      if not saved and options and options.restore then
        table.insert(journal.entries, index, entry)
      end
      recheck_full(journal)
      return saved, err
    end
  end
  return true
end

local function journal_suppresses(journal, recipient_id, message_id)
  ensure_loaded(journal)
  -- A corrupt journal owns no known ID. Admission still queues the notice, and
  -- the dispatch itself fails closed with an explicit reason and alert.
  return journal_find(journal, recipient_id, message_id) ~= nil
end

local function all_read(ids, is_read)
  for _, id in ipairs(ids) do
    local ok, read = pcall(is_read, id)
    if not ok or not read then return false end
  end
  return true
end

local function journal_prune_accepted(journal, recipient_id, is_read)
  local result = { removed = 0, saved = true }
  if type(is_read) ~= "function" then return result end
  local kept = {}
  for _, entry in ipairs(journal.entries) do
    local drop = entry.state == "accepted_unread" and entry.recipient_id == recipient_id
      and all_read(entry.message_ids, is_read)
    if drop then result.removed = result.removed + 1 else kept[#kept + 1] = entry end
  end
  if result.removed == 0 then return result end
  journal.entries = kept
  result.saved, result.error = journal_save(journal)
  recheck_full(journal)
  return result
end

local function journal_status(journal, now)
  now = now or journal.now()
  local counts = { dispatching = 0, uncertain = 0, accepted_unread = 0 }
  local oldest, items = nil, {}
  for _, entry in ipairs(journal.entries) do
    counts[entry.state] = (counts[entry.state] or 0) + 1
    local age = math.max(0, now - entry.created)
    if not oldest or age > oldest then oldest = age end
    if #items < MAX_STATUS_ITEMS then
      items[#items + 1] = { recipient_id = entry.recipient_id,
        message_ids = entry.message_ids, state = entry.state,
        age_seconds = age, reason = entry.reason }
    end
  end
  return { usable = journal.corrupt == nil and journal.blocked == nil
      and not journal.full and not journal.digests_unverified,
    corrupt = journal.corrupt, blocked = journal.blocked, full = journal.full,
    digests_unverified = journal.digests_unverified,
    entries = #journal.entries,
    dispatching = counts.dispatching, uncertain = counts.uncertain,
    accepted_unread = counts.accepted_unread, oldest_seconds = oldest, items = items }
end

local function journal_state_of(journal, recipient_id, message_id)
  local entry = journal_find(journal, recipient_id, message_id)
  return entry and entry.state or nil
end

local function runtime_hash(body)
  local approval = remuda.butler and remuda.butler.guard_approval
  if approval and type(approval.sha256) == "function" then return approval.sha256(body) end
  return nil, "hash_unavailable"
end

local function runtime_json()
  return remuda.json
end

function M.new(options)
  options = options or {}
  local journal = {
    path = assert(options.path, "delivery journal path is required"),
    now = options.now or os.time,
    read = assert(options.read, "delivery journal read seam is required"),
    write = assert(options.write, "delivery journal write seam is required"),
    json = options.json or runtime_json(),
    hash = options.hash or runtime_hash,
    is_current = options.is_current,
    cap_bytes = options.cap_bytes or DEFAULT_CAP_BYTES,
    entries = {}, loaded = false, corrupt = nil, blocked = nil, full = false,
    digests_unverified = false,
  }
  journal.load = function() return journal_load(journal) end
  journal.begin = function(record) return journal_begin(journal, record) end
  journal.mark = function(entry, state, reason) return journal_mark(journal, entry, state, reason) end
  journal.retire = function(entry, options) return journal_retire(journal, entry, options) end
  journal.find = function(recipient_id, message_id) return journal_find(journal, recipient_id, message_id) end
  journal.suppresses = function(recipient_id, message_id)
    return journal_suppresses(journal, recipient_id, message_id)
  end
  journal.prune_accepted = function(recipient_id, is_read)
    return journal_prune_accepted(journal, recipient_id, is_read)
  end
  journal.status = function(now) return journal_status(journal, now) end
  journal.state_of = function(recipient_id, message_id)
    return journal_state_of(journal, recipient_id, message_id)
  end
  journal.current = function() return journal_is_current(journal) end
  return journal
end

-- Production instance: one private file beside the Butler data lock. M.new is
-- pure through its seams; this wiring is skipped by standalone tests without a
-- data home.
local function production_read(path, limit)
  local file, err = io.open(path, "r")
  if not file then
    if tostring(err or ""):lower():find("no such file", 1, true) then return nil, "missing" end
    return nil, tostring(err or "open_failed")
  end
  local size = file:seek("end")
  if type(limit) == "number" and type(size) == "number" and size > limit then
    file:close()
    return nil, "too_large"
  end
  file:seek("set", 0)
  local text = file:read("*a")
  file:close()
  return text
end

local function production_write(path, text)
  -- Require the core's atomic-private writer directly. guard.write_private has
  -- a plain io.open fallback for old cores, which is not good enough here: a
  -- journal that may not be atomic or 0600 must not accept a dispatch.
  local fs = remuda.fs
  if not (fs and type(fs.write_atomic) == "function") then
    return false, "no atomic-private writer"
  end
  local ok, result, detail = pcall(fs.write_atomic, path, text, { private = true })
  if not ok then return false, tostring(result) end
  if result ~= true then return false, tostring(detail or result or "write refused") end
  return true
end

local function install_production_instance()
  local paths = remuda._butler_paths
  if not (paths and type(paths.data_home) == "string" and paths.data_home ~= "") then return end
  local directory = paths.data_home .. "/remuda/butler"
  local path = directory .. "/delivery-journal"
  if remuda.mkdir then pcall(remuda.mkdir, directory) end
  local instance
  instance = M.new({ path = path, read = production_read, write = production_write,
    is_current = function() return remuda._butler_delivery_journal == instance end })
  remuda._butler_delivery_journal = instance
  local loaded, err = instance.load()
  if not loaded and err then instance.blocked = tostring(err) end
end

remuda.butler = remuda.butler or {}
remuda.butler.delivery_journal = M
install_production_instance()
return M
