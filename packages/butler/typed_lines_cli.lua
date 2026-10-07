-- Terminal-only, owner-confirmed switches for Matrix typed lines and status commands.
local matrix = assert(remuda.butler and remuda.butler.matrix,
  "load butler/matrix_request before butler/typed_lines_cli")
local M = {}

local USAGE = "Usage: remuda butler typed-lines on|off\n"
  .. "       remuda butler shell-lines on|off\n"
  .. "       remuda butler status-commands on|off\n"
  .. "       remuda butler approve-text on|off"
local SWITCH_KEYS = { ["typed-lines"] = "typed_lines", ["shell-lines"] = "shell_lines",
  ["status-commands"] = "status_commands", ["approve-text"] = "approve_text" }
local SWITCH_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    ["typed-lines"] = { about = "Turn typed Matrix lines on or off", args = {
      { name = "STATE", help = "on or off" }, }, next = "remuda butler typed-lines on|off" },
    ["shell-lines"] = { about = "Turn Matrix shell lines on or off", args = {
      { name = "STATE", help = "on or off" }, }, next = "remuda butler shell-lines on|off" },
    ["status-commands"] = { about = "Turn Matrix status commands on or off", args = {
      { name = "STATE", help = "on or off" }, }, next = "remuda butler status-commands on|off" },
    ["approve-text"] = { about = "Turn text approval on or off", args = {
      { name = "STATE", help = "on or off" }, }, next = "remuda butler approve-text on|off" },
  },
}
local WARNINGS = {
  typed_lines = "Whoever controls the owner's Matrix account, or the homeserver that carries it, can type text into every agent session of this machine, and the session cannot tell that text from text typed at its keyboard. Such text counts as the owner's own instruction, including approvals.",
  shell_lines = "Whoever controls that account or homeserver can run shell commands on this machine as this user, with no review by anyone. It is remote command execution, bounded only by rules 1 to 8. Recommended only with the Matrix account protected as well as the machine's own login (device verification, a homeserver the owner runs or trusts).",
  status_commands = "Whoever controls that account or homeserver can read this machine's session names, kinds, context use, unread mail counts and Claude quota by sending ?status, without involving an agent. The answer never contains mail, prompts or screen text.",
  approve_text = "Whoever controls the owner's Matrix account, or the homeserver that carries it, can approve registered text to be typed into agent sessions on this machine.",
}

local function fail(message)
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  return nil, message
end

local function config_path()
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  return paths.config_path
end

local function read_switches(path)
  local ok, config, err = pcall(matrix.read_config, path)
  if not ok then return nil, tostring(config) end
  if not config then return nil, tostring(err or "could not read Matrix config") end
  return config
end

local function each_raw_line(contents, visit)
  local start = 1
  while start <= #contents do
    local newline = contents:find("\n", start, true)
    local finish = newline or (#contents + 1)
    local raw = contents:sub(start, finish - 1)
    local line = raw:gsub("\r$", "")
    visit(raw, line, newline and "\n" or "")
    start = finish + 1
  end
end

local function write_switches(path, updates)
  local latest, config_error = read_switches(path)
  if not latest then return nil, config_error end
  local file, read_error = io.open(path, "rb")
  if not file then return nil, "cannot read Matrix config: " .. tostring(read_error) end
  local contents = file:read("*a")
  file:close()
  local kept, written = {}, {}
  each_raw_line(contents, function(raw, line, ending)
    local key = line:match("^([^=]+)=")
    key = key and key:gsub("^%s+", ""):gsub("%s+$", "")
    if updates[key] ~= nil then
      if not written[key] then
        kept[#kept + 1] = key .. "=" .. tostring(updates[key]) .. ending
        written[key] = true
      end
    else
      kept[#kept + 1] = raw .. ending
    end
  end)
  for _, key in ipairs({ "typed_lines", "shell_lines", "status_commands", "approve_text" }) do
    if updates[key] ~= nil and not written[key] then
      if #kept > 0 and kept[#kept]:sub(-1) ~= "\n" then kept[#kept + 1] = "\n" end
      kept[#kept + 1] = key .. "=" .. tostring(updates[key]) .. "\n"
    end
  end
  if not remuda.fs or type(remuda.fs.write_atomic) ~= "function" then
    return nil, "atomic typed-line config writes are unavailable"
  end
  local ok, wrote, err = pcall(remuda.fs.write_atomic, path, table.concat(kept), { private = true })
  if not ok then return nil, tostring(wrote) end
  if not wrote then return nil, tostring(err or "could not update Matrix typed-line switches") end
  return true
end

local function enable(args, key, path)
  if type(remuda.pending) ~= "function" then
    return fail("Turning on a typed-line switch needs a Remuda core with terminal prompts. Nothing was changed.")
  end
  if type(matrix.prompt_preface_supported) ~= "function" or not matrix.prompt_preface_supported() then
    return fail("Turning on a typed-line switch needs a Remuda core with prompt prefaces. Nothing was changed.")
  end
  local pending_ok, reply = pcall(remuda.pending, { timeout = 90 })
  if not pending_ok or type(reply) ~= "table" or type(reply.prompt_line) ~= "function" then
    return fail("Turning on a typed-line switch needs a terminal prompt. Nothing was changed.")
  end
  local completed = false
  local function resolve(code, stdout, stderr)
    if completed then return end
    completed = true
    if type(reply.resolve) == "function" then reply:resolve(code, stdout or "", stderr or "") end
  end
  local prompt = {
    label = "Type yes to enable " .. args[1] .. ".",
    preface = matrix.wrap_prompt_preface(WARNINGS[key]),
    callback = function(answer, prompt_error)
      if completed then return end
      if prompt_error then
        resolve(1, "", "The typed-line switch prompt failed. Nothing was changed.\n")
        return
      end
      if answer ~= "yes" then
        resolve(1, "", "Not enabled. Nothing was changed.\n")
        return
      end
      local latest, read_error = read_switches(path)
      if not latest then
        resolve(1, "", tostring(read_error) .. "\n")
        return
      end
      if key == "shell_lines" and latest.typed_lines ~= true then
        resolve(1, "", "typed-lines must be on before shell-lines can be enabled. Nothing was changed.\n")
        return
      end
      if latest[key] == true then
        resolve(0, args[1] .. " is already on.\n", "")
        return
      end
      local written, write_error = write_switches(path, { [key] = true })
      if not written then
        resolve(1, "", tostring(write_error) .. "\n")
        return
      end
      resolve(0, args[1] .. " is now on.\n", "")
    end,
  }
  local prompted, prompt_error = pcall(reply.prompt_line, reply, prompt)
  if not prompted then
    resolve(1, "", "The typed-line switch prompt failed: " .. tostring(prompt_error) .. ". Nothing was changed.\n")
    return reply
  end
  return reply
end

function M.cli(args, agent)
  local verb, state
  local cli = remuda.cli
  if type(cli) == "table" and type(cli.parse) == "function" then
    -- The switch's usage response is deliberately the historical one; clap help/errors used to
    -- be ordinary invalid-switch output here. Parsing must stay before all policy/config checks.
    for _, word in ipairs(args or {}) do if word == "--" then return fail(USAGE) end end
    local report = cli.parse(SWITCH_CLI_SPEC, args or {})
    if not report.ok or report.kind == "help" then return fail(USAGE) end
    verb, state = report.verb, report.values.STATE
    if SWITCH_KEYS[verb] == nil or (state ~= "on" and state ~= "off") then return fail(USAGE) end
  else
    verb, state = type(args) == "table" and args[1], type(args) == "table" and args[2]
    if type(args) ~= "table" or #args ~= 2 or SWITCH_KEYS[verb] == nil
        or (state ~= "on" and state ~= "off") then return fail(USAGE) end
  end
  if not verb or not state then
    return fail(USAGE)
  end
  if type(agent) == "string" and agent ~= "" then
    return fail(verb .. " is operator-only. Run it from the owner's terminal; it cannot be enabled from Matrix or Butler mail.")
  end
  local path = config_path()
  if type(path) ~= "string" or path == "" then
    return fail("Matrix is not configured.\nNext: remuda butler matrix setup")
  end
  local config, config_error = read_switches(path)
  if not config then return fail(tostring(config_error)) end
  local key = SWITCH_KEYS[verb]
  if state == "on" then
    if key == "shell_lines" and config.typed_lines ~= true then
      return fail("typed-lines must be on before shell-lines can be enabled. Nothing was changed.")
    end
    if config[key] == true then return verb .. " is already on." end
    return enable({ verb, state }, key, path)
  end
  local updates = { [key] = false }
  if key == "typed_lines" then updates.shell_lines = false end
  local needs_write = config[key] ~= false
  if key == "typed_lines" and config.shell_lines ~= false then needs_write = true end
  if needs_write then
    local written, write_error = write_switches(path, updates)
    if not written then return fail(tostring(write_error)) end
  end
  return verb .. " is now off." .. (key == "typed_lines" and " shell-lines is also off." or "")
end

remuda.butler.typed_lines_cli = M
return M
