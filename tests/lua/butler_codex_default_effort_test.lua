-- #490: production compaction callbacks, synthetic picker screens, private daemon.
T.test("Codex default effort follows the marked row and restores session-only", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function() return T.eval('return remuda._butler_bus ~= nil') == "true" end, 5)
  T.eq(T.eval([[
    remuda._butler_compaction_has_session = function() return true end
    remuda._butler_compaction_preflight = function() end
    remuda._butler_compaction_action_guard = function() end
    remuda._butler_compaction_failure_cooldown = function() return false end
    remuda._butler_compaction_failure_exhausted = function() return false end
    remuda._butler_mail.unread = function() return 0 end
    local serial = 0
    local function scenario(lower_default, restore_default, footer_effort, bad)
      serial = serial + 1
      local name = "default-case-" .. serial
      local reports, watchers, keys, commands = {}, {}, {}, {}
      local used = "500000"
      local footer = "GPT-6-Sol " .. footer_effort .. " · /work\n› Ask Codex to do anything"
      local screen = footer
      remuda._butler_bus.agents[name] = {id=name, kind="codex", session_name=name, parent="butler"}
      remuda._butler_telemetry_for = function() return {context_used=used} end
      remuda.capture = function() return screen end
      remuda.session = function() return {is_busy=false, attached=false} end
      remuda._butler_send = function(_, _, text) reports[#reports+1] = text end
      remuda._butler_notice_compacted = function() end
      remuda.type_text = function(_, text) commands[#commands+1] = text; return true end
      remuda.key = function(_, key)
        keys[#keys+1] = key
        assert(key ~= "RET", "global default Return sent")
        if key == "ESC" then screen = footer end
      end
      remuda.expect = function(_, branches)
        watchers[#watchers+1] = branches
        return {cancel=function() end}
      end
      assert(remuda._butler_compaction_execute(name, true) == "started")
      local function drive(id, painted)
        screen = painted
        local branch = watchers[#watchers][1]
        assert(branch.id == id, "expected " .. id .. ", got " .. branch.id)
        assert(branch.match(screen), "screen did not match " .. id)
        branch.action(screen)
      end
      local labels, efforts = {"Low", "Medium", "High", "Extra high"}, {"low", "medium", "high", "xhigh"}
      local function picker(model, default, cursor, invalid)
        local lines = {"Select Reasoning Level for " .. model}
        for i, label in ipairs(labels) do
          local marked = i == default or (invalid == "ambiguous" and i == 3)
          lines[#lines+1] = (i == cursor and "› " or "  ") .. i .. ". " .. label
            .. (marked and " (default)" or "")
        end
        return table.concat(lines, "\n")
      end
      drive("codex-model-picker", "Select Model and Effort\n› 1. gpt-6-luna")
      drive("codex-effort-picker", picker("gpt-6-luna", lower_default, 2, bad))
      if bad then
        drive("codex-picker-escape", screen)
        drive("codex-effort-picker-closed", footer)
        drive("codex-picker-escape", footer)
        assert(reports[1] == "Compaction failed: no 'default' effort row for gpt-6-luna", reports[1])
        assert(table.concat(keys, ",") == "1,ESC", "unsafe key on missing/ambiguous default")
        assert(#commands == 1 and commands[1] == "/model", "compact sent after failed selection")
        return
      end
      local lower_target = footer_effort == "default" and lower_default or 3
      drive("codex-effort-row", picker("gpt-6-luna", lower_default, lower_target))
      assert(not watchers[#watchers][1].match("GPT-6-Sol " .. efforts[lower_target] .. " · /work"),
        "wrong model accepted as confirmation")
      local wrong_effort = lower_target == 1 and "high" or "low"
      assert(not watchers[#watchers][1].match("GPT-6-Luna " .. wrong_effort .. " · /work"),
        "wrong concrete effort accepted as default")
      drive("codex-model-set", "GPT-6-Luna " .. efforts[lower_target] .. " · /work")
      assert(commands[2] == "/compact", "compact not sent after session switch")
      used = "100000"
      drive("compact-complete", screen)
      drive("codex-model-picker", "Select Model and Effort\n› 1. gpt-6-sol")
      drive("codex-effort-picker", picker("gpt-6-sol", restore_default, 2))
      local restore_target = footer_effort == "default" and restore_default or 3
      drive("codex-effort-row", picker("gpt-6-sol", restore_default, restore_target))
      -- Some footers retain the symbolic default; others show its concrete effort.
      local restored_effort = serial == 2 and "default" or efforts[restore_target]
      drive("codex-model-set", "GPT-6-Sol " .. restored_effort .. " · /work")
      local applies = 0
      for _, key in ipairs(keys) do if key == "s" then applies = applies + 1 end end
      assert(applies == 2, "switch and restore must each use session-only s")
      assert(table.concat(commands, ",") == "/model,/compact,/model", "unexpected commands")
      assert(#reports == 0, table.concat(reports, "\n"))
      assert(not remuda._butler_compaction_members_state[name].restore_pending,
        "restore record not cleared after confirmation")
    end
    scenario(2, 1, "default") -- luna Medium default, prior model Low default
    scenario(4, 3, "default") -- Extra high -> xhigh, symbolic restored footer
    scenario(1, 4, "high") -- explicit High retains existing selection behavior
    scenario(nil, 1, "default", "missing")
    scenario(2, 1, "default", "ambiguous")
    return "ok"
  ]]), "ok")
end)
