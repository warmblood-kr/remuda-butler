-- Explicit effective root session name (opt-in, no silent rename).
--
-- The root's durable IDENTITY stays logical "butler": the agent ULID,
-- agents.jsonl alias, memory/<butler>, the leader field and the `butler`
-- extension command are unchanged. Only the PHYSICAL session name -- the
-- name `remuda ls`/`remuda send` use and restart recovery looks for -- can
-- be chosen. That lets an operator start a distinct Butler instance after a
-- collision without claiming the old process died, and without splitting the
-- Butler identity in two.
--
-- Sources, in order (see `resolve`):
--   1. remuda._butler_initial_name_override -- written by install-butler.sh
--      into the user init.lua and re-applied by every fresh daemon,
--   2. REMUDA_BUTLER_NAME in the daemon image environment,
--   3. the name recorded in effective-name by an earlier launch/adoption,
--   4. the stable default "butler".
-- An INVALID explicit value returns nil instead of a name: the caller must
-- refuse to start rather than silently fall back to a different name.
--
-- `effective-name` is a small durable record next to the roster:
--   version=1
--   logical=butler
--   name=<physical session name>
--   instance=<last bound launch instance id, or empty>
-- The instance id in roster.json stays authoritative; the record only answers
-- "which physical session name is logical butler" after a daemon restart.
local M = {}

local DEFAULT = "butler"
local MAX_LEN = 64
local RECORD_VERSION = "1"

-- A session/control name: starts with a word character, then word, dot,
-- underscore or dash. Conservative so it is safe in shell, awk, filenames
-- and `remuda send NAME` without quoting surprises.
local function valid(name)
  if type(name) ~= "string" or name == "" or #name > MAX_LEN then
    return false
  end
  if name:find("%c") then return false end
  return name:match("^[%w][%w._%-]*$") ~= nil
end

function M.valid(name)
  return valid(name)
end

function M.default_name()
  return DEFAULT
end

-- Returns name, source on success, and nil, "invalid" when an explicit value
-- is malformed. `recorded` is our own cache: when it is corrupt it is ignored
-- (a corrupt cache must not keep the root from starting), which is different
-- from an explicit operator value.
function M.resolve(override, env, recorded)
  if type(override) == "string" and override ~= "" then
    if valid(override) then return override, "override" end
    return nil, "invalid"
  end
  if type(env) == "string" and env ~= "" then
    if valid(env) then return env, "env" end
    return nil, "invalid"
  end
  if type(recorded) == "string" and valid(recorded) then
    return recorded, "recorded"
  end
  return DEFAULT, "default"
end

-- The parsed name from an effective-name record, or nil when the text is
-- missing/foreign/corrupt. Never raises.
function M.recorded_name(text)
  if type(text) ~= "string" or text == "" then return nil end
  local fields = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then fields[key] = value end
  end
  if fields.version ~= RECORD_VERSION then return nil end
  if fields.logical ~= "butler" then return nil end
  if not valid(fields.name) then return nil end
  return fields.name
end

-- The durable record text. `instance` may be nil/empty (the roster's
-- instance binding stays authoritative).
function M.format_binding(name, instance, logical)
  return table.concat({
    "version=" .. RECORD_VERSION,
    "logical=" .. (logical or "butler"),
    "name=" .. tostring(name or ""),
    "instance=" .. tostring(instance or ""),
    "",
  }, "\n")
end

-- Restart/adoption predicate. A listed row stands for this name only when
-- the name matches and the row is alive; a missing or unavailable row is not
-- a live session.
function M.session_alive(rows, name)
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and row.name == name and row.alive then
      return true
    end
  end
  return false
end

-- Routing: the logical alias that owns a physical session name, from roster
-- rows ({ alias, session_name, ... }). A physical name resolves to exactly
-- one logical alias, or nil when unknown; callers must not guess.
function M.logical_for(rows, physical)
  if type(physical) ~= "string" or physical == "" then return nil end
  local found
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and row.session_name == physical then
      if found and found ~= row.alias then return nil end -- ambiguous
      found = row.alias
    end
  end
  return found
end

if type(remuda) == "table" then remuda._butler_effective_name = M end
return M
