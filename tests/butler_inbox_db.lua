-- Focused inbox index tests: fake SQLite handle, real temp files, no daemon.
local function run(command)
  local ok = os.execute(command)
  return ok == true or ok == 0
end
remuda = {
  fs = { mkdir_new = function(path)
    if run("mkdir '" .. path .. "'") then return true end
    return nil, "exists"
  end },
  mkdir = function(path) assert(run("mkdir -p '" .. path .. "'")); return true end,
  remove_dir_all = function(path) assert(run("rm -rf '" .. path .. "'")) end,
}

local events = {}

local function report(subsystem, outcome, reason)
  events[#events + 1] = { subsystem = subsystem, outcome = outcome, reason = reason }
end

local function fake_db(options)
  local db = { calls = {}, fail_insert = options and options.fail_insert, offsets = {} }
  function db:exec(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail_insert and sql:find("INSERT", 1, true) then error("synthetic disk full") end
    if sql:find("INSERT OR REPLACE INTO import_state", 1, true) then
      db.offsets[params[1] .. ":" .. params[2]] = params[3]
    end
    return 1
  end
  function db:query(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if sql:find("FROM import_state", 1, true) then
      local offset = db.offsets[params[1] .. ":" .. params[2]]
      if offset then return { { offset = offset } } end
      return {}
    end
    return { { n = 1 } }
  end
  return db
end

local function load(open, root)
  remuda._butler_inbox_db_config = { root = root, open = open }
  remuda._butler_diagnostics = { record = report }
  dofile("packages/butler/inbox_db.lua")
  return remuda._butler_inbox_db
end

local function find_call(db, needle)
  for _, call in ipairs(db.calls) do
    if call.sql:find(needle, 1, true) then return call end
  end
  return nil
end

local function count_calls(db, needle)
  local n = 0
  for _, call in ipairs(db.calls) do
    if call.sql:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

-- Open failure is sticky and never raises; mail can continue file-only.
local denied = load(function() return nil, "too_large: over quota" end, nil)
assert(denied.available() == false, "a failed open leaves the index unavailable")
local wrote, why = denied.deliver("agent", "m1")
assert(wrote == nil and tostring(why):find("too_large", 1, true), "open failure is returned, not raised")
assert(#events == 1 and events[1].outcome == "error", "open failure is diagnosed once")

-- Delivery and read rows use the stable hex mailbox component.
events = {}
local db = fake_db()
local index = load(function() return db end, nil)
assert(index.deliver("a/b", "m1") == true, "delivery succeeds")
local delivery = find_call(db, "INSERT OR IGNORE INTO deliveries")
assert(delivery, "delivery insert exists")
assert(delivery.params[1] == "612f62", "recipient is hex encoded: " .. tostring(delivery.params[1]))
assert(delivery.params[2] == "m1", "message id is bound")
assert(delivery.params[3] == "612f62", "max(seq) is scoped to the recipient")
assert(delivery.sql:find("COALESCE(MAX(seq), 0) + 1", 1, true), "sequence is allocated in SQL")

assert(index.read("a/b", "m2") == true, "read succeeds")
local read = find_call(db, "INSERT OR IGNORE INTO reads")
assert(read and read.params[1] == "612f62" and read.params[2] == "m2", "read row binds recipient and id")

-- A DB write failure is diagnosed and returns nil, never escaping into mail.
events = {}
local broken = fake_db({ fail_insert = true })
local failing = load(function() return broken end, nil)
local ok, err = failing.deliver("agent", "m3")
assert(ok == nil and tostring(err):find("disk full", 1, true), "write failure is returned")
assert(#events == 1 and events[1].reason == "delivery_write", "write failure is diagnosed")

-- Import scans existing inbox/read files and is safe to repeat.
local root = os.tmpname(); os.remove(root)
assert(remuda.fs.mkdir_new(root))
assert(remuda.mkdir(root .. "/inboxes"))
assert(remuda.mkdir(root .. "/read"))
local function put(path, text)
  local file = assert(io.open(path, "w")); assert(file:write(text)); assert(file:close())
end
put(root .. "/inboxes/612f62.jsonl", '{"message_id":"m1"}\n{"message_id":"m2"}\n')
put(root .. "/read/612f62.jsonl", "m1\nm2\n")
remuda.list_dir = function(path)
  if path == root .. "/inboxes" then return { "612f62.jsonl", "notes.txt" } end
  error("missing: " .. path)
end
events = {}
local import_db = fake_db()
local imported = load(function() return import_db end, root)
assert(imported.import_all() == true, "import succeeds")
assert(imported.available(), "import opened the index")
assert(count_calls(import_db, "BEGIN IMMEDIATE") == 1, "one transaction per recipient file")
assert(count_calls(import_db, "INSERT OR IGNORE INTO deliveries") == 2, "two delivery rows")
assert(count_calls(import_db, "INSERT OR IGNORE INTO reads") == 2, "two read rows")
assert(find_call(import_db, "rollback") == nil, "no rollback on success")
assert(imported.import_all() == true, "a second import is safe")
assert(count_calls(import_db, "INSERT OR IGNORE INTO deliveries") == 2,
  "an unchanged log imports nothing twice")
assert(count_calls(import_db, "INSERT OR IGNORE INTO reads") == 2,
  "an unchanged read log imports nothing twice")

-- A torn tail line is not consumed; completing it indexes it on the next boot.
local append = assert(io.open(root .. "/inboxes/612f62.jsonl", "a"))
assert(append:write('{"message_id":"m3"}'))
assert(append:close())
assert(imported.import_all() == true, "partial tail import succeeds")
assert(count_calls(import_db, "INSERT OR IGNORE INTO deliveries") == 2,
  "a line without its newline stays untouched")
append = assert(io.open(root .. "/inboxes/612f62.jsonl", "a"))
assert(append:write("\n"))
assert(append:close())
assert(imported.import_all() == true, "completed tail import succeeds")
assert(count_calls(import_db, "INSERT OR IGNORE INTO deliveries") == 3,
  "the completed line is imported once")

remuda.remove_dir_all(root)
print("ok")
