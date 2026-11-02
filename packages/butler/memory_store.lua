-- Agent-neutral memory (remuda-butler#535, phase 3). Each Butler (the root
-- and every member, by name) owns a plain directory of Markdown notes indexed
-- by MEMORY.md, under Butler's data home. The store belongs to Butler, not to
-- the agent, so it stays with the Butler across restarts, compaction and a
-- switch between Claude and Codex. The adapters only point each agent at it:
--   every agent: a managed `memory` block in AGENTS.md (path, rules, index)
--                and REMUDA_BUTLER_MEMORY_DIR in its environment
--   Claude:      autoMemoryDirectory in the per-launch settings, so Claude's
--                own auto memory reads and writes this store, plus file access
--   Codex:       the store as an extra sandbox writable root
--
-- Pure: the caller does the I/O.
local memory = {}

memory.BLOCK_ID = "memory"
memory.INDEX = "MEMORY.md"
memory.INDEX_MAX = 8192
memory.INDEX_SEED = "# Memory\n\nOne line per note: `- [Title](file.md) — one-line hook`.\n"

-- The store root: REMUDA_BUTLER_MEMORY_HOME, else DATA_HOME/remuda/butler/memory.
function memory.root(getenv, data_home)
  local override = getenv("REMUDA_BUTLER_MEMORY_HOME")
  if override and override ~= "" then return override end
  return data_home and (data_home .. "/remuda/butler/memory") or nil
end

-- A Butler name is a single safe path segment.
function memory.valid_name(name)
  return type(name) == "string" and name:match("^[%w][%w._-]*$") ~= nil and name:find("..", 1, true) == nil
end

function memory.dir(root, name)
  if not root or not memory.valid_name(name) then return nil end
  return root .. "/" .. name
end

-- The managed block's body. `index` is MEMORY.md's text, or nil with a
-- reason ("missing", "too-large", "unreadable").
function memory.render(dir, name, index, reason)
  local out = {
    "## Butler memory",
    "",
    "Your durable memory is in `" .. dir .. "` (also `$REMUDA_BUTLER_MEMORY_DIR`).",
    "Butler owns it for `" .. name .. "`, so it stays with you across restarts,",
    "compaction and a switch between Claude and Codex. Use it for facts that",
    "must outlive this session: decisions, standing instructions from the",
    "owner, and handoff context. Task notes for this working directory stay in",
    "`docs/`.",
    "",
    "- Read `MEMORY.md` there before you start; it indexes one note per file.",
    "- To remember something, write one Markdown file per fact in that",
    "  directory, then add a one-line pointer to `MEMORY.md`:",
    "  `- [Title](file.md) — one-line hook`.",
    "- Update a note instead of adding a duplicate; delete a note that is wrong.",
    "- Never store secrets or credentials there.",
    "",
  }
  if index then
    out[#out + 1] = "`MEMORY.md` when this session started (the file is the source of truth):"
    out[#out + 1] = ""
    out[#out + 1] = (index:gsub("\r\n", "\n"):gsub("\n+$", ""))
  else
    out[#out + 1] = "`MEMORY.md` was not shown here (" .. tostring(reason or "missing") .. "); read the file."
  end
  return table.concat(out, "\n") .. "\n"
end

-- The block for `name`. read(path) -> text | nil, reason.
function memory.block(dir, name, read)
  local text, why = read(dir .. "/" .. memory.INDEX)
  local index, reason = nil, why and "unreadable" or "missing"
  if text and #text > memory.INDEX_MAX then reason = "over 8 KiB"
  elseif text and text:find("remuda%-butler:managed id=") then reason = "it holds a Butler marker line"
  elseif text then index = text end
  return { id = memory.BLOCK_ID, body = memory.render(dir, name, index, reason), max = memory.INDEX_MAX + 2048 }
end

-- Claude adapter: JSON members for the per-launch settings file. `permissions`
-- holds what goes inside "permissions" (additionalDirectories and allow
-- rules), `top` the top-level keys. An allow rule uses `//` for an absolute
-- path; Edit covers writes (Claude checks Edit and Read rules only).
function memory.claude_settings(dir, json_quote)
  if type(dir) ~= "string" or dir:sub(1, 1) ~= "/" then return nil end
  local q = json_quote
  return {
    permissions = '"additionalDirectories":[' .. q(dir) .. ']',
    allow = { q("Read(/" .. dir .. "/**)"), q("Edit(/" .. dir .. "/**)") },
    top = '"autoMemoryDirectory":' .. q(dir),
  }
end

-- Codex adapter: the writable roots with the store added once.
function memory.codex_writable(writable, dir)
  local out, seen = {}, {}
  for _, path in ipairs(writable or {}) do
    if not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  if dir and not seen[dir] then out[#out + 1] = dir end
  return out
end

if type(remuda) == "table" then remuda._butler_memory_store = memory end
return memory
