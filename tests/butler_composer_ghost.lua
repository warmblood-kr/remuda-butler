-- #372: first-task delivery judged the raw screen, so a dim ghost suggestion in an idle
-- Claude composer read NON-EMPTY forever while the notice policy said EMPTY. One shared decision.
-- A Claude composer is EMPTY only when styled capture proves it: a dim 'Try "..."' suggestion on the cursor
-- row, blank rows down to a bottom border as wide as the top one. Run from the repository root: luajit tests/butler_composer_ghost.lua
_butler_session_trace = function() end
local bus = { agents = { lead = { id = "lead-id", kind = "claude" } }, notices = {}, pending_tasks = {},
  notice_timers = {}, messages = {}, objects = {}, mail_delivered = {} }
local rule = string.rep("─", 20)
local ghost = 'Try "remuda butler inbox"'
local ghost_screen = rule .. "\n❯ " .. ghost .. "\n" .. rule .. "\n  ⏵⏵ auto mode on"
remuda = {
  _butler_notice_config = { bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = { mailbox = function() return {} end }, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { claude = {} },
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = false } } end,
  capture = function() return ghost_screen end,
  capture_styled = function()
    return { cursor = { row = 2 }, rows = { { { text = rule } },
      { { text = "❯ " }, { text = ghost, dim = true } }, { { text = rule } }, { { text = "  ⏵⏵ auto mode on" } } } }
  end,
}
dofile("packages/butler/notice.lua")

assert(remuda._butler_prompt_is_empty("claude", ghost_screen) == "NON-EMPTY", "raw screen reads the ghost as text")
assert(remuda._butler_notify_policy("lead"), "the policy drops the ghost: idle is quiet")
local decision = remuda._butler_composer_decision("claude", "lead", ghost_screen)
assert(decision == "EMPTY", "first-task delivery must agree with the policy, got " .. tostring(decision))

-- Without capture_styled it falls back to the raw screen; real text stays NON-EMPTY.
remuda.capture_styled = nil
assert(remuda._butler_composer_decision("claude", "lead", "❯ real draft\n────") == "NON-EMPTY")
print("ok - composer decision ignores ghost text")

-- A multi-line draft with an empty first line: the cursor row alone reads EMPTY, but the text
-- below is the human's. Only upgrade when the raw text IS the dim ghost.
remuda.capture_styled = function()
  return { cursor = { row = 1 }, rows = { { { text = "❯ " } }, { { text = "  second line" } } } }
end
local draft = remuda._butler_composer_decision("claude", "lead", "❯ \n  second line\n────")
assert(draft == "NON-EMPTY", "a draft below an empty first line must stay NON-EMPTY, got " .. tostring(draft))
print("ok - multi-line draft is not upgraded")

-- A real, non-dim 23-byte draft with capture_styled present must stay NON-EMPTY: the styled
-- read only upgrades a dim ghost (fails under an always-EMPTY decision).
local typed = "this is a real draft ok"
assert(#typed == 23)
remuda.capture_styled = function()
  return { cursor = { row = 2 }, rows = { {}, { { text = "❯ " }, { text = typed } } } }
end
local real = remuda._butler_composer_decision("claude", "lead", rule .. "\n❯ " .. typed .. "\n" .. rule)
assert(real == "NON-EMPTY", "a real draft with capture_styled present must stay NON-EMPTY, got " .. tostring(real))
print("ok - real draft stays NON-EMPTY with capture_styled")
