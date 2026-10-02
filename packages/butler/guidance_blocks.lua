-- Managed blocks inside a shared markdown file (the root Butler's AGENTS.md).
-- Each block is a marker pair; `merge` replaces only what is between a pair,
-- appends a block that has no pair yet, and never touches other text. Pure: it
-- takes the file's text and returns the new text, so the caller owns all I/O.
local guidance_blocks = {}

local MAX_BODY = 8192
local function begin_line(id) return "<!-- BEGIN remuda-butler:managed id=" .. id .. " -->" end
local function end_line(id) return "<!-- END remuda-butler:managed id=" .. id .. " -->" end

-- Legacy comparison is exact (CRLF read as LF) except for one trailing newline.
local function exact(text) return (text:gsub("\r\n", "\n"):gsub("\n$", "")) end

-- Whole-file texts the root guidance had before it was marked, one per
-- historical version of Butler's own text (oldest first). A file equal to one
-- of these, or to a current block body, holds nothing of the user's.
guidance_blocks.known_old = {
  -- first one-liners (before the markdown form)
  "You are Butler, a manager of this household. You may spawn a new member session "
    .. "and delegate things to do. Supervise it and manage the things to be done.",
  "You are Butler, manager of this household. Create team members only with "
    .. "`remuda butler topic delegate NAME --agent codex --leader butler TASK`; never use an agent "
    .. "CLI's built-in background or subagent facility. Supervise members through `remuda butler sessions`, "
    .. "`inbox`, and `send`.",
  "You are Butler, manager of this household. Create team members only with "
    .. "`remuda butler topic delegate NAME TASK`. Internal agent subagents are separate from Butler "
    .. "team members. Supervise Butler members through `remuda butler sessions`, "
    .. "`inbox`, and `send`.",
  -- markdown form, with the operator-form paragraph
  [==[
You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER MESSAGE...` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]==],
  -- plus caller-env forwarding and the member list
  [==[# Butler

You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER "MESSAGE"` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.

If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]==],
  -- plus the long-body line
  [==[# Butler

You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER "MESSAGE"` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.
- For long bodies, use `cat <<'EOF' | remuda butler send MEMBER -` or `--file "$PWD/path"`;
  `send-to-leader` and `reply MESSAGE_ID` accept those forms too. The limit is 64 KiB.

If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]==],
  -- long bodies via a file or a pipe
  [==[# Butler

You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER "MESSAGE"` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.
- For long bodies, write the text to a file and use `remuda butler send MEMBER --file "$PWD/path"`,
  or pipe it: `cat <<'EOF' | remuda butler send MEMBER -`. `send-to-leader` and `reply MESSAGE_ID`
  accept those forms too. The limit is 64 KiB.

If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]==],
}

local function valid_id(id) return type(id) == "string" and id:match("^[a-z0-9%-]+$") ~= nil end

-- Marker lines of `text`: { kind, id, from, to } where from..to spans the line
-- without its line ending. A line that starts like a marker but is not a
-- well-formed one for a valid id is kind "BAD".
local function scan(text)
  local marks, pos = {}, 1
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local to = (nl or #text + 1) - 1
    local line = text:sub(pos, to):gsub("\r$", "")
    local kind, id = line:match("^<!%-%- (%u+) remuda%-butler:managed id=([a-z0-9%-]+) %-%->$")
    local from, upto = pos, to - (text:sub(to, to) == "\r" and 1 or 0)
    if kind == "BEGIN" or kind == "END" then marks[#marks + 1] = { kind = kind, id = id, from = from, to = upto }
    elseif line:find("^<!%-%- BEGIN remuda%-butler:managed") or line:find("^<!%-%- END remuda%-butler:managed") then
      marks[#marks + 1] = { kind = "BAD", from = from, to = upto }
    end
    pos = (nl or #text) + 1
  end
  return marks
end

local function render(id, body, eol)
  if body:sub(-1) ~= "\n" then body = body .. "\n" end
  return (begin_line(id) .. "\n" .. body .. end_line(id)):gsub("\r?\n", eol)
end

-- Where `id`'s pair sits in `marks`: "none", "ok" (with the pair), or
-- "damaged"/"duplicated". A pair must hold no other marker line.
local function locate(marks, id)
  local mine = {}
  for i, m in ipairs(marks) do if m.id == id then mine[#mine + 1] = i end end
  if #mine == 0 then return "none" end
  if #mine > 2 then
    local paired = #mine % 2 == 0
    for k, i in ipairs(mine) do if marks[i].kind ~= (k % 2 == 1 and "BEGIN" or "END") then paired = false end end
    return paired and "duplicated" or "damaged"
  end
  local first, last = mine[1], mine[2]
  if #mine ~= 2 or marks[first].kind ~= "BEGIN" or marks[last].kind ~= "END" or last ~= first + 1 then return "damaged" end
  return "ok", marks[first], marks[last]
end

-- merge(text_or_nil, blocks) -> new_text_or_nil, report
-- blocks: ordered { id, body }. new_text is nil when nothing must be written.
-- report: one { id, outcome } per block, in order. outcome is written,
-- unchanged, appended, migrated, damaged, duplicated, mixed-eol (a file with
-- both LF and CRLF line endings is refused) or dropped (bad id, a body over
-- 8 KiB, or a body holding a marker line). A CRLF file keeps its CRLF.
function guidance_blocks.merge(text, blocks)
  local report, valid, seen = {}, {}, {}
  for _, block in ipairs(blocks or {}) do
    local id, body = block.id, block.body
    if valid_id(id) and type(body) == "string" and #body <= MAX_BODY and not seen[id]
      and not body:find("remuda%-butler:managed id=") then
      seen[id] = true
      valid[#valid + 1] = block
    else
      report[#report + 1] = { id = tostring(id), outcome = "dropped" }
    end
  end
  local current, original = text or "", text or ""
  local crlf = current:find("\r\n", 1, true) ~= nil
  if crlf and current:gsub("\r\n", ""):find("\n", 1, true) then
    for _, block in ipairs(valid) do report[#report + 1] = { id = block.id, outcome = "mixed-eol" } end
    return nil, report
  end
  local eol = crlf and "\r\n" or "\n"
  if #valid == 0 then return nil, report end

  local function note(id, outcome) report[#report + 1] = { id = id, outcome = outcome } end
  for _, m in ipairs(scan(current)) do
    if m.kind == "BAD" then -- a malformed marker line: the file is damaged for every block
      for _, block in ipairs(valid) do note(block.id, "damaged") end
      return nil, report
    end
  end
  if #scan(current) == 0 then
    local whole, legacy = exact(current), current:find("%S") == nil
    for _, old in ipairs(guidance_blocks.known_old) do if exact(old) == whole then legacy = true end end
    for _, block in ipairs(valid) do if exact(block.body) == whole then legacy = true end end
    if legacy then
      local parts = {}
      for _, block in ipairs(valid) do parts[#parts + 1] = render(block.id, block.body, eol); note(block.id, current:find("%S") and "migrated" or "written") end
      return table.concat(parts, eol .. eol) .. eol, report
    end
  end
  for _, block in ipairs(valid) do
    local state, from, to = locate(scan(current), block.id)
    if state == "ok" then
      local replaced = current:sub(1, from.from - 1) .. render(block.id, block.body, eol) .. current:sub(to.to + 1)
      note(block.id, replaced == current and "unchanged" or "written")
      current = replaced
    elseif state == "none" then
      local sep = current == "" and "" or (current:sub(-#eol) == eol and eol or eol .. eol)
      current = current .. sep .. render(block.id, block.body, eol) .. eol
      note(block.id, "appended")
    else
      note(block.id, state)
    end
  end
  if current == original then return nil, report end
  return current, report
end

-- The file side. `fs`: read(path), is_symlink(path) (nil when it cannot tell),
-- write(path, text). A link is refused (outcome "symlink"), as is a link that
-- cannot be told from a file; the write is atomic where the core has one and
-- happens only when the text differs, so a caller on a timer leaves the file
-- and its modification time alone (issue 236).
function guidance_blocks.sync(path, blocks, fs)
  if fs.is_symlink(path) ~= false then return nil, { { id = "*", outcome = "symlink" } } end
  local text, report = guidance_blocks.merge(fs.read(path), blocks)
  if text then
    local wrote, why = fs.write(path, text)
    if not wrote then return nil, report, tostring(why or "write failed") end
  end
  return text ~= nil, report
end

if type(remuda) == "table" then remuda._butler_guidance_blocks = guidance_blocks end
return guidance_blocks
