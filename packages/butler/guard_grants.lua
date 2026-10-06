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
M._revoked = M._revoked or {} -- ids revoked in memory whose line could not be saved; the file is the truth otherwise
M._frozen = M._frozen or false -- a freeze whose marker could not be saved
M.MAX_TTL, M.DEFAULT_TTL = 86400, 3600
local CLASS = { writable = "path", git = "path", net = "net" }
local CEILING = { T1 = true, T2 = true } -- T3 is never grantable
local MAX_FILE = 256 * 1024

-- Test seams: M.now(), M.insensitive(real) and M.verified(e) replace these, but only when the process env carried
-- REMUDA_BUTLER_TEST=1 when this module loaded (the harness sets it for its child daemon). The flag is read once, here:
-- later Lua cannot switch it on, and the text deny in guard_policy refuses the field and the env name.
local TEST_MODE = os.getenv("REMUDA_BUTLER_TEST") == "1"
local function seam(name) return TEST_MODE and M[name] or nil end
local function now() return (seam("now") or os.time)() end

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
local function insensitive(real) return (seam("insensitive") or probe)(real) end

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
local PROTECTED_SEGMENTS = { { ".ssh" }, { ".claude" }, { ".config", "remuda" } }
local function protected_places(home)
  return { policy.dir(), home and (home .. "/.ssh"), home and (home .. "/.claude"), home and (home .. "/.config/remuda") }
end
local function protected_segment(path)
  local segs = {}
  for s in path:gmatch("[^/]+") do segs[#segs + 1] = s end
  -- .git (or a bare repo dir ending in .git, x.git) then hooks|config|config.worktree at any later depth
  -- (.git/modules/<s>/hooks, linked worktrees)
  local git_at
  for i, s in ipairs(segs) do
    local l = s:lower()
    if l:sub(-4) == ".git" then git_at = git_at or i end
    if git_at and i > git_at and (l == "hooks" or l == "config" or l == "config.worktree") then return true end
  end
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

-- Butler's own record of the owner's reaction (the approval store written when the relay saw it): a line the store
-- holds but that record does not vouch for (same reaction event, id, class and scope) is no grant. M.verified is a
-- test seam, like M.now.
local function verified(e)
  local fake = seam("verified")
  if fake then return fake(e) end
  local a = butler.approval
  return a and type(a.granted_by) == "function" and a.granted_by(e.event, e.id, e.class, e.scope, e.holder) == true
end

-- No grant unless every field is sound, the clock agrees and the owner's reaction is on record (fail closed).
local function valid(e, t)
  return type(e.id) == "string" and e.id:match("^g%d%d%d+$") and CLASS[e.class] and CEILING[e.ceiling]
    and text(e.holder) and text(e.event) and parse(e.class, e.scope) and e.scope == e.scope:gsub("/+$", "")
    and math.type(e.written) == "integer" and math.type(e.expires) == "integer"
    and e.written <= t and e.expires > t and e.expires - e.written <= M.MAX_TTL and e.expires > e.written
    and not e.revoked and not M._revoked[e.id] and verified(e)
end

-- Frozen: every grant stops matching and no new one is made until the owner lifts it (marker file under the
-- protected data dir, so it survives a restart). Read fresh each time, like the store itself.
local function frozen_file() local d = policy.dir(); return d and (d .. "/guard-grants-frozen") end
function M.frozen()
  if M._frozen then return true end
  local path = frozen_file()
  local f = path and io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

local function live()
  local t, seen, out = now(), {}, {}
  for _, e in ipairs(entries()) do
    if not seen[tostring(e.id)] and valid(e, t) then seen[e.id] = true; out[#out + 1] = e end
  end
  return out
end

function M.active()
  if M.frozen() then return {} end
  return live()
end

-- The grants the store holds (valid, not expired or revoked), frozen or not: what the expiry notice tracks, so a
-- grant that runs out during a freeze is still announced. It never decides a call; active() does.
function M.held() return live() end

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
  if M.frozen() then return nil, "grants are frozen" end
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

-- Owner controls, handed out with add and never reachable from the CLI. They only narrow power, except unfreeze,
-- which the owner-approved handler alone calls. Each answers a short word, or nil and why.
local controls = {}

-- Revoke one grant: its line is rewritten with the revoke time, so the next hook call no longer matches it. The
-- revoke holds in memory even when the line cannot be saved (fail closed); the failure is returned.
function controls.revoke(id)
  if type(id) ~= "string" or not id:match("^g%d%d%d+$") then return "unknown" end
  local path = file()
  if not path then return nil, "Butler data directory is unknown" end
  return locked(path .. ".lock", function()
    local t, all = now(), lines()
    if not all then return nil, "grant store is too large" end
    local at
    for i, l in ipairs(all) do if l.e.id == id then at = i; break end end
    if not at then return "unknown" end
    local e = all[at].e
    if e.revoked or M._revoked[id] then return "already" end
    if math.type(e.expires) ~= "integer" or e.expires <= t then return "expired" end
    M._revoked[id] = true
    e.revoked = t
    local out = {}
    for i, l in ipairs(all) do out[i] = i == at and remuda.json.encode(e) or l.raw end
    local ok, err = remuda.fs.write_atomic(path, table.concat(out, "\n") .. "\n", { private = true })
    if not ok then return nil, tostring(err) end
    M._revoked[id] = nil
    return "revoked"
  end)
end

function controls.freeze()
  if M.frozen() then return "already" end
  M._frozen = true -- grants stop now, even if the marker cannot be saved
  local path = frozen_file()
  if not path then return nil, "Butler data directory is unknown" end
  pcall(remuda.mkdir, policy.dir())
  local ok, err = remuda.fs.write_atomic(path, "frozen " .. now() .. "\n", { private = true })
  if not ok then return nil, tostring(err) end
  M._frozen = false
  return "frozen"
end

function controls.unfreeze()
  if not M.frozen() then return "not frozen" end
  local path = frozen_file()
  if path then
    local ok, err = os.remove(path)
    local f = not ok and io.open(path, "r")
    if f then f:close(); return nil, tostring(err) end -- still there: stays frozen
  end
  M._frozen = false
  return "lifted"
end

-- Narrowing is public, so an emergency freeze or revoke never depends on the one-time hand-over below (a refused
-- register, or guard_approval reloaded alone). Add and unfreeze, which widen, stay private.
M.freeze, M.revoke = controls.freeze, controls.revoke

-- The one-time hand-over of add and the owner controls to the owner-gated handler: handler(add, controls) runs
-- once per load of this module, later calls (and non-functions) get nil. Cooperative like the text deny in
-- guard_policy: it keeps them off the module table, it does not stop Lua running inside the daemon.
local registered
function M.register(handler)
  if registered or type(handler) ~= "function" then return nil, "grant store add is already registered" end
  registered = true
  handler(add, controls)
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
  local gs, t, frozen = live(), now(), M.frozen()
  local revoked = {}
  for _, e in ipairs(entries()) do
    if (e.revoked or M._revoked[e.id]) and math.type(e.expires) == "integer" and e.expires > t and parse(e.class, e.scope) then
      revoked[#revoked + 1] = string.format("%s  revoked  %s %s", tostring(e.id):gsub("[^%w]", ""), tostring(e.class):gsub("[^%w]", ""), show(e.scope, 300))
    end
  end
  if #gs == 0 and #revoked == 0 and not frozen then return "guard grants: no active grants" end
  local out = { "guard grants: " .. (frozen and ("frozen, none matches and none is made until the owner lifts it in Matrix; " .. #gs .. " held")
    or (#gs .. " active")) }
  for _, g in ipairs(gs) do
    out[#out + 1] = string.format("%s  %s  %s  ceiling %s  holder %s  expires %s (in %dm)  event %s", g.id, g.class,
      show(g.scope, 300), g.ceiling, show(g.holder, 60),
      os.date("!%Y-%m-%dT%H:%M:%SZ", g.expires), math.ceil((g.expires - t) / 60), show(g.event, 80))
  end
  for _, line in ipairs(revoked) do out[#out + 1] = line end
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

-- One wall-clock budget for all the git probes of one match()/offer(), checked before each call; spent means no grant.
-- ponytail: os.time() has 1 s resolution, so the budget is 2 s +/- 1 s; a finer clock when core has one.
local GIT_BUDGET, GIT_TIMEOUT = 2, 2
local deadline
local function spent() return deadline ~= nil and os.time() >= deadline end
local function budgeted(fn)
  return function(...)
    deadline = os.time() + GIT_BUDGET
    local r = table.pack(pcall(fn, ...))
    deadline = nil
    if not r[1] then error(r[2], 0) end
    return table.unpack(r, 2, r.n)
  end
end

-- Files the push would add over the upstream ref, best effort; nil when it cannot be computed.
function M.diff_names(cwd, base)
  -- Repo config must not run anything at hook time (fsmonitor, hooks, external diff, textconv); renames are
  -- split so a move out of a CI path still lists the source. base is the ref the push updates.
  local argv = { "env", "GIT_OPTIONAL_LOCKS=0", "git", "-C", cwd, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
    "--no-pager", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", (base or "@{upstream}") .. "...HEAD" }
  if spent() then return nil end
  local ok, r = pcall(remuda.process.run, { argv = argv, timeout = GIT_TIMEOUT })
  if not ok or type(r) ~= "table" or r.code ~= 0 or r.timed_out then return nil end
  local names = {}
  for name in (r.stdout or ""):gmatch("[^\0]+") do names[#names + 1] = name end
  return names
end

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

-- Trimmed stdout and exit code of `git -C cwd ...`; nil when git could not run, timed out or the budget is spent.
local function git(cwd, ...)
  if spent() then return nil end
  local ok, r = pcall(remuda.process.run, { argv = { "git", "-C", cwd, ... }, timeout = GIT_TIMEOUT })
  if ok and type(r) == "table" and type(r.code) == "number" and not r.timed_out then return ((r.stdout or ""):gsub("%s+$", "")), r.code end
end

-- A grant never publishes the default branches: they are T3 and always ask, as are tags.
local PROTECTED_BRANCH = { main = true, master = true, trunk = true }

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
  -- the full ref: --short prints heads/main when a tag named main exists
  local ref, bcode = git(cwd, "symbolic-ref", "-q", "HEAD")
  local branch = bcode == 0 and ref:match("^refs/heads/(.+)$")
  if not branch or PROTECTED_BRANCH[branch:lower()] then return nil end
  -- A config probe: exit 0 = set (value), exit 1 = unset (nil); any other result (failure, timeout) is no grant.
  local failed = false
  local function cfg(...)
    local out, code = git(cwd, "config", ...)
    if code ~= 0 and code ~= 1 then failed = true end
    if code == 0 then return out end
  end
  -- git pushes to remote.pushDefault / branch.<b>.pushRemote when set, not to the upstream the diff is taken against
  if cfg("--get", "remote.pushDefault") or cfg("--get", "branch." .. branch .. ".pushRemote") then return nil end
  -- config that redirects or rewrites a push (mirror, pushurl, insteadOf, submodule recursion) is no grant
  if cfg("--get-regexp", "^(remote\\..*\\.(mirror|pushurl)|url\\..*\\.(insteadof|pushinsteadof)|push\\.recursesubmodules)$") then return nil end
  -- push.followTags publishes tags (releases) with the branch; of the push.* settings in git-push(1) it is the only one that does
  if cfg("--get", "push.followTags") then return nil end
  local mode = cfg("--get", "push.default")
  if mode == "matching" or mode == "nothing" then return nil end
  local up_remote, up_merge = cfg("--get", "branch." .. branch .. ".remote"), cfg("--get", "branch." .. branch .. ".merge")
  if failed then return nil end
  local remote = w[3] or up_remote
  if #w < 4 and not (up_remote == remote and up_merge == "refs/heads/" .. branch) then return nil end
  if #w == 4 and w[4] ~= branch then return nil end
  local remotes, rcode = git(cwd, "remote")
  if rcode ~= 0 then return nil end
  for name in remotes:gmatch("[^\n]+") do
    if name == remote then
      local pushes = cfg("--get-all", "remote." .. name .. ".push")
      if pushes or failed then return nil end
      -- nor the remote's default branch (its HEAD as last fetched; unknown locally means only the names above)
      local head, hcode = git(cwd, "symbolic-ref", "-q", "refs/remotes/" .. remote .. "/HEAD")
      if (hcode ~= 0 and hcode ~= 1) or (hcode == 0 and head:lower() == ("refs/remotes/" .. remote .. "/" .. branch):lower()) then return nil end
      return "refs/remotes/" .. remote .. "/" .. branch
    end
  end
end

-- What a standing grant for this call would be: { class, scope, ceiling } with the scope resolved, or nil. The
-- approval post shows it and the owner's reaction decides; nothing here creates a grant. Only calls the approval
-- post routes can be offered: a fetch (net, exact host) or a plain push (git, the working directory).
M.offer = budgeted(function(tool, input, cwd)
  input = type(input) == "table" and input or {}
  local class, pattern
  if tool == "WebFetch" then
    class, pattern = "net", host_of(input.url)
  elseif (tool == "Bash" or tool == "PowerShell") and policy.classify(tool, input, { cwd = cwd }) == "push"
      and plain_push(input.command, cwd) then
    class, pattern = "git", M.canonical(cwd)
  end
  local scope = pattern and M.scope(class, pattern)
  if scope then return { class = class, scope = scope, ceiling = "T2" } end
end)

-- The store's clock (the test seam included), and the display escape, for the code that announces grants.
function M.time() return now() end
M.show = show

-- Who is calling, by core's caller identity (the client's process ancestry, never its environment): the ids of the
-- calling Butler session and of each leader above it, nearest first, and its alias; nil when the caller is not exactly one session
-- Butler knows. A grant's holder is such an id, so it covers its session and the sessions below it, never a sibling
-- or a leader above. Advisory like the rest of the guard (core: caller() is no authentication boundary), but an
-- agent cannot name it the way it names an alias in its env.
function M.holders()
  local ok, c = pcall(function() return remuda.caller() end)
  if not ok or type(c) ~= "table" or c.kind ~= "session" or type(c.session) ~= "string" or c.session == "" then return nil end
  local agents = remuda._butler_bus and remuda._butler_bus.agents
  if type(agents) ~= "table" then return nil end
  local alias
  for a, agent in pairs(agents) do
    if type(agent) == "table" and agent.session_name == c.session then
      if alias then return nil end
      alias = a
    end
  end
  local out, seen, name = {}, {}, alias
  while alias ~= nil and not seen[alias] do
    seen[alias] = true
    local agent = agents[alias]
    if type(agent) ~= "table" or not text(agent.id) then break end
    out[#out + 1] = agent.id
    alias = agent.parent
  end
  if not out[1] then return nil end
  return out, name
end

-- Clock skew: the highest time seen is kept (daemon memory, survives a live reload); a clock more than a minute
-- behind it matches nothing until it catches up. A forward jump only expires grants early.
M._clock = M._clock or { high = 0 }
local function skewed(t)
  if t > M._clock.high then M._clock.high = t end
  return t < M._clock.high - 60
end

-- The id of the active grant that covers this call, or nil. Never takes an id from the call itself. `class` is the
-- call's class (guard_policy.classify, computed here when not given): only a plain push or a WebFetch may match, so
-- a call that classifies as weaken, identity, escape, control, destroy, script or other never has a grant. `holders`
-- (M.holders()) keeps only the grants held by the caller or a leader above it; the hook always passes it.
M.match = budgeted(function(tool, input, cwd, class, holders)
  if not policy.grants_enabled() or skewed(now()) then return nil end
  input = type(input) == "table" and input or {}
  class = class or policy.classify(tool, input, { cwd = cwd })
  local kind, target, base
  local grants = M.active()
  if holders then
    local mine, held = {}, {}
    for _, h in ipairs(holders) do held[h] = true end
    for _, g in ipairs(grants) do if held[g.holder] then mine[#mine + 1] = g end end
    grants = mine
  end
  if tool == "WebFetch" and class == "net" then
    kind, target = "net", host_of(input.url)
  elseif (tool == "Bash" or tool == "PowerShell") and class == "push" then
    local any -- no git grant, no git: the probes below spawn processes
    for _, g in ipairs(grants) do if g.class == "git" then any = true; break end end
    if not any then return nil end
    base = plain_push(input.command, cwd)
    if not base then return nil end
    kind, target = "git", M.canonical(cwd)
  end
  if not target or (kind ~= "net" and protected_target(target)) then return nil end
  for _, g in ipairs(grants) do
    if g.class == kind and covers(g, target) then
      if kind == "git" then
        local names = M.diff_names(cwd, base)
        if names == nil or M.touches_ci(names) then return nil end -- no diff: the tier asks
      end
      return g.id
    end
  end
  return nil
end)

-- Use accounting: at most HOURLY uses per grant per rolling hour; past that the call asks. Uses are UTC stamps
-- (the audit line format, which sorts as time does) kept in daemon memory, surviving a live reload. After a start,
-- a grant's first use rebuilds its list from the grant_used lines of the live audit log within the last hour (one
-- bounded read); a rotation in that hour hides older lines, so the count can be low by what the rotated file held.
M.HOURLY = 30
local REBUILD_READ = 4 * 1024 * 1024
M._uses = M._uses or {}
M._limited = M._limited or {} -- grant id -> stamp of its last grant_limited line
local function stamp(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end

local function rebuild(id)
  local path = policy.log_path()
  local f = path and io.open(path, "r")
  if not f then return nil end
  local size = f:seek("end") or 0
  f:seek("set", math.max(0, size - REBUILD_READ))
  local text = f:read("a")
  f:close()
  if not text then return nil end
  local used, want = {}, '"grant_id":' .. remuda.json.encode(id)
  for line in text:gmatch("[^\n]+") do
    local at = line:match('^{"time":"([^"]+)"')
    if at and line:find('"event":"grant_used"', 1, true) and line:find(want, 1, true) then used[#used + 1] = at end
  end
  return used
end

-- "ok" when the grant has a use left this hour, "limited" when not, nil when its count cannot be known (ask).
function M.room(id)
  local list = M._uses[id] or rebuild(id)
  if not list then return nil end
  M._uses[id] = list
  local floor = stamp(now() - 3600)
  for i = #list, 1, -1 do if list[i] <= floor then table.remove(list, i) end end
  return #list >= M.HOURLY and "limited" or "ok"
end

-- Reserve one use and return its stamp; release(id, stamp) gives it back when its grant_used line was not written.
function M.count(id)
  local list, at = M._uses[id] or {}, stamp(now())
  M._uses[id] = list
  list[#list + 1] = at
  return at
end
function M.release(id, at)
  local list = M._uses[id] or {}
  for i = #list, 1, -1 do if list[i] == at then table.remove(list, i); return end end
end

-- True once per grant per hour: when its grant_limited line is due. noted() records that it was written.
function M.limit_due(id) return (M._limited[id] or "") <= stamp(now() - 3600) end
function M.noted(id) M._limited[id] = stamp(now()) end

return M
