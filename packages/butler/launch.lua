-- Member launch and topic creation. main.lua passes its locals in (the
-- mail.lua pattern); the chooser helpers come from agents_launch.lua.
local config = assert(remuda._butler_launch_config)
local bus = assert(config.bus)
local system = assert(remuda._butler_system)
local sandbox_lib = assert(remuda._butler_sandbox)
local launch_failure_lines = assert(remuda.butler.launch_failure_lines)
local topic_config = config.topic_config
local data_home = config.data_home
local load_topic_config = config.load_topic_config
local valid_child_name = config.valid_child_name
local create_fresh_directory = config.create_fresh_directory
local directory_is_under = config.directory_is_under
local identity_record = config.identity_record
local register_identity = config.register_identity
local resolve = config.resolve
local mail_address = config.mail_address
local next_token = config.next_token
local mailbox = config.mailbox
local queue_message = config.queue_message
local migrate_legacy_mail = config.migrate_legacy_mail
-- main.lua assigns startup_action_safe with the notice policy; read it late.
local startup_action_safe = config.startup_action_safe
local chooser = assert(remuda._butler_chooser)
local PROMPT_DELIVERY = chooser.PROMPT_DELIVERY
local trust_modal_state = chooser.trust_modal_state
local choose = chooser.choose
local configured_agent_order = chooser.configured_agent_order
local setup_telemetry = chooser.setup_telemetry
local team_member_guidance = chooser.team_member_guidance
local team_member_prompt = chooser.team_member_prompt
local write_agent_guidance = chooser.write_agent_guidance
local option_number = chooser.option_number
local codex_update_version = chooser.codex_update_version
local skip_option_number = chooser.skip_option_number
local startup_modal_timeout_seconds = chooser.startup_modal_timeout_seconds
local startup_modal = chooser.startup_modal
local codex_update_complete = chooser.codex_update_complete
local capture_update_evidence = chooser.capture_update_evidence

local function launch_agent(kind, requested_name, cwd, model, parent, task, relaunch_identity, fresh_trusted_cwd, profile)
  local candidates = kind and { kind } or configured_agent_order()
  kind = kind or candidates[1]
  if profile and (kind ~= "codex" or not remuda._butler_codex_config_ok()) then
    error("this core cannot pass a sandbox profile to Codex (`_codex_tui` lacks -c KEY=VALUE); refusing to launch without it.\nNext: remuda upgrade, then retry", 0)
  end
  -- Every launch and relaunch passes here: the profile is checked again, and `full`
  -- needs a person at a terminal on a first launch, or that earlier grant on a relaunch.
  if profile then
    profile = sandbox_lib.normalize(kind, profile.sandbox, profile.writable, config.realpath,
      config.protected_dirs and config.protected_dirs())
    bus.sandbox_granted = bus.sandbox_granted or {}
    if profile and profile.sandbox == "full" then
      local granted = relaunch_identity and bus.sandbox_granted[requested_name or kind]
      if not granted and (relaunch_identity or sandbox_lib.caller_is_agent()) then
        sandbox_lib.refuse_full(sandbox_lib.owner_command("remuda butler launch " .. tostring(kind) .. " " .. tostring(requested_name or "NAME"), profile))
      end
      bus.sandbox_granted[requested_name or kind] = true
    end
  end
  if kind == "claude" and (not model or model == "") then
    local config = remuda._butler_compaction_config or {}
    model = remuda._butler_claude_default_model
      or os.getenv("REMUDA_BUTLER_CLAUDE_DEFAULT_MODEL") or config.claude_default_model or "opus"
  end
  local name = valid_child_name(requested_name or kind or "agent", "agent name")
  if cwd ~= nil and (type(cwd) ~= "string" or cwd:find("%c")) then
    error("cwd must be a string without control characters", 0)
  end
  if bus.agents[name] then
    error("alias " .. name .. " is live as " .. tostring(bus.agents[name].id) .. "; pick another alias", 0)
  end
  local parent_identity = parent and bus.agents[parent]
  local identity = relaunch_identity and (bus.identity_ids[relaunch_identity] or bus.identities[name])
    or register_identity(name, kind, parent_identity and parent_identity.id or "")
  if relaunch_identity then
    identity.kind, identity.leader_id, identity.state = kind, parent_identity and parent_identity.id or "", "running"
    identity.ended_at, identity.reason = nil, nil
    identity_record(identity)
  end
  local topic_trust_path = fresh_trusted_cwd == true
  local auto_trust = topic_trust_path
  if not cwd and data_home then
    local sessions_root = data_home .. "/remuda/butler/sessions"
    cwd = sessions_root .. "/" .. name
    local created_now = create_fresh_directory(cwd)
    if created_now then
      bus.trusted_launch_dirs = bus.trusted_launch_dirs or {}
      bus.trusted_launch_dirs[cwd] = true
    end
    if not created_now then remuda.mkdir(cwd) end
    auto_trust = created_now and directory_is_under(sessions_root, data_home)
      and directory_is_under(cwd, sessions_root)
  end
  local launch_cwd = cwd or "."
  if cwd and parent and auto_trust then write_agent_guidance(cwd, team_member_guidance(parent)) end
  local token = next_token(name)
  local telemetry_by_kind = {}
  local agent_telemetry = setup_telemetry(kind, { name = name, model = model })
  telemetry_by_kind[kind] = agent_telemetry
  local choose_opts = {
    name = name, cwd = launch_cwd, auto_trust = auto_trust,
    trust_path_gate = topic_trust_path,
    spec = function(candidate_kind)
      local telemetry = telemetry_by_kind[candidate_kind]
        or setup_telemetry(candidate_kind, { name = name, model = model })
      telemetry_by_kind[candidate_kind] = telemetry
      return { name = name, token = token, model = model, cwd = launch_cwd,
        sandbox = profile and profile.sandbox, writable = profile and profile.writable,
        settings_path = telemetry.settings_path, telemetry = telemetry,
        system_prompt = parent and team_member_prompt(parent) or nil }
    end,
    env = function(candidate_kind)
      return { REMUDA_BUTLER_SESSION_NAME = name, REMUDA_BUTLER_AGENT_ID = identity.id,
        REMUDA_BUTLER_AGENT_ALIAS = name,
        REMUDA_BUTLER_LEADER_ID = parent_identity and parent_identity.id or "",
        REMUDA_BUTLER_AGENT_KIND = candidate_kind,
        CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1" }
    end,
  }
  local function finish(actual, selected_kind, attempts)
  if not actual then
    if bus.trusted_launch_dirs then bus.trusted_launch_dirs[launch_cwd] = nil end
    local message = table.concat(launch_failure_lines(attempts), "\n")
    bus.launch_failures = bus.launch_failures or {}
    bus.launch_failures[name] = { attempts = attempts, error = message }
    -- The private trace keeps the internal reason and detail (one entry, one
    -- line); the user-facing message above never shows them.
    local traced = {}
    for _, a in ipairs(attempts or {}) do
      traced[#traced + 1] = tostring(a.kind) .. ": " .. tostring(a.reason) .. " (" .. tostring(a.detail or "") .. ")"
    end
    _butler_session_trace("launch_failed", name .. ": " .. table.concat(traced, "; "):gsub("%c+", " "))
    return message
  end
  kind = selected_kind
  agent_telemetry = telemetry_by_kind[kind]
  identity.kind = kind
  identity_record(identity)
  local waiting_for_trust, trust_answered = false, false
  for _, attempt in ipairs(attempts or {}) do
    if attempt.session == actual and tostring(attempt.reason):match("^waiting_for_human_trust") then
      waiting_for_trust = true
    end
    if attempt.session == actual and attempt.trust_answered then trust_answered = true end
  end
  bus.tokens[token] = actual
  bus.agents[actual] = {
    kind = kind, token = token, model = model, telemetry = agent_telemetry,
    parent = parent, children = {}, id = identity.id, alias = actual, session_name = actual,
    session_start_marker = remuda._butler_new_ulid(),
    cwd = launch_cwd, task = task, launch_attempts = attempts, trust_allowed = auto_trust,
    sandbox = profile and profile.sandbox, writable = profile and profile.writable,
    trust_reported = waiting_for_trust, trust_answered = trust_answered,
  }
  if parent and bus.agents[parent] then
    local children = bus.agents[parent].children
    children[#children + 1] = actual
  end
  local migrated, migration_error = migrate_legacy_mail(actual, identity.id)
  if not migrated then error("cannot migrate legacy Butler mail: " .. tostring(migration_error), 0) end
  mailbox(identity.id)
  if waiting_for_trust then
    pcall(remuda._butler_send, "butler", parent or "butler",
      "waiting for a human: trust dialog in " .. tostring(launch_cwd or "unknown directory")
        .. ". Next: review the folder and approve it in the member session.")
  end
  -- A failed welcome write must not prevent the agent from starting.
  if not relaunch_identity then
    pcall(queue_message, mail_address(parent or "butler"), mail_address(actual),
      team_member_guidance(parent or "butler") .. sandbox_lib.guidance_line(profile), "Welcome to Butler")
    -- First sight of a new member: nothing to replay or re-show (notice.lua).
    bus.unread_seeded[actual] = "launched"
  end
  if task and task ~= "" then
    -- Keep an immediate mail notice out of the child's first prompt until the
    -- delegated task has been submitted.
    bus.pending_tasks[actual] = true
    bus.first_task_delivery = bus.first_task_delivery or {}
    local delivery = {
      marker = bus.agents[actual] and bus.agents[actual].session_start_marker,
      state = "waiting",
    }
    bus.first_task_delivery[actual] = delivery
    local function same_delivery_record()
      local agent = bus.agents[actual]
      return bus.first_task_delivery[actual] == delivery
        and (agent == nil or agent.session_start_marker == delivery.marker)
    end
    local function same_launch()
      local agent = bus.agents[actual]
      return same_delivery_record() and agent ~= nil
    end
    local function shell_quote(value)
      return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
    end
    local function finish_task(delivered, reason)
      if not same_delivery_record() or delivery.state ~= "waiting" then return end
      delivery.state = delivered and "delivered" or "failed"
      bus.pending_tasks[actual] = nil
      if delivered then return end
      reason = tostring(reason or "task was not delivered")
      _butler_session_trace("first_task_delivery", actual .. " marker=" .. tostring(delivery.marker)
        .. " state=failed reason=" .. reason)
      local command = "remuda butler send " .. shell_quote(actual) .. " " .. shell_quote(task)
      pcall(remuda._butler_send, "butler", parent or "butler", "The initial task for " .. actual
        .. " was not delivered: " .. reason .. ". Resend it with `" .. command .. "`.")
    end
    local function recipient_alive()
      for _, row in ipairs(remuda.ls()) do
        if row.name == actual and row.alive then return true end
      end
      return false
    end
    local function same_live_launch()
      return same_launch() and recipient_alive(), "recipient is gone or launch was replaced"
    end
    local startup = remuda._butler_agent_startup[kind] or {}
    if kind == "codex" then
    local poke, confirm, attempts, settle, deferred = nil, nil, 0, 0, 0
    local update_waiting, waiting_for_update, update_deadline = false, false, 0
    local modal_wait_started, update_timeout_reported, update_version = nil, false, nil
    local function modal_wait_expired()
      modal_wait_started = modal_wait_started or os.time()
      return os.time() - modal_wait_started >= startup_modal_timeout_seconds()
    end
    local update_relaunch_record_ref
    local function update_relaunch_record()
      local agent = bus.agents[actual] or {}
      return {
        kind = kind, name = actual, cwd = agent.cwd, model = agent.model,
        parent = agent.parent, task = task, identity = agent.id,
        profile = sandbox_lib.of(agent),
        update_pressed = false, last_screen = agent.last_screen,
      }
    end
    local function relaunch_after_update()
      if update_relaunch_record_ref and update_relaunch_record_ref.relaunched then
        remuda.cancel(poke)
        return true
      end
      if not startup_action_safe or not startup_action_safe(actual) then return false end
      bus.codex_update_relaunches[actual] = update_relaunch_record()
      update_relaunch_record_ref = bus.codex_update_relaunches[actual]
      update_relaunch_record_ref.version = update_version
      update_relaunch_record_ref.expected_close = true
      if bus.codex_update_state.waiting then bus.codex_update_state.waiting[actual] = nil end
      if bus.codex_update_state.restart_waiting then bus.codex_update_state.restart_waiting[actual] = nil end
      local closed, result = pcall(remuda.close, actual)
      if not closed or result == false then
        bus.codex_update_relaunches[actual] = nil
        update_relaunch_record_ref = nil
        return false
      end
      remuda.cancel(poke)
      return true
    end
    local function finish_update()
      local state = bus.codex_update_state
      state.done, state.claimed, state.done_version, state.owner = true, false, update_version, nil
      state.restart_waiting = state.restart_waiting or {}
      for member in pairs(state.waiting or {}) do state.restart_waiting[member] = true end
      state.waiting = {}
    end
    -- Either timeout means the task never reached the agent: say so to its
    -- leader rather than only in the trace (#29).
    local function give_up(detail)
      remuda.cancel(poke)
      if confirm then remuda.cancel(confirm) end
      if bus.codex_update_state.waiting then bus.codex_update_state.waiting[actual] = nil end
      if bus.codex_update_state.restart_waiting then bus.codex_update_state.restart_waiting[actual] = nil end
      finish_task(false, "its pane never became ready or free to type into" .. tostring(detail or ""))
    end
    local function report_update_timeout(detail)
      if update_timeout_reported then return end
      update_timeout_reported = true
      _butler_session_trace("codex_update_timeout", actual .. detail)
      remuda.cancel(poke)
      finish_task(false, "the Codex update dialog did not clear" .. tostring(detail or ""))
    end
    poke = remuda.schedule({ every = 0.5, run = function()
      local checked, alive = pcall(same_live_launch)
      if not checked or not alive then
        remuda.cancel(poke)
        finish_task(false, "the recipient is gone or launch was replaced")
        return
      end
      if update_relaunch_record_ref and (update_relaunch_record_ref.relaunched or update_relaunch_record_ref.cancelled) then
        remuda.cancel(poke)
        finish_task(false, "the recipient launch was replaced")
        return
      end
      attempts = attempts + 1
      -- A short-lived launcher (or a failed executable) can disappear before
      -- the agent has painted its composer. A deferred poke is best-effort; it
      -- must not leave a throwing callback in the daemon's shared Lua image.
      local captured, screen = pcall(remuda.capture, actual)
      if not captured then
        remuda.cancel(poke)
        finish_task(false, "the recipient is gone")
        return
      end
      local agent = bus.agents[actual]
      if agent then agent.last_screen = capture_update_evidence(actual, screen) end
      if update_relaunch_record_ref then
        update_relaunch_record_ref.last_screen = agent and agent.last_screen or capture_update_evidence(actual, screen)
      end
      if attempts < settle then return end -- let an answered modal repaint
      local modal = startup_modal(startup, screen)
      if modal and modal.trust then
        local trust_state = trust_modal_state(modal, screen)
        local agent = bus.agents[actual]
        if trust_state == "safe" and agent.trust_answered then return end
        if agent.last_trust_screen == screen then agent.trust_ticks = (agent.trust_ticks or 0) + 1
        else agent.last_trust_screen, agent.trust_ticks = screen, 1 end
        if agent.trust_ticks < 2 then return end
        if trust_state == "safe" and agent.trust_allowed and bus.trusted_launch_dirs
            and bus.trusted_launch_dirs[agent.cwd] == true and startup_action_safe
            and startup_action_safe(actual) then
          if not agent.trust_answered then
            local answered = true
            for _, key in ipairs(modal.keys or {}) do
              local ok, result = pcall(remuda.key, actual, key)
              if not ok or result == false then answered = false end
            end
            if answered then
              agent.trust_answered = true
              bus.trusted_launch_dirs[agent.cwd] = nil
            end
          end
        elseif not agent.trust_reported then
          agent.trust_reported = true
          pcall(remuda._butler_send, "butler", parent or "butler",
            "waiting for a human: trust dialog in " .. tostring(agent.cwd or "unknown directory")
              .. ". Next: review the folder and approve it in the member session.")
        end
        return
      end
      if update_waiting and update_relaunch_record_ref and codex_update_complete(screen) then
        update_relaunch_record_ref.update_complete_seen = true
      end
      if update_waiting then
        if not modal and startup.ready and startup.ready(screen) then
          -- The update completed in place. Restart the same alias with the
          -- same identity so the task is submitted only by its fresh pane.
          finish_update()
          if not relaunch_after_update() then
            if modal_wait_expired(screen) then
              bus.codex_update_state.restart_waiting[actual] = true
              report_update_timeout(" update completed while human attached")
            end
          end
          return
        end
        if os.time() >= update_deadline then
          local skip = modal and modal.update and skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            local update_state = bus.codex_update_state
            if update_state.owner == actual then
              update_state.claimed, update_state.owner = false, nil
              update_state.aborted_version = update_version
              update_state.waiting, update_state.restart_waiting = {}, {}
            end
            bus.codex_update_relaunches[actual] = nil
            update_relaunch_record_ref = nil
            update_waiting, settle = false, attempts + 3
            return
          end
          -- Never close a pane while brew may still be replacing Codex.
          report_update_timeout(" still updating")
          return
        end
        return
      end
      local update_state = bus.codex_update_state
      if update_state.done and update_state.waiting and update_state.waiting[actual] then
        update_version, waiting_for_update = update_state.done_version, true
        if relaunch_after_update() then return end
        if modal_wait_expired(screen) then give_up(" update completed while human attached") end
        return
      end
      if update_state.done and update_state.restart_waiting and update_state.restart_waiting[actual] then
        update_version, waiting_for_update = update_state.done_version, true
        if relaunch_after_update() then update_state.restart_waiting[actual] = nil; return end
        if modal_wait_expired(screen) then give_up(" update completed while human attached") end
        return
      end
      if update_state.claimed and update_state.owner ~= actual
          and update_state.waiting and update_state.waiting[actual] then
        waiting_for_update = true
        if update_deadline == 0 then
          update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
        end
        if os.time() >= update_deadline then
          local skip = modal and modal.update and skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            waiting_for_update, settle = false, attempts + 3
            update_state.waiting[actual] = nil
          else
            give_up(" waiting for Codex update")
          end
        end
        return
      end
      local version = modal and modal.update and (codex_update_version(screen) or "unknown") or nil
      if version and version ~= "unknown" then
        if update_state.version and update_state.version ~= version and not update_state.claimed then
          update_state.done, update_state.done_version = false, nil
          update_state.waiting, update_state.restart_waiting = {}, {}
        end
        update_state.version = version
        update_version = version
      end
      if modal then
        _butler_session_trace("startup_modal", actual .. " " .. modal.match)
        if modal.update then
          if update_state.done and update_state.done_version == version
              and update_state.waiting and update_state.waiting[actual] then
            waiting_for_update = true
          end
          if update_state.claimed and update_state.owner ~= actual then
            waiting_for_update = true
            update_state.waiting[actual] = true
            if update_deadline == 0 then
              update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
            end
            if update_state.done and update_state.done_version == version then
              if relaunch_after_update() then return end
              if modal_wait_expired(screen) then give_up(" modal human attached") end
              return
            end
            if os.time() >= update_deadline then
              local skip = skip_option_number(screen)
              if skip and startup_action_safe and startup_action_safe(actual) then
                pcall(remuda.key, actual, skip)
                waiting_for_update, settle = false, attempts + 3
                update_state.waiting[actual] = nil
                return
              end
            end
            if modal_wait_expired(screen) then give_up(" waiting for Codex update") end
            return
          end
          if waiting_for_update and update_state.done and update_state.done_version == version then
            if relaunch_after_update() then return end
          end
          if update_state.aborted_version == version then
            local skip = skip_option_number(screen)
            if skip and startup_action_safe and startup_action_safe(actual) then
              pcall(remuda.key, actual, skip)
              settle = attempts + 3
              return
            end
          elseif update_state.done and update_state.done_version == version then
            local skip = skip_option_number(screen)
            if skip and startup_action_safe and startup_action_safe(actual) then
              pcall(remuda.key, actual, skip)
              settle = attempts + 3
              return
            end
          elseif not update_state.claimed then
            local update = option_number(screen, function(label)
              return label:lower():find("update now", 1, true) ~= nil
            end)
            if update and startup_action_safe and startup_action_safe(actual) then
              update_state.claimed, update_state.owner = true, actual
              update_waiting = true
              update_deadline = os.time() + (tonumber(remuda._butler_codex_update_timeout) or 300)
              update_state.waiting = update_state.waiting or {}
              bus.codex_update_relaunches[actual] = update_relaunch_record()
              update_relaunch_record_ref = bus.codex_update_relaunches[actual]
              update_relaunch_record_ref.version = update_version
              update_relaunch_record_ref.update_pressed = true
              local pressed = pcall(remuda.key, actual, update)
              if pressed then
                return
              end
              update_relaunch_record_ref.update_pressed = false
              bus.codex_update_relaunches[actual] = nil
              update_relaunch_record_ref = nil
              update_state.claimed, update_state.owner = false, nil
            end
          end
          local skip = skip_option_number(screen)
          if skip and startup_action_safe and startup_action_safe(actual) then
            pcall(remuda.key, actual, skip)
            settle = attempts + 3
          else
            if modal_wait_expired(screen) then give_up(" update dialog") end
          end
          return
        end
        if modal_wait_expired(screen) then give_up(" modal"); return end
        if startup_action_safe and not startup_action_safe(actual) then return end
        for _, key in ipairs(modal.keys or {}) do pcall(remuda.key, actual, key) end
        settle = attempts + 3
        return
      end
      if not startup.ready or startup.ready(screen) then
        -- #29: never type the task over a human's line. Waiting is bounded
        -- separately (default 600 ticks = 300s); then the leader is told.
        local empty = remuda._butler_prompt_is_empty(kind, screen)
        if empty ~= "EMPTY" or not remuda._butler_notify_policy(actual) then
          attempts, deferred = attempts - 1, deferred + 1
          if deferred >= (remuda._butler_task_poke_deferrals or 600) then give_up(" deferred") end
          return
        end
        remuda.cancel(poke)
        local typed, result, detail = pcall(remuda.type_text, actual, task)
        local outcome, first = PROMPT_DELIVERY.trace_write(remuda, actual, delivery.marker,
          typed, result, detail)
        delivery.write_outcome = outcome
        if outcome ~= "success" then
          finish_task(false, first ~= "" and first or "the write was refused")
          return
        end

        -- A write succeeding does not mean the agent accepted its Return.
        -- Retry Return while the task sits in the composer; a write that
        -- never appeared is reported only after 15 seconds.
        delivery.write_at = os.time()
        local task_line = task:gsub("^%s+", ""):match("^[^\n]*") or ""
        local checks, seen_in_composer = 0, false
        confirm = remuda.schedule({ every = 0.5, run = function()
          if not same_live_launch() then
            remuda.cancel(confirm)
            finish_task(false, "the recipient is gone")
            return
          end
          checks = checks + 1
          local seen, latest = pcall(remuda.capture, actual)
          if not seen then
            remuda.cancel(confirm)
            finish_task(false, "the recipient is gone")
            return
          end
          local decision, text = remuda._butler_prompt_is_empty(kind, latest)
          local working = false
          if startup.working then
            local checked, result = pcall(startup.working, latest)
            working = not checked or result == true
          end
          local checked, session = pcall(remuda.session, actual)
          local active = working or not checked or not session or session.is_busy == true
          local task_in_composer = #task_line > 0 and (text == task_line
            or (#text > 0 and task_line:sub(1, #text) == text))
          if task_in_composer then seen_in_composer = true end
          if decision == "EMPTY" and (active or seen_in_composer) then
            remuda.cancel(confirm)
            finish_task(true)
            return
          end
          if decision == "EMPTY" and os.time() - delivery.write_at >= 15 then
            remuda.cancel(confirm)
            finish_task(false, "write returned success but the task never appeared")
            return
          end
          -- Give the UI time to consume the first Return before retrying.
          if decision == "NON-EMPTY" and task_in_composer and checks >= 4 and checks % 4 == 0 then
            pcall(remuda.key, actual, "RET")
          end
          if checks >= (remuda._butler_task_poke_deferrals or 600) then
            remuda.cancel(confirm)
            finish_task(false, "it was typed but not submitted")
          end
        end })
        return
      end
      if attempts >= (remuda._butler_task_poke_attempts or 60) then give_up("") end
    end })
    else
    PROMPT_DELIVERY.schedule(remuda, kind, actual, name, parent, task, {
      detect_only = true,
      marker = delivery.marker,
      same_launch = same_live_launch,
      on_write = function(outcome) delivery.write_outcome = outcome end,
      ready = startup.ready,
      modals = startup.modals,
      working = startup.working,
      trust_dialog = function(screen)
        local modal = startup_modal(startup, screen)
        return modal ~= nil and modal.trust ~= nil
      end,
      allowed = function(retrying)
        if retrying then return remuda._butler_task_retry_policy(actual) end
        return remuda._butler_notify_policy(actual)
      end,
      human_active = function() return remuda._butler_human_active(actual) end,
      empty = function(screen)
        return remuda._butler_prompt_is_empty(kind, screen)
      end,
      timeout = remuda._butler_task_poke_deferrals or 600,
      ready_timeout = remuda._butler_task_poke_attempts or 60,
      submit_timeout = remuda._butler_submit_timeout or 300,
      on_done = function(delivered, reason)
        finish_task(delivered, reason)
      end,
    })
    end
  end
  return actual
  end
  local result
  choose(candidates, choose_opts, function(actual, selected_kind, attempts)
    local ok, value = pcall(finish, actual, selected_kind, attempts)
    if ok then result = value
    else
      bus.launch_failures = bus.launch_failures or {}
      bus.launch_failures[name] = { attempts = attempts, error = tostring(value) }
      _butler_session_trace("launch_failed", name .. ": " .. tostring(value))
    end
  end)
  return result or ("launching " .. name)
end

local function make_topic(name, template, kind, parent, task, model, cwd, profile)
  valid_child_name(name, "topic name")
  load_topic_config()
  local root = topic_config.project_home .. "/" .. name
  local created_now = create_fresh_directory(root)
  if not created_now then remuda.mkdir(root) end
  if template and not created_now then
    error("topic directory already exists; templates require a fresh topic name", 0)
  end
  local allowed_trust_path = directory_is_under(root, topic_config.project_home)
  local auto_trust = created_now and not template
    and directory_is_under(root, topic_config.project_home)
    and (kind ~= "claude" or allowed_trust_path)
  -- A non-root --cwd launches elsewhere; a root grant would outlive it unused.
  if auto_trust and (cwd == nil or cwd == root) then
    bus.trusted_launch_dirs = bus.trusted_launch_dirs or {}
    bus.trusted_launch_dirs[root] = true
  end
  local topic = { name = name, root = root }
  function topic.write(relative_path, contents)
    local f = assert(io.open(root .. "/" .. relative_path, "w"))
    f:write(contents)
    f:close()
  end
  function topic.run(argv)
    local ok, why = system.run_in(root, argv)
    if not ok then error(why, 0) end
  end
  if template then
    local setup = topic_config.templates[template]
    assert(setup, "unknown Butler topic template: " .. template)
    assert(type(setup) == "function", "Butler topic template must be a function: " .. template)
    setup(topic)
  end
  if created_now and not template then
    write_agent_guidance(root, team_member_guidance(parent or "butler") .. sandbox_lib.guidance_line(profile))
  end
  return launch_agent(kind, name, cwd or root, model, parent, task, nil,
    auto_trust and (cwd == nil or cwd == root), profile)
end

-- Shell-facing doors into the same deliberately mutable bus.  These are not
-- capability checks: Butler is a workshop, and the `from` name is simply the
-- attribution a human (or an agent using the CLI) chose to leave on a note.
-- Keeping them on `remuda` also makes the post office pleasant to explore from
-- a REPL without having to know this chunk's private locals.
function remuda._butler_launch(kind, name, model, parent, profile)
  if profile and profile.sandbox == "full" and sandbox_lib.caller_is_agent() then
    sandbox_lib.refuse_full(sandbox_lib.owner_command("remuda butler launch " .. tostring(kind) .. " " .. tostring(name or "NAME"), profile))
  end
  return launch_agent(kind, name, nil, model, resolve(parent or "butler"), nil, nil, nil, profile)
end
function remuda._butler_topic_new(name, template, kind, model)
  return make_topic(name, template, kind, "butler", nil, model)
end
function remuda._butler_topic_delegate(name, task, template, kind, parent, model, cwd, profile)
  if profile and profile.sandbox == "full" and sandbox_lib.caller_is_agent() then
    sandbox_lib.refuse_full(sandbox_lib.owner_command("remuda butler topic delegate " .. name .. " --agent codex", profile, cwd) .. " <task...>")
  end
  local requested_parent = parent or "butler"
  local resolved, leader = pcall(resolve, requested_parent)
  if resolved then
    parent = leader
  else
    local session_live = false
    for _, row in ipairs(remuda.ls()) do
      if row.name == requested_parent and row.alive then session_live = true; break end
    end
    if not session_live then error(leader, 0) end
    if type(remuda.expect) ~= "function" then
      error("Butler leader " .. tostring(requested_parent) .. " is still starting.\n"
        .. "Next: wait for the leader to become ready, then retry delegation.", 0)
    end
    local timeout = tonumber(remuda._butler_leader_ready_timeout) or 10
    if timeout <= 0 then timeout = 10 end
    pcall(remuda.expect, requested_parent, {
      { id = "butler-leader-ready", match = function() return bus.agents[requested_parent] ~= nil end },
    }, { timeout = timeout, interval = 0.1 })
    if not bus.agents[requested_parent] then
      error("Butler leader " .. tostring(requested_parent) .. " is still starting; wait before delegating.\n"
        .. "Next: retry the delegation after the leader appears in `remuda butler agents`.", 0)
    end
    parent = requested_parent
  end
  local leader = bus.agents[parent]
  if not leader then error("no Butler leader named " .. tostring(parent), 0) end
  return make_topic(name, template, kind, parent, task, model, cwd, profile)
end

-- Entry points turn requested flags into a checked profile (nil when none).
function remuda._butler_profile(kind, sandbox_mode, writable)
  return sandbox_lib.normalize(kind, sandbox_mode, writable, config.realpath, config.protected_dirs and config.protected_dirs())
end

remuda._butler_launch_impl = { launch_agent = launch_agent }
