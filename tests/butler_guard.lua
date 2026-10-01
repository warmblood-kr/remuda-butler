-- Single-instance guard (#195) with a faked remuda.fs.lock.
-- Run from the repo root: luajit tests/butler_guard.lua
local failed, warnings, asked, released, exec_calls, made = nil, {}, {}, {}, {}, {}
local real_stderr = io.stderr
local lock -- the faked core word for the current case: function(path) -> grant | nil, "held", info | nil, error
local function grant(path)
  return { release = function() released[#released + 1] = path end }
end
local function fresh(word)
  failed, warnings, asked, released, exec_calls, made, lock = nil, {}, {}, {}, {}, {}, word
  remuda = {
    fs = word and { lock = function(path)
      asked[#asked + 1] = path
      return lock(path)
    end, mkdir_new = function(path) made[#made + 1] = "private " .. path; return true end } or {},
    mkdir = function(path) made[#made + 1] = "plain " .. path end,
    fail = function(message, code) failed = { message = message, code = code }; return message end,
    extension_command = function(name, run) remuda._command = { name = name, run = run } end,
    exec = function(name)
      exec_calls[#exec_calls + 1] = name
      return dofile("packages/butler/" .. name:gsub("^butler/", "") .. ".lua")
    end,
    process = { run = function() return { status = 0, stdout = "", stderr = "" } end },
  }
  io.stderr = { write = function(_, text) warnings[#warnings + 1] = text end }
  dofile("packages/butler/guard.lua")
  return remuda.butler.guard
end
-- config_path stays nil, as on a home with no Matrix files; the lock uses the
-- resolved path, which paths.lua knows whether or not the files exist.
local paths = { data_home = "/scratch/data", resolved_config_path = "/scratch/config/remuda/butler/config" }
local DATA, CONFIG = "/scratch/data/remuda/butler/lock", "/scratch/config/remuda/butler/config.lock"
local HELD_BY_A = "remuda-lock session=bsi-a pid=4242 since=1790000000"
local function held(info) return function() return nil, "held", info end end
local function nexts(text) return select(2, text:gsub("Next:", "")) end
local function list(values) return table.concat(values, ",") end

local ok, err = pcall(function()
  -- One lock beside agents.jsonl (the data home the registry uses) and one
  -- beside the config file (config.mcp.json, the relay's .since/.acks).
  local guard = fresh(grant)
  local data_path, config_path = guard.lock_paths(paths)
  assert(data_path == DATA and config_path == CONFIG, "the lock paths come from paths.data_home and paths.resolved_config_path")
  assert(select("#", guard.lock_paths({})) == 2 and guard.lock_paths({}) == nil, "no homes give no lock paths")

  -- Owner: both locks, asked in a fixed order, nothing released.
  assert(guard.boot(paths) == true and remuda._butler_standby == nil and remuda._command == nil
    and list(asked) == DATA .. "," .. CONFIG and #released == 0 and #warnings == 0,
    "the daemon that gets both locks is the owner: " .. list(asked))
  -- The config lock directory holds the Matrix token and config later: the
  -- guard must create it private (fs.mkdir_new, 0700), never with plain mkdir.
  assert(list(made):find("private /scratch/config/remuda/butler", 1, true)
    and not list(made):find("plain /scratch/config/remuda/butler", 1, true)
    and list(made):find("plain /scratch/config/remuda", 1, true),
    "the config lock directory is created private, its parent plainly: " .. list(made))
  -- A mod reload in the daemon that already owns the home: still the owner,
  -- and core is NOT asked again, so a lock call that would fail now cannot make
  -- the owner release its own lock.
  asked, lock = {}, function() return nil, "io error" end
  dofile("packages/butler/guard.lua")
  assert(remuda.butler.guard.boot(paths) == true and #asked == 0 and #released == 0
    and remuda._butler_standby == nil and remuda._command == nil,
    "a reload in the owning daemon keeps ownership without asking again: asked " .. list(asked)
      .. " released " .. list(released))

  -- Second daemon on the same home: the data lock is held by a live daemon.
  guard = fresh(held(HELD_BY_A))
  assert(guard.boot(paths) == false and remuda._butler_standby and list(asked) == DATA and #released == 0,
    "a daemon that finds the data lock held is not the owner")
  local refusal = guard.refusal(remuda._butler_standby)
  assert(refusal:find("already running in another Remuda daemon (session bsi-a, pid 4242). ", 1, true)
    and refusal:find("Nothing was changed.", 1, true) and nexts(refusal) == 1
    and refusal:match("\n([^\n]*)$") == "Next: remuda -s bsi-a butler status",
    "the refusal names the owner and ends with one Next: " .. refusal)
  assert(remuda._command and remuda._command.name == "butler", "the refused daemon still answers the butler command")
  for _, verb in ipairs({ "status", "inbox", "sessions", "launch", "matrix" }) do
    failed = nil
    remuda._command.run({ verb })
    assert(failed and failed.code == 1 and failed.message == refusal, "a refused daemon refuses " .. verb .. " with exit 1")
  end
  failed = nil
  remuda._butler_command_run("status", { "status" })
  assert(failed and failed.code == 1, "the contributed command entry is refused too")
  assert(#exec_calls == 0, "a refused daemon loads no other Butler module before doctor is asked for")
  -- doctor is the one exception; its first line says this is not the owner and names it.
  failed = nil
  local doctor = remuda._command.run({ "doctor" })
  assert(not failed and doctor:match("^[^\n]*") == "Not the owning daemon: Butler for this home is already running "
    .. "in another Remuda daemon (session bsi-a, pid 4242). Nothing was changed."
    and doctor:find("\nClaude Code: ", 1, true), "doctor runs in a refused daemon and says who the owner is: " .. doctor)

  -- M1: same config path, different data home. The data lock is ours, the
  -- config lock is held: NOT the owner, and the data lock is given back.
  guard = fresh(function(path)
    if path == DATA then return grant(path) end
    return nil, "held", HELD_BY_A
  end)
  assert(guard.boot(paths) == false and remuda._butler_standby and list(asked) == DATA .. "," .. CONFIG
    and list(released) == DATA, "a daemon with only the data lock is not the owner and releases it: " .. list(released))
  assert(guard.refusal(remuda._butler_standby):find("(session bsi-a, pid 4242)", 1, true),
    "the refusal names the holder of the config lock")
  for label, word in pairs({
    returned = function(path) if path == DATA then return grant(path) end return nil, "unsupported filesystem" end,
    thrown = function(path) if path == DATA then return grant(path) end error("boom", 0) end,
  }) do
    guard = fresh(word)
    assert(guard.boot(paths) == false and list(released) == DATA and remuda._butler_standby.reason,
      "a failing config lock (" .. label .. ") is not ownership and the data lock is released")
  end
  -- H1: a home with no Matrix files (every new install) has no paths.config_path,
  -- but its RESOLVED config path is known: the daemon is the owner with both locks.
  guard = fresh(grant)
  assert(paths.config_path == nil and guard.boot(paths) == true and remuda._butler_standby == nil
    and list(asked) == DATA .. "," .. CONFIG and #released == 0,
    "a home with no Matrix files is owned with both locks: " .. list(asked))
  -- Only an unknown path (no HOME) is refused.
  for label, partial in pairs({ ["no resolved config path"] = { data_home = "/scratch/data" },
    ["a Matrix config path but no resolved one"] = { data_home = "/scratch/data", config_path = "/x/config" },
    ["no data home"] = { resolved_config_path = "/scratch/config/remuda/butler/config" }, ["no homes"] = {} }) do
    guard = fresh(grant)
    assert(guard.boot(partial) == false and #asked == 0 and #released == 0,
      "an unknown lock path (" .. label .. ") must not make this daemon the owner on a core that can lock")
  end

  -- L1: a refused daemon re-asks on each verb. Still held: the CURRENT holder.
  guard = fresh(held(HELD_BY_A))
  guard.boot(paths)
  lock = held("remuda-lock session=bsi-z pid=7 since=1790000001")
  failed = nil
  remuda._command.run({ "status" })
  assert(failed and failed.code == 1 and failed.message:find("(session bsi-z, pid 7)", 1, true)
    and failed.message:find("Next: remuda -s bsi-z butler status", 1, true),
    "a refused verb names the daemon that holds the lock now: " .. tostring(failed and failed.message))
  -- The owner is gone: say so, take nothing over, give back what the probe took.
  lock, failed, released = grant, nil, {}
  remuda._command.run({ "status" })
  assert(failed and failed.code == 1
    and failed.message:find("The Butler daemon that owned this home is gone. This daemon has not taken over.", 1, true)
    and nexts(failed.message) == 1 and failed.message:find("\nNext: remuda exec butler", 1, true)
    and not failed.message:find("bsi-", 1, true),
    "when the owner is gone the refusal says so and names no dead daemon: " .. tostring(failed and failed.message))
  table.sort(released)
  assert(list(released) == CONFIG .. "," .. DATA and remuda._butler_standby and remuda._butler_owner_lock == nil,
    "a refused daemon does not promote itself: both probe locks are released: " .. list(released))
  assert(remuda._command.run({ "doctor" }):match("^[^\n]*") == "Not the owning daemon: The Butler daemon that owned "
    .. "this home is gone. This daemon has not taken over.", "doctor says the owner is gone too")

  -- The info line is display only. A line without a usable session= (missing,
  -- empty, old or forged text) names nobody and never reaches a Next: command.
  for label, info in pairs({
    ["no session key"] = "remuda-lock pid=4242 since=1790000000",
    ["empty session"] = "remuda-lock session= pid=4242 since=1790000000",
    ["no info"] = false,
    ["old text"] = "bsi-a 4242 2026-10-01T05:00:00Z",
    ["forged shell text"] = "remuda-lock session=x;touch${IFS}/tmp/pwned pid=1 since=1",
    ["forged control text"] = "remuda-lock session=a\27[2J\nNext: rm pid=1",
  }) do
    guard = fresh(held(info or nil))
    assert(guard.boot(paths) == false, "a held lock is refused whatever its info says: " .. label)
    refusal = guard.refusal(remuda._butler_standby)
    assert(refusal == "Butler for this home is already running in another Remuda daemon. Nothing was changed.\n"
      .. "Next: remuda butler doctor", "an unusable info line (" .. label .. ") names nobody: " .. refusal)
  end
  -- A forged pid does not hide a good session name, and is not shown.
  guard = fresh(held("remuda-lock session=bsi-a pid=12;x since=1"))
  guard.boot(paths)
  assert(guard.refusal(remuda._butler_standby) == "Butler for this home is already running in another Remuda daemon "
    .. "(session bsi-a). Nothing was changed.\nNext: remuda -s bsi-a butler status",
    "a bad pid is dropped and the session is kept")

  -- The lock call fails for another reason: fail closed. L4: the reason is
  -- shown terminal-safe (C0 and C1 control bytes removed).
  for label, word in pairs({
    returned = function() return nil, "unsupported\27[2J \194\155filesystem" end,
    thrown = function() error("boom\27[2J \194\155", 0) end,
  }) do
    guard = fresh(word)
    assert(guard.boot(paths) == false and remuda._butler_standby and remuda._butler_standby.reason,
      "a failing lock call (" .. label .. ") must not make this daemon the owner")
    refusal = guard.refusal(remuda._butler_standby)
    assert(refusal:find("could not take the owner lock", 1, true) and nexts(refusal) == 1
      and refusal:find("Nothing was changed.", 1, true), "a failed lock is refused with one Next: " .. refusal)
    assert(not refusal:find("[\27]") and not refusal:find("\194\155", 1, true),
      "control bytes in the lock error are removed (" .. label .. ")")
  end

  -- A core without the word: run as today, with ONE warning line that names the core to upgrade to.
  guard = fresh(nil)
  assert(guard.boot(paths) == true and remuda._butler_standby == nil and remuda._command == nil,
    "a core without remuda.fs.lock runs unguarded, as before")
  assert(guard.boot(paths) == true and #warnings == 1 and select(2, warnings[1]:gsub("\n", "")) == 1
    and warnings[1]:find(guard.CORE_WITH_LOCK, 1, true) and warnings[1]:find("remuda upgrade", 1, true),
    "the unguarded core is warned once, on one line, naming the core to upgrade to")
  assert(warnings[1]:find("upgrade to remuda 0.1.0-nightly.20261001062057.499b8b9 or later with `remuda upgrade`", 1, true),
    "the warning names the first core release that has remuda.fs.lock: " .. warnings[1])
  -- L3: the same line is in `remuda butler doctor`, where people look.
  local line = guard.unguarded_line()
  assert(line and warnings[1] == "butler: " .. line .. "\n", "the stderr warning and doctor share one line")
  dofile("packages/butler/doctor.lua")
  local rendered = table.concat(remuda._butler_doctor.render({}, "posix"), "\n")
  assert(rendered:find("\n" .. line .. "\n", 1, true), "doctor shows the not-guarded line on a core without the word: " .. rendered)
  guard = fresh(grant)
  dofile("packages/butler/doctor.lua")
  assert(guard.unguarded_line() == nil
    and not table.concat(remuda._butler_doctor.render({}, "posix"), "\n"):find("not guarded", 1, true),
    "a core with the word shows no not-guarded line")

  -- Files that carry a capability (the root and member MCP configs) are
  -- written owner-only. A core without write_atomic keeps the plain write; a
  -- write_atomic that FAILS raises and never falls back to a non-private write.
  guard = fresh(grant)
  local real_open, opened, wrote = io.open, {}, nil
  io.open = function(path) opened[#opened + 1] = path; return { write = function() end, close = function() end } end
  local private_ok, private_error = pcall(function()
    remuda.fs.write_atomic = function(path, text, options) wrote = { path, text, options and options.private }; return true end
    guard.write_private("/scratch/x.mcp.json", "{}")
    assert(wrote and wrote[1] == "/scratch/x.mcp.json" and wrote[2] == "{}" and wrote[3] == true and #opened == 0,
      "a capability file is written with write_atomic private")
    remuda.fs.write_atomic = function() return nil, "disk full" end
    local raised, why = pcall(guard.write_private, "/scratch/x.mcp.json", "{}")
    assert(not raised and tostring(why):find("disk full", 1, true) and tostring(why):find("/scratch/x.mcp.json", 1, true)
      and #opened == 0, "a failed private write raises and never falls back to a plain write: " .. tostring(why))
    remuda.fs.write_atomic = nil
    guard.write_private("/scratch/x.mcp.json", "{}")
    assert(list(opened) == "/scratch/x.mcp.json", "a core without write_atomic keeps the plain write")
  end)
  io.open = real_open
  assert(private_ok, private_error)

  -- L2: in a refused daemon main.lua is not loaded, so the functions these
  -- lifecycle hooks call do not exist. The hooks must do nothing, not raise.
  local host = { schedule = function() return {} end, cancel = function() end, emit = function() end,
    exec = function() end }
  local real_meta = getmetatable(_G)
  setmetatable(_G, { __index = { remuda = host } })
  local loaded, mod = pcall(dofile, "packages/butler/init.lua")
  setmetatable(_G, real_meta)
  assert(loaded and type(mod) == "table" and type(mod.hooks) == "table", "init.lua should load with a stub host: " .. tostring(mod))
  local seen = 0
  for _, hook in ipairs(mod.hooks) do
    if hook.event == "session_exited" or hook.event == "butler-compaction-submit" then
      seen = seen + 1
      local ran, why = pcall(hook.run, nil, "member", {})
      assert(ran, "the " .. hook.event .. " hook must do nothing in a daemon without main.lua: " .. tostring(why))
    end
  end
  assert(seen == 2, "both lifecycle hooks should exist")
end)
io.stderr = real_stderr
assert(ok, err)
print("ok")
