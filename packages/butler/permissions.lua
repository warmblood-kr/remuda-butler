-- The permission rules Butler grants its own agents. They ride in the
-- mod-owned Claude settings file passed with `--settings`; nothing is written
-- into a session's `.claude/` directory, and nothing for Codex.
local permissions = {}

local PREFIX = "Bash(remuda butler:*)"
local MAIL_VERBS = { "inbox", "send", "send-to-leader", "reply", "forward", "sessions" }

-- Only `Bash(remuda butler[ VERB...]:*)`: a rule never reaches past this CLI.
function permissions.valid_rule(rule)
  if type(rule) ~= "string" then return false end
  local verbs = rule:match("^Bash%(remuda butler([ %w%-]*):%*%)$")
  if not verbs then return false end
  local rest = verbs
  while rest ~= "" do
    local word, tail = rest:match("^ (%w[%w%-]*)(.*)$")
    if not word then return false end
    rest = tail
  end
  return true
end

-- The role is a constant at the launch call site; anything but "root" is a member.
function permissions.builtin(ctx)
  if type(ctx) == "table" and ctx.role == "root" then return { PREFIX } end
  local rules = {}
  for _, verb in ipairs(MAIL_VERBS) do rules[#rules + 1] = "Bash(remuda butler " .. verb .. ":*)" end
  return rules
end

-- Joins the `butler.permission` rows. Returns the rules and what was dropped
-- (`{ id, rule }`); a bad row loses its rules and never fails a launch.
function permissions.rules(ctx, rows)
  local role = type(ctx) == "table" and ctx.role == "root" and "root" or "member"
  local rules, seen, dropped = {}, {}, {}
  for _, row in ipairs(rows or {}) do
    local render = type(row.entry) == "table" and row.entry.rules
    if render then
      local ok, list = pcall(render, { role = role, kind = "claude" })
      if not ok or type(list) ~= "table" then
        dropped[#dropped + 1] = { id = row.id, rule = ok and "(not a list)" or "(failed)" }
      else
        for _, rule in ipairs(list) do
          -- The whole prefix is the root Butler's alone, whoever offers it.
          if not permissions.valid_rule(rule) or (role ~= "root" and rule == PREFIX) then
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

local function json_quote(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    :gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end

-- The whole settings file: the status line it always had, plus the rules.
function permissions.settings_json(statusline_command, rules)
  local allow = {}
  for _, rule in ipairs(rules or {}) do allow[#allow + 1] = json_quote(rule) end
  return '{"statusLine":{"type":"command","command":' .. json_quote(statusline_command) .. '}'
    .. (#allow > 0 and (',"permissions":{"allow":[' .. table.concat(allow, ",") .. ']}') or "")
    .. '}'
end

if type(remuda) == "table" then remuda._butler_permissions = permissions end
return permissions
