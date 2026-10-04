-- Guard slice 2: narrow, opt-in PreToolUse denials.
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
  end, 5, "Butler root start")
  T.eval([=[
    local gp = remuda.butler.guard_policy
    remuda._t_dir = function(name)
      local d = os.getenv('XDG_DATA_HOME') .. '/' .. name
      remuda.mkdir(d); remuda._butler_guard_dir = d; return d
    end
    remuda._t_hook = function(stdin, env)
      return remuda._butler_command_run('guard', {'guard'}, { stdin = stdin, env = env or
        { REMUDA_BUTLER_AGENT_ALIAS = 's2-a', REMUDA_BUTLER_AGENT_KIND = 'claude' } })
    end
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    return 'ok'
  ]=])
end
local function ev(code)
  return T.eval("local ok, v = pcall(function() " .. code .. " end); return (ok and 'ok:' or 'err:') .. tostring(v)")
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local function luaq(value) return string.format("%q", value) end
local function reason(tool, command, ctx)
  local input = (tool == "Bash" or tool == "PowerShell") and "{command=" .. luaq(command) .. "}"
    or "{file_path=" .. luaq(command) .. "}"
  return T.eval("local r=remuda.butler.guard_policy.deny_reason(" .. luaq(tool) .. "," .. input .. "," .. (ctx or "{}") .. "); return r or 'nil'")
end
local function shquote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

T.test("deny switch is independent, off by default, and appears in doctor", function()
  start_butler()
  T.eval("remuda._t_dir('s2-switch')")
  local status = ev("return remuda._butler_command_run('guard', {'guard','deny','status'}, {})")
  T.expect(has(status, "guard deny: off") and has(status, "guard: off"), "default: " .. status)
  T.eval("remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  T.expect(has(ev("return remuda._butler_command_run('guard', {'guard','status'}, {})"), "guard: off"),
    "deny switch must not turn audit on")
  local doctor = ev("local d=remuda._butler_doctor; return table.concat(d.render(d.probe()), '\\n')")
  T.expect(has(doctor, "Guard deny: on"), "doctor: " .. doctor, "ok - deny switch and doctor")
  T.eval("remuda._butler_command_run('guard', {'guard','deny','off'}, {})")
  T.expect(ev("return remuda._butler_command_run('guard', {'guard','deny','bogus'}, {})"):find("^err:") ~= nil,
    "bad deny verb accepted")
end)

T.test("bypass flags are denied across wrapped segments, with near misses allowed", function()
  start_butler()
  for _, command in ipairs({
    "claude --dangerously-skip-permissions", "codex --yolo", "agent --permission-mode bypassPermissions",
    "agent --permission-mode danger-full-access", "agent --permission-mode=bypassPermissions", "agent --danger-full-access", "agent --sandbox full",
    "codex -a never", "codex --ask-for-approval never", "codex -c approval_policy=never",
    "echo ok && sudo env X=1 codex --yolo", "echo ok; agent '--dangerously-skip-permissions'",
  }) do
    T.expect(reason("Bash", command) ~= "nil", "not denied: " .. command)
  end
  T.expect(reason("PowerShell", "codex --yolo") ~= "nil", "PowerShell bypass flag")
  for _, command in ipairs({ "claude --permission-mode default", "echo --yolov2", "echo danger-full-accessible", "echo --sandbox workspace" }) do
    T.eq(reason("Bash", command), "nil", "near miss: " .. command)
  end
  T.expect(reason("Read", "--yolo") == "nil", "unknown tools must not be denied")
  T.expect(true, "", "ok - bypass flags")
end)

T.test("owner controls and daemon stop are narrow", function()
  start_butler()
  for _, command in ipairs({
    "remuda butler guard on", "remuda butler guard deny status", "env X=1 remuda -s default butler guard deny off",
    "sudo remuda butler approve abc", "remuda butler deny abc", "remuda butler approve-text on",
    "remuda butler typed-lines on", "remuda butler shell-lines off", "remuda butler status-commands on",
    "remuda stop", "env X=1 remuda -s default restart", "sudo remuda kill",
    "remuda -s h1 -s default stop", "remuda stop -s h1 -s default", "remuda -s h1 -s default restart",
    "remuda --server h1 --server default stop",
    "remuda -s h1 --socket /run/default.sock stop", "remuda --runtime-dir /run/remuda -s h1 stop",
    "remuda --data-home /tmp/remuda -s h1 restart",
    "env -i remuda stop", "env FOO=1 -i remuda stop", "sudo -u root remuda stop", "timeout 5 remuda stop", "nohup command exec remuda stop",
    "nice -n 5 remuda stop", "xargs remuda stop",
    "remuda --config /tmp/r.conf stop", "remuda --runtime-dir /tmp/r restart",
    "\\remuda stop", "(remuda stop)", "{ remuda stop; }", "! remuda stop", "if true; then remuda stop; fi",
    "echo $(remuda stop)", "echo `remuda stop`", "sh -c 'remuda stop'", "bash -c 'git push -fu origin main'",
    "zsh -c 'remuda stop'", "dash -c 'remuda stop'", "ksh -c 'remuda stop'", "ash -c 'remuda stop'",
    "eval 'remuda stop'", "find . -exec remuda stop \\;", "find . -execdir remuda stop \\;",
  }) do
    T.expect(reason("Bash", command) ~= "nil", "not denied: " .. command)
  end
  for _, command in ipairs({ "remuda -s h123 stop", "remuda -s h123c restart", "remuda --server h123 stop", "pkill sleep", "kill 123", "killall sleep", "remuda butler guard status",
    "remuda butler send-to-leader stop the build", "remuda butler send X 'restart the server'", "remuda send h1 'kill it'" }) do
    T.eq(reason("Bash", command), "nil", "near miss: " .. command)
  end
  T.expect(reason("Bash", "echo x; remuda butler guard approvals on") ~= "nil", "later owner command segment")
  T.expect(reason("Bash", "echo x\nremuda butler guard deny off") ~= "nil", "newline owner command segment")
  T.expect(true, "", "ok - owner and daemon controls")
end)

T.test("quoted text is not scanned as flags, segments, or redirects", function()
  start_butler()
  for _, command in ipairs({
    'git commit -m "mentions --yolo"', "grep yolo .", "cat yolo.md", "echo sandbox full",
    'git commit -m "fix; remuda stop"', "grep 'remuda stop'", "echo 'hello > ~/.ssh/key'",
  }) do T.eq(reason("Bash", command, "{home='/home/a',cwd='/home/a/work'}"), "nil", "quoted/ordinary text: " .. command) end
  T.expect(true, "", "ok - quoted text remains non-executable")
end)

T.test("protected file writes are denied while worktree writes are allowed", function()
  start_butler()
  for _, pair in ipairs({
    { "Write", "/home/a/.claude/settings.json" }, { "Edit", "/home/a/.codex/hooks.json" },
    { "MultiEdit", "/home/a/.ssh/config" }, { "NotebookEdit", "/home/a/.config/remuda/prefs.lua" },
  }) do T.expect(reason(pair[1], pair[2], "{home='/home/a',cwd='/home/a/work'}") ~= "nil", pair[1] .. " not denied: " .. pair[2]) end
  for _, command in ipairs({
    "tee ~/.claude/settings.json", "sed -i s/a/b/ ~/.codex/config.toml", "echo x > ~/.ssh/authorized_keys",
    "echo x >| ~/.claude/settings.json",
    "sudo cp /x ~/.config/remuda/config", "touch /home/a/.local/share/remuda/butler/agents.jsonl",
    "echo {} > .claude/settings.local.json", "tee .claude/settings.json", "sed -i s/a/b/ .claude/settings.json",
    "rm -rf ~/.ssh", "rm -rf ~/.local/share/remuda/butler",
    "mv ~/.ssh/config ./backup", "mv /tmp/new ~/.ssh/config",
    "dd if=/dev/zero of=~/.ssh/known_hosts",
  }) do T.expect(reason("Bash", command, "{home='/home/a',cwd='/home/a/work'}") ~= "nil", "not denied: " .. command) end
  for _, command in ipairs({
    "cat ~/.claude/settings.json 2>/dev/null", "ls ~/.ssh 2>&1", "git commit -m 'a -> ~/.claude/x'",
    "cp ~/.claude/x ./backup", "sed -n p ~/.ssh/config",
  }) do T.eq(reason("Bash", command, "{home='/home/a',cwd='/home/a/work'}"), "nil", "read/non-destination near miss: " .. command) end
  T.eq(reason("Bash", "rm -rf ~/.claude", "{home='/home/a',cwd='/home/a/work'}"), "nil", "Claude config root is not broadly protected")
  T.eq(reason("Write", "/home/a/work/file.txt", "{home='/home/a',cwd='/home/a/work'}"), "nil", "worktree Write")
  T.eq(reason("Bash", "echo x > file.txt", "{home='/home/a',cwd='/home/a/work'}"), "nil", "worktree redirect")
  T.eq(reason("Bash", "touch /home/a/work/notes.txt", "{home='/home/a',cwd='/home/a/work'}"), "nil", "worktree Bash writer")
  T.eq(reason("Write", "/home/a/work/.claude/commands/help.md", "{home='/home/a',cwd='/home/a/work'}"), "nil", "worktree Claude docs")
  T.eq(reason("Write", "/home/a/.claude/projects/sample/memory/MEMORY.md", "{home='/home/a',cwd='/home/a/work'}"), "nil", "Claude auto-memory remains writable")
  T.eq(reason("Write", "/home/a/.claude/plans/implementation.md", "{home='/home/a',cwd='/home/a/work'}"), "nil", "Claude plans remain writable")
  T.eq(reason("Write", "/home/a/projects/remuda/butler/docs/index.md", "{home='/home/a',cwd='/home/a/projects'}"), "nil", "sibling Butler source tree")
  T.expect(true, "", "ok - protected writes and worktree near misses")
end)

T.test("only destructive pushes naming protected branches are denied", function()
  start_butler()
  for _, command in ipairs({
    "git push origin main --force", "git push -f origin refs/heads/master", "git push --force-with-lease=refs/heads/trunk origin trunk",
    "git push origin +feature:main", "git push origin '+feature:main'", "git push --delete origin main", "git push origin main:main --delete",
    "git push origin :main", "git push origin :refs/heads/main", "git push -d origin main", "git push -df origin master", "git push -fu origin trunk",
    "env GIT_DIR=x git push origin main --force", "sudo git push --force origin main",
  }) do T.expect(reason("Bash", command) ~= "nil", "not denied: " .. command) end
  for _, command in ipairs({
    "git push origin main", "git push origin feature --force", "git push --force origin feature",
    "git push --delete origin feature", "git push origin feature:feature", "git push origin +feature:feature",
    "git push --force", "git push -f origin HEAD", "git push --force --all",
  }) do T.eq(reason("Bash", command), "nil", "near miss: " .. command) end
  T.expect(true, "", "ok - protected branch pushes")
end)

T.test("settings preserve off bytes and retain stdout only for active deny", function()
  start_butler()
  T.eval("remuda._t_dir('s2-settings'); remuda._butler_command_run('guard', {'guard','on'}, {})")
  local function settings()
    return T.eval([[local p=remuda._butler_agent_support.status_settings(os.getenv('XDG_DATA_HOME') .. '/s2.settings');
      local f=io.open(p,'r'); local t=f:read('*a'); f:close(); remuda.json.decode(t); return t]])
  end
  local off = settings()
  T.eval("remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local on = settings()
  local pre = on:match('"PreToolUse":(%b[])')
  T.expect(pre and has(pre, "2>/dev/null; exit 0") and not has(pre, ">/dev/null 2>&1"), "deny PreToolUse entry: " .. tostring(pre))
  T.eval("remuda._butler_command_run('guard', {'guard','deny','off'}, {})")
  T.eq(settings(), off, "settings bytes with deny off")
  T.expect(true, "", "ok - settings stdout and off bytes")
end)

T.test("oversized hook payloads still deny from bounded structured fields", function()
  start_butler()
  T.eval("remuda._t_dir('s2-large'); remuda._butler_command_run('guard', {'guard','on'}, {}); remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local bash = T.eval([=[local p=remuda.json.encode({hook_event_name='PreToolUse',tool_name='Bash',
    tool_input={command='remuda stop; '..string.rep('x', 70000)}}); return remuda._t_hook(p)]=])
  T.eq(bash, [[{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Butler guard: Remuda daemon control"}}]],
    "oversized Bash structured prefix")
  local write = T.eval([=[local p=remuda.json.encode({hook_event_name='PreToolUse',tool_name='Write',
    tool_input={file_path='/home/a/.claude/settings.json',content=string.rep('x', 70000)}}); return remuda._t_hook(p)]=])
  T.eq(write, [[{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Butler guard: Protected settings or directory write"}}]],
    "oversized protected Write")
  T.expect(true, "", "ok - oversized structured fields remain protected")
end)

T.test("audit append failure does not turn a denial into an allow", function()
  start_butler()
  T.eval("remuda._t_dir('s2-audit-fail'); remuda._butler_command_run('guard', {'guard','on'}, {}); remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local out = T.eval([=[local gp=remuda.butler.guard_policy; local append=gp.append
    gp.append=function() return nil, 'forced audit failure' end
    local payload=remuda.json.encode({hook_event_name='PreToolUse',tool_name='Bash',tool_input={command='remuda stop'}})
    local result=remuda._t_hook(payload); gp.append=append; return result]=])
  T.eq(out, [[{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Butler guard: Remuda daemon control"}}]],
    "audit failure keeps deny")
  T.expect(true, "", "ok - deny survives audit failure")
end)

T.test("deny policy errors fail open and are audited", function()
  start_butler()
  T.eval("remuda._t_dir('s2-policy-error'); remuda._butler_command_run('guard', {'guard','on'}, {}); remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local out = T.eval([=[local gp=remuda.butler.guard_policy; local policy=gp.deny_reason
    gp.deny_reason=function() error('forced policy failure') end
    local payload=remuda.json.encode({hook_event_name='PreToolUse',tool_name='Bash',tool_input={command='remuda stop'}})
    local result=remuda._t_hook(payload); gp.deny_reason=policy; return result]=])
  T.eq(out, "", "policy error fails open")
  local audit = T.eval("return remuda._t_lines()")
  T.expect(has(audit, '"event":"policy_error"') and has(audit, '"tool":"Bash"'), "policy error was not audited: " .. audit)
  T.expect(true, "", "ok - policy failure is separately audited and fail-open")
end)

T.test("deny switch leaves PermissionRequest behavior unchanged", function()
  start_butler()
  T.eval("remuda._t_dir('s2-permission'); remuda._butler_command_run('guard', {'guard','on'}, {}); remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local out = T.eval([=[local payload=remuda.json.encode({hook_event_name='PermissionRequest',tool_name='Bash',tool_input={command='remuda stop'}}); return remuda._t_hook(payload)]=])
  T.eq(out, "", "PermissionRequest stays silent without approvals")
  local audit = T.eval("return remuda._t_lines()")
  T.expect(has(audit, '"event":"PermissionRequest"') and not has(audit, '"event":"deny"'), "PermissionRequest was changed: " .. audit)
  T.expect(true, "", "ok - PermissionRequest unchanged")
end)

T.test("real CLI prints exact deny JSON, gates switches, and audits a redacted summary", function()
  start_butler()
  T.eval("remuda._t_dir('s2-cli'); remuda._butler_command_run('guard', {'guard','deny','on'}, {})")
  local json = [[{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Butler guard: Agent permission bypass flag"}}]]
  local function run_cli(name, command, expected, tool)
    tool = tool or "Bash"
    local input = tool == "Write" and "{file_path=" .. luaq(command) .. "}" or "{command=" .. luaq(command) .. "}"
    local payload = T.eval("return remuda.json.encode({hook_event_name='PreToolUse',tool_name=" .. luaq(tool) .. ",cwd=" .. luaq(os.getenv("HOME")) .. ",tool_input=" .. input .. "})")
    local expected_json = tool == "Write"
      and [[{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Butler guard: Protected settings or directory write"}}]]
      or json
    local script = "out=$(printf '%s' " .. shquote(payload) .. " | REMUDA_BUTLER_AGENT_ALIAS=" .. name
      .. " REMUDA_BUTLER_AGENT_KIND=claude " .. shquote(os.getenv("REMUDA_BIN")) .. " -s "
      .. shquote(os.getenv("REMUDA_LUA_CHILD_SERVER")) .. " --stdin butler guard 2>/dev/null); rc=$?; "
      .. "if [ \"$out\" = " .. shquote(expected_json) .. " ]; then r=EXACT; elif [ -z \"$out\" ]; then r=SILENT; else r=OTHER; fi; "
      .. "echo RESULT=$r rc=$rc; sleep 30"
    T.new_session(name, { "sh", "-c", script })
    local screen = T.wait_for_screen(name, "RESULT=", 15)
    T.expect(has(screen, "RESULT=" .. expected .. " rc=0"), "CLI result: " .. screen)
    return screen
  end
  run_cli("s2-off", "codex --yolo", "SILENT") -- audit is still off
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {})")
  run_cli("s2-on", "TOKEN=hunter2 codex --yolo", "EXACT")
  run_cli("s2-write", os.getenv("HOME") .. "/.ssh/config", "EXACT", "Write")
  local audit = T.eval("return remuda._t_lines()")
  T.expect(has(audit, '"event":"deny"') and has(audit, '"class":"weaken"'), "deny event/class missing from audit: " .. audit)
  T.expect(has(audit, '"summary":"TOKEN=*** codex --yolo"') and not has(audit, "hunter2"), "audit summary not redacted: " .. audit)
  T.eval("remuda._butler_command_run('guard', {'guard','deny','off'}, {})")
  run_cli("s2-gated", "codex --yolo", "SILENT")
  local unknown = T.eval("return remuda.butler.guard_policy.deny_reason('Read',{file_path='/x/.ssh/a'}, {}) or 'nil'")
  T.eq(unknown, "nil", "unknown tools stay allowed")
  T.expect(true, "", "ok - exact CLI decision, switch gating, redacted audit")
end)
