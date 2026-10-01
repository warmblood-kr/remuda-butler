-- Markdown subset -> Matrix-safe HTML (org.matrix.custom.html).
-- Everything is HTML-escaped first; raw HTML never passes through. The only
-- tags emitted are the ones written literally in this file.
-- Check: luajit tests/md2html.lua
local M = {}

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
local function esc(s) return (s:gsub("[&<>\"']", ESC)) end
M.escape = esc

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function safe_href(url) -- url is already escaped
  local lower = url:lower()
  return lower:match("^https?://") ~= nil or lower:match("^mailto:") ~= nil
end

local function emphasis(s) -- s is escaped; tags below are the only '<' '>' in it
  s = s:gsub("%*%*([^%s%*][^%*]-)%*%*", "<strong>%1</strong>")
  -- opener must not follow a word char, closer must not precede one: keeps 2*3*4 literal
  s = (" " .. s):gsub("([^%w%*])%*([^%s%*<>][^%*<>]-)%*%f[^%w%*]", function(pre, body)
    if body:match("%s$") then return nil end
    return pre .. "<em>" .. body .. "</em>"
  end)
  return s:sub(2)
end

local function inline(raw)
  local stash = {}
  local function keep(html)
    stash[#stash + 1] = html
    return "\1" .. #stash .. "\1"
  end
  local s = raw:gsub("`([^`\n]+)`", function(code) return keep("<code>" .. esc(code) .. "</code>") end)
  s = esc(s)
  s = s:gsub("%[([^%]\n]-)%]%(([^%s%)\1]+)%)", function(text, url)
    if text == "" or not safe_href(url) then return nil end
    return keep('<a href="' .. url .. '">' .. emphasis(text) .. "</a>")
  end)
  s = emphasis(s)
  for _ = 1, 2 do -- anchors may hold code placeholders
    s = s:gsub("\1(%d+)\1", function(n) return stash[tonumber(n)] end)
  end
  return s
end

local function is_fence(line) return line:match("^%s*```") ~= nil end
local function heading(line)
  local marks, text = line:match("^(#+)%s+(.-)%s*$")
  if marks and #marks <= 6 and text ~= "" then return #marks, text end
end
local function bullet(line) return line:match("^%s*[-*+]%s+(.+)$") end
local function numbered(line)
  local n, text = line:match("^%s*(%d+)[.)]%s+(.+)$")
  if n and #n <= 9 then return n, text end
end
local function quote(line) return line:match("^%s*>%s?(.*)$") end
local function is_rule(line) return line:match("^%s*%-%-%-+%s*$") ~= nil end
local function is_table_sep(line)
  return line:find("|", 1, true) ~= nil and line:find("-", 1, true) ~= nil
    and line:match("^[%s|:%-]+$") ~= nil
end

-- ponytail: splits on every '|', so a pipe inside a code span or an escaped
-- \| breaks the cell; add a tokenizer if tables with pipes in cells show up.
local function cells(line)
  line = trim(line):gsub("^|", ""):gsub("|$", "")
  local out = {}
  for cell in (line .. "|"):gmatch("([^|]*)|") do out[#out + 1] = trim(cell) end
  return out
end

local function row(line, tag)
  local out = {}
  for _, cell in ipairs(cells(line)) do
    out[#out + 1] = "<" .. tag .. ">" .. inline(cell) .. "</" .. tag .. ">"
  end
  return "<tr>" .. table.concat(out) .. "</tr>"
end

-- ponytail: lists are flat (nested items join the parent list) and a
-- blockquote is one paragraph; recurse if nested structure matters.
function M.convert(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", "")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local out, i, n = {}, 1, #lines

  local function starts_block(at)
    local line = lines[at]
    return line:match("^%s*$") or is_fence(line) or heading(line) or bullet(line)
      or numbered(line) or quote(line) or is_rule(line)
      or (line:find("|", 1, true) and lines[at + 1] and is_table_sep(lines[at + 1]))
  end

  while i <= n do
    local line = lines[i]
    if line:match("^%s*$") then
      i = i + 1
    elseif is_fence(line) then
      local lang = line:match("^%s*```%s*([%w_+%-]+)%s*$")
      local code = {}
      i = i + 1
      while i <= n and not lines[i]:match("^%s*```%s*$") do
        code[#code + 1] = lines[i]
        i = i + 1
      end
      i = i + 1 -- closing fence (or past the end when unclosed)
      out[#out + 1] = "<pre><code" .. (lang and (' class="language-' .. lang .. '"') or "") .. ">"
        .. esc(table.concat(code, "\n")) .. "\n</code></pre>"
    elseif heading(line) then
      local level, title = heading(line)
      out[#out + 1] = "<h" .. level .. ">" .. inline(title) .. "</h" .. level .. ">"
      i = i + 1
    elseif is_rule(line) then
      out[#out + 1] = "<hr>"
      i = i + 1
    elseif line:find("|", 1, true) and lines[i + 1] and is_table_sep(lines[i + 1]) then
      local rows = {}
      local head = row(line, "th")
      i = i + 2
      while i <= n and lines[i]:find("|", 1, true) do
        rows[#rows + 1] = row(lines[i], "td")
        i = i + 1
      end
      out[#out + 1] = "<table><thead>" .. head .. "</thead><tbody>" .. table.concat(rows) .. "</tbody></table>"
    elseif quote(line) then
      local parts = {}
      while i <= n and quote(lines[i]) do
        parts[#parts + 1] = inline(quote(lines[i]))
        i = i + 1
      end
      out[#out + 1] = "<blockquote><p>" .. table.concat(parts, "<br>") .. "</p></blockquote>"
    elseif bullet(line) then
      local items = {}
      while i <= n and bullet(lines[i]) and not is_rule(lines[i]) do
        items[#items + 1] = "<li>" .. inline(bullet(lines[i])) .. "</li>"
        i = i + 1
      end
      out[#out + 1] = "<ul>" .. table.concat(items) .. "</ul>"
    elseif numbered(line) then
      local first = numbered(line)
      local items = {}
      while i <= n and numbered(lines[i]) do
        local _, item = numbered(lines[i])
        items[#items + 1] = "<li>" .. inline(item) .. "</li>"
        i = i + 1
      end
      local start = tonumber(first) ~= 1 and (' start="' .. tonumber(first) .. '"') or ""
      out[#out + 1] = "<ol" .. start .. ">" .. table.concat(items) .. "</ol>"
    else
      local parts = { inline(trim(line)) }
      i = i + 1
      while i <= n and not starts_block(i) do
        parts[#parts + 1] = inline(trim(lines[i]))
        i = i + 1
      end
      out[#out + 1] = "<p>" .. table.concat(parts, "<br>") .. "</p>"
    end
  end
  return table.concat(out)
end

-- Registered by name so callers look convert up at call time and it stays
-- advisable (#166); plain Lua (the unit test) has no remuda and just gets M.
if type(remuda) == "table" then
  remuda.butler = remuda.butler or {}
  remuda.butler.md2html = M
end
return M
