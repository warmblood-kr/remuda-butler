local T = { patience = 10 }
_G.T = T

local tests, sessions, reports = {}, {}, {}
local current, test_index, completed, ticker
local remuda_api = remuda
local process = remuda.process
local fs = remuda.fs
local exe = assert(os.getenv("REMUDA_BIN"), "REMUDA_BIN is required")
local result_path = assert(os.getenv("REMUDA_LUA_RESULT"), "REMUDA_LUA_RESULT is required")
local child_server = assert(os.getenv("REMUDA_LUA_CHILD_SERVER"), "child server is required")
local controller_server = assert(os.getenv("REMUDA_LUA_SERVER"), "controller server is required")

local function quote(value)
  return string.format("%q", value)
end

local function remote(code)
  local result = process.run {
    argv = { exe, "-s", child_server, "-e", code },
    timeout = 10,
  }
  if result.timed_out or result.code ~= 0 then
    error("child Remuda command failed: " .. tostring(result.stderr or result.stdout), 2)
  end
  return result.stdout or ""
end

local function screen_report()
  local parts = {}
  for name in pairs(sessions) do
    local ok, value = pcall(remote, "return remuda.capture(" .. quote(name) .. ")")
    parts[#parts + 1] = "screen " .. name .. ":\n" .. (ok and value or tostring(value))
  end
  if #parts == 0 then return "screen: (no sessions)" end
  return table.concat(parts, "\n")
end

local function failure_text(what, timeout, last)
  return tostring(what or "condition")
    .. " timed out after " .. tostring(timeout) .. "s; last=" .. tostring(last)
    .. "\n" .. screen_report()
end

function T.test(name, fn)
  assert(type(name) == "string" and type(fn) == "function", "T.test(name, fn) expected")
  tests[#tests + 1] = { name = name, fn = fn }
end

function T.eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

function T.ok(value, message)
  if not value then error(message or "expected a truthy value", 2) end
end

function T.expect(value, message, success_message)
  if not value then error(message or "expectation failed", 2) end
  if success_message then reports[#reports + 1] = success_message end
  return value
end

function T.eval(code)
  -- The CLI appends one newline to the value it prints; the value itself has none.
  return (remote(code):gsub("\n$", ""))
end

local function copy_tree(source, destination)
  local ok, entries = pcall(remuda_api.list_dir, source)
  if ok and type(entries) == "table" then
    remuda_api.mkdir(destination)
    for _, entry in ipairs(entries) do
      copy_tree(source .. "/" .. entry, destination .. "/" .. entry)
    end
    return
  end
  local input = assert(io.open(source, "rb"), "cannot read mod file: " .. source)
  local contents = input:read("*a")
  input:close()
  local wrote, err = fs.write_atomic(destination, contents)
  assert(wrote, "cannot install mod file: " .. tostring(err))
end

function T.install_mod(name, source)
  assert(type(name) == "string" and name:match("^[%w_-]+$"), "invalid mod name")
  assert(type(source) == "string" and source ~= "", "mod source directory required")
  local destination = assert(os.getenv("XDG_DATA_HOME"), "XDG_DATA_HOME is required")
    .. "/remuda/mods/" .. name
  remuda_api.mkdir(destination)
  copy_tree(source .. "/extension.toml", destination .. "/extension.toml")
  copy_tree(source .. "/packages", destination .. "/packages")
end

function T.new_session(name, argv)
  local values = {}
  for _, value in ipairs(argv or { "sh" }) do
    values[#values + 1] = quote(value)
  end
  remote("return remuda.new(" .. quote(name) .. ", {" .. table.concat(values, ",") .. "})")
  sessions[name] = true
end

function T.send(name, text)
  T.ok(sessions[name], "unknown test session: " .. tostring(name))
  remote("return remuda.send(" .. quote(name) .. ", " .. quote(text) .. ")")
end

function T.screen(name)
  T.ok(sessions[name], "unknown test session: " .. tostring(name))
  return remote("return remuda.capture(" .. quote(name) .. ")")
end

function T.wait_until(predicate, timeout, what)
  assert(type(predicate) == "function", "T.wait_until expects a predicate")
  timeout = timeout or T.patience
  local deadline = remuda_api.clock() + timeout * 1000
  local last
  repeat
    local ok, value = pcall(predicate)
    if not ok then error(value, 2) end
    last = value
    if value then return value end
    if remuda_api.clock() >= deadline then
      error(failure_text(what, timeout, last), 2)
    end
    coroutine.yield()
  until false
end

function T.wait_for_screen(name, needle, timeout)
  return T.wait_until(function()
    local text = T.screen(name)
    if text:find(needle, 1, true) then return text end
    return false
  end, timeout, "screen " .. tostring(name) .. " contains " .. tostring(needle))
end

function T.report_expected_failure(message)
  reports[#reports + 1] = "FAIL (expected diagnostic): " .. tostring(message)
end

local function save_result(status, message)
  local lines = { status, message or "" }
  for _, report in ipairs(reports) do lines[#lines + 1] = report end
  lines[#lines + 1] = "harness: killed pids: 0; stopped child: " .. child_server .. "; left: 0"
  fs.write_atomic(result_path, table.concat(lines, "\n") .. "\n")
end

local function stop_child()
  for name in pairs(sessions) do
    pcall(remote, "pcall(remuda.close, " .. quote(name) .. ")")
  end
  local stopped = process.run {
    argv = { exe, "-s", child_server, "stop", "-f" },
    timeout = 10,
  }
  if stopped.timed_out or stopped.code ~= 0 then
    return false, "child stop failed: " .. tostring(stopped.stderr or stopped.stdout)
  end
  local probe = process.run {
    argv = { exe, "-s", child_server, "ls" },
    timeout = 3,
  }
  if probe.code == 0 then return false, "child daemon still answers ls" end
  return true
end

local function finish(status, message)
  if completed then return end
  completed = true
  if ticker then ticker:cancel() end
  local ok, err = stop_child()
  if not ok then
    status, message = "FAIL", tostring(message or "") .. "\n" .. tostring(err)
  end
  save_result(status, message)
  remuda_api.after(0.01, function()
    process.run { argv = { exe, "-s", controller_server, "stop", "-f" }, timeout = 5 }
  end)
end

local function begin_child()
  local started = process.run {
    argv = { exe, "-s", child_server, "-e", "1" },
    timeout = 30,
  }
  if started.timed_out or started.code ~= 0 then
    finish("FAIL", "child daemon start failed: " .. tostring(started.stderr or started.stdout))
    return false
  end
  return true
end

function T.tick()
  if completed then return end
  if not current then
    test_index = test_index + 1
    local spec = tests[test_index]
    if not spec then
      finish("PASS")
      return
    end
    current = { spec = spec, co = coroutine.create(spec.fn) }
  end
  local ok, message = coroutine.resume(current.co)
  if not ok then
    finish("FAIL", current.spec.name .. ": " .. tostring(message) .. "\n" .. screen_report())
    return
  end
  if coroutine.status(current.co) == "dead" then current = nil end
end

local function run()
  local test_path = assert(os.getenv("REMUDA_LUA_TEST"), "REMUDA_LUA_TEST is required")
  local scratch = assert(os.getenv("REMUDA_LUA_SCRATCH"), "REMUDA_LUA_SCRATCH is required")
  local runtime = fs.realpath(os.getenv("REMUDA_RUNTIME_DIR"))
  local scratch_real = fs.realpath(scratch)
  local default_runtime = os.getenv("REMUDA_LUA_DEFAULT_RUNTIME")
  local resolved, value = pcall(fs.realpath, default_runtime)
  if resolved and type(value) == "string" then default_runtime = value end
  local controller_socket = runtime .. "/remuda/" .. controller_server .. ".sock"
  local child_socket = runtime .. "/remuda/" .. child_server .. ".sock"
  assert(runtime == scratch_real .. "/run",
    "runtime directory must be the harness scratch runtime")
  assert(controller_socket:sub(1, #scratch_real) == scratch_real
    and child_socket:sub(1, #scratch_real) == scratch_real,
    "controller and child sockets must remain under scratch")
  assert(controller_socket ~= default_runtime .. "/remuda/" .. controller_server .. ".sock"
    and child_socket ~= default_runtime .. "/remuda/" .. child_server .. ".sock"
    and controller_server ~= "default" and child_server ~= "default",
    "refusing the default Remuda socket")

  local chunk = assert(loadfile(test_path))
  chunk()
  if not begin_child() then return end
  current = nil
  test_index = 0
  ticker = remuda_api.every(0.05, T.tick)
end

local ok, err = xpcall(run, function(e) return tostring(e) end)
if not ok then
  local success, stop_error = pcall(stop_child)
  save_result("FAIL", tostring(err) .. (success and "" or "\n" .. tostring(stop_error)))
  remuda_api.after(0.01, function()
    process.run { argv = { exe, "-s", controller_server, "stop", "-f" }, timeout = 5 }
  end)
end
