-- QA owner for the shadow relay intake module.
--
-- The shell wrapper copies this over packages/butler/init.lua in a disposable
-- tree. Each case opens a distinct disposable relay DB through the product
-- module; no real relay database or event path is used.
local host = getmetatable(_G).__index.remuda
assert(assert(loadfile('tests/lib/isolated_test.lua'))()(host))

local cases = {}
local function case(name, run) cases[#cases + 1] = { name = name, run = run } end

local function number(db, sql, args)
  local result, err = db:query(sql, args or {})
  assert(result, err)
  return tonumber(result[1].n)
end

local function event(id, payload, room)
  return { event_id = id, room_id = room or "room", payload_json = payload or id }
end

local function reset()
  local db = assert(host.db.open("relay", { migrations = true }))
  for _, table_name in ipairs({ "relay_inbound", "relay_outbox",
    "relay_dedupe", "relay_cursor" }) do
    assert(db:exec("DELETE FROM " .. table_name))
  end
  pcall(db.close, db)
end

local function load(limits, opener)
  host._butler_relay_intake_config = {
    open = opener or host.db.open, name = "relay", limits = limits,
  }
  return assert(loadfile('packages/butler/relay_intake.lua'))()
end

-- A real handle whose ROLLBACK fails, to prove the module disposes instead of
-- reusing a handle with an unknown transaction state.
local function failing_rollback_open(name, opts)
  local db = assert(host.db.open(name, opts))
  return setmetatable({}, { __index = function(_, key)
    if key == "exec" then
      return function(_, sql, args)
        if sql == "ROLLBACK" then return nil, "injected rollback failure" end
        return db:exec(sql, args)
      end
    elseif key == "query" then
      return function(_, sql, args) return db:query(sql, args) end
    elseif key == "close" then
      return function(_) return db:close() end
    end
    return nil
  end })
end

case("admit advances the cursor and dedupes identity", function(index)
  reset()
  local M = load()
  local stats = assert(M.admit({ event("e1"), event("e2") }, "s1", 100))
  assert(stats.inserted == 2 and stats.duplicates == 0)
  assert(M.cursor() == "s1")
  local db = assert(host.db.open("relay", { migrations = true }))
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 2)
  local again = assert(M.admit({ event("e1") }, "s2", 101))
  assert(again.inserted == 0 and again.duplicates == 1)
  assert(M.cursor() == "s2")
  local conflict, why = M.admit({ event("e1", "changed") }, "bad", 102)
  assert(not conflict and why == "identity conflict")
  assert(M.cursor() == "s2")
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 2)
  pcall(db.close, db)
  M.close()
end)
case("row cap rolls back a partially inserted batch", function(index)
  reset()
  local M = load({ unresolved_max_rows = 2 })
  assert(M.admit({ event("e1") }, "s1", 100))
  -- e2 fits, e3 exceeds the cap: the whole batch, including e2, rolls back.
  local full, why = M.admit({ event("e2"), event("e3") }, "bad", 101)
  assert(not full and why == "backpressure: unresolved")
  assert(M.cursor() == "s1")
  local db = assert(host.db.open("relay", { migrations = true }))
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 1)
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound " ..
    "WHERE event_id = 'e2'") == 0)
  pcall(db.close, db)
  M.close()
end)
case("payload-byte cap rolls back a partially inserted batch", function(index)
  reset()
  local M = load({ unresolved_max_rows = 10, unresolved_max_payload_bytes = 12 })
  assert(M.admit({ event("e1", string.rep("x", 6)) }, "s1", 100))
  -- 6 + 4 fits, the second 4 exceeds 12: both new rows and the cursor roll back.
  local full, why = M.admit({ event("e2", string.rep("y", 4)),
    event("e3", string.rep("z", 4)) }, "bad", 101)
  assert(not full and why == "backpressure: payload bytes")
  assert(M.cursor() == "s1")
  local db = assert(host.db.open("relay", { migrations = true }))
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 1)
  assert(M.status().unresolved_payload_bytes == 6)
  pcall(db.close, db)
  M.close()
end)

case("a sparse or malformed batch is rejected before the cursor", function(index)
  reset()
  local M = load()
  local sparse, why = M.admit({ [1] = event("e1"), [3] = event("e3") }, "bad", 100)
  assert(not sparse and why == "events must be a dense list")
  local nil_batch, nil_why = M.admit(nil, "bad", 100)
  assert(not nil_batch and nil_why == "events must be a list")
  local string_batch, string_why = M.admit("x", "bad", 100)
  assert(not string_batch and string_why == "events must be a list")
  local db = assert(host.db.open("relay", { migrations = true }))
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 0)
  assert(M.cursor() == nil)
  pcall(db.close, db)
  M.close()
end)

case("a failed rollback disposes the handle", function(index)
  reset()
  local M = load(nil, failing_rollback_open)
  assert(M.admit({ event("e1") }, "s1", 100))
  local failed, why = M.admit({ event("e2") }, 42, 101)
  assert(not failed and why == "rollback: invalid cursor")
  assert(M.status().available == false)
  local db = assert(host.db.open("relay", { migrations = true }))
  assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound") == 1)
  pcall(db.close, db)
  M.close()
end)

case("reopen keeps the cursor and rows", function(index)
  reset()
  local M = load()
  assert(M.admit({ event("e1") }, "s1", 100))
  M.close()
  local reopened = load()
  assert(reopened.cursor() == "s1")
  assert(reopened.status().unresolved == 1)
  reopened.close()
end)

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = function()
    for index, item in ipairs(cases) do
      local ok, why = pcall(item.run, index)
      if not ok then error(item.name .. ": " .. tostring(why), 0) end
      print("ok - " .. item.name)
    end
  end,
}
