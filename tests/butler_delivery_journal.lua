-- Run from the repository root: luajit tests/butler_delivery_journal.lua
-- Pure delivery journal: durable DISPATCHING/UNCERTAIN, bounded bytes,
-- fail-closed save/corruption, reservations, native accepted_unread and PTY
-- accepted retirement. Storage, clock, codec and hash are injected; no daemon.
local files, writes = {}, 0
local failing, replaced = false, false
local now = 1000

local function read_seam(path)
  if files[path] == nil then return nil, "missing" end
  return files[path]
end

local function write_seam(path, text)
  if replaced then return false, "journal_replaced" end
  if failing then return false, "disk full" end
  files[path] = text
  writes = writes + 1
  return true
end

local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" then
    if value ~= value then return "(0/0)" end
    if value == math.huge then return "(1/0)" end
    if value == -math.huge then return "(-1/0)" end
    return tostring(value)
  end
  if kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

-- Test-only codec; production injects the core's real remuda.json.
local codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
  array = function(value) return value end,
  object = function(value) return value end,
}

local function fake_hash(body) return string.format("%x", #body) end

remuda = {}
local module = dofile("packages/butler/delivery_journal.lua")

local function journal(options)
  options = options or {}
  options.path = options.path or "journal"
  options.read = read_seam
  options.write = write_seam
  options.now = function() return now end
  options.hash = fake_hash
  options.json = codec
  if options.is_current == nil then options.is_current = function() return not replaced end end
  return module.new(options)
end

local function record(id, message_ids, protocol)
  return { recipient_id = id, message_ids = message_ids, protocol = protocol or "pty",
    instance = "instance-1", body = "Butler message " .. message_ids[1] .. " arrived." }
end

local function fresh() return journal() end

-- 1. DISPATCHING is persisted before any dispatch and suppresses re-entry.
local j = fresh()
local entry, err = j.begin(record("lead", { "m1" }))
assert(entry and not err, "begin succeeds: " .. tostring(err))
assert(j.state_of("lead", "m1") == "dispatching", "begin records dispatching")
assert(writes == 1, "begin wrote the journal exactly once")
local again, why = j.begin(record("lead", { "m1" }))
assert(again == nil and why == "already_reserved: dispatching",
  "a re-entrant begin for the same mail is refused: " .. tostring(why))
assert(writes == 1, "a refused begin does not write")
local other = j.begin(record("lead", { "m2" }))
assert(other, "a different message id is not reserved")
j.retire(other)

-- 2. Accepted PTY retires its entry, so legacy reminders are not suppressed.
local accepted = j.begin(record("lead", { "m3" }))
assert(accepted, "begin accepted-pty")
assert(j.retire(accepted) == true, "retire saves")
assert(j.find("lead", "m3") == nil and j.suppresses("lead", "m3") == false,
  "a known-accepted PTY entry is retired, not treated as uncertainty")

-- 3. UNCERTAIN survives a canonical READ and stuck closure (nothing clears it).
local uncertain = j.begin(record("lead", { "m4" }))
assert(uncertain, "begin uncertain")
assert(j.mark(uncertain, "uncertain", "submission is unconfirmed") == true, "mark uncertain saves")
assert(j.suppresses("lead", "m4") == true, "uncertain suppresses")
assert(j.state_of("lead", "m4") == "uncertain", "state stays uncertain after a read")
local blocked_retry, retry_why = j.begin(record("lead", { "m4" }))
assert(blocked_retry == nil and retry_why == "already_reserved: uncertain",
  "an uncertain id is never retried: " .. tostring(retry_why))
local next_id = j.begin(record("lead", { "m5" }))
assert(next_id, "new ids are still admitted beside an uncertain one")
j.retire(next_id)

-- 4. A fresh object reconstructed from the persisted bytes keeps uncertainty.
local rebuilt = fresh()
assert(rebuilt.load() == true, "fresh journal loads")
assert(rebuilt.state_of("lead", "m4") == "uncertain", "uncertainty survives reconstruction")
assert(rebuilt.suppresses("lead", "m4") == true, "suppression survives reconstruction")

-- 5. A new instance/nonce for the same recipient+message stays reserved.
local reshow = rebuilt.begin({ recipient_id = "lead", message_ids = { "m4" }, protocol = "pty",
  instance = "instance-2", nonce = "nonce-2", body = "re-shown after compaction" })
assert(reshow == nil, "new instance/nonce cannot restart an uncertain id")

-- 6. Crash before ACK: persisted DISPATCHING becomes UNCERTAIN at load.
local crash = fresh()
assert(crash.begin(record("lead", { "m6" })), "dispatch then crash")
local restarted = fresh()
assert(restarted.load() == true, "restart loads")
assert(restarted.state_of("lead", "m6") == "uncertain", "restart turns dispatching into uncertain")
assert(files.journal:find("restart_before_ack", 1, true) ~= nil,
  "the conversion itself is persisted")

-- 7. If the boot conversion cannot persist, the journal is globally blocked.
local crash2 = journal({ path = "bootfail" })
assert(crash2.begin(record("lead", { "m7" })), "dispatch then crash again")
failing = true
local blocked = journal({ path = "bootfail" })
local loaded, load_err = blocked.load()
assert(loaded == false and tostring(load_err):find("boot_recovery_save_failed", 1, true) ~= nil,
  "boot conversion save failure is reported: " .. tostring(load_err))
assert(blocked.status().blocked ~= nil, "the journal reports its blocked state")
local denied, denied_why = blocked.begin(record("other", { "m8" }))
assert(denied == nil and tostring(denied_why):find("save", 1, true) ~= nil,
  "global fail-closed: even a different recipient cannot dispatch: " .. tostring(denied_why))
failing = false
assert(blocked.begin(record("other", { "m8" })) ~= nil, "a later successful save recovers the journal")

-- 8. A failed save during DISPATCHING writes nothing.
local save_fail = journal({ path = "savefail" })
failing = true
local failed_begin, failed_why = save_fail.begin(record("lead", { "m9" }))
assert(failed_begin == nil and failed_why == "save_failed: disk full",
  "failed DISPATCHING save refuses the dispatch: " .. tostring(failed_why))
assert(save_fail.find("lead", "m9") == nil, "a failed begin rolls back its in-memory entry")
assert(files.savefail == nil, "a failed begin leaves no bytes")
failing = false
assert(save_fail.begin(record("lead", { "m9" })) ~= nil, "a later save admits the dispatch")

-- 8b. A writer that returns nil (even with a detail) has not acknowledged a
-- durable write, so the dispatch must not happen.
local silent = module.new({ path = "silent", read = read_seam,
  write = function() return nil, "disk failure" end,
  now = function() return now end, hash = fake_hash, json = codec })
local silent_begin, silent_why = silent.begin(record("lead", { "sil1" }))
assert(silent_begin == nil and tostring(silent_why):find("save_failed", 1, true) ~= nil,
  "a nil writer result is not a durable acknowledgement: " .. tostring(silent_why))
assert(silent.status().usable == false, "a failed journal is not usable")
local silent_again = module.new({ path = "silent2", read = read_seam,
  write = function() return nil end, now = function() return now end,
  hash = fake_hash, json = codec })
assert(silent_again.begin(record("lead", { "sil2" })) == nil,
  "a bare nil writer result also refuses the dispatch")

-- 9. No small message-id count cap: a 128-id backlog is one valid attempt.
local backlog = journal({ path = "backlog" })
local many = {}
for index = 1, 128 do many[index] = "m" .. index end
local many_entry = backlog.begin(record("lead", many))
assert(many_entry, "128 message ids are admitted (no arbitrary count cap)")
assert(#many_entry.message_ids == 128, "all 128 ids are journaled")
assert(backlog.suppresses("lead", "m128") == true, "the tail id is reserved too")

-- 10. The global byte cap refuses before any write and never evicts.
local cap = journal({ path = "cap" })
local first = cap.begin(record("lead", { "b1" }))
assert(first, "first entry fits")
assert(cap.mark(first, "uncertain", "lost ack") == true, "uncertain persists")
local limit = #files.cap
local bounded = journal({ path = "cap", cap_bytes = limit })
assert(bounded.load() == true, "bounded journal loads")
local full, full_why = bounded.begin(record("lead", { "b2" }))
assert(full == nil and full_why == "journal_full", "byte cap refuses: " .. tostring(full_why))
assert(bounded.state_of("lead", "b1") == "uncertain", "no eviction of the uncertain entry")
-- Full is a GLOBAL fail-closed gate: a smaller dispatch cannot slip past it.
assert(bounded.status().full == true and bounded.status().usable == false,
  "a full journal is not usable")
local smaller, smaller_why = bounded.begin(record("a", { "c3" }))
assert(smaller == nil and smaller_why == "journal_full",
  "no smaller bypass while the journal is full: " .. tostring(smaller_why))
-- Retiring an entry frees capacity and reopens the gate.
local existing = bounded.find("lead", "b1")
assert(existing and bounded.retire(existing) == true, "retire frees capacity")
assert(bounded.status().full == false and bounded.status().usable == true,
  "capacity recovery reopens the journal")
assert(bounded.begin(record("a", { "c3" })) ~= nil, "a dispatch fits after recovery")

-- 11. Corruption fails closed and is never silently reset.
files.corrupt = "not a journal\n"
local corrupt = journal({ path = "corrupt" })
assert(corrupt.load() == false, "corruption is reported")
assert(corrupt.status().corrupt ~= nil, "status exposes corruption")
assert(corrupt.begin(record("lead", { "d1" })) == nil, "a corrupt journal blocks dispatch")
assert(corrupt.suppresses("lead", "d1") == false,
  "a corrupt journal owns no IDs; dispatch, not admission, fails closed")

-- 11b. The decode path enforces the same constraints as the write path.
files.badstate = codec.encode({ version = 1, entries = { { state = "sent", protocol = "pty",
  recipient_id = "lead", message_ids = { "x1" }, body = "b", body_sha256 = "ab",
  created = 1, updated = 1 } } })
local badstate = journal({ path = "badstate" })
assert(badstate.load() == false, "an invalid decoded state is corruption, not acceptance")

-- 11c. Strict schema: object-shaped entries, duplicates, digest mismatch and
-- non-finite times are corruption, not a usable empty/mtime journal.
local function persisted(entries)
  return codec.encode({ version = 1, entries = entries })
end
local function persisted_entry(recipient, id, body, extra)
  local entry = { state = "uncertain", protocol = "pty", recipient_id = recipient,
    message_ids = { id }, body = body, body_sha256 = fake_hash(body),
    created = 10, updated = 10 }
  for key, value in pairs(extra or {}) do entry[key] = value end
  return entry
end
files.schemaobj = persisted({ hidden = persisted_entry("lead", "h1", "body") })
local schemaobj = journal({ path = "schemaobj" })
assert(schemaobj.load() == false and schemaobj.status().corrupt ~= nil,
  "an object-shaped entries map is corruption, not an empty list")
assert(schemaobj.begin(record("lead", { "h2" })) == nil,
  "a malformed journal admits no new dispatch")

files.duplicate = persisted({ persisted_entry("lead", "d1", "body"),
  persisted_entry("lead", "d1", "other body") })
local duplicate = journal({ path = "duplicate" })
assert(duplicate.load() == false, "a duplicate recipient/message id is corruption")

files.digest = persisted({ persisted_entry("lead", "g1", "body", { body_sha256 = "dead" }) })
local digest = journal({ path = "digest" })
assert(digest.load() == false, "a body digest mismatch is corruption")

files.nonfinite = persisted({ persisted_entry("lead", "n2", "body", { created = math.huge }) })
local nonfinite = journal({ path = "nonfinite" })
assert(nonfinite.load() == false, "a non-finite timestamp is corruption")

local big_path = "big"
files[big_path] = string.rep("x", 200)
local too_big = journal({ path = big_path, cap_bytes = 60 })
local too_big_ok, too_big_why = too_big.load()
assert(too_big_ok == false and tostring(too_big_why):find("file_too_large", 1, true) ~= nil,
  "a file over the byte cap is rejected before decoding: " .. tostring(too_big_why))

-- 11d. Production boot order: the journal loads before guard_approval (the
-- hash module). A valid nonempty persisted journal must not be called corrupt
-- while the hash is absent; verification is deferred and gates the first
-- dispatch once the real hash is available.
local order_body = "Butler message o1 arrived."
files.order = codec.encode({ version = 1, entries = {
  persisted_entry("lead", "o1", order_body) } })
remuda.butler.guard_approval = nil
local orderless = module.new({ path = "order", read = read_seam, write = write_seam,
  now = function() return now end, json = codec })
assert(orderless.load() == true, "a valid journal loads without the hash module")
assert(orderless.status().corrupt == nil, "missing hash is not corruption at load")
assert(orderless.status().digests_unverified == true, "digest verification is deferred")
assert(orderless.status().usable == false, "an unverified journal is not dispatch-ready")
local early, early_why = orderless.begin(record("lead", { "o2" }))
assert(early == nil and early_why == "hash_unavailable",
  "no dispatch before the hash module is available: " .. tostring(early_why))
remuda.butler.guard_approval = { sha256 = fake_hash }
local late, late_why = orderless.begin(record("lead", { "o2" }))
assert(late ~= nil, "the first dispatch verifies and proceeds once the hash exists: "
  .. tostring(late_why))
assert(orderless.status().digests_unverified == false, "verification clears the deferral")

files.order_bad = codec.encode({ version = 1, entries = {
  persisted_entry("lead", "o3", "tampered", { body_sha256 = "dead" }) } })
remuda.butler.guard_approval = nil
local tampered = module.new({ path = "order_bad", read = read_seam,
  write = write_seam, now = function() return now end, json = codec })
assert(tampered.load() == true, "a deferred-digest journal still loads")
remuda.butler.guard_approval = { sha256 = fake_hash }
local tampered_begin, tampered_why = tampered.begin(record("lead", { "o4" }))
assert(tampered_begin == nil and tostring(tampered_why):find("body_digest", 1, true) ~= nil,
  "a tampered digest blocks the first dispatch: " .. tostring(tampered_why))

-- 11e. Generation fence: a reload (is_current false) during the persist call
-- must not let the old continuation dispatch; the replacement journal recovers
-- the persisted DISPATCHING as UNCERTAIN and keeps it reserved.
local live = true
local fenced = module.new({ path = "fence", read = read_seam,
  write = function(path, text) files[path] = text; live = false; return true end,
  now = function() return now end, hash = fake_hash, json = codec,
  is_current = function() return live end })
local fenced_entry, fenced_why = fenced.begin(record("lead", { "f1" }))
assert(fenced_entry == nil and fenced_why == "journal_replaced",
  "a reload during the persist call refuses the dispatch: " .. tostring(fenced_why))
assert(fenced.status().blocked ~= nil, "the stale generation is blocked, not usable")
local replacement = module.new({ path = "fence", read = read_seam, write = write_seam,
  now = function() return now end, hash = fake_hash, json = codec })
assert(replacement.load() == true, "the replacement journal loads the written bytes")
assert(replacement.state_of("lead", "f1") == "uncertain",
  "boot recovery keeps the stale attempt reserved as uncertain")
assert(replacement.begin(record("lead", { "f1" })) == nil,
  "the replacement never dispatches the reserved id")
local stale_mark, stale_mark_why = fenced.mark(fenced_entry or { state = "dispatching" },
  "uncertain", "late")
assert(stale_mark == false and stale_mark_why == "journal_replaced",
  "a stale generation cannot mark through the replacement journal")

-- 12. Native accepted_unread suppresses until the canonical read.
local native = journal({ path = "native" })
local accepted_native = native.begin(record("lead", { "n1" }, "native"))
assert(accepted_native, "native begin")
assert(native.mark(accepted_native, "accepted_unread", "native accepted") == true, "native accepted saves")
assert(native.suppresses("lead", "n1") == true, "accepted native still suppresses duplicates")
local unread_prune = native.prune_accepted("lead", function() return false end)
assert(unread_prune.removed == 0, "unread mail keeps its accepted entry")
local read_prune = native.prune_accepted("lead", function() return true end)
assert(read_prune.removed == 1 and read_prune.saved == true, "canonical read releases the entry")
assert(native.suppresses("lead", "n1") == false, "read releases suppression")

-- 13. A replaced module generation cannot rewrite the journal.
local stale = journal({ path = "stale" })
replaced = true
local stale_begin, stale_why = stale.begin(record("lead", { "r1" }))
assert(stale_begin == nil and stale_why == "journal_replaced",
  "a replaced module fails closed: " .. tostring(stale_why))
replaced = false

-- 14. Status is bounded and carries IDs/reasons only, never the frozen body.
local status = rebuilt.status(now + 90)
assert(status.uncertain >= 1, "status counts uncertain entries")
assert(status.oldest_seconds >= 90, "status reports age")
assert(status.items[1].recipient_id == "lead" and type(status.items[1].message_ids) == "table",
  "status carries recipient and message ids")
local dumped = table.concat({ status.items[1].state, status.items[1].reason,
  status.items[1].recipient_id }, " ")
assert(not dumped:find("Butler message", 1, true), "status never carries the frozen body")

-- 15. Validation refuses malformed records and missing crypto explicitly.
local strict = journal({ path = "strict" })
local bad_ids, bad_ids_why = strict.begin(record("lead", { "bad id" }))
assert(bad_ids == nil and bad_ids_why == "invalid_message_id", "invalid message id")
local no_ids, no_ids_why = strict.begin({ recipient_id = "lead", message_ids = {}, protocol = "pty" })
assert(no_ids == nil and no_ids_why == "no_message_ids", "empty ids")
local map_ids, map_ids_why = strict.begin({ recipient_id = "lead",
  message_ids = { [1] = "x1", hidden = "x2" }, protocol = "pty", body = "b" })
assert(map_ids == nil and map_ids_why == "message_ids_schema",
  "a message_ids map key is refused: " .. tostring(map_ids_why))
local hole_ids, hole_ids_why = strict.begin({ recipient_id = "lead",
  message_ids = { [1] = "x1", [3] = "x3" }, protocol = "pty", body = "b" })
assert(hole_ids == nil and hole_ids_why == "message_ids_schema",
  "a hole in message_ids is refused: " .. tostring(hole_ids_why))
remuda.butler.guard_approval = nil
local no_hash = module.new({ path = "hashless", read = read_seam, write = write_seam,
  now = function() return now end, json = codec })
local hashless, hashless_why = no_hash.begin(record("lead", { "h1" }))
assert(hashless == nil and hashless_why == "hash_unavailable",
  "no crypto means no dispatch: " .. tostring(hashless_why))
local no_codec = module.new({ path = "jsonless", read = read_seam, write = write_seam,
  now = function() return now end, hash = fake_hash, json = nil })
local jsonless, jsonless_why = no_codec.begin(record("lead", { "j1" }))
assert(jsonless == nil and jsonless_why == "codec_unavailable",
  "no codec means no dispatch: " .. tostring(jsonless_why))

-- 16. The frozen body is exact and the persisted digest covers it.
local exact = journal({ path = "exact" })
local body = "Butler message e1 from alice arrived."
assert(exact.begin({ recipient_id = "lead", message_ids = { "e1" }, protocol = "pty",
  body = body }), "exact body begin")
local persisted = codec.decode(files.exact)
assert(persisted.entries[1].body == body, "body is persisted exactly")
assert(persisted.entries[1].body_sha256 == fake_hash(body), "body digest is persisted")

print("ok - delivery journal is durable, bounded, reserved and fail-closed")
