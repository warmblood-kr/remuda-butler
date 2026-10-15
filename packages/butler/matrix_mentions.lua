-- Convert only confirmed Matrix user mention pills to readable @display text.
-- We require the formatted HTML to map byte-for-byte to body before applying
-- any replacement. Any parse or alignment uncertainty leaves body untouched.
local mentions = {}
local MAX_BYTES = 64 * 1024
local MAX_MENTIONS = 128
local MAX_TAGS = 4096
local ALLOWED_TAGS = { a=true, b=true, strong=true, i=true, em=true, u=true, s=true,
  del=true, strike=true, code=true, pre=true, blockquote=true, p=true, div=true, span=true, br=true }
local VOID_TAGS = { br=true }

local function valid_mxid(value)
  return type(value) == "string" and #value <= 255 and value:match("^@[^%s:]+:[^%s]+$") ~= nil
end

local function utf8(code)
  if code <= 0x7f then return string.char(code) end
  if code <= 0x7ff then return string.char(0xc0 + math.floor(code / 64), 0x80 + code % 64) end
  if code <= 0xffff and (code < 0xd800 or code > 0xdfff) then
    return string.char(0xe0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
  end
  if code <= 0x10ffff then
    return string.char(0xf0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
      0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
  end
end

local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }
local function decode_entities(value)
  local bad = false
  local decoded = value:gsub("&([^;]-);", function(entity)
    if named[entity] then return named[entity] end
    local number = entity:match("^#(%d+)$")
    if not number then number = entity:match("^#[xX]([%da-fA-F]+)$") end
    if number then
      local base = entity:match("^#[xX]") and 16 or 10
      local code = tonumber(number, base)
      local char = code and utf8(code)
      if char and code ~= 0 then return char end
    end
    bad = true
    return ""
  end)
  if bad or decoded:find("&[^;]*;", 1) then return nil end
  return decoded
end

local function tag_info(raw)
  local closing, name = raw:match("^%s*(/?)%s*([%a][%w:-]*)")
  if not name then return nil end
  name = name:lower()
  local self_close = raw:match("/%s*$") ~= nil
  local attrs = {}
  local prefix = raw:match("^%s*/?%s*[%a][%w:-]*")
  local rest = raw:sub(#prefix + 1)
  if self_close then rest = rest:gsub("/%s*$", "") end
  if closing == "/" then
    if rest:find("%S") then return nil end
    return { closing = true, name = name, self_close = false, attrs = attrs }
  end
  local seen, at = {}, 1
  while at <= #rest do
    while rest:sub(at, at):match("%s") do at = at + 1 end
    if at > #rest then break end
    local key, after = rest:sub(at):match("^([%a_:][%w:._-]*)()")
    if not key then return nil end
    key, at = key:lower(), at + after - 1
    if seen[key] then return nil end
    seen[key] = true
    while rest:sub(at, at):match("%s") do at = at + 1 end
    local value
    if rest:sub(at, at) == "=" then
      at = at + 1
      while rest:sub(at, at):match("%s") do at = at + 1 end
      local quote = rest:sub(at, at)
      if quote ~= "'" and quote ~= '"' then return nil end
      local finish = rest:find(quote, at + 1, true)
      if not finish then return nil end
      value, at = rest:sub(at + 1, finish - 1), finish + 1
    elseif key == "href" then
      return nil
    end
    attrs[key] = value
  end
  return { closing = false, name = name, self_close = self_close, attrs = attrs }
end

local function matrix_to_user(href)
  if type(href) ~= "string" then return nil end
  local prefix = "https://matrix.to/#/"
  if href:sub(1, #prefix) ~= prefix then return nil end
  local user = href:sub(#prefix + 1)
  if user:find("[/?#]") then return nil end
  return user
end

local function parse(content)
  local body, html = content.body, content.formatted_body
  if type(body) ~= "string" or type(html) ~= "string" or #body > MAX_BYTES or #html > MAX_BYTES
      or content.format ~= "org.matrix.custom.html" then return nil end
  local listed = {}
  local meta = content["m.mentions"]
  if type(meta) ~= "table" or type(meta.user_ids) ~= "table" then return nil end
  local count = 0
  for _, user in ipairs(meta.user_ids) do
    count = count + 1
    if count > MAX_MENTIONS or not valid_mxid(user) then return nil end
    listed[user] = true
  end
  local output, anchors, stack = {}, {}, {}
  local at, tags, in_code, active_anchor, output_bytes = 1, 0, 0, nil, 0
  local function add(text)
    if text == "" then return end
    if active_anchor and in_code == 0 then active_anchor.text = active_anchor.text .. text end
    output[#output + 1] = text
    local start = output_bytes + 1
    output_bytes = output_bytes + #text
    return start, output_bytes + 1
  end
  while at <= #html do
    local first = html:find("<", at, true)
    local text_end = first and first - 1 or #html
    if text_end >= at then
      local text = decode_entities(html:sub(at, text_end))
      if not text then return nil end
      local start, finish = add(text)
      if active_anchor and in_code == 0 and start then
        active_anchor.end_pos = finish
      end
    end
    if not first then break end
    local close = html:find(">", first + 1, true)
    if not close then return nil end
    tags = tags + 1
    if tags > MAX_TAGS then return nil end
    local raw = html:sub(first + 1, close - 1)
    if raw:sub(1, 3) == "!--" then
      local comment_end = html:find("-->", first + 4, true)
      if not comment_end then return nil end
      at = comment_end + 3
    else
      local tag = tag_info(raw)
      if not tag then return nil end
      if tag.closing then
        if tag.name == "br" or stack[#stack] ~= tag.name then return nil end
        stack[#stack] = nil
        if tag.name == "a" then
          if active_anchor then
            if active_anchor.user_id and active_anchor.start_pos and active_anchor.end_pos
                and not active_anchor.text:find("[\r\n]")
                and active_anchor.end_pos > active_anchor.start_pos then
              anchors[#anchors + 1] = active_anchor
            end
            active_anchor = nil
          end
        elseif tag.name == "code" or tag.name == "pre" then
          in_code = math.max(0, in_code - 1)
        end
      else
        if not ALLOWED_TAGS[tag.name] or (tag.self_close and not VOID_TAGS[tag.name]) then return nil end
        if VOID_TAGS[tag.name] then
          if tag.name == "br" then
            local start, finish = add("\n")
            if active_anchor and in_code == 0 then active_anchor.end_pos = finish end
          end
        elseif not tag.self_close then
          stack[#stack + 1] = tag.name
        end
        if tag.name == "code" or tag.name == "pre" then in_code = in_code + 1 end
        if tag.name == "a" then
          for index = 1, #stack - 1 do if stack[index] == "a" then return nil end end
          local user = in_code == 0 and matrix_to_user(tag.attrs.href) or nil
          active_anchor = user and listed[user] and { user_id = user, start_pos = output_bytes + 1, text = "" } or nil
        end
      end
      at = close + 1
    end
  end
  local plain = table.concat(output)
  if active_anchor or #stack ~= 0 or plain ~= body then return nil end
  for _, anchor in ipairs(anchors) do
    anchor.display = anchor.text
    if anchor.display:sub(1, 1) ~= "@" then anchor.display = "@" .. anchor.display end
  end
  table.sort(anchors, function(a, b) return a.start_pos < b.start_pos end)
  local previous = 0
  for _, anchor in ipairs(anchors) do
    if anchor.start_pos <= previous or body:sub(anchor.start_pos, anchor.end_pos - 1) ~= anchor.text then return nil end
    previous = anchor.end_pos - 1
  end
  local normalized, mapped, cursor = {}, {}, 1
  for _, anchor in ipairs(anchors) do
    normalized[#normalized + 1] = body:sub(cursor, anchor.start_pos - 1)
    normalized[#normalized + 1] = anchor.display
    mapped[#mapped + 1] = anchor.user_id
    cursor = anchor.end_pos
  end
  if #anchors == 0 then return body, {} end
  normalized[#normalized + 1] = body:sub(cursor)
  return table.concat(normalized), mapped
end

function mentions.normalize(content)
  if type(content) ~= "table" then return nil, {} end
  local body, metadata = parse(content)
  if not body then return content.body, {} end
  return body, metadata
end

local matrix = assert(remuda.butler and remuda.butler.matrix, "load Matrix before matrix_mentions")
matrix.mention_normalization = mentions
return mentions
