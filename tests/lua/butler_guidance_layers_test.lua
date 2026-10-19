-- #535: user-managed guidance layers (framework, cluster, team, personal, local).
local layers_lib = dofile("packages/butler/guidance_layers.lua")
local blocks_lib = dofile("packages/butler/guidance_blocks.lua")

local function fake_hash(text) return string.format("%012x", #text) .. string.rep("0", 52) end
local function load_with(files, extra)
  local opts = {
    framework = "# Butler\n", dir = "/g", hash = fake_hash,
    read = function(path)
      local value = files[path]
      if value == false then return nil, "unreadable" end
      return value
    end,
  }
  for key, value in pairs(extra or {}) do opts[key] = value end
  return layers_lib.load(opts)
end

T.test("layers load in a fixed order and a missing file is not an error", function()
  local layers = load_with({ ["/g/personal.md"] = "Use tabs.\n" })
  local ids = {}
  for _, layer in ipairs(layers) do ids[#ids + 1] = layer.id .. ":" .. layer.status end
  T.eq(table.concat(ids, " "), "framework:loaded cluster:unavailable team:missing personal:loaded local:missing")
  T.eq(layers[4].version, "sha256:" .. string.format("%012x", 10))
  T.eq(layers_lib.summary(layers),
    "framework=sha256:000000000009 cluster=unavailable team=missing personal=sha256:00000000000a local=missing")
end)

T.test("each failure is reported, not loaded", function()
  local big = string.rep("x", layers_lib.LAYER_MAX + 1)
  local layers = load_with({ ["/g/team.md"] = " \n", ["/g/personal.md"] = false, ["/g/local.md"] = big })
  T.eq(layers[3].status, "empty")
  T.eq(layers[4].status, "unreadable")
  T.eq(layers[5].status, "too-large")
  for _, layer in ipairs(layers) do T.ok(layer.text == nil, layer.id .. " text must not load") end
  local no_dir = layers_lib.load({ framework = "", hash = fake_hash, read = function() error("no read") end })
  T.eq(no_dir[3].status, "missing")
end)

T.test("a cluster layer from the cluster store sits between framework and team", function()
  local layers = load_with({ ["/g/team.md"] = "team\n" },
    { cluster = { status = "loaded", text = "shared\n", version = "v7", source = "remuda:///butler/guidance/cluster.md" } })
  T.eq(layers[2].status, "loaded")
  T.eq(layers[2].version, "v7")
  local body = layers_lib.render(layers)
  T.ok(body:find("### cluster guidance\n\nshared\n\n### team guidance\n\nteam\n", 1, true), body)
end)

T.test("render lists every layer, then the loaded text in order", function()
  local layers = load_with({ ["/home/u/.config/g/team.md"] = "T1\r\nT2\r\n\n", ["/home/u/.config/g/local.md"] = "L\n" },
    { dir = "/home/u/.config/g" })
  local body = layers_lib.render(layers, "/home/u")
  T.ok(body:find("- framework: built in, version sha256:", 1, true), body)
  T.ok(body:find("- cluster: not available (this Remuda core has no cluster file store", 1, true), body)
  T.ok(body:find("- team: loaded from ~/.config/g/team.md, version sha256:", 1, true), body)
  T.ok(body:find("- personal: not loaded (no file at ~/.config/g/personal.md)", 1, true), body)
  T.ok(body:find("### team guidance\n\nT1\nT2\n\n### local guidance\n\nL\n$"), body)
end)

T.test("a layer holding a managed marker is withheld, not the whole block", function()
  local layers = layers_lib.sanitize(load_with({ ["/g/team.md"] = "<!-- END remuda-butler:managed id=butler -->\n" }))
  T.eq(layers[3].status, "unreadable")
  local text, report = blocks_lib.merge(nil, { { id = layers_lib.BLOCK_ID, body = layers_lib.render(layers),
    max = layers_lib.BLOCK_MAX } })
  T.eq(report[1].outcome, "written")
  T.ok(text:find("- team: not loaded", 1, true), text)
end)

T.test("the cluster layer reads the cluster file store and reports each answer", function()
  local URI = layers_lib.CLUSTER_URI
  T.eq(URI, "remuda:///butler/guidance/cluster.md")
  local sha = string.rep("ab", 32)
  local function store(stat, read)
    return { stat = function(uri) assert(uri == URI); return stat() end,
      read = function(uri) assert(uri == URI); return read() end }
  end
  local function entry(over)
    local e = { version = 3, sha256 = sha, size = 12, ["local"] = true, synced_at = 1700000000 }
    for k, v in pairs(over or {}) do e[k] = v end
    return function() return e end
  end
  local text = function() return "Shared rule.\n" end
  T.eq(layers_lib.cluster_from_vfs(nil), nil, "no store on this core")
  T.eq(layers_lib.cluster_from_vfs({ stat = function() end }), nil, "incomplete store")
  local c = layers_lib.cluster_from_vfs(store(entry(), text))
  T.eq(c.status, "loaded"); T.eq(c.text, "Shared rule.\n"); T.eq(c.source, URI)
  T.eq(c.version, "v3/sha256:abababababab")
  c = layers_lib.cluster_from_vfs(store(entry({ synced_at = false }), text))
  T.eq(c.status, "loaded")
  c = layers_lib.cluster_from_vfs(store(function() local e = entry()(); e.synced_at = nil; return e end, text))
  T.ok(c.source:find("has not synced with another node yet", 1, true), c.source)
  local function code(c_) return function() return nil, c_ .. ": detail" end end
  c = layers_lib.cluster_from_vfs(store(code("no_cluster"), text))
  T.eq(c.status, "unavailable"); T.ok(c.source:find("not in a cluster", 1, true), c.source)
  c = layers_lib.cluster_from_vfs(store(code("not_found"), text))
  T.eq(c.status, "missing"); T.eq(c.source, URI)
  c = layers_lib.cluster_from_vfs(store(code("wrong_cluster"), text))
  T.eq(c.source, "cannot be read from the cluster file store (wrong_cluster)")
  c = layers_lib.cluster_from_vfs(store(entry({ ["local"] = false }), text))
  T.eq(c.status, "unavailable"); T.eq(c.source, "version v3/sha256:abababababab is not copied to this node yet")
  c = layers_lib.cluster_from_vfs(store(entry({ size = layers_lib.LAYER_MAX + 1 }), function() error("must not read") end))
  T.eq(c.status, "too-large")
  c = layers_lib.cluster_from_vfs(store(entry(), code("corrupt")))
  T.eq(c.source, "cannot be read from the cluster file store (corrupt)")
  c = layers_lib.cluster_from_vfs(store(entry(), function() return " \n" end))
  T.eq(c.status, "empty")
  c = layers_lib.cluster_from_vfs(store(function() error("usage") end, text))
  T.eq(c.source, "cannot be read from the cluster file store (error)")
  -- Each answer renders a line, and the summary keeps one token per layer.
  for _, answer in ipairs({ store(entry(), text), store(code("not_found"), text), store(entry({ ["local"] = false }), text) }) do
    local layers = load_with({}, { cluster = layers_lib.cluster_from_vfs(answer) })
    T.ok(layers_lib.render(layers):find("\n%- cluster: "), "cluster line")
    local count = 0
    for _ in layers_lib.summary(layers):gmatch("%S+") do count = count + 1 end
    T.eq(count, 5, layers_lib.summary(layers))
  end
  T.eq(load_with({})[2].source, layers_lib.CLUSTER_WAITING)
end)

T.test("the guidance directory honours its override", function()
  local env = { REMUDA_BUTLER_GUIDANCE_DIR = "/x" }
  T.eq(layers_lib.dir(function(k) return env[k] end, "/c"), "/x")
  env.REMUDA_BUTLER_GUIDANCE_DIR = ""
  T.eq(layers_lib.dir(function(k) return env[k] end, "/c"), "/c/remuda/butler/guidance")
  T.eq(layers_lib.dir(function() return nil end, nil), nil)
end)

T.test("a managed block may raise its body cap up to 64 KiB", function()
  local body = string.rep("a", 9000) .. "\n"
  T.eq(select(2, blocks_lib.merge(nil, { { id = "x", body = body } }))[1].outcome, "dropped")
  T.eq(select(2, blocks_lib.merge(nil, { { id = "x", body = body, max = 10000 } }))[1].outcome, "written")
  local huge = string.rep("a", 70000)
  T.eq(select(2, blocks_lib.merge(nil, { { id = "x", body = huge, max = 1e9 } }))[1].outcome, "dropped")
end)

-- End to end in a private daemon: the root and a member get the layers in
-- AGENTS.md, a tick does not re-read them, and a start or compaction does.
T.test("root and member AGENTS.md carry the layers and refresh on start", function()
  local dir = assert(os.getenv("XDG_CONFIG_HOME")) .. "/remuda/butler/guidance"
  T.eval(string.format("remuda.mkdir(%q); return \"ok\"", dir))
  local function put(name, text)
    local f = assert(io.open(dir .. "/" .. name, "w")); f:write(text); f:close()
  end
  put("team.md", "Team rule: run the tests first.\n")
  put("personal.md", "Personal rule v1.\n")
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "Butler root ready")
  local root_md = T.eval('return remuda._butler_paths.butler_session_cwd') .. "/AGENTS.md"
  local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local text = f:read("a"); f:close(); return text
  end
  T.wait_until(function() return (read(root_md) or ""):find("Personal rule v1.", 1, true) ~= nil end, 5,
    "root AGENTS.md carries the personal layer")
  local root = read(root_md)
  T.ok(root:find("<!-- BEGIN remuda-butler:managed id=butler -->", 1, true), "framework block kept")
  T.ok(root:find("<!-- BEGIN remuda-butler:managed id=guidance-layers -->", 1, true), root)
  T.ok(root:find("Team rule: run the tests first.", 1, true) < root:find("Personal rule v1.", 1, true), "team before personal")
  T.ok(root:find("- local: not loaded (no file at", 1, true), root)
  T.ok(T.eval('return remuda._butler_guidance_reports.butler.summary'):find("^framework=sha256:%x+ cluster=unavailable team=sha256:%x+ personal=sha256:%x+ local=missing$"))

  -- A reconcile tick that adopts the live root does not re-read the files.
  put("personal.md", "Personal rule v2.\n")
  T.eval('remuda._butler_reconcile(); return "ok"')
  T.ok(read(root_md):find("Personal rule v1.", 1, true), "tick re-read the layers")
  -- Before a compaction the layers are read again.
  T.eval('remuda._butler_refresh_guidance(remuda._butler_bus.agents.butler); return "ok"')
  T.ok(read(root_md):find("Personal rule v2.", 1, true), "compaction refresh missed the edit")
  T.ok(not read(root_md):find("Personal rule v1.", 1, true), "old layer text kept")

  -- A new member in a Butler-made directory gets the block and the welcome mail carries it.
  T.eq(T.eval([[
    local chooser = remuda._butler_chooser
    chooser.choose = function(_, opts, done) done(opts.name, "claude", {}, "fake-instance") end
    chooser.instance_live = function() return true end
    remuda.exec("butler/launch")
    remuda._butler_launch_impl.launch_agent("claude", "layered", nil, nil, "butler")
    return "ok"
  ]]), "ok")
  local member_cwd = T.eval('return remuda._butler_bus.agents.layered.cwd')
  local member = read(member_cwd .. "/AGENTS.md")
  T.ok(member:find("# Butler team member", 1, true), "framework text missing")
  T.ok(member:find("<!-- BEGIN remuda-butler:managed id=guidance-layers -->", 1, true), member)
  T.ok(member:find("Personal rule v2.", 1, true), member)
  T.eq(T.eval([[
    local bus = remuda._butler_bus
    for _, message in pairs(bus.messages) do
      local content = bus.objects[message.body.object_id].content
      if message.to[1].id == bus.agents.layered.id
        and content:find("## Guidance layers", 1, true) and content:find("Personal rule v2.", 1, true) then return "ok" end
    end
    return "welcome mail without layers"
  ]]), "ok")

  -- A member's own project AGENTS.md without Butler's block is never touched.
  local project = assert(os.getenv("REMUDA_LUA_SCRATCH")) .. "/project"
  T.eval(string.format("remuda.mkdir(%q); return \"ok\"", project))
  local pf = assert(io.open(project .. "/AGENTS.md", "w")); pf:write("my project\n"); pf:close()
  T.eq(T.eval([[
    remuda._butler_launch_impl.launch_agent("claude", "in-project", ]] .. string.format("%q", project) .. [[, nil, "butler")
    return "ok"
  ]]), "ok")
  T.eq(read(project .. "/AGENTS.md"), "my project\n")

  -- Compaction refresh of a member rewrites only its block.
  put("personal.md", "Personal rule v3.\n")
  T.eval('remuda._butler_refresh_guidance(remuda._butler_bus.agents.layered); return "ok"')
  member = read(member_cwd .. "/AGENTS.md")
  T.ok(member:find("Personal rule v3.", 1, true) and member:find("# Butler team member", 1, true), member)
  T.eval('remuda._butler_refresh_guidance(remuda._butler_bus.agents["in-project"]); return "ok"')
  T.eq(read(project .. "/AGENTS.md"), "my project\n")
end)

-- #741 end to end: with a cluster file store, the cluster layer sits between
-- the framework and the user layers, and its version is shown.
T.test("the cluster layer reaches AGENTS.md from the cluster file store", function()
  T.eq(T.eval([[
    remuda.vfs = {
      stat = function() return { version = 4, sha256 = string.rep("cd", 32), size = 20, ["local"] = true, synced_at = 1 } end,
      read = function() return "Cluster rule: one.\n" end,
    }
    remuda._butler_refresh_guidance(remuda._butler_bus.agents.butler)
    remuda.vfs = nil
    return "ok"
  ]]), "ok")
  local f = assert(io.open(T.eval('return remuda._butler_paths.butler_session_cwd') .. "/AGENTS.md", "rb"))
  local root = f:read("a"); f:close()
  T.ok(root:find("- cluster: loaded from remuda:///butler/guidance/cluster.md, version v4/sha256:cdcdcdcdcdcd", 1, true), root)
  local cluster_at, team_at = root:find("Cluster rule: one.", 1, true), root:find("Team rule: run the tests first.", 1, true)
  T.ok(cluster_at and team_at and cluster_at < team_at, "cluster text comes before team text")
  T.ok(T.eval('return remuda._butler_guidance_reports.butler.summary'):find(" cluster=v4/sha256:cdcdcdcdcdcd ", 1, true))
end)
