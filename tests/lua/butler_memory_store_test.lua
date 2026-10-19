-- #535 phase 3: the agent-neutral, Butler-owned memory store and its adapters.
local memory = dofile("packages/butler/memory_store.lua")

local function q(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end

T.test("the store root and per-Butler directory", function()
  local env = {}
  local getenv = function(k) return env[k] end
  T.eq(memory.root(getenv, "/d"), "/d/remuda/butler/memory")
  env.REMUDA_BUTLER_MEMORY_HOME = "/m"
  T.eq(memory.root(getenv, "/d"), "/m")
  T.eq(memory.root(function() return nil end, nil), nil)
  T.eq(memory.dir("/m", "lead1"), "/m/lead1")
  for _, bad in ipairs({ "", "../x", "a/b", ".hidden", "a..b", 7 }) do
    T.eq(memory.dir("/m", bad), nil, "name " .. tostring(bad))
  end
  T.eq(memory.dir(nil, "lead1"), nil)
end)

T.test("the block shows the index, or says why it does not", function()
  local files = { ["/m/a/MEMORY.md"] = "# Memory\n- [x](x.md) — hook\n" }
  local read = function(path) return files[path] end
  local block = memory.block("/m/a", "a", read)
  T.eq(block.id, "memory")
  T.ok(block.body:find("Your durable memory is in `/m/a`", 1, true), block.body)
  T.eq(block.body:sub(-#"- [x](x.md) — hook\n"), "- [x](x.md) — hook\n")
  T.ok(memory.block("/m/b", "b", read).body:find("was not shown here (missing)", 1, true))
  files["/m/c/MEMORY.md"] = string.rep("x", memory.INDEX_MAX + 1)
  T.ok(memory.block("/m/c", "c", read).body:find("(over 8 KiB)", 1, true))
  files["/m/d/MEMORY.md"] = "<!-- BEGIN remuda-butler:managed id=butler -->\n"
  local marked = memory.block("/m/d", "d", read)
  T.ok(not marked.body:find("BEGIN remuda", 1, true), "a marker line must not reach AGENTS.md")
  T.ok(memory.block("/m/e", "e", function() return nil, "unreadable" end).body:find("(unreadable)", 1, true))
end)

T.test("Claude and Codex adapters", function()
  local s = memory.claude_settings("/m/a", q)
  T.eq(s.top, '"autoMemoryDirectory":"/m/a"')
  T.eq(s.permissions, '"additionalDirectories":["/m/a"]')
  T.eq(table.concat(s.allow, ","), '"Read(//m/a/**)","Edit(//m/a/**)"')
  T.eq(memory.claude_settings("relative", q), nil)
  T.eq(memory.claude_settings(nil, q), nil)
  T.eq(table.concat(memory.codex_writable({ "/w", "/w" }, "/m/a"), ","), "/w,/m/a")
  T.eq(table.concat(memory.codex_writable(nil, "/m/a"), ","), "/m/a")
  T.eq(table.concat(memory.codex_writable({ "/m/a" }, "/m/a"), ","), "/m/a")
  T.eq(#memory.codex_writable(nil, nil), 0)
end)

T.test("root and members get their store, block, env and adapters", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "Butler root ready")
  local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("a"); f:close(); return text
  end
  local root_dir = T.eval('return remuda._butler_memory_dir("butler")')
  T.ok(root_dir:find("/remuda/butler/memory/butler$"), root_dir)
  T.eq(read(root_dir .. "/MEMORY.md"), memory.INDEX_SEED, "seed index")
  local root_md = T.eval('return remuda._butler_paths.butler_session_cwd') .. "/AGENTS.md"
  T.wait_until(function() return (read(root_md) or ""):find("managed id=memory", 1, true) ~= nil end, 5,
    "root AGENTS.md carries the memory block")
  -- A note the agent saved shows in the block at the next refresh; the seed is never rewritten.
  local f = assert(io.open(root_dir .. "/MEMORY.md", "w"))
  f:write("# Memory\n- [deploy](deploy.md) — deploy only from main\n"); f:close()
  T.eval('remuda._butler_refresh_guidance(remuda._butler_bus.agents.butler); return "ok"')
  T.ok(read(root_md):find("- [deploy](deploy.md) — deploy only from main", 1, true), read(root_md))
  T.ok(read(root_dir .. "/MEMORY.md"):find("deploy only from main", 1, true), "index overwritten")

  -- A Claude member, then the same member relaunched on Codex: one store.
  T.eq(T.eval([[
    local chooser = remuda._butler_chooser
    remuda._butler_codex_config_ok = function() return true end
    local captured = {}
    chooser.choose = function(_, opts, done)
      captured.claude_spec, captured.codex_spec = opts.spec("claude"), opts.spec("codex")
      captured.env = opts.env("claude")
      done(opts.name, "claude", {}, "fake-instance")
    end
    chooser.instance_live = function() return true end
    remuda.exec("butler/launch")
    remuda._butler_launch_impl.launch_agent("claude", "mem1", nil, nil, "butler")
    remuda._t_captured = captured
    return "ok"
  ]]), "ok")
  local dir = T.eval('return remuda._butler_memory_dir("mem1")')
  T.eq(T.eval('return remuda._t_captured.env.REMUDA_BUTLER_MEMORY_DIR'), dir)
  T.eq(read(dir .. "/MEMORY.md"), memory.INDEX_SEED)
  local settings = read(T.eval('return remuda._t_captured.claude_spec.settings_path'))
  T.ok(settings:find('"autoMemoryDirectory":' .. q(dir), 1, true), settings)
  T.ok(settings:find('"additionalDirectories":[' .. q(dir) .. ']', 1, true), settings)
  T.ok(settings:find(q("Edit(/" .. dir .. "/**)"), 1, true), settings)
  T.ok(settings:find('"instructionFiles":"claude-md-and-agents-md"', 1, true), settings)
  T.eq(T.eval('local w = remuda._t_captured.codex_spec.writable; return w and w[#w] or "none"'), dir,
    "Codex member gets the same store as a writable root")
  T.eq(T.eval('return tostring(remuda._t_captured.claude_spec.writable)'), "nil", "Claude spec gets no Codex roots")
  local member_md = read(T.eval('return remuda._butler_bus.agents.mem1.cwd') .. "/AGENTS.md")
  T.ok(member_md:find("managed id=guidance-layers", 1, true) and member_md:find("managed id=memory", 1, true), member_md)
  T.ok(member_md:find("Your durable memory is in `" .. dir .. "`", 1, true), member_md)
end)
