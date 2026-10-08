T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local alice = T.eval([[
  local a = remuda._butler_bus.agents.alice
  return a.id .. "\n" .. a.session_name
]])
local alice_id, alice_session = alice:match("([^\n]+)\n([^\n]+)")
assert(alice_id and alice_session, "member setup failed")

local function quote(value) return string.format("%q", value) end
local function caller(kind, session, env)
  local entries = { "kind = " .. (kind and quote(kind) or "nil") }
  if session then entries[#entries + 1] = "session = " .. quote(session) end
  if env == "nil" then entries[#entries + 1] = "env = nil"
  elseif type(env) == "table" then
    local fields = {}
    for k, v in pairs(env) do fields[#fields + 1] = k .. " = " .. quote(v) end
    entries[#entries + 1] = "env = { " .. table.concat(fields, ", ") .. " }"
  end
  return "{ " .. table.concat(entries, ", ") .. " }"
end
local function eval(code) return T.eval(code) end
local function snapshot()
  return eval([=[
    local b = remuda._butler_bus
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
    local reads, delivered = 0, 0
    for _, values in pairs(b.mail_read or {}) do reads = reads + count(values) end
    for _, values in pairs(b.mail_delivered or {}) do delivered = delivered + count(values) end
    return table.concat({ count(b.messages), count(b.objects), reads,
      delivered, count(b.inboxes), b.next }, ":")
  ]=])
end
local function command(c)
  return eval([[
    local ok, out = pcall(remuda._butler_command_run, "inbox", { "inbox" }, ]] .. c .. [[)
    return (ok and "ok|" or "error|") .. tostring(out)
  ]])
end

T.test("session_identity_comes_from_daemon_session_despite_conflicting_env", function()
  local c = caller("session", alice_session, { REMUDA_BUTLER_AGENT_ID = "bob" })
  T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.tag"), "member")
  T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.id"), alice_id)
  T.eq(eval("return remuda._butler_current_agent(" .. c .. ")"), alice_id)
end)

T.test("missing_or_conflicting_env_never_changes_the_member", function()
  local cases = {
    caller("session", alice_session),
    caller("session", alice_session, {}),
    caller("session", alice_session, { REMUDA_BUTLER_AGENT_ID = "bob" }),
    caller("session", alice_session, { REMUDA_BUTLER_SESSION_NAME = "bob" }),
  }
  for _, c in ipairs(cases) do
    T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.tag"), "member")
    T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.id"), alice_id)
  end
end)

T.test("forged_environment_on_outside_caller_does_not_select_member", function()
  local c = caller("outside", nil, { REMUDA_BUTLER_AGENT_ID = alice_id, REMUDA_BUTLER_SESSION_NAME = alice_session })
  T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.tag"), "operator")
  T.eq(eval("return tostring(remuda._butler_current_agent(" .. caller("outside", nil,
    { REMUDA_BUTLER_AGENT_ID = alice_id }) .. "))"), "nil")
end)

T.test("outside_is_the_named_transitional_operator_policy", function()
  T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. caller("outside") .. "); return p.tag"), "operator")
end)

T.test("unidentified_context_refuses_with_next_and_does_not_mutate_mail", function()
  local cases = {
    caller("session", "unregistered-session"),
    caller("session", alice_session .. "-ambiguous"),
    caller("unknown"),
    { session = alice_session, env = { REMUDA_BUTLER_AGENT_ID = alice_id } },
  }
  for _, c in ipairs(cases) do
    local before = snapshot()
    local encoded = type(c) == "string" and c or caller(c.kind, c.session, c.env)
    local outcome = eval("local ok, err = pcall(remuda._butler_current_agent, " .. encoded .. "); return tostring(ok) .. \"|\" .. tostring(err)")
    T.ok(outcome:match("^false|"), "unidentified caller must throw: " .. outcome)
    T.ok(outcome:find("Next:", 1, true), "refusal needs a Next line: " .. outcome)
    local result = command(encoded)
    T.ok(result:match("^error|") and result:find("Next:", 1, true), "command refusal needs Next: " .. result)
    T.eq(snapshot(), before, "refusal must not mutate mail, read logs, or counters")
  end
end)

T.test("ambiguous_session_mapping_refuses", function()
  eval([[remuda._butler_bus.agents.bob.session_name = remuda._butler_bus.agents.alice.session_name]])
  local c = caller("session", alice_session)
  T.eq(eval("local p = remuda._butler_caller_principal.resolve(" .. c .. "); return p.tag"), "unidentified")
  local before = snapshot()
  local outcome = eval("local ok, err = pcall(remuda._butler_current_agent, " .. c .. "); return tostring(ok) .. \"|\" .. tostring(err)")
  T.ok(outcome:match("^false|") and outcome:find("Next:", 1, true), "ambiguous caller must fail closed: " .. outcome)
  local result = command(c)
  T.ok(result:match("^error|") and result:find("Next:", 1, true), "ambiguous command must fail closed: " .. result)
  T.eq(snapshot(), before, "ambiguous refusal must not mutate mail or read state")
  eval([[remuda._butler_bus.agents.bob.session_name = "bob"]])
end)

T.test("outside_policy_is_persistently_audited_without_caller_secrets", function()
  local result = eval([[
    local saved = remuda.log
    remuda.log = nil -- pinned and installed cores have no logger
    local c = { kind = "outside", session = "SECRET-SESSION", capability = "SECRET-CAPABILITY",
      env = { REMUDA_BUTLER_AGENT_ID = "SECRET-ENV" }, stdin = "SECRET-BODY" }
    local p = remuda._butler_caller_principal.resolve(c)
    remuda.log = saved
    local f = io.open(remuda.butler.guard_policy.log_path(), "r")
    if not f then return "missing audit" end
    local text = f:read("a"); f:close()
    local row
    for line in text:gmatch("[^\n]+") do
      local r = remuda.json.decode(line)
      if r.event == "caller_policy" then row = r end
    end
    return p.tag .. "|" .. (row and row.summary or "missing policy line")
      .. "|" .. tostring(text:find("SECRET", 1, true) == nil)
  ]])
  T.eq(result, "operator|outside_is_operator_transitional: outside caller mapped to operator|true")
end)

T.test("mcp_capability_only_callers_keep_the_existing_path", function()
  eval([[local a = remuda._butler_bus.agents.alice
    remuda._butler_bus.tokens["test-capability"] = { id = a.id, generation = a.session_start_marker }]])
  T.eq(eval([[return remuda._butler_identity.caller_agent({capability = "test-capability"})]]), "alice")
  T.eq(eval([[return remuda._butler_identity.caller_name({capability = "invalid"})]]), "outside")
  local outcome = eval([[local ok, err = pcall(remuda._butler_identity.caller_agent, {}); return tostring(ok) .. "|" .. tostring(err)]])
  T.ok(outcome:find("false|unknown caller", 1, true), "MCP refusal keeps its existing reason: " .. outcome)
end)

for _, failure in ipairs({ "close", "flush", "write", "open" }) do
  T.test("audit_" .. failure .. "_failure_refuses_operator_before_mail_mutation", function()
    local before = snapshot()
    local result = eval(([=[
      local gp, real = remuda.butler.guard_policy, io.open
      local stage, closes = %q, 0
      io.open = function(path, mode)
        if path ~= gp.log_path() or mode ~= "a" then return real(path, mode) end
        if stage == "open" then return nil, "injected open failure" end
        local out = {}
        function out:write() if stage == "write" then return nil, "injected write failure" end; return self end
        function out:flush() if stage == "flush" then return nil, "injected flush failure" end; return true end
        function out:close()
          closes = closes + 1
          if stage == "close" then return nil, "File too large" end
          return true
        end
        return out
      end
      local appended, why = gp.append({event = "caller_policy", summary = "failure probe"})
      local p = remuda._butler_caller_principal.resolve({kind = "outside"})
      local ok, out = pcall(remuda._butler_command_run, "send", {"send", "alice", "audit failure probe"}, {kind = "outside"})
      io.open = real
      return tostring(not appended) .. "|" .. tostring(why ~= nil) .. "|" .. p.tag .. "|"
        .. tostring(not ok and tostring(out):find("Next:", 1, true) ~= nil) .. "|"
        .. tostring(stage == "open" or closes == 3)
    ]=]):format(failure))
    T.eq(result, "true|true|unidentified|true|true", failure .. " must fail closed and close opened handles")
    T.eq(snapshot(), before, failure .. " must leave mail, read state and counters unchanged")
  end)
end
