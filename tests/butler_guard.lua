-- Single-instance guard (#195) with a faked remuda.fs.lock.
-- Run from the repo root: luajit tests/butler_guard.lua
local failed, warnings, lock_calls, exec_calls = nil, {}, 0, {}
local real_stderr = io.stderr
local function fresh(lock)
  failed, warnings, lock_calls, exec_calls = nil, {}, 0, {}
  remuda = {
    fs = lock and { lock = function(path)
      lock_calls = lock_calls + 1
      return lock(path)
    end } or {},
    mkdir = function() end,
    fail = function(message, code) failed = { message = message, code = code }; return message end,
    extension_command = function(name, run) remuda._command = { name = name, run = run } end,
    exec = function(name)
      exec_calls[#exec_calls + 1] = name
      if name == "butler/doctor" then
        remuda._butler_doctor = { probe = function() return {} end,
          render = function() return { "claude: ok" } end }
        return
      end
      return dofile("packages/butler/" .. name:gsub("^butler/", "") .. ".lua")
    end,
  }
  io.stderr = { write = function(_, text) warnings[#warnings + 1] = text end }
  dofile("packages/butler/guard.lua")
  return remuda.butler.guard
end
local paths = { data_home = "/scratch/data" }
local function nexts(text) return select(2, text:gsub("Next:", "")) end

local ok, err = pcall(function()
  -- The lock sits beside agents.jsonl, under the data home the mod already uses.
  local guard = fresh(function() return {} end)
  assert(guard.lock_path(paths) == "/scratch/data/remuda/butler/lock", "the lock path comes from paths.data_home")
  assert(guard.lock_path({}) == nil, "no data home gives no lock path")

  -- Owner: the lock is granted.
  assert(guard.boot(paths) == true and remuda._butler_standby == nil and remuda._command == nil
    and lock_calls == 1 and #warnings == 0, "the daemon that gets the lock is the owner")
  -- Same daemon asks twice (a mod reload): still the owner, core is not asked again.
  dofile("packages/butler/guard.lua")
  assert(remuda.butler.guard.boot(paths) == true and lock_calls == 1,
    "a reload in the owning daemon keeps ownership without asking core again")

  -- Second daemon: the lock is held by a live daemon.
  guard = fresh(function() return nil, "held", "bsi-a 4242 2026-10-01T05:00:00Z" end)
  assert(guard.boot(paths) == false and remuda._butler_standby and remuda._butler_owner_lock == nil,
    "a daemon that finds the lock held is not the owner")
  local refusal = guard.refusal(remuda._butler_standby)
  assert(refusal:find("already running in another Remuda daemon (bsi-a 4242", 1, true)
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
    .. "in another Remuda daemon (bsi-a 4242 2026-10-01T05:00:00Z). Nothing was changed."
    and doctor:find("\nclaude: ok", 1, true), "doctor runs in a refused daemon and says who the owner is: " .. doctor)
  -- Holder text is display only and is made terminal-safe.
  guard = fresh(function() return nil, "held", "evil\27[2J\nname 1" end)
  guard.boot(paths)
  assert(not guard.refusal(remuda._butler_standby):find("[\27]"), "control characters in the holder text are removed")

  -- The lock call fails for another reason: fail closed.
  for label, lock in pairs({
    returned = function() return nil, "unsupported filesystem" end,
    thrown = function() error("boom", 0) end,
  }) do
    guard = fresh(lock)
    assert(guard.boot(paths) == false and remuda._butler_standby and remuda._butler_standby.reason,
      "a failing lock call (" .. label .. ") must not make this daemon the owner")
    refusal = guard.refusal(remuda._butler_standby)
    assert(refusal:find("could not take the owner lock", 1, true) and nexts(refusal) == 1
      and refusal:find("Nothing was changed.", 1, true), "a failed lock is refused with one Next: " .. refusal)
  end
  guard = fresh(function() return {} end)
  assert(guard.boot({}) == false, "no data home must not make this daemon the owner on a core that can lock")

  -- A core without the word: run as today, with ONE warning line that names the core to upgrade to.
  guard = fresh(nil)
  assert(guard.boot(paths) == true and remuda._butler_standby == nil and remuda._command == nil,
    "a core without remuda.fs.lock runs unguarded, as before")
  assert(guard.boot(paths) == true and #warnings == 1 and select(2, warnings[1]:gsub("\n", "")) == 1
    and warnings[1]:find(guard.CORE_WITH_LOCK, 1, true) and warnings[1]:find("remuda upgrade", 1, true),
    "the unguarded core is warned once, on one line, naming the core to upgrade to")
end)
io.stderr = real_stderr
assert(ok, err)
print("ok")
