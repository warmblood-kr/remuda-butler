-- Pure source adapter v1: exact immutable-file snapshot for one recipient.
--
-- This module performs migration-time verification only. It opens no SQLite,
-- performs no delivery or read receipt, and never mutates the mail source.
-- Every filesystem, JSON and hash capability is injected; absent capabilities
-- fail closed instead of guessing.
local M = { contract_version = 1 }

local function fail(code, field, path, line)
  return nil, { code = code, field = field, path = path, line = line }
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

-- Mailbox names are lowercase, even-length hex file components, never names.
local function is_hex(value)
  return type(value) == "string" and #value > 0 and #value % 2 == 0
    and value:match("^[0-9a-f]+$") ~= nil
end

-- An id becomes a path component; never one that leaves its directory.
local function safe_component(value)
  return nonempty(value) and not value:find("[/\\]") and not value:find("..", 1, true)
end

local function error_code(err)
  if type(err) == "table" and nonempty(err.code) then return err.code end
  if type(err) == "string" and err:find("No such file", 1, true) then return "not_found" end
  return "io"
end

local Source = {}
Source.__index = Source

local function read(self, path)
  local ok, text, err = pcall(self.fs.read, path)
  if not ok or type(text) ~= "string" then
    local code = (not ok) and "io" or error_code(err)
    return nil, { code = (code == "not_found") and "not_found" or "source_unreadable", path = path }
  end
  return text
end

local function list(self, path)
  local ok, names, err = pcall(self.fs.list, path)
  if not ok then return nil, { code = "source_unreadable", path = path } end
  if names == nil then
    local code = error_code(err)
    if code == "not_found" then return {}, nil end
    return nil, { code = "source_unreadable", path = path }
  end
  if type(names) ~= "table" then return nil, { code = "source_unreadable", path = path } end
  return names, nil
end

local function decode(self, text, path)
  local ok, value = pcall(self.json.decode, text)
  if not ok or value == nil then return nil, { code = "source_unreadable", path = path } end
  return value
end

local function canonical(self, value, path)
  local ok, text = pcall(self.json.canonical, value)
  if not ok or type(text) ~= "string" then return nil, { code = "source_unreadable", path = path } end
  return text
end

local function check_root(self, root)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  return true
end

local function check_recipient(hex)
  if not is_hex(hex) then return fail("invalid_snapshot", "recipient") end
  return true
end

-- A missing content file is unreadable source, never an empty mailbox.
local function content_error(why, path, field)
  return fail("source_unreadable", field or "missing", path)
end

local function torn(text, path)
  return text ~= "" and text:sub(-1) ~= "\n" and { code = "partial", path = path } or nil
end

-- Strict newline-terminated JSONL of objects with a nonempty safe message_id.
-- Duplicates collapse at first distinct appearance; only a PRESENT resent
-- object replaces the retained annotation.
local function parse_inbox(self, hex, text)
  local path = "inboxes/" .. hex .. ".jsonl"
  local partial = torn(text, path)
  if partial then return nil, partial end
  local rows, index = {}, {}
  for line in text:gmatch("([^\n]*)\n") do
    local value, decode_err = decode(self, line, path)
    if decode_err or type(value) ~= "table" then
      return fail("source_unreadable", nil, path)
    end
    local id = value.message_id
    if not safe_component(id) then return fail("source_unreadable", "message_id", path) end
    local resent = value.resent
    if resent ~= nil and (type(resent) ~= "table" or #resent > 0) then
      return fail("source_unreadable", "resent", path)
    end
    local row = index[id]
    if not row then
      row = { id = id, seq = #rows + 1 }
      rows[#rows + 1] = row
      index[id] = row
    end
    if resent ~= nil then
      local encoded, encode_err = canonical(self, resent, path)
      if not encoded then return nil, encode_err end
      row.resent = encoded
      row.resent_value = resent
    end
  end
  return rows, nil
end

-- Raw read ids: exact legacy line values (CR is data), duplicates collapse.
local function parse_reads(self, hex, text)
  local path = "read/" .. hex .. ".jsonl"
  local partial = torn(text, path)
  if partial then return nil, partial end
  local reads = {}
  for line in text:gmatch("([^\n]*)\n") do
    if not safe_component(line) then return fail("source_unreadable", nil, path) end
    reads[line] = true
  end
  return reads, nil
end

local function log_text(self, path)
  local text, why = read(self, self.root .. "/" .. path)
  if not text then
    if why.code == "not_found" then return false, nil end
    return nil, why
  end
  return text, nil
end

-- Every path the witness covers: both logs, each delivered envelope, its body
-- object, and any retained resent note object. Each file is read exactly once.
local function dependency_files(self, hex)
  local files = {}
  local inbox_text, inbox_err = log_text(self, "inboxes/" .. hex .. ".jsonl")
  if inbox_text == nil then return nil, inbox_err end
  files["inboxes/" .. hex .. ".jsonl"] = inbox_text
  local rows, rows_err = parse_inbox(self, hex, inbox_text or "")
  if not rows then return nil, rows_err end
  local read_text, read_err = log_text(self, "read/" .. hex .. ".jsonl")
  if read_text == nil then return nil, read_err end
  files["read/" .. hex .. ".jsonl"] = read_text
  local reads, reads_err = parse_reads(self, hex, read_text or "")
  if not reads then return nil, reads_err end
  for _, row in ipairs(rows) do
    local envelope_path = "messages/" .. row.id .. ".json"
    local text, why = read(self, self.root .. "/" .. envelope_path)
    if not text then return content_error(why, envelope_path) end
    files[envelope_path] = text
    local envelope, decode_err = decode(self, text, envelope_path)
    if decode_err or type(envelope) ~= "table" then
      return fail("source_unreadable", nil, envelope_path)
    end
    if envelope.id ~= row.id then return fail("source_unreadable", "id", envelope_path) end
    local body = envelope.body
    if type(body) ~= "table" or not safe_component(body.object_id) then
      return fail("source_unreadable", "object_id", envelope_path)
    end
    local object_path = "objects/" .. body.object_id
    local content, content_err = read(self, self.root .. "/" .. object_path)
    if not content then return content_error(content_err, object_path) end
    files[object_path] = content
    if body.bytes ~= nil and (type(body.bytes) ~= "number" or body.bytes % 1 ~= 0
      or body.bytes ~= #content) then
      return fail("source_unreadable", "bytes", envelope_path)
    end
    local note = row.resent_value and row.resent_value.note_object_id or nil
    if note ~= nil then
      if not safe_component(note) then
        return fail("source_unreadable", "note_object_id", "inboxes/" .. hex .. ".jsonl")
      end
      local note_path = "objects/" .. note
      local note_text, note_err = read(self, self.root .. "/" .. note_path)
      if not note_text then return content_error(note_err, note_path) end
      files[note_path] = note_text
    end
  end
  return files, nil
end

local function witness(self, root, hex)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  local files, dep_err = dependency_files(self, hex)
  if not files then return nil, dep_err end
  local ordered = {}
  for path in pairs(files) do ordered[#ordered + 1] = path end
  table.sort(ordered)
  local framed = {}
  local function frame(value) framed[#framed + 1] = #value .. ":" .. value end
  frame("source-v1")
  frame(self.root)
  frame(hex)
  for _, path in ipairs(ordered) do
    frame(path)
    local text = files[path]
    if text == false then
      frame("absent")
    else
      frame("present")
      frame(tostring(#text))
      frame(text)
    end
  end
  local digest = self.sha256(table.concat(framed))
  if not is_hex(digest) or #digest ~= 64 then return fail("unavailable", "sha256") end
  return "source-v1:sha256:" .. digest
end

function Source:recipients(root)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  local names, names_err = list(self, self.root .. "/inboxes")
  if not names then return nil, names_err end
  local read_names, read_err = list(self, self.root .. "/read")
  if not read_names then return nil, read_err end
  local seen = {}
  for _, group in ipairs({ names, read_names }) do
    for _, name in ipairs(group) do
      local hex = type(name) == "string" and name:match("^([0-9a-f]+)%.jsonl$") or nil
      if not is_hex(hex) then return fail("source_unreadable", "filename") end
      seen[hex] = true
    end
  end
  local recipients = {}
  for hex in pairs(seen) do recipients[#recipients + 1] = hex end
  table.sort(recipients)
  return { recipients = recipients, complete = true }
end

function Source:snapshot(root, hex)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  local before, before_err = witness(self, root, hex)
  if not before then return nil, before_err end
  local inbox_text, inbox_why = log_text(self, "inboxes/" .. hex .. ".jsonl")
  if inbox_text == nil then return nil, inbox_why end
  local rows, rows_err = parse_inbox(self, hex, inbox_text or "")
  if not rows then return nil, rows_err end
  local read_text, read_why = log_text(self, "read/" .. hex .. ".jsonl")
  if read_text == nil then return nil, read_why end
  local reads, reads_err = parse_reads(self, hex, read_text or "")
  if not reads then return nil, reads_err end
  local deliveries = {}
  for index, row in ipairs(rows) do
    local envelope_path = "messages/" .. row.id .. ".json"
    local text, why = read(self, self.root .. "/" .. envelope_path)
    if not text then return content_error(why, envelope_path) end
    local envelope, decode_err = decode(self, text, envelope_path)
    if decode_err or type(envelope) ~= "table" then
      return fail("source_unreadable", nil, envelope_path)
    end
    if envelope.id ~= row.id then return fail("source_unreadable", "id", envelope_path) end
    local body = envelope.body
    if type(body) ~= "table" or not safe_component(body.object_id) then
      return fail("source_unreadable", "object_id", envelope_path)
    end
    local object_path = "objects/" .. body.object_id
    local content, content_err = read(self, self.root .. "/" .. object_path)
    if not content then return content_error(content_err, object_path) end
    if body.bytes ~= nil and (type(body.bytes) ~= "number" or body.bytes % 1 ~= 0
      or body.bytes ~= #content) then
      return fail("source_unreadable", "bytes", envelope_path)
    end
    local digest = self.sha256(content)
    if not is_hex(digest) or #digest ~= 64 then return fail("unavailable", "sha256") end
    local metadata, metadata_err = canonical(self, {
      envelope = envelope,
      object = { id = body.object_id, bytes = #content, sha256 = digest },
    }, envelope_path)
    if not metadata then return nil, metadata_err end
    deliveries[index] = { message_id = row.id, seq = index, resent = row.resent,
      envelope_ref = envelope_path, object_ref = object_path, metadata = metadata }
  end
  local after, after_err = witness(self, root, hex)
  if not after then return nil, after_err end
  if before ~= after then return fail("stale_generation") end
  return { deliveries = deliveries, reads = reads, recipient = hex, complete = true,
    witness = after, source_before = before, source_after = after }
end

function Source:witness(root, hex)
  return witness(self, root, hex)
end

function M.open(config)
  if type(config) ~= "table" then return fail("invalid_snapshot", "config") end
  if not nonempty(config.root) then return fail("invalid_snapshot", "root") end
  local fs = config.fs
  if type(fs) ~= "table" or type(fs.list) ~= "function" or type(fs.read) ~= "function" then
    return fail("unavailable", "fs")
  end
  local json = config.json
  if type(json) ~= "table" or type(json.decode) ~= "function"
    or type(json.canonical) ~= "function" then
    return fail("unavailable", "json")
  end
  if type(config.sha256) ~= "function" then return fail("unavailable", "sha256") end
  return setmetatable({ root = config.root, fs = fs, json = json, sha256 = config.sha256 },
    Source)
end

if type(remuda) == "table" then remuda._butler_inbox_source = M end
return M
