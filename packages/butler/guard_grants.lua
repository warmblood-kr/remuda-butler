-- Guard slice 3, PR3: the standing-grant store. A grant is one JSON line in guard-grants.jsonl under
-- the protected Butler data dir: scope (class + narrow pattern), ceiling, absolute expiry, holder,
-- and the approval event id. Nothing here creates a grant from the CLI or from agent text: `add` is private
-- and handed once, by register(), to the owner's verified-reaction handler (PR4). With the grants switch
-- off nothing reads the store. Every read is fresh (no cache), so a start always reloads it, and an
-- entry that is expired, unparseable, lacks its approval event or was written "in the future" is no
-- grant (fail closed). Cooperative, like the rest of the guard: not a boundary.
local butler = assert(remuda.butler, "load butler/guard_policy before butler/guard_grants")
local policy = assert(butler.guard_policy, "load butler/guard_policy before butler/guard_grants")
local M = butler.guard_grants or {}
butler.guard_grants = M

M.add = nil -- a live reload must not keep an add from an older load
M.MAX_TTL, M.DEFAULT_TTL = 86400, 3600
local CLASS = { writable = "path", git = "path", net = "net" }
local CEILING = { T1 = true, T2 = true } -- T3 is never grantable
local MAX_FILE = 256 * 1024

-- Test seams: M.now() and M.insensitive(real) replace these when set.
local function now() return (M.now or os.time)() end

local function file() local d = policy.dir(); return d and (d .. "/guard-grants.jsonl") end

local function realpath(path)
  local ok, real = pcall(remuda.fs.realpath, path)
  return ok and type(real) == "string" and real or nil
end

-- A volume is case-insensitive when the case-swapped spelling of an existing path still resolves.
local function probe(real)
  local swapped = real:gsub("%a", function(c) local u = c:upper(); return u == c and c:lower() or u end)
  return swapped ~= real and realpath(swapped) ~= nil
end
local function insensitive(real) return (M.insensitive or probe)(real) end

-- The ONE path canonicaliser (posix paths; ponytail: Windows drive paths yield no grant, add when codex-on-windows grants land).
-- realpath of the nearest existing ancestor plus the remaining segments, which may not be . or ..;
-- lowercased only when the volume is case-insensitive. nil means "cannot parse": no grant.
function M.canonical(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then return nil end
  local segs = {}
  for s in path:gmatch("[^/]+") do segs[#segs + 1] = s end
  for n = #segs, 0, -1 do
    local real = realpath("/" .. table.concat(segs, "/", 1, n))
    if real then
      local out = real
      for i = n + 1, #segs do
        if segs[i] == "." or segs[i] == ".." then return nil end
        out = (out == "/" and "" or out) .. "/" .. segs[i]
      end
      return insensitive(real) and out:lower() or out
    end
  end
end

-- Syntax of a scope pattern, no filesystem: returns segments (path classes) or the host (net).
local function parse(class, pattern)
  if type(pattern) ~= "string" or pattern == "" or pattern:find("%c") then return nil end
  if CLASS[class] == "net" then
    local host = pattern:lower():gsub("%.$", "")
    local h, port = host:match("^([^:]+):(%d+)$")
    h = h or host
    if not h:match("^%w[%w%.%-]*$") or h:find("..", 1, true) or h:match("^[%d%.]+$") then return nil end
    return h .. (port and (":" .. port) or "")
  end
  if CLASS[class] ~= "path" or pattern:sub(1, 1) ~= "/" then return nil end
  local segs = {}
  for s in pattern:gmatch("[^/]+") do segs[#segs + 1] = s end
  if #segs == 0 or segs[1] == "*" then return nil end
  for _, s in ipairs(segs) do
    if s == "." or s == ".." or (s ~= "*" and s:find("[%*%?%[%]]")) then return nil end
  end
  return segs
end

local function covers(g, target)
  if g.class == "net" then return g.scope == target end
  local want = {}
  for s in g.scope:gmatch("[^/]+") do want[#want + 1] = s end
  local have = {}
  for s in target:gmatch("[^/]+") do have[#have + 1] = s end
  if #have < #want then return false end
  for i, s in ipairs(want) do if s ~= "*" and s ~= have[i] then return false end end
  return true
end

-- A grant never overrides a deny or a weaken/identity/escape decision: the guard consults the store only for
-- calls it would otherwise ask about. These scopes are refused anyway so a grant cannot even be requested
-- over the places the guard protects: a shallow root, the home itself, credentials, Butler's own data and
-- config, and git's code-running files.
local PROTECTED_SEGMENTS = { { ".ssh" }, { ".claude" }, { ".git", "hooks" }, { ".git", "config" }, { ".config", "remuda" } }
local function protected_places(home)
  return { policy.dir(), home and (home .. "/.ssh"), home and (home .. "/.claude"), home and (home .. "/.config/remuda") }
end
local function protected_segment(path)
  local segs = {}
  for s in path:gmatch("[^/]+") do segs[#segs + 1] = s end
  for _, seq in ipairs(PROTECTED_SEGMENTS) do
    for i = 1, #segs - #seq + 1 do
      local hit = true
      for k, name in ipairs(seq) do if segs[i + k - 1]:lower() ~= name then hit = false; break end end
      if hit then return true end
    end
  end
end
local function protected_scope(scope, fixed, asked)
  local pattern = { class = "path", scope = scope }
  local depth = asked -- depth as written: a firmlink like /home resolves deeper on macOS
  local home = M.canonical(os.getenv("HOME") or "")
  if depth < 2 or (home and covers(pattern, home)) then return "scope is too shallow" end
  for _, place in ipairs(protected_places(home)) do
    local p = place and M.canonical(place)
    if p and (covers(pattern, p) or fixed == p or p:sub(1, #fixed + 1) == fixed .. "/" or fixed:sub(1, #p + 1) == p .. "/") then
      return "scope covers a protected directory"
    end
  end
  if protected_segment(scope) then return "scope covers a protected directory" end
end

-- The same places, asked of a call's canonical target: a broad scope never reaches them.
local function protected_target(target)
  if protected_segment(target) then return true end
  for _, place in ipairs(protected_places(M.canonical(os.getenv("HOME") or ""))) do
    local p = place and M.canonical(place)
    if p and (target == p or target:sub(1, #p + 1) == p .. "/") then return true end
  end
end

-- The resolved scope to store: the fixed prefix through canonical(), any whole-segment * kept after it.
function M.scope(class, pattern)
  local parsed = parse(class, pattern)
  if not parsed then return nil, "scope is not a narrow pattern" end
  if type(parsed) == "string" then return parsed end
  local star
  for i, s in ipairs(parsed) do if s == "*" then star = i; break end end
  local fixed = M.canonical("/" .. table.concat(parsed, "/", 1, (star or #parsed + 1) - 1))
  if not fixed then return nil, "scope cannot be resolved" end
  local out = fixed
  if star then
    local tail = table.concat(parsed, "/", star)
    out = fixed .. "/" .. (insensitive(fixed) and tail:lower() or tail)
  end
  local why = protected_scope(out, fixed, (star or #parsed + 1) - 1)
  if why then return nil, why end
  return out
end

-- Every line, decoded, with its raw text. At most MAX_FILE+1 bytes are read: add() keeps the file under MAX_FILE,
-- so a larger one was not written by us and is nil (no grants, fail closed).
local function lines()
  local path = file()
  local f = path and io.open(path, "r")
  if not f then return {} end
  local text = f:read(MAX_FILE + 1) or ""
  f:close()
  if #text > MAX_FILE then return nil end
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local ok, e = pcall(remuda.json.decode, line)
    if ok and type(e) == "table" then out[#out + 1] = { raw = line, e = e } end
  end
  return out
end
local function entries()
  local out = {}
  for _, l in ipairs(lines() or {}) do out[#out + 1] = l.e end
  return out
end

local function text(v) return type(v) == "string" and v ~= "" and #v <= 200 and not v:find("%c") end

-- No grant unless every field is sound and the clock agrees (fail closed).
local function valid(e, t)
  return type(e.id) == "string" and e.id:match("^g%d%d%d+$") and CLASS[e.class] and CEILING[e.ceiling]
    and text(e.holder) and text(e.event) and parse(e.class, e.scope) and e.scope == e.scope:gsub("/+$", "")
    and math.type(e.written) == "integer" and math.type(e.expires) == "integer"
    and e.written <= t and e.expires > t and e.expires - e.written <= M.MAX_TTL and e.expires > e.written
end

function M.active()
  local t, seen, out = now(), {}, {}
  for _, e in ipairs(entries()) do
    if not seen[tostring(e.id)] and valid(e, t) then seen[e.id] = true; out[#out + 1] = e end
  end
  return out
end

-- Run fn holding the store's advisory lock (core's remuda.fs.lock); refuse if it stays held.
-- ponytail: on a core without fs.lock this runs unlocked, as Butler's single-instance guard does.
local function locked(path, fn)
  if not (remuda.fs and type(remuda.fs.lock) == "function") then return fn() end
  for _ = 1, 20 do
    local ok, handle = pcall(remuda.fs.lock, path)
    if ok and handle then
      local ran, a, b = pcall(fn)
      pcall(function() handle:release() end)
      if not ran then return nil, tostring(a) end
      return a, b
    end
    pcall(remuda.process.run, { argv = { "sleep", "0.05" }, timeout = 2 })
  end
  return nil, "grant store is busy"
end

-- Record a grant. Returns its id (gNNN), or nil and why. TTL <= 24h whoever asks.
local function add(e)
  local path = file()
  if not path then return nil, "Butler data directory is unknown" end
  local ttl = e.ttl == nil and M.DEFAULT_TTL or e.ttl
  if not CLASS[e.class] then return nil, "unknown class" end
  if not CEILING[e.ceiling] then return nil, "ceiling must be T1 or T2" end
  if math.type(ttl) ~= "integer" or ttl <= 0 or ttl > M.MAX_TTL then return nil, "ttl must be 1 second to 24 hours" end
  if not (text(e.holder) and text(e.event)) then return nil, "holder and approval event are required" end
  local scope, why = M.scope(e.class, e.scope)
  if not scope then return nil, why end
  pcall(remuda.mkdir, policy.dir())
  return locked(path .. ".lock", function()
    -- Under the lock: prune what is gone, allocate the id and write, so two adds never share an id or lose a line.
    -- The line holding the highest id stays even when expired, so an id is never reused.
    local t, top, topraw, keep = now(), 0, nil, {}
    local old = lines()
    if not old then return nil, "grant store is too large" end
    for _, l in ipairs(old) do
      local n = tonumber(tostring(l.e.id):match("^g(%d+)$")) or 0
      if n > top then top, topraw = n, l.raw end
      if math.type(l.e.expires) == "integer" and l.e.expires > t then keep[#keep + 1] = l.raw end
    end
    local id = string.format("g%03d", top + 1)
    local line = remuda.json.encode({ id = id, class = e.class, scope = scope, ceiling = e.ceiling, holder = e.holder,
      event = e.event, written = t, expires = t + ttl })
    local out = {}
    if topraw then out[1] = topraw end
    for _, raw in ipairs(keep) do if raw ~= topraw then out[#out + 1] = raw end end
    out[#out + 1] = line
    local body = table.concat(out, "\n") .. "\n"
    if #body > MAX_FILE then return nil, "grant store is full" end
    local ok, err = remuda.fs.write_atomic(path, body, { private = true })
    if not ok then return nil, tostring(err) end
    return id
  end)
end

-- The one-time hand-over of add to the owner-reaction handler: handler(add) runs once per load of this module,
-- later calls (and non-functions) get nil. Cooperative like the text deny in guard_policy: it keeps add off the
-- module table, it does not stop Lua running inside the daemon.
local registered
function M.register(handler)
  if registered or type(handler) ~= "function" then return nil, "grant store add is already registered" end
  registered = true
  handler(add)
  return true
end

-- Direction-control characters (U+202A-202E, U+2066-2069, U+200E/F and friends) are shown escaped, as in the approval post.
local function show(v, cap)
  return (policy.redact(v, cap):gsub("\226\128[\142\143\168-\174]", function(c) return string.format("\\u%04X", utf8.codepoint(c)) end)
    :gsub("\226\129[\166-\175]", function(c) return string.format("\\u%04X", utf8.codepoint(c)) end)
    :gsub("\216\156", "\\u061C"))
end

-- `guard grants`: the operator's view. Names and times only, control characters removed.
function M.list()
  if not policy.grants_enabled() then
    return "guard grants: off (the store is not consulted). Next: remuda butler guard grants on"
  end
  local gs, t = M.active(), now()
  if #gs == 0 then return "guard grants: no active grants" end
  local out = { "guard grants: " .. #gs .. " active" }
  for _, g in ipairs(gs) do
    out[#out + 1] = string.format("%s  %s  %s  ceiling %s  holder %s  expires %s (in %dm)  event %s", g.id, g.class,
      show(g.scope, 300), g.ceiling, show(g.holder, 60),
      os.date("!%Y-%m-%dT%H:%M:%SZ", g.expires), math.ceil((g.expires - t) / 60), show(g.event, 80))
  end
  return table.concat(out, "\n")
end

-- Pushes under a grant: any CI or workflow path is T3 (always asks). The list is reviewed like a guard rule.
-- scripts/ (a segment at any depth), Makefile and justfile (by basename) are what CI calls, so they count as CI.
local CI_PREFIX = { ".github/", ".circleci/", ".buildkite/", ".gitlab/" }
local CI_FILE = { [".gitlab-ci.yml"] = 1, ["jenkinsfile"] = 1, [".travis.yml"] = 1, ["azure-pipelines.yml"] = 1,
  ["bitbucket-pipelines.yml"] = 1, [".drone.yml"] = 1, ["cloudbuild.yaml"] = 1, ["appveyor.yml"] = 1, [".appveyor.yml"] = 1 }
local CI_BASENAME = { ["makefile"] = 1, ["gnumakefile"] = 1, ["justfile"] = 1 }
function M.touches_ci(names)
  for _, name in ipairs(names) do
    local lower = name:lower()
    if CI_FILE[lower] or CI_BASENAME[lower:match("[^/]*$")] or ("/" .. lower):find("/scripts/", 1, true) then return true end
    for _, p in ipairs(CI_PREFIX) do if lower:sub(1, #p) == p then return true end end
  end
  return false
end

-- Files the push would add over the upstream ref, best effort; nil when it cannot be computed.
function M.diff_names(cwd, base)
  -- Repo config must not run anything at hook time (fsmonitor, hooks, external diff, textconv); renames are
  -- split so a move out of a CI path still lists the source. base is the ref the push updates.
  local argv = { "env", "GIT_OPTIONAL_LOCKS=0", "git", "-C", cwd, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
    "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", (base or "@{upstream}") .. "...HEAD" }
  local ok, r = pcall(remuda.process.run, { argv = argv, timeout = 5 })
  if not ok or type(r) ~= "table" or r.code ~= 0 or r.timed_out then return nil end
  local names = {}
  for name in (r.stdout or ""):gmatch("[^\0]+") do names[#names + 1] = name end
  return names
end

local FILE_TOOLS = { Write = 1, Edit = 1, MultiEdit = 1, NotebookEdit = 1 }
local DEFAULT_PORT = { http = "80", https = "443" }
local function host_of(url)
  if type(url) ~= "string" then return nil end
  local scheme, authority = url:match("^(%a[%w+.-]*)://([^/?#]*)")
  if not scheme then return nil end
  -- Anything a parser could read differently from us is no grant: backslash, whitespace, control, userinfo.
  if url:find("[\\%s%c]") or authority:find("@", 1, true) then return nil end
  local host, port = authority:match("^([^:]+):(%d+)$")
  host = host or authority
  if port and port == DEFAULT_PORT[scheme:lower()] then port = nil end
  return parse("net", host .. (port and (":" .. port) or ""))
end

-- Trimmed stdout of `git -C cwd ...`, nil when git fails (an unset config key included).
local function git(cwd, ...)
  local ok, r = pcall(remuda.process.run, { argv = { "git", "-C", cwd, ... }, timeout = 5 })
  if ok and type(r) == "table" and r.code == 0 and not r.timed_out then return ((r.stdout or ""):gsub("%s+$", "")) end
end

-- A push is covered only when the command is exactly `git push [remote [current-branch]]`: no shell syntax, no
-- cd/-C/env/GIT_DIR prefix, no refspec, no flag. The remote word must be a configured remote (never a path) with
-- no remote.<r>.push, push.default must not be matching/nothing, and the 2-3 word forms must push to the upstream
-- (git's `simple` rule). Returns the ref the push updates, which is what the diff runs against; anything else
-- falls to the tier (ask).
local function plain_push(command, cwd)
  -- the character set also refuses tabs, newlines, = : + ; & | ` $ ( ) < > and quotes
  if type(command) ~= "string" or type(cwd) ~= "string" or command:find("[^%w %./_@%-]") then return nil end
  local w = {}
  for s in command:gmatch("%S+") do w[#w + 1] = s end
  if #w < 2 or #w > 4 or w[1] ~= "git" or w[2] ~= "push" then return nil end
  for i = 3, #w do if w[i]:find("^%-") then return nil end end
  local branch = git(cwd, "symbolic-ref", "--short", "-q", "HEAD")
  if not branch or branch == "" then return nil end
  -- git pushes to remote.pushDefault / branch.<b>.pushRemote when set, not to the upstream the diff is taken against
  if git(cwd, "config", "--get", "remote.pushDefault") or git(cwd, "config", "--get", "branch." .. branch .. ".pushRemote") then return nil end
  local mode = git(cwd, "config", "--get", "push.default")
  if mode == "matching" or mode == "nothing" then return nil end
  local up_remote, up_merge = git(cwd, "config", "--get", "branch." .. branch .. ".remote"), git(cwd, "config", "--get", "branch." .. branch .. ".merge")
  local remote = w[3] or up_remote
  if #w < 4 and not (up_remote == remote and up_merge == "refs/heads/" .. branch) then return nil end
  if #w == 4 and w[4] ~= branch then return nil end
  for name in (git(cwd, "remote") or ""):gmatch("[^\n]+") do
    if name == remote then
      if git(cwd, "config", "--get-all", "remote." .. name .. ".push") then return nil end
      return "refs/remotes/" .. remote .. "/" .. branch
    end
  end
end

-- The id of the active grant that covers this call, or nil. Never takes an id from the call itself.
function M.match(tool, input, cwd)
  if not policy.grants_enabled() then return nil end
  input = type(input) == "table" and input or {}
  local class, target, base
  if FILE_TOOLS[tool] then
    class, target = "writable", M.canonical(input.file_path or input.notebook_path)
  elseif tool == "WebFetch" then
    class, target = "net", host_of(input.url)
  elseif (tool == "Bash" or tool == "PowerShell") and policy.classify(tool, input, { cwd = cwd }) == "push" then
    base = plain_push(input.command, cwd)
    if not base then return nil end
    class, target = "git", M.canonical(cwd)
  end
  if not target or (class ~= "net" and protected_target(target)) then return nil end
  for _, g in ipairs(M.active()) do
    if g.class == class and covers(g, target) then
      if class == "git" then
        local names = M.diff_names(cwd, base)
        if names == nil or M.touches_ci(names) then return nil end -- no diff: the tier asks
      end
      return g.id
    end
  end
  return nil
end

return M
