-- #372: first-task delivery judged the raw screen, so a dim ghost suggestion in an idle
-- Claude composer read NON-EMPTY forever while the notice policy (cursor row, dim dropped)
-- said EMPTY. One shared decision. Run from the repository root: luajit tests/butler_composer_ghost.lua
_butler_session_trace = function() end
local bus = { agents = { lead = { id = "lead-id", kind = "claude" } }, notices = {}, pending_tasks = {},
  notice_timers = {}, messages = {}, objects = {}, mail_delivered = {} }
local ghost_screen = "────\n❯ remuda butler inbox\n────\n  ⏵⏵ auto mode on"
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
    return { cursor = { row = 2 }, rows = { {}, { { text = "❯ " }, { text = "remuda butler inbox", dim = true } } } }
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
