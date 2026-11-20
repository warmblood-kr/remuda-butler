-- First task vs the folder-trust dialog: Butler must not type while the dialog is up (Return would
-- dismiss the dialog and the text would be lost), must deliver after it clears, and must resend
-- when the text never reached the composer. Fake TUI keyed by session name.
local DIALOG = table.concat({
  "────────────────────", " Accessing workspace:", "", " /p/work", "",
  " Quick safety check: Is this a project you created or one you trust?", "",
  " ❯ No, exit", "   Yes, I trust this folder", "", " Enter to confirm · Esc to cancel" }, "\n")
local COMPOSER = "────────────────────\n❯ \n────────────────────\n  ⏵⏵ auto mode on"

local function start_butler()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  T.eval(string.format([[
    remuda.butler.project_home(%q)
    remuda._butler_agent_builders.claude = function() return { "sleep", "100" } end
    remuda._butler_notify_policy = function() return true end
    remuda._butler_task_retry_policy = function() return true end
    remuda._butler_task_poke_deferrals = 40
    -- dialog: up until RET; typed while up is consumed (lost); drop_first loses the first write
    remuda._t = { dialog = {}, typed = {}, writes = {}, drop = {} }
    remuda.capture = function(name)
      if remuda._t.dialog[name] then return %q end
      local text = remuda._t.typed[name] or ""
      return "────────────────────\n❯ " .. text .. "\n────────────────────\n  ⏵⏵ auto mode on"
    end
    remuda.capture_styled = function() return nil end
    remuda.session = function(name) return { is_busy = false } end
    remuda.key = function(name, key)
      if key == "RET" and remuda._t.dialog[name] then remuda._t.dialog[name] = false end
    end
    remuda.type_text = function(name, text)
      remuda._t.writes[name] = (remuda._t.writes[name] or 0) + 1
      if remuda._t.dialog[name] then return end
      if remuda._t.drop[name] and remuda._t.writes[name] == 1 then return end
      remuda._t.typed[name] = text
    end
  ]], os.getenv("XDG_DATA_HOME") .. "/projects", DIALOG))
end

local function writes(name) return T.eval(string.format("return tostring(remuda._t.writes[%q] or 0)", name)) end
local function state(name)
  return T.eval(string.format("return tostring((remuda._butler_bus.first_task_delivery[%q] or {}).state)", name))
end
local function wait_ticks(seconds)
  local at = os.time() + seconds
  T.wait_until(function() return os.time() >= at end, seconds + 3, "settle")
end
local function delegate(name, dialog, drop)
  T.eval(string.format("remuda._t.dialog[%q] = %s; remuda._t.drop[%q] = %s", name, tostring(dialog), name, tostring(drop)))
  T.eval(string.format("remuda._butler_topic_delegate(%q, 'do the thing', nil, 'claude', 'butler')", name))
  T.wait_until(function() return state(name) ~= "nil" end, 5, "delivery record")
end

T.test("first task is held while the trust dialog is up, then delivered", function()
  start_butler()
  local name = "t-trust"
  delegate(name, true, false)
  wait_ticks(3)
  T.eq(writes(name), "0", "nothing typed while the trust dialog is up")
  T.eval(string.format("remuda._t.dialog[%q] = false", name))
  T.wait_until(function() return writes(name) == "1" end, 8, "task typed after the dialog cleared")
end)

T.test("first task is resent when the first write never reached the composer", function()
  local name = "t-resend"
  delegate(name, false, true)
  T.wait_until(function() return tonumber(writes(name)) >= 2 end, 20, "task resent after the first write was lost")
end)
