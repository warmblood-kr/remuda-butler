-- PR3 declared-spec regressions: approvals and standby preserve behavior with
-- remuda.cli.parse present and on older cores without it.
local started
local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

local function q(words)
  local out = {}
  for _, word in ipairs(words) do out[#out + 1] = string.format("%q", word) end
  return table.concat(out, ",")
end

local function approval_case(parser, args, agent)
  start_butler()
  return T.eval([[
    local saved_cli, saved_fail, saved_exec = remuda.cli, remuda.fail, remuda.exec
    local approval = remuda.butler.approval
    local saved_list, saved_answer = approval.list, approval.answer
    local state = { decision = "open", answers = 0, lists = 0 }
    approval.list = function() state.lists = state.lists + 1; return {} end
    approval.answer = function(id, verb)
      state.answers = state.answers + 1
      if id == "--" or id == "-x" then
        state.decision = "expired"
        return false, nil, { id = id, status = "expired" }
      end
      if id ~= "A7K2" then return false, "unknown approval request", nil end
      state.decision = verb == "approve" and "approved" or "denied"
      return true, nil, { id = id, summary = "stub" }
    end
    remuda.fail = function(text, code) return { failed = true, text = text, code = code } end
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    local ok, result = pcall(approval.cli, { ]] .. q(args) .. [[ }, ]] .. (agent and '"agent-test"' or "nil") .. [[)
    local output
    if not ok then output = "THREW:" .. tostring(result)
    elseif type(result) == "table" and result.failed then output = "FAIL:" .. result.code .. ":" .. result.text
    else output = "OK:" .. tostring(result) end
    output = output .. "|" .. state.decision .. ":" .. state.answers .. ":" .. state.lists
    approval.list, approval.answer, remuda.cli, remuda.fail = saved_list, saved_answer, saved_cli, saved_fail
    return output
  ]])
end

local function both_approval(args, want, agent)
  for _, parser in ipairs({ true, false }) do
    T.eq(approval_case(parser, args, agent), want,
      table.concat(args, " ") .. " parser=" .. tostring(parser))
  end
end

local function approval_bad_element(parser, expr, agent)
  start_butler()
  return T.eval([[
    local saved_cli, saved_fail = remuda.cli, remuda.fail
    local approval = remuda.butler.approval
    local saved_answer = approval.answer
    local calls = 0
    approval.answer = function() calls = calls + 1; return false, "unknown approval request" end
    remuda.fail = function(text, code) return { failed = true, text = text, code = code } end
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    local ok, result = pcall(approval.cli, { "approve", ]] .. expr .. [[ }, ]] .. (agent and '"agent-test"' or "nil") .. [[)
    local output
    if not ok then output = "THREW:" .. tostring(result)
    elseif type(result) == "table" and result.failed then output = "FAIL:" .. result.code .. ":" .. result.text
    else output = "OK:" .. tostring(result) end
    output = output .. "|" .. calls
    approval.answer, remuda.cli, remuda.fail = saved_answer, saved_cli, saved_fail
    return output
  ]])
end

T.test("approvals declared parsing leaves state untouched for help and malformed calls", function()
  both_approval({ "approvals" }, "OK:No open approval requests.\nNext: nothing to do; agent requests appear here.|open:0:1")
  for _, args in ipairs({ { "approvals", "--help" }, { "approvals", "-h" } }) do
    both_approval(args, "OK:Usage: remuda butler approvals\nExample: remuda butler approvals|open:0:0")
  end
  for _, args in ipairs({ { "approvals", "extra" }, { "approvals", "--" },
    { "approvals", "--help", "extra" }, { "approvals", "--help=1" } }) do
    local result = approval_case(true, args)
    T.ok(result:find("FAIL:1:Usage: remuda butler approvals", 1, true), "rejects " .. table.concat(args, " "))
    T.ok(result:match("|open:0:0$"), "no list or decision on parse failure")
    T.eq(approval_case(false, args), result, "fallback result for " .. table.concat(args, " "))
  end
end)

T.test("approve and deny preserve valid, malformed, help, and operator-gate behavior", function()
  for _, verb in ipairs({ "approve", "deny" }) do
    local decision = verb == "approve" and "approved" or "denied"
    both_approval({ verb, "A7K2" }, "OK:" .. (verb == "approve"
      and "Approved request A7K2 (stub); joining now. The result goes to the request thread and the asker's mail.\nNext: remuda butler approvals"
      or "Denied request A7K2 (stub).\nNext: remuda butler approvals") .. "|" .. decision .. ":1:0")
    for _, args in ipairs({ { verb, "--help" }, { verb, "-h" } }) do
      both_approval(args, "OK:Usage: remuda butler " .. verb .. " ID\nExample: remuda butler " .. verb .. " A7K2|open:0:0")
    end
    for _, args in ipairs({ { verb }, { verb, "" }, { verb, "A7K2", "extra" },
      { verb, "--help", "A7K2" } }) do
      local with = approval_case(true, args)
      T.ok(with:find("FAIL:1:Usage: remuda butler " .. verb .. " ID", 1, true), "rejects " .. table.concat(args, " "))
      T.ok(with:match("|open:0:0$"), "failure does not call approval.answer")
      T.eq(approval_case(false, args), with, "fallback result for " .. table.concat(args, " "))
    end
    both_approval({ verb, "-A7K2" }, "FAIL:1:unknown approval request\nNext: remuda butler approvals|open:1:0")
    local denied_agent = approval_case(true, { verb, "A7K2" }, true)
    T.ok(denied_agent:find("operator%-only"), "member refusal follows valid parse")
    T.ok(denied_agent:match("|open:0:0$"), "member cannot decide")
    T.eq(approval_case(false, { verb, "A7K2" }, true), denied_agent, "member fallback preserves gate order")
  end
end)

T.test("leading-dash IDs retain legacy answer path, including expired records", function()
  for _, id in ipairs({ "--", "-x" }) do
    for _, verb in ipairs({ "approve", "deny" }) do
      both_approval({ verb, id }, "FAIL:1:Request " .. id .. " was already expired.\nNext: remuda butler approvals|expired:1:0")
    end
  end
end)

T.test("native parser failures fall back for malformed Lua argv", function()
  local non_string = "FAIL:1:Usage: remuda butler approve ID\nExample: remuda butler approve A7K2\nNext: remuda butler approvals|0"
  T.eq(approval_bad_element(true, "false"), non_string, "non-string operator argv")
  T.eq(approval_bad_element(false, "false"), non_string, "non-string parserless argv")
  for _, parser in ipairs({ true, false }) do
    local agent = approval_bad_element(parser, "string.char(255)", true)
    T.ok(agent:find("operator%-only"), "invalid UTF-8 still gets operator refusal: " .. agent)
    T.ok(not agent:find("THREW:", 1, true), "invalid UTF-8 does not throw")
  end
end)

local function standby_case(parser, args)
  start_butler()
  return T.eval([[
    local saved_cli, saved_fail = remuda.cli, remuda.fail
    local guard = remuda.butler.guard
    local saved_claim = guard.claim
    local saved_extension = remuda._extension_commands.butler
    local saved_run = remuda._butler_command_run
    local state = { claims = 0, probes = 0 }
    guard.claim = function()
      state.claims = state.claims + 1
      return { owner = false, guarded = true, held = true, session = "owner", pid = 9 }
    end
    remuda._butler_doctor.probe = function() state.probes = state.probes + 1; return {} end
    remuda._butler_doctor.render = function() return { "doctor-stub" } end
    remuda._butler_doctor.permission_lines = function() return {} end
    remuda.exec = function() return true end
    remuda.fail = function(text, code) return { failed = true, text = text, code = code } end
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    guard.standby({ owner = false, guarded = true, held = true, session = "owner", pid = 9 }, {})
    local ok, result = pcall(remuda._extension_commands.butler, { ]] .. q(args) .. [[ }, nil)
    local output
    if not ok then output = "THREW:" .. tostring(result)
    elseif type(result) == "table" and result.failed then output = "FAIL:" .. result.code .. ":" .. result.text
    else output = "OK:" .. tostring(result) end
    output = output .. "|" .. state.claims .. ":" .. state.probes
    remuda._extension_commands.butler, remuda._butler_command_run = saved_extension, saved_run
    guard.claim, remuda.cli, remuda.fail, remuda.exec = saved_claim, saved_cli, saved_fail, saved_exec
    return output
  ]])
end

T.test("standby uses the doctor declaration and refuses every parse error without promotion", function()
  local doctor = "OK:Not the owning daemon: Butler for this home is already running in another Remuda daemon (session owner, pid 9). Nothing was changed.\ndoctor-stub|1:1"
  T.eq(standby_case(true, { "doctor" }), doctor)
  T.eq(standby_case(false, { "doctor" }), doctor)
  local refusal = "FAIL:1:Butler for this home is already running in another Remuda daemon (session owner, pid 9). Nothing was changed.\nNext: remuda -s owner butler status|1:0"
  for _, args in ipairs({ { "doctor", "extra" }, { "doctor", "--help" }, { "doctor", "-h" },
    { "status" }, { "approve", "A7K2" }, { "--help" }, { "--", "doctor" }, { "doctor", "--" } }) do
    T.eq(standby_case(true, args), refusal, "native parser refuses " .. table.concat(args, " "))
    T.eq(standby_case(false, args), refusal, "fallback refuses " .. table.concat(args, " "))
  end
end)

T.test("standby parser failure preserves refusal for malformed Lua argv", function()
  start_butler()
  for _, bad in ipairs({ "false", "string.char(255)" }) do
    local result = T.eval([[
      local saved_cli, saved_fail = remuda.cli, remuda.fail
      local guard = remuda.butler.guard
      local saved_claim = guard.claim
      guard.claim = function() return { owner = false, guarded = true, held = true, session = "owner", pid = 9 } end
      remuda.fail = function(text, code) return { failed = true, text = text, code = code } end
      guard.standby({ owner = false, guarded = true, held = true, session = "owner", pid = 9 }, {})
      local ok, value = pcall(remuda._extension_commands.butler, { "doctor", ]] .. bad .. [[ }, nil)
      guard.claim, remuda.cli, remuda.fail = saved_claim, saved_cli, saved_fail
      if not ok then return "THREW:" .. tostring(value) end
      return type(value) == "table" and value.text or tostring(value)
    ]])
    T.ok(result:find("already running in another Remuda daemon", 1, true), "standby refusal: " .. result)
    T.ok(not result:find("stack traceback", 1, true), "no parser stack trace")
  end
end)
