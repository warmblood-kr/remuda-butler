-- Guard slice 3, PR3: the standing-grant store. A grant is one JSON line in guard-grants.jsonl under
-- the protected Butler data dir: scope (class + narrow pattern), ceiling, absolute expiry, holder,
-- and the approval event id. Nothing here creates a grant from the CLI or from agent text: `add` is
-- the in-process API a later PR calls from the owner's verified reaction. With the grants switch
-- off nothing reads the store. Every read is fresh (no cache), so a start always reloads it, and an
-- entry that is expired, unparseable, lacks its approval event or was written "in the future" is no
-- grant (fail closed). Cooperative, like the rest of the guard: not a boundary.
local butler = assert(remuda.butler, "load butler/guard_policy before butler/guard_grants")
local policy = assert(butler.guard_policy, "load butler/guard_policy before butler/guard_grants")
local M = butler.guard_grants or {}
butler.guard_grants = M

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

-- The resolved scope to store: the fixed prefix through canonical(), any whole-segment * kept after it.
function M.scope(class, pattern)
  local parsed = parse(class, pattern)
  if not parsed then return nil, "scope is not a narrow pattern" end
  if type(parsed) == "string" then return parsed end
  local star
  for i, s in ipairs(parsed) do if s == "*" then star = i; break end end
  local fixed = M.canonical("/" .. table.concat(parsed, "/", 1, (star or #parsed + 1) - 1))
  if not fixed then return nil, "scope cannot be resolved" end
  if not star then return fixed end
  local tail = table.concat(parsed, "/", star)
  return fixed .. "/" .. (insensitive(fixed) and tail:lower() or tail)
end

local function entries()
  local path = file()
  local f = path and io.open(path, "r")
  if not f then return {} end
  local text = f:read(MAX_FILE) or ""
  f:close()
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local ok, e = pcall(remuda.json.decode, line)
    if ok and type(e) == "table" then out[#out + 1] = e end
  end
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

-- Record a grant. Returns its id (gNNN), or nil and why. TTL <= 24h whoever asks.
function M.add(e)
  local path = file()
  if not path then return nil, "Butler data directory is unknown" end
  local ttl = e.ttl == nil and M.DEFAULT_TTL or e.ttl
  if not CLASS[e.class] then return nil, "unknown class" end
  if not CEILING[e.ceiling] then return nil, "ceiling must be T1 or T2" end
  if math.type(ttl) ~= "integer" or ttl <= 0 or ttl > M.MAX_TTL then return nil, "ttl must be 1 second to 24 hours" end
  if not (text(e.holder) and text(e.event)) then return nil, "holder and approval event are required" end
  local scope, why = M.scope(e.class, e.scope)
  if not scope then return nil, why end
  local t, top = now(), 0
  for _, old in ipairs(entries()) do top = math.max(top, tonumber(tostring(old.id):match("^g(%d+)$")) or 0) end
  local id = string.format("g%03d", top + 1)
  local line = remuda.json.encode({ id = id, class = e.class, scope = scope, ceiling = e.ceiling, holder = e.holder,
    event = e.event, written = t, expires = t + ttl })
  local f = io.open(path, "r")
  local old = f and f:read("a") or ""
  if f then f:close() end
  pcall(remuda.mkdir, policy.dir())
  local ok, err = remuda.fs.write_atomic(path, old .. line .. "\n", { private = true })
  if not ok then return nil, tostring(err) end
  return id
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
      policy.redact(g.scope, 300), g.ceiling, policy.redact(g.holder, 60),
      os.date("!%Y-%m-%dT%H:%M:%SZ", g.expires), math.ceil((g.expires - t) / 60), policy.redact(g.event, 80))
  end
  return table.concat(out, "\n")
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

-- Pushes under a grant: any CI or workflow path is T3 (always asks). The list is reviewed like a guard rule.
local CI_PREFIX = { ".github/", ".circleci/", ".buildkite/", ".gitlab/" }
local CI_FILE = { [".gitlab-ci.yml"] = 1, ["jenkinsfile"] = 1, [".travis.yml"] = 1, ["azure-pipelines.yml"] = 1,
  ["bitbucket-pipelines.yml"] = 1, [".drone.yml"] = 1, ["cloudbuild.yaml"] = 1, ["appveyor.yml"] = 1, [".appveyor.yml"] = 1 }
function M.touches_ci(names)
  for _, name in ipairs(names) do
    local lower = name:lower()
    if CI_FILE[lower] then return true end
    for _, p in ipairs(CI_PREFIX) do if lower:sub(1, #p) == p then return true end end
  end
  return false
end

-- Files the push would add over the upstream ref, best effort; nil when it cannot be computed.
function M.diff_names(cwd)
  local ok, r = pcall(remuda.process.run, { argv = { "git", "-C", cwd, "diff", "--name-only", "-z", "@{upstream}...HEAD" }, timeout = 5 })
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
  authority = authority:match("([^@]*)$") -- userinfo: judge the host after the last @
  local host, port = authority:match("^([^:]+):(%d+)$")
  host = host or authority
  if port and port == DEFAULT_PORT[scheme:lower()] then port = nil end
  return parse("net", host .. (port and (":" .. port) or ""))
end

-- The id of the active grant that covers this call, or nil. Never takes an id from the call itself.
function M.match(tool, input, cwd)
  if not policy.grants_enabled() then return nil end
  input = type(input) == "table" and input or {}
  local class, target
  if FILE_TOOLS[tool] then
    class, target = "writable", M.canonical(input.file_path or input.notebook_path)
  elseif tool == "WebFetch" then
    class, target = "net", host_of(input.url)
  elseif (tool == "Bash" or tool == "PowerShell") and policy.classify(tool, input, { cwd = cwd }) == "push" then
    -- ponytail: the diff runs in the hook's cwd, so a command that moves elsewhere (cd, -C, --git-dir) gets no grant.
    local command = input.command
    if type(command) ~= "string" or command:find("%f[%w]cd%f[%W]") or command:find("%-C") or command:find("%-%-git%-dir")
        or command:find("%-%-work%-tree") then return nil end
    class, target = "git", M.canonical(cwd)
  end
  if not target then return nil end
  for _, g in ipairs(M.active()) do
    if g.class == class and covers(g, target) then
      if class == "git" then
        local names = M.diff_names(cwd)
        if names == nil or M.touches_ci(names) then return nil end -- no diff: the tier asks
      end
      return g.id
    end
  end
  return nil
end

return M
