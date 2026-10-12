-- Pure lexical path helpers. The flavour is explicit so either path syntax can
-- be checked on any host. normalize() does not inspect the filesystem: do not
-- use it alone to make access decisions when symlinks may be involved.
local path = {}

local function check_flavour(flavour)
  assert(flavour == "posix" or flavour == "windows", "path flavour must be 'posix' or 'windows'")
end

local function is_sep(char, flavour)
  return char == "/" or (flavour == "windows" and char == "\\")
end

local function starts_windows(value, prefix)
  return value:sub(1, #prefix):lower() == prefix:lower()
end

local function trim_separators(value, flavour)
  while #value > 0 and is_sep(value:sub(-1), flavour) do value = value:sub(1, -2) end
  return value
end

local function windows_root(pathname)
  -- Device paths have no volume components, but are rooted paths.
  if starts_windows(pathname, "\\\\.\\") then return "\\\\.\\", true, 5 end

  local verbatim_unc = starts_windows(pathname, "\\\\?\\UNC\\")
  if verbatim_unc then
    local tail = pathname:sub(9)
    local server, share, finish = tail:match("^([^\\/]+)[\\/]([^\\/]+)()")
    if server and share then return "\\\\?\\UNC\\" .. server .. "\\" .. share, true, finish + 8 end
    return "\\\\?\\UNC", true, 9
  end

  if starts_windows(pathname, "\\\\?\\") then
    local drive = pathname:match("^\\\\%?\\([%a]:)[\\/]")
    if drive then return "\\\\?\\" .. drive, true, 8 end
    return "\\\\?", true, 5
  end

  local unc = pathname:match("^\\\\[^\\/]+[\\/][^\\/]+")
  if unc then return trim_separators(unc, "windows"), true, #unc + 1 end

  local drive = pathname:match("^(%a:)")
  if drive then
    if is_sep(pathname:sub(3, 3), "windows") then return drive, true, 4 end
    return drive, false, 3
  end

  if is_sep(pathname:sub(1, 1), "windows") then return "", true, 2 end
  return "", false, 1
end

function path.separator(flavour)
  check_flavour(flavour)
  return flavour == "windows" and "\\" or "/"
end

function path.to_native(value, flavour)
  check_flavour(flavour)
  assert(type(value) == "string", "path must be a string")
  if flavour == "windows" then return (value:gsub("/", "\\")) end
  return (value:gsub("\\", "/"))
end

function path.parse(value, flavour)
  check_flavour(flavour)
  assert(type(value) == "string", "path must be a string")
  local prefix, rooted, first
  if flavour == "posix" then
    rooted = value:sub(1, 1) == "/"
    prefix, first = rooted and "/" or "", rooted and 2 or 1
  else
    prefix, rooted, first = windows_root(value)
  end
  local trailing_sep = #value > 0 and is_sep(value:sub(-1), flavour)
  local segments = {}
  local index = first
  while index <= #value do
    while index <= #value and is_sep(value:sub(index, index), flavour) do index = index + 1 end
    if index <= #value then
      local finish = index
      while finish <= #value and not is_sep(value:sub(finish, finish), flavour) do finish = finish + 1 end
      segments[#segments + 1] = value:sub(index, finish - 1)
      index = finish
    end
  end
  return { prefix = prefix, rooted = rooted, segments = segments, trailing_sep = trailing_sep }
end

function path.is_absolute(value, flavour)
  local parsed = path.parse(value, flavour)
  if flavour == "posix" then return parsed.rooted end
  return parsed.rooted and parsed.prefix ~= ""
end

local function render(parsed, flavour, segments, trailing)
  local sep = path.separator(flavour)
  local body = table.concat(segments, sep)
  local result
  if parsed.prefix ~= "" then
    if parsed.rooted then
      result = parsed.prefix == sep and (sep .. body) or (parsed.prefix .. sep .. body)
    elseif body == "" then
      result = parsed.prefix
    else
      result = parsed.prefix .. body
    end
  elseif parsed.rooted then
    result = sep .. body
  else
    result = body
  end
  if trailing and result ~= "" and not is_sep(result:sub(-1), flavour) then result = result .. sep end
  return result
end

function path.normalize(value, flavour)
  local parsed = path.parse(value, flavour)
  local segments = {}
  for _, segment in ipairs(parsed.segments) do
    if segment == "." or segment == "" then
      -- Skip current-directory components.
    elseif segment == ".." then
      if #segments > 0 and segments[#segments] ~= ".." then
        segments[#segments] = nil
      elseif not parsed.rooted then
        segments[#segments + 1] = segment
      end
    else
      segments[#segments + 1] = segment
    end
  end
  return render(parsed, flavour, segments, parsed.trailing_sep)
end

local function compatible(a, b, flavour)
  local left, right = path.parse(a, flavour), path.parse(b, flavour)
  local lp, rp = left.prefix, right.prefix
  if flavour == "windows" then lp, rp = lp:lower(), rp:lower() end
  return lp == rp and left.rooted == right.rooted, left, right
end

function path.join(base, child, flavour)
  check_flavour(flavour)
  assert(type(base) == "string" and type(child) == "string", "paths must be strings")
  local part = path.parse(child, flavour)
  local left_volume, right_volume = path.parse(base, flavour).prefix, part.prefix
  if flavour == "windows" and left_volume ~= "" and right_volume ~= ""
      and left_volume:lower() ~= right_volume:lower() then
    return nil, "paths are on different volumes"
  end
  if part.rooted or part.prefix ~= "" then return path.normalize(child, flavour) end
  if child == "" then return path.normalize(base, flavour) end
  local sep = path.separator(flavour)
  local left = base
  if left == "" then return path.normalize(child, flavour) end
  if not is_sep(left:sub(-1), flavour) then left = left .. sep end
  return path.normalize(left .. child, flavour)
end

function path.relative(from, to, flavour)
  check_flavour(flavour)
  local a, b = path.parse(path.normalize(from, flavour), flavour), path.parse(path.normalize(to, flavour), flavour)
  local ap, bp = a.prefix, b.prefix
  if flavour == "windows" then ap, bp = ap:lower(), bp:lower() end
  if ap ~= bp or a.rooted ~= b.rooted then return nil, "paths are on different volumes or roots" end
  local common = 0
  while common < #a.segments and common < #b.segments do
    local left, right = a.segments[common + 1], b.segments[common + 1]
    if flavour == "windows" then left, right = left:lower(), right:lower() end
    if left ~= right then break end
    common = common + 1
  end
  local result = {}
  for _ = common + 1, #a.segments do result[#result + 1] = ".." end
  for index = common + 1, #b.segments do result[#result + 1] = b.segments[index] end
  local value = table.concat(result, path.separator(flavour))
  if value == "" and b.trailing_sep then return "." .. path.separator(flavour) end
  return value == "" and "." or value
end

function path.split(value, flavour)
  local parsed = path.parse(value, flavour)
  if parsed.trailing_sep then return parsed.prefix, path.normalize(value, flavour), "" end
  local base = parsed.segments[#parsed.segments] or ""
  local directory_segments = {}
  for index = 1, math.max(0, #parsed.segments - 1) do
    directory_segments[#directory_segments + 1] = parsed.segments[index]
  end
  local directory = render(parsed, flavour, directory_segments, #parsed.segments > 0)
  if #parsed.segments == 0 then
    directory = render(parsed, flavour, {}, parsed.trailing_sep)
  end
  return parsed.prefix, directory, base
end

local function equal_segment(a, b, flavour)
  if flavour == "windows" then return a:lower() == b:lower() end
  return a == b
end

function path.same(a, b, flavour)
  local left, right = path.parse(path.normalize(a, flavour), flavour), path.parse(path.normalize(b, flavour), flavour)
  if not equal_segment(left.prefix, right.prefix, flavour) or left.rooted ~= right.rooted
      or #left.segments ~= #right.segments then return false end
  for index = 1, #left.segments do
    if not equal_segment(left.segments[index], right.segments[index], flavour) then return false end
  end
  return true
end

function path.contains(root, value, flavour)
  local parent, child = path.parse(path.normalize(root, flavour), flavour), path.parse(path.normalize(value, flavour), flavour)
  if not equal_segment(parent.prefix, child.prefix, flavour) or parent.rooted ~= child.rooted
      or #parent.segments > #child.segments then return false end
  for index = 1, #parent.segments do
    if not equal_segment(parent.segments[index], child.segments[index], flavour) then return false end
  end
  return true
end

function path.simplify_verbatim(value)
  assert(type(value) == "string", "path must be a string")
  if starts_windows(value, "\\\\?\\UNC\\") then return "\\\\" .. value:sub(9) end
  if starts_windows(value, "\\\\?\\") and value:sub(5, 6):match("^%a:$")
      and is_sep(value:sub(7, 7), "windows") then
    return value:sub(5)
  end
  return value
end

if type(remuda) == "table" then remuda._butler_path = path end
return path
