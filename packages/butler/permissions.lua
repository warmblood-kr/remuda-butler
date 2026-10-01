-- The permission rule Butler grants its own root session: one allow rule for
-- the `remuda butler` CLI, merged into the root session's
-- `.claude/settings.local.json`. Add-only: every byte the user wrote stays.
-- Members, leads and Codex get nothing here.
local permissions = {}

local PREFIX = "Bash(remuda butler:*)"

-- Only `Bash(remuda butler[ VERB...]:*)`: a rule never reaches past this CLI.
function permissions.valid_rule(rule)
  if type(rule) ~= "string" then return false end
  local rest = rule:match("^Bash%(remuda butler([ %w%-]*):%*%)$")
  if not rest then return false end
  while rest ~= "" do
    local tail = rest:match("^ %w[%w%-]*(.*)$")
    if not tail then return false end
    rest = tail
  end
  return true
end

-- The role is a constant at the launch call site, never a name or the environment.
function permissions.builtin(ctx)
  if type(ctx) == "table" and ctx.role == "root" then return { PREFIX } end
  return {}
end

-- Joins the `butler.permission` rows for the root Butler. Returns the rules
-- and what was dropped (`{ id, rule }`); a bad row loses its rules only.
function permissions.rules(ctx, rows)
  local rules, seen, dropped = {}, {}, {}
  if type(ctx) ~= "table" or ctx.role ~= "root" then return rules, dropped end
  for _, row in ipairs(rows or {}) do
    local render = type(row.entry) == "table" and row.entry.rules
    if render then
      local ok, list = pcall(render, { role = "root", kind = "claude" })
      if not ok or type(list) ~= "table" then
        dropped[#dropped + 1] = { id = row.id, rule = ok and "(not a list)" or "(failed)" }
      else
        for _, rule in ipairs(list) do
          if not permissions.valid_rule(rule) then
            dropped[#dropped + 1] = { id = row.id, rule = rule }
          elseif not seen[rule] then
            seen[rule] = true
            rules[#rules + 1] = rule
          end
        end
      end
    end
  end
  return rules, dropped
end

-- A strict JSON reader that keeps byte positions, so the merge can splice
-- into the user's text instead of re-encoding it. Returns the top-level
-- object, or nil for anything it is not sure about (then nothing is written).
local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
local function scan(text)
  local pos = 1
  local function ws() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
  local value
  local function str()
    local start, out = pos, {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" or c:byte() < 0x20 then return nil end
      if c == '"' then
        pos = pos + 1
        return { type = "string", s = start, e = pos - 1, value = table.concat(out) }
      end
      if c ~= "\\" then
        out[#out + 1] = c
        pos = pos + 1
      elseif text:sub(pos + 1, pos + 1) == "u" then
        local hex = text:match("^%x%x%x%x", pos + 2)
        if not hex then return nil end
        local code = tonumber(hex, 16)
        out[#out + 1] = code < 0x80 and string.char(code) or text:sub(pos, pos + 5)
        pos = pos + 6
      else
        local plain = ESCAPES[text:sub(pos + 1, pos + 1)]
        if not plain then return nil end
        out[#out + 1] = plain
        pos = pos + 2
      end
    end
  end
  local function number()
    local start = pos
    local int = text:match("^%-?%d+", pos)
    if not int or int:match("^%-?0%d") then return nil end
    pos = pos + #int
    pos = pos + #(text:match("^%.%d+", pos) or "")
    pos = pos + #(text:match("^[eE][%+%-]?%d+", pos) or "")
    return { type = "other", s = start, e = pos - 1 }
  end
  local function collection(kind, close)
    local node = { type = kind, s = pos, keys = {} }
    pos = pos + 1
    ws()
    if text:sub(pos, pos) == close then node.e = pos; pos = pos + 1; return node end
    while true do
      ws()
      local item_start = pos
      local item
      if kind == "object" then
        local key = text:sub(pos, pos) == '"' and str()
        if not key or node.keys[key.value] then return nil end
        ws()
        if text:sub(pos, pos) ~= ":" then return nil end
        pos = pos + 1
        item = value()
        if not item then return nil end
        node.keys[key.value] = item
      else
        item = value()
        if not item then return nil end
        node[#node + 1] = item
      end
      node.last_s, node.last_e = item_start, pos - 1
      ws()
      local c = text:sub(pos, pos)
      pos = pos + 1
      if c == close then node.e = pos - 1; return node end
      if c ~= "," then return nil end
    end
  end
  function value()
    ws()
    local c = text:sub(pos, pos)
    if c == '"' then return str() end
    if c == "{" then return collection("object", "}") end
    if c == "[" then return collection("array", "]") end
    for _, word in ipairs({ "true", "false", "null" }) do
      if text:sub(pos, pos + #word - 1) == word then
        pos = pos + #word
        return { type = "other", s = pos - #word, e = pos - 1 }
      end
    end
    return number()
  end
  local root = value()
  ws()
  if not root or root.type ~= "object" or pos <= #text then return nil end
  return root
end

local function json_quote(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    :gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end

-- Adds `piece` as the last element of a scanned object or array, laid out
-- like the element before it.
local function append(text, node, piece)
  if not node.last_e then return text:sub(1, node.s) .. piece .. text:sub(node.e) end
  local gap = text:sub(1, node.last_s - 1):match("[ \t\r\n]*$")
  return text:sub(1, node.last_e) .. "," .. gap .. piece .. text:sub(node.last_e + 1)
end

local function holds(array, rule)
  for _, item in ipairs(array or {}) do
    if item.type == "string" and item.value == rule then return true end
  end
  return false
end

-- merge(text or nil, rules) -> new text or nil, report. nil text means there
-- is nothing to write. The report lists `added`, `present`, `withheld`
-- (`{ rule, list }`: the user's deny or ask wins) and `error`.
function permissions.merge(text, rules)
  local report = { added = {}, present = {}, withheld = {} }
  local current, changed = text, false
  for _, rule in ipairs(rules or {}) do
    local quoted = json_quote(rule)
    if current == nil then
      current = '{\n  "permissions": {\n    "allow": [\n      ' .. quoted .. '\n    ]\n  }\n}\n'
      changed, report.added[#report.added + 1] = true, rule
    else
      -- pcall: a file nested deeply enough to overflow the reader is not ours to edit.
      local ok, root = pcall(scan, current)
      if not ok or not root then report.error = "not valid JSON"; return nil, report end
      local perms = root.keys.permissions
      if perms and perms.type ~= "object" then report.error = "wrong type"; return nil, report end
      for _, key in ipairs({ "allow", "deny", "ask" }) do
        local list = perms and perms.keys[key]
        if list and list.type ~= "array" then report.error = "wrong type"; return nil, report end
      end
      local allow = perms and perms.keys.allow
      local blocked = perms and ((holds(perms.keys.deny, rule) and "deny") or (holds(perms.keys.ask, rule) and "ask"))
      if blocked then
        report.withheld[#report.withheld + 1] = { rule = rule, list = blocked }
      elseif holds(allow, rule) then
        report.present[#report.present + 1] = rule
      else
        if allow then current = append(current, allow, quoted)
        elseif perms then current = append(current, perms, '"allow":[' .. quoted .. ']')
        else current = append(current, root, '"permissions":{"allow":[' .. quoted .. ']}') end
        changed, report.added[#report.added + 1] = true, rule
      end
    end
  end
  return changed and current or nil, report
end

-- The file side of the merge. `fs` holds the mod's helpers: read(path),
-- is_symlink(path), mkdir(path), write(path, text, private) (atomic). Never
-- raises: a failure is reported, and the launch goes on.
function permissions.ensure(path, rules, fs)
  local report = { added = {}, present = {}, withheld = {} }
  local ok, err = pcall(function()
    if #rules == 0 then return end
    if fs.is_symlink(path) then report.error = "is a symlink"; return end
    local existing = fs.read(path)
    local text
    text, report = permissions.merge(existing, rules)
    if not text then return end
    if existing == nil then fs.mkdir(path:match("^(.*)/[^/]+$")) end
    local wrote, why = fs.write(path, text, true)
    if not wrote then error(why or "write failed", 0) end
  end)
  if not ok then report = { added = {}, present = {}, withheld = {}, error = tostring(err) } end
  report.path = path
  return report
end

-- Writes only when the text differs, so a caller on a timer leaves the file
-- and its modification time alone (issue 236).
function permissions.write_if_changed(path, text, fs, private)
  if fs.read(path) == text then return "unchanged" end
  local wrote, why = fs.write(path, text, private)
  if not wrote then return nil, tostring(why or "write failed") end
  return "written"
end

local function one_line(value)
  return (tostring(value):gsub("[\r\n]+", " "):gsub("%c", "?"))
end

-- The root line for `remuda butler doctor`; the block ends with Next:.
function permissions.doctor_lines(report, kind)
  local head = "Permissions butler (" .. one_line(kind or "?") .. "): "
  if kind ~= "claude" then
    return { head .. "none — the mod writes no Codex permission rules", "Next: nothing to do" }
  end
  if type(report) ~= "table" then return { head .. "not checked yet", "Next: remuda butler status" } end
  local path = one_line(report.path or "?")
  if report.error then
    return { head .. "not written: " .. one_line(report.error) .. " — " .. path,
      "Next: fix or delete that file; Butler adds the rule at its next launch" }
  end
  local lines, next_line = {}, "Next: to block the rule, move it to permissions.deny in that file"
  for _, item in ipairs(report.withheld or {}) do
    lines[#lines + 1] = head .. "withheld " .. one_line(item.rule) .. " — listed under " .. one_line(item.list) .. " in " .. path
    next_line = "Next: remove the rule from " .. one_line(item.list) .. " in that file; Butler adds it at its next launch"
  end
  for _, state in ipairs({ "added", "present" }) do
    if #(report[state] or {}) > 0 then
      lines[#lines + 1] = head .. state .. " " .. one_line(table.concat(report[state], ", ")) .. " — " .. path
    end
  end
  if #lines == 0 then return { head .. "none", "Next: nothing to do" } end
  lines[#lines + 1] = next_line
  return lines
end

if type(remuda) == "table" then remuda._butler_permissions = permissions end
return permissions
