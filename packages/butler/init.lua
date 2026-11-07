-- The module owns every hook and schedule. main.lua loads the implementation
-- from the lifecycle start event, where #143 also owns its imperative command
-- and contribution registrations.
if not getmetatable(_G) then
  -- Cores before warmblood-kr/remuda#98 send this entry as a plain chunk.
  return remuda.exec("butler")
end

local host = getmetatable(_G).__index.remuda
local cli_parse = assert(host.cli and host.cli.parse,
  "Butler CLI requires remuda.cli.parse (Remuda core #465 or later); upgrade Remuda")
local system, dialogs, input_originals
-- `main_loading` is the reentry guard; `main_loaded` is the success flag. A
-- failed main must leave the latter false so a corrected activation retries.
local main_loading, main_loaded = false, false
-- 0 not booted; 1 main; 2 bootstrap; 3 butler-start emitted; 4 relay started.
local boot_stage, booted = 0, false
local boot_emit_incomplete, runtime_failed = false, false
local runtime_refusal_only = false
local last_good

local function shallow_copy(value)
  if type(value) ~= "table" then return nil end
  local copy = {}
  for key, item in pairs(value) do copy[key] = item end
  return copy
end

-- Transitive notification/lifecycle helpers published as globals. A failed
-- notice load can leave candidate functions here that close over the old
-- policy owner/journal, so restore every key, including one absent before.
local RUNTIME_HELPERS = {
  "_butler_notify", "_butler_deliver_notices", "_butler_schedule_tick",
  "_butler_inbox_message", "_butler_send", "_butler_notice_compacted",
  "_butler_notice_open_stuck", "_butler_inbox_delivery", "_butler_dialog_tick",
  "_butler_reconcile", "_butler_reconcile_retry", "_butler_done_tick",
  "_butler_compaction_tick", "_butler_session_exited", "_butler_compaction_submit",
  "_butler_cancel_active_choosers",
  -- Dynamic deps read by restored notice closures. Durable bus/mail/journal
  -- modules stay live and are deliberately absent.
  "_butler_notify_policy", "_butler_composer_decision", "_butler_approved_text_policy",
  "_butler_task_retry_policy", "_butler_human_active", "_butler_prompt_is_empty",
  "_butler_notice_after", "_butler_notice_clock", "_butler_notice_human_idle",
  "_butler_schedule_env", "_butler_telemetry_for", "_butler_agent_startup",
}

local function restore_entries(target, snapshot)
  if type(target) ~= "table" or type(snapshot) ~= "table" then return end
  for key in pairs(target) do
    if snapshot[key] == nil then target[key] = nil end
  end
  for key, value in pairs(snapshot) do target[key] = value end
end

local function runtime_graph_complete()
  return main_loaded and type(host.butler) == "table"
    and type(host.butler.send_policy) == "table"
    and type(host.butler.native_dispatch) == "table"
    and type(host.butler.matrix) == "table"
    and type(host._butler_notice) == "table"
end

-- Capture only runtime exports and resource intent. The durable bus, mail,
-- journal, pending and uncertain facts are deliberately excluded: a reload
-- must not rewind delivery facts to an older snapshot.
local function capture_runtime()
  if not runtime_graph_complete() then return last_good end
  local butler, matrix = host.butler, host.butler.matrix
  local relay = matrix.relay
  local helpers = {}
  for _, key in ipairs(RUNTIME_HELPERS) do helpers[key] = { value = host[key] } end
  last_good = {
    butler = butler,
    butler_entries = shallow_copy(butler),
    matrix = matrix,
    matrix_entries = shallow_copy(matrix),
    send_policy = butler.send_policy,
    send_policy_entries = shallow_copy(butler.send_policy),
    native_dispatch = butler.native_dispatch,
    native_dispatch_entries = shallow_copy(butler.native_dispatch),
    notice = host._butler_notice,
    notice_entries = shallow_copy(host._butler_notice),
    notice_config = host._butler_notice_config,
    dialogs = dialogs,
    input_originals = input_originals,
    helpers = helpers,
    -- Resource intent, not the handle: a pre-stop stopped instance must not be
    -- restored as if it were still running.
    relay_running = type(relay) == "table" and relay.instance ~= nil or false,
    relay_config = host._butler_matrix_config,
  }
  return last_good
end

local function restore_runtime()
  local snapshot = last_good
  if not snapshot then return end
  host.butler = snapshot.butler
  restore_entries(host.butler, snapshot.butler_entries)
  host.butler.matrix = snapshot.matrix
  restore_entries(host.butler.matrix, snapshot.matrix_entries)
  host.butler.send_policy = snapshot.send_policy
  restore_entries(host.butler.send_policy, snapshot.send_policy_entries)
  host.butler.native_dispatch = snapshot.native_dispatch
  restore_entries(host.butler.native_dispatch, snapshot.native_dispatch_entries)
  host._butler_notice = snapshot.notice
  restore_entries(host._butler_notice, snapshot.notice_entries)
  host._butler_notice_config = snapshot.notice_config
  host._butler_matrix_config = snapshot.relay_config
  dialogs, input_originals = snapshot.dialogs, snapshot.input_originals
  host._butler_dialog_originals = snapshot.input_originals
  for _, key in ipairs(RUNTIME_HELPERS) do
    local saved = snapshot.helpers[key]
    host[key] = saved and saved.value or nil
  end
end

-- Read-only identity and ownership checks. They never reopen the consumed
-- factory or rebind a policy; an unverifiable graph fails closed.
local function validate_runtime()
  local butler = host.butler
  if type(butler) ~= "table" then
    error("Butler runtime graph is unavailable; reload Butler when idle", 0)
  end
  local policy, notice = butler.send_policy, host._butler_notice
  if type(policy) ~= "table" then
    error("Butler notification policy is unavailable; reload Butler when idle", 0)
  end
  -- A missing, throwing or partial checker is unverifiable, not ready.
  if type(policy.readiness) ~= "function" then
    error("Butler notification policy has no readiness check; reload Butler when idle", 0)
  end
  local checked, ready = pcall(policy.readiness)
  if not checked or type(ready) ~= "table" or ready.bound ~= true
      or ready.transport_acquired ~= true or ready.owner ~= notice then
    error("Butler notification policy is not ready; reload Butler when idle", 0)
  end
  if type(notice) ~= "table" or notice._policy_bound ~= true then
    error("Butler notice owner is not policy-bound; reload Butler when idle", 0)
  end
  if type(butler.native_dispatch) ~= "table"
      or type(butler.native_dispatch.admit) ~= "function" then
    error("Butler native dispatch is unavailable; reload Butler when idle", 0)
  end
  if type(butler.matrix) ~= "table" then
    error("Butler Matrix exports are unavailable; reload Butler when idle", 0)
  end
  local config = host._butler_notice_config
  if type(config) == "table" and config.bus ~= nil and host._butler_bus ~= nil
      and config.bus ~= host._butler_bus then
    error("Butler notice bus identity changed; reload Butler when idle", 0)
  end
end

-- The exact compiled Matrix request-client pair from this activation. A failed
-- candidate may replace the shared butler.matrix table, so resume must use
-- this pair, never a late lookup. A half-pair is a hard degraded state.
local request_client_api, request_client_incomplete

local function capture_request_client()
  local matrix = host.butler and host.butler.matrix
  local retire = matrix and matrix.request_retire
  local resume = matrix and matrix.request_resume
  local request = matrix and matrix.request
  local request_json = matrix and matrix.request_json
  if type(retire) == "function" and type(resume) == "function"
      and type(request) == "function" and type(request_json) == "function" then
    request_client_api = { retire = retire, resume = resume,
      request = request, request_json = request_json }
    request_client_incomplete = nil
    host._butler_request_retire_failed = nil
    host._butler_request_retire_blocked = nil
    return true
  end
  request_client_api = nil
  request_client_incomplete = (type(retire) == "function" or type(resume) == "function"
    or type(request) == "function" or type(request_json) == "function")
    and "request lifecycle API is incomplete" or nil
  return false
end

local function request_client_present()
  local matrix = host.butler and host.butler.matrix
  return type(matrix) == "table" and type(matrix.request) == "function"
end

local function load_main()
  if main_loaded then return end
  if main_loading then return end
  main_loading = true
  -- The refusal signal is a per-load outcome, never a sticky bypass: clear it
  -- before this load and let main.lua set it only for its own guard decision.
  host._butler_runtime_refusal = nil
  runtime_refusal_only = false
  local ok, err = pcall(function()
    host.exec("butler/system")
    system = assert(host._butler_system)
    host.exec("butler/main")
    dialogs = host.butler and host.butler.dialogs
    input_originals = host._butler_dialog_originals
  end)
  main_loading = false
  if not ok then error(err, 0) end
  -- guard.boot refusal and the test-mode early return publish a commands-only
  -- graph. Keep its command/help/refusal contract, but never call it an active
  -- runtime or validate it as one.
  if host._butler_standby or host._butler_runtime_refusal then
    runtime_refusal_only = true
    main_loaded = true
    return
  end
  -- A cold successful load must satisfy the same graph/ownership readiness
  -- contract as a resume; an unverifiable graph is not loaded.
  local valid, validation_err = pcall(validate_runtime)
  if not valid then error(validation_err, 0) end
  runtime_refusal_only = false
  main_loaded = true
  capture_request_client()
end

-- A stopped handle does not prove the old writer is gone. A future resource
-- registry/owner epoch may expose a read-only proof; until then the answer is
-- no and resume must not start a second writer.
local function relay_owner_fenced()
  local matrix = host.butler and host.butler.matrix
  local relay = matrix and matrix.relay
  if type(relay) ~= "table" or type(relay.owner_proven) ~= "function" then return false end
  local ok, proven = pcall(relay.owner_proven)
  return ok and proven == true
end

local function report_relay(outcome, reason)
  local diagnostics = host._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "relay", outcome, reason, nil)
  end
end

-- Final typed API: {ok, retired, queued_settled, cancel_failed, detail}.
-- `cancel_failed` is a required dense array of unique roles, not a boolean:
-- an empty array is clean; any role is a named, observable cancellation
-- failure. pcall alone is not success.
local REQUEST_CANCEL_ROLES = { refill = true, watchdog = true }

local function request_cancel_roles(value)
  if type(value) ~= "table" then return false, "cancel_failed is not an array" end
  local seen, count = {}, 0
  for key, role in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, "cancel_failed is not a dense array"
    end
    if type(role) ~= "string" or not REQUEST_CANCEL_ROLES[role] then
      return false, "unknown cancel role"
    end
    if seen[role] then return false, "duplicate cancel role" end
    seen[role] = true
    count = count + 1
  end
  if count ~= #value then return false, "cancel_failed is sparse" end
  for index = 1, count do
    if value[index] == nil then return false, "cancel_failed is sparse" end
  end
  return true, count
end

local function request_result_ok(result, phase)
  if type(result) ~= "table" then return false, "request result missing" end
  if result.ok ~= true then return false, "request operation failed" end
  local clean, roles = request_cancel_roles(result.cancel_failed)
  if not clean then return false, "request cancellation state invalid" end
  if roles ~= 0 then return false, "request timers not confirmed gone" end
  if type(result.queued_settled) ~= "number" or result.queued_settled < 0
      or result.queued_settled % 1 ~= 0 then
    return false, "request queue count invalid"
  end
  if result.detail ~= nil and (type(result.detail) ~= "string" or #result.detail > 512) then
    return false, "request detail invalid"
  end
  if phase == "retire" and result.retired ~= true then
    return false, "request retire did not commit"
  end
  if phase == "resume" and result.retired ~= false then
    return false, "request resume stayed retired"
  end
  return true
end

-- Bounded constants only: never echo a plugin result/detail or an exception
-- into the diagnostic/doctor surface.
local function request_fail(phase)
  local why = phase == "retire" and "request retire failed" or "request resume failed"
  host._butler_request_retire_failed = why
  host._butler_request_retire_blocked = true
  report_relay("degraded",
    phase == "retire" and "request_retire_failed" or "request_resume_failed")
  return false, why
end

local function request_pair_coherent()
  if not request_client_api then return true end
  local matrix = host.butler and host.butler.matrix
  if type(matrix) ~= "table" then return false, "request matrix missing" end
  if matrix.request ~= request_client_api.request
      or matrix.request_json ~= request_client_api.request_json
      or matrix.request_retire ~= request_client_api.retire
      or matrix.request_resume ~= request_client_api.resume then
    return false, "request pair changed"
  end
  return true
end

local function request_retire()
  if not request_client_api then
    if request_client_incomplete or request_client_present() then
      return request_fail("retire")
    end
    return true
  end
  local called, result = pcall(request_client_api.retire)
  if not called then return request_fail("retire") end
  local ok, why = request_result_ok(result, "retire")
  if not ok then
    host._butler_request_retire_failed = why or "request retire failed"
    host._butler_request_retire_blocked = true
    report_relay("degraded", "request_retire_failed")
    return false, host._butler_request_retire_failed
  end
  host._butler_request_retire_failed = nil
  host._butler_request_retire_blocked = nil
  return true
end

local function request_resume()
  if not request_client_api then
    if request_client_incomplete or request_client_present() then
      return request_fail("resume")
    end
    return true
  end
  if host._butler_request_retire_blocked then
    report_relay("degraded", "request_resume_failed")
    return false, "request generation teardown incomplete"
  end
  local called, result = pcall(request_client_api.resume)
  if not called then return request_fail("resume") end
  local ok, why = request_result_ok(result, "resume")
  if not ok then
    host._butler_request_retire_failed = why or "request resume failed"
    host._butler_request_retire_blocked = true
    report_relay("degraded", "request_resume_failed")
    return false, host._butler_request_retire_failed
  end
  local coherent, coherence_why = request_pair_coherent()
  if not coherent then
    host._butler_request_retire_failed = coherence_why or "request pair changed"
    host._butler_request_retire_blocked = true
    report_relay("degraded", "request_resume_failed")
    return false, host._butler_request_retire_failed
  end
  host._butler_request_retire_failed = nil
  host._butler_request_retire_blocked = nil
  return true
end

local function start_matrix_relay()
  local matrix = host.butler and host.butler.matrix
  local relay = matrix and matrix.relay
  -- A request generation that could not confirm both timer cancellations is
  -- not a safe base for a new relay. Keep the admission barrier explicit.
  if host._butler_request_retire_blocked then
    host._butler_relay_restart_blocked = true
    report_relay("degraded", "request_generation_incomplete")
    return
  end
  -- The marker is an admission barrier, not just a diagnostic: a relay that
  -- was running when the previous activation stopped may have a hidden writer.
  -- Only a positive owner proof may start again; a clean cold start has no
  -- marker and is unaffected.
  if host._butler_relay_owner_unverified then
    if relay_owner_fenced() then
      host._butler_relay_owner_unverified = nil
      host._butler_relay_restart_blocked = nil
      report_relay("ok", "owner_proven")
    else
      host._butler_relay_restart_blocked = true
      report_relay("degraded", "owner_unknown")
      return
    end
  end
  if host._butler_matrix_config and relay and not relay.instance and not host._butler_skip_relay
    and not host._butler_standby
    and type(host.http) == "table" and type(host.http.request) == "function" then
    relay.start(host._butler_matrix_config)
  end
end

local function boot()
  if runtime_failed then
    error("Butler runtime recovery failed; reload Butler when idle", 0)
  end
  if boot_stage >= 4 then return end
  -- A commands-only standby loaded only the refusal verbs. Explicit start
  -- must re-ask the home locks inside this lifecycle transaction.
  if host._butler_standby then
    main_loaded = false
    main_loading = false
  end
  load_main()
  if runtime_refusal_only or host._butler_standby then
    -- A refusal/test-mode catalog is commands-only: never run bootstrap,
    -- emit a start notification or start a resource from it.
    main_loaded = false
    local guard = host.butler and host.butler.guard
    local reason = guard and type(guard.refusal) == "function"
      and guard.refusal(host._butler_standby or "home already owned")
      or "Butler is not the active owner; commands only"
    error(reason, 0)
  end
  if boot_stage < 1 then boot_stage = 1 end
  if boot_stage < 2 then
    if host._butler_bootstrap and host._butler_test_mode ~= "lifecycle" then host._butler_bootstrap() end
    boot_stage = 2
  end
  if boot_stage < 3 then
    -- Partial hook emission is not idempotent: after a failure, only a fresh
    -- activation may emit again. This activation fails closed.
    if boot_emit_incomplete then
      error("Butler startup notification is incomplete; reload Butler when idle", 0)
    end
    local emitted, emit_err = pcall(host.emit, "butler-start")
    if not emitted then
      boot_emit_incomplete = true
      error(emit_err, 0)
    end
    boot_stage = 3
  end
  if boot_stage < 4 then
    start_matrix_relay()
    boot_stage = 4
  end
  booted = true
end

-- Retire only the process handle recorded by the legacy Matrix relay. The
-- handle is scoped to this Remuda image; require its old script location to
-- match the exact path that the Butler module used under its install dir.
local function stop_legacy_matrix_relay()
  -- The pre-extraction Butler stored its relay in this host slot.
  -- It has no script-path argv to verify; the daemon-owned handle and current
  -- process membership are the identity boundary for this one-time upgrade stop.
  local old_id = host._butler_relay
  if old_id ~= nil then
    if type(host.processes) == "function" and type(host.kill) == "function" then
      for _, running_id in ipairs(host.processes()) do
        if running_id == old_id then
          pcall(host.kill, old_id)
          break
        end
      end
    end
    host._butler_relay = nil
  end

  local id = host._butler_matrix_relay
  if id == nil or type(host.processes) ~= "function" or type(host.kill) ~= "function" then return end
  local data_home = os.getenv("XDG_DATA_HOME")
  if not data_home or data_home == "" then
    local ok, home = pcall(system.home)
    if not ok then return end
    data_home = home .. "/.local/share"
  end
  local mod_dir = data_home .. "/remuda/mods/butler"
  local expected_script = mod_dir .. "/packages/butler/matrix_relay.py"
  local script = host._butler_matrix_relay_script_path or expected_script
  if script ~= expected_script or not script:match("^" .. mod_dir:gsub("([^%w])", "%%%1") .. "/") then return end
  for _, running_id in ipairs(host.processes()) do
    if running_id == id then
      pcall(host.kill, id)
      break
    end
  end
  host._butler_matrix_relay = nil
  host._butler_matrix_relay_script_path = nil
end

-- Core instantiates declared schedules only for an accepted activation. A
-- discarded exec candidate must neither create nor cancel a fallback timer.
local commands_only = false
local function cancel_start_fallback()
  -- Declared callbacks receive state, not their schedule handle. Find this
  -- activation's timer in the registry; older cores do not record an owner.
  for handle, schedule in pairs(host.schedules) do
    if schedule.name == "butler-start-fallback"
      and (schedule.owner == nil or schedule.owner == "butler") then
      host.cancel(handle)
    end
  end
  -- Retire the imperative timer left by a Butler version predating this fix.
  if host._butler_start_fallback then host.cancel(host._butler_start_fallback) end
  host._butler_start_fallback = nil
end

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return { compaction_enabled = false, active_choosers = {}, next_chooser_id = 0 } end,
  source_refresh_ready = function(state)
    if host._module_resume_supported ~= true then return "core lacks lifecycle resume; upgrade Remuda before source refresh" end
    if state.compaction_fleet_active then return "compaction is active" end
    for _, member in pairs(state.compaction_members or {}) do
      if member.compaction_in_progress or member.dialog_operation or member.restore_pending_attempt_active then
        return "compaction or model restoration is active"
      end
    end
    if dialogs and dialogs.source_refresh_busy and dialogs.source_refresh_busy() then return "input recovery is active" end
    if next(state.active_choosers or {}) then return "a launch chooser is active" end
    local controls = host.butler and host.butler.startup_controls
    if controls and type(controls.active_count) == "function" and controls.active_count() > 0 then
      return "a Codex startup control is active"
    end
    if host._butler_launching or host._butler_start_pending then return "Butler is starting" end
    local bus = host._butler_bus or {}
    -- A reload replaces the Lua image. Do not drop a native publication
    -- watcher or an in-flight native dispatch mid-delivery; the message is
    -- already durable mail, so waiting one refresh costs nothing.
    if next(bus.notice_native_watchers or {}) then
      return "native publication is waiting"
    end
    if next(bus.notice_native_dispatching or {}) then
      return "native delivery is in flight"
    end
    if next(bus.pending_tasks or {}) then return "mail delivery is pending" end
    for _, dialog in pairs(bus.dialog_states or {}) do
      if dialog.blocked or dialog.id or dialog.reporting then return "a managed dialog is active" end
    end
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay and matrix.relay.instance then return "Matrix relay is active" end
    local approval = host.butler and host.butler.approval
    if approval and type(approval.source_refresh_busy) == "function" and approval.source_refresh_busy() then
      return "an approval is pending"
    end
  end,
  -- Registers the CLI verbs only; `start` boots. Cores without the hook ignore this field.
  commands = function(state)
    commands_only = true
    host._butler_state = state
    if host._butler_standby then
      -- A refused start rolls back. Rediscovery preserves its refusal even
      -- if the owner has since gone; only an explicit start may take over.
      -- A refusal-only graph may not publish the standby helper; the command
      -- catalog and refusal verb still have to load.
      local guard = host.butler and host.butler.guard
      if guard and type(guard.standby) == "function" then
        guard.standby(host._butler_standby, host._butler_paths)
      end
    else
      load_main()
    end
  end,
  start = function(state)
    host._butler_state = state
    boot()
    capture_request_client()
    stop_legacy_matrix_relay()
  end,
  -- Rollback restores this activation's registrations. Reinstall only resources
  -- stop() unwrapped; cached start/main closures must not reread a broken helper.
  resume = function(state)
    local ok, err = pcall(function()
      host._butler_state = state
      restore_runtime()
      if dialogs then
        host.butler.dialogs = dialogs
        host._butler_dialog_originals = input_originals
        dialogs.install()
      end
      -- Validate the restored graph before activating the captured client:
      -- an invalid bus/owner must not cause a request_resume side effect.
      validate_runtime()
      local resumed, resume_why = request_resume()
      if not resumed then
        error("Matrix request resume failed: " .. tostring(resume_why), 0)
      end
      local coherent, coherence_why = request_pair_coherent()
      if not coherent then
        error("Matrix request pair is not coherent: " .. tostring(coherence_why), 0)
      end
      -- A stopped handle is not proof the old writer is gone. Never restart a
      -- stopped snapshot without a positive owner/resource fence; the shared
      -- start path makes that an admission barrier and reports owner_unknown.
      if boot_stage >= 4 and last_good and last_good.relay_running then
        local matrix = host.butler and host.butler.matrix
        local relay = matrix and matrix.relay
        if relay and not relay.instance then
          host._butler_relay_owner_unverified = true
          start_matrix_relay()
        end
      end
    end)
    if not ok then
      -- Never leave raw input exposed if the old activation cannot resume.
      -- Keep the originals for a later explicit, corrected activation.
      runtime_failed = true
      booted, boot_stage = false, 0
      local matrix = host.butler and host.butler.matrix
      if matrix and matrix.relay and type(matrix.relay.stop) == "function" then
        pcall(matrix.relay.stop)
      end
      host._butler_dialog_originals = input_originals
      local function refuse() error("Butler input gate recovery failed; reload Butler when idle", 0) end
      host.key, host.type_text = refuse, refuse
      if input_originals and input_originals.send then host.send = refuse end
      error(err, 0)
    end
  end,
  stop = function(state)
    -- Capture before stop unwraps resources: identities, nested entries and
    -- whether the relay was running, but never the active handle itself.
    capture_runtime()
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay and matrix.relay.instance then
      -- A successful candidate may start a new relay while a hidden writer
      -- survives the stop. Without an owner registry this remains unverified;
      -- it is reported, never claimed healthy.
      host._butler_relay_owner_unverified = true
    end
    if dialogs then dialogs.stop() end
    local controls = host.butler and host.butler.startup_controls
    if controls and type(controls.stop_all) == "function" then pcall(controls.stop_all) end
    if host._butler_cancel_active_choosers then host._butler_cancel_active_choosers(state) end
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay and type(matrix.relay.stop) == "function" then
      local stopped, stop_err = pcall(matrix.relay.stop)
      if not stopped then
        -- A relay stop that threw is not a verified stop; keep it visible.
        report_relay("degraded", "relay_stop_failed")
      end
    end
    -- Stop the relay first, then retire the captured request generation: queued
    -- pre-dispatch work settles once with the typed queue_retired/not_sent
    -- result, dispatched requests stay untouched and nothing is replayed.
    local retired, retire_why = request_retire()
    host._butler_request_retire_failed = retired and nil or retire_why
    stop_legacy_matrix_relay()
    cancel_start_fallback()
  end,
  hooks = {
    { event = "butler-start", id = "boot", run = load_main },
    { event = "butler/deliver", id = "inbox", depth = 0,
      run = function(_, message)
        local ok, result = pcall(host._butler_inbox_delivery, message)
        if not ok then return { __butler_delivery_hook_error = tostring(result) } end
        return result
      end },
    { event = "session_exited", id = "identity", depth = -50,
      run = function(_, name, info)
        if host._butler_session_exited then return host._butler_session_exited(name, info) end
      end },
    { event = "butler-compaction-submit", id = "submit",
      run = function()
        if host._butler_compaction_submit then return host._butler_compaction_submit() end
      end },
  },
  schedules = {
    -- Commands-only loads boot nothing. A core that ignores `start` still
    -- boots an accepted exec/reload once through this compatibility timer.
    { name = "butler-start-fallback", every = 0.05, run = function()
      cancel_start_fallback()
      if not booted and not commands_only then
        io.stderr:write("butler: this remuda core ignores the lifecycle start hook"
          .. " (warmblood-kr/remuda#104); booted by fallback -- run `remuda upgrade`\n")
        boot()
      end
    end },
    { name = "butler-notices", every = 1, run = function()
      if booted and host._butler_deliver_notices then host._butler_deliver_notices() end
    end },
    { name = "butler-dialogs", every = 1, run = function()
      if booted and host._butler_dialog_tick then host._butler_dialog_tick() end
    end },
    { name = "butler-reconcile", every = host._butler_reconcile_interval or 2, run = function()
      if booted and host._butler_reconcile and host._butler_reconcile_retry
          and host._butler_reconcile_retry.remaining_ms() <= 0 then
        host._butler_reconcile()
      end
    end },
    { name = "butler-done-autoclose", every = 30, run = function()
      if booted and host._butler_done_tick then host._butler_done_tick() end
    end },
    { name = "butler-schedule", every = 30, run = function()
      if booted and host._butler_schedule_tick then host._butler_schedule_tick() end
    end },
    { name = "butler-compaction", every = host._butler_compaction_interval or 45, run = function()
      local state = host._butler_state or host._butler_compaction_state
      if booted and state and state.compaction_enabled and host._butler_compaction_tick then host._butler_compaction_tick() end
    end },
  },
  contributes = {
    ["butler.agent"] = {
      { id = "claude", order = 10, executable = "claude", requires = "claude",
        argv = function(_, spec) return host._butler_agent_builders.claude(spec) end,
        -- Launch readiness only says the session reached a Claude composer, so it also accepts the joined
        -- dim 'Try "' hint (ConPTY). It is not permission to type: agents/claudecode.lua startup.ready keeps
        -- the empty-suffix match, and the unchanged composer gate (notice.lua) decides when to type.
        ready = function(_, screen)
          if screen:find("─\n❯", 1, true) then return true end
          for line in (screen .. "\n"):gmatch("(.-)\n") do
            local offset = 1
            while line:sub(offset, offset + 2) == "─" do offset = offset + 3 end
            if offset > 1 and line:sub(offset, offset + 2) == "❯" then
              local suffix = line:sub(offset + 3):gsub("^[ \t\194\160]+", "")
              if suffix == "" or suffix:sub(1, 5) == 'Try "' then return true end
            end
          end
          return false
        end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Invalid API key", "Please run /login", "Select login method" },
        dialogs = function() return host._butler_agent_startup.claude.modals end },
      { id = "codex", order = 20, executable = "codex", requires = "codex",
        argv = function(_, spec) return host._butler_agent_builders.codex(spec) end,
        ready = function(_, screen) return screen:find("Ask Codex", 1, true) ~= nil end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Sign in to continue", "Not authenticated" },
        dialogs = function() return host._butler_agent_startup.codex.modals end },
      { id = "opencode", order = 25, executable = "opencode", requires = "opencode", automatic = false,
        argv = function(_, spec) return host._butler_agent_builders.opencode(spec) end,
        -- The agent module owns the composer grammar. Delegate at call time so
        -- this declaration cannot drift from the startup/notice parser.
        ready = function(_, screen)
          local grammar = host._butler_agent_startup and host._butler_agent_startup.opencode
          return type(grammar) == "table" and type(grammar.ready) == "function"
            and grammar.ready(screen) == true
        end,
        working = function(_, screen)
          local grammar = host._butler_agent_startup and host._butler_agent_startup.opencode
          return type(grammar) == "table" and type(grammar.working) == "function"
            and grammar.working(screen) == true
        end,
        login = { "Authentication required", "Not authenticated", "Please log in" } },
      { id = "monocle", order = 30, executable = "monocle", requires = "monocle", automatic = false,
        argv = function(_, spec) return host._butler_agent_builders.monocle(spec) end,
        ready = function(_, screen) return host._butler_agent_startup.monocle.ready(screen) end,
        working = function(_, screen) return host._butler_agent_startup.monocle.working(screen) end,
        login = { "monocle login" } },
    },
    ["butler.guidance"] = {
      { id = "header", order = 10,
        agents_md = function(_, ctx)
          return [[# Butler team member

You are a Butler team member. Your leader is ]] .. ctx.parent .. [[. Work on the
task sent to this terminal. Your Butler identity is already in
`REMUDA_BUTLER_AGENT_ID`, and your leader is in `REMUDA_BUTLER_LEADER_ID`.
Start by running `remuda butler inbox` to read your welcome message.

## Milestones

At the start of a task, set a self-targeted milestone reminder:

```
remuda butler schedule add milestone "<M> <H> * * *" \
  "Milestone: re-check the task and its definition of done, re-check the approach, align the team; set the next --once reminder if the work continues; report only new evidence, a decision, a change or a blocker" --once
```

Use 20-30 minutes for fast work and one hour for normal work. When it fires,
remind yourself of the task and its definition of done, re-check whether the
current approach is still the shortest safe path, confirm your members are
aligned, and set the next reminder if the work continues. A finished `--once`
item stays listed until removed and its name must be unique, so remove it with
`remuda butler schedule rm milestone` before adding the next slot, or use a
different name. The reminder is for that self-check, not a duty to report to a
human every time; if a risky path goes beyond your remit, use your judgment and
escalate to your leader or the team. Report to your leader or the owner when you
have new evidence, a decision, a change, or a specific blocker; never send
repetitive empty reports.

## Memory

Keep useful notes under `docs/`. Put stable, reusable facts and decisions in
`docs/concepts/`; put dated events, progress, and context that may expire in
`docs/journal/YYYY-MM-DD.md`. Keep source files concise: each concepts file and
daily note must stay at or below 5,000 characters. Use at most 50 concepts
files; when full, delete low-value material, consolidate or compress existing
notes, or decline lower-priority material.

Summarize daily notes older than two ISO weeks into
`docs/journal/YYYY-Www.md` (use the correct ISO week year and week number), then
gzip the summarized daily files under `docs/journal/archive/`. These are
manual file practices; do not assume a process performs them automatically.

]]
        end,
        prompt = function()
          return "You are a Butler team member. Start by running `remuda butler inbox` to read "
            .. "your welcome message, then read AGENTS.md in your working directory. "
            .. "Set a self-targeted milestone reminder at task start (20-30 minutes for fast work, "
            .. "1 hour for normal work), use it to re-check the task and approach and align your "
            .. "members, remove a fired `--once` item with `remuda butler schedule rm milestone` "
            .. "before adding the next, and report only new evidence, decisions, changes or blockers. "
        end },
      { id = "cli", order = 20,
        agents_md = function()
          return [[Use Butler's CLI for communication:

- `remuda butler inbox` reads your own queued messages.
- `remuda butler send MEMBER "MESSAGE"` sends a message; your sender is inferred.
- For long bodies, write the text to a file inside your working directory and use `remuda butler send MEMBER --file "$PWD/path"`, or pipe it: `cat <<'EOF' | remuda butler send MEMBER -`.
- `send-to-leader` and `reply MESSAGE_ID` accept `-` and `--file "$PWD/path"` too.
- Message bodies are limited to 64 KiB; short quoted messages can stay positional.
- `remuda butler send-to-leader RESULT...` reports a completed work loop.
- `remuda butler sessions` shows the household.
- `remuda butler reply MESSAGE-ID -` (or `--file PATH`) answers a message in its thread; for Matrix mail it keeps the room and thread (prefer this over send when answering); answers to Matrix mail ALWAYS use this, never `remuda butler matrix send`.
- `remuda butler forward MESSAGE-ID MEMBER [NOTE]` passes a message on with an optional note
- Run `remuda butler ...` exactly as shown. Do not prefix it with REMUDA_NO_UPDATE_CHECK=1 or other VAR=value assignments: managed sessions never print the update banner, and a leading assignment can stop an allow rule such as Bash(remuda butler *) from matching.

]]
        end,
        prompt = function()
          return "Use `remuda butler inbox`, `remuda butler send MEMBER \"MESSAGE\"`, and "
            .. "`remuda butler send-to-leader RESULT...` for coordination; answer mail with "
            .. "`remuda butler reply MESSAGE-ID -` (or `--file PATH`). Long bodies use "
            .. 'stdin (`-`) or `--file "$PWD/path"`; message bodies are limited to 64 KiB. '
        end },
      { id = "schedule", order = 22,
        agents_md = function()
          return [[Use Butler's persistent schedule for recurring checks or delayed follow-ups
that should survive a Claude/Codex/OpenCode/Monocle session or harness change.
First check `remuda butler schedule list`. A schedule sends its fixed text as
timed mail; it does not run a shell command or CI job by itself. Read the mail
and perform the check it describes.

Schedules repeat. You can add one for your own session and remove the schedules
created by your current Butler identity:

`remuda butler schedule add NAME "*/20 * * * *" "Check CI and report its status."`

Your session is the target and the command itself is the confirmation. Adding
one starts standing mail from the reserved sender `schedule` at every due time,
also after restarts, until you remove it with `remuda butler schedule rm NAME`.
Ask the owner to add or remove a schedule for another session, or to manage
schedules from the terminal; there the add asks for confirmation and
`--to SESSION` names the target.

The schedule has five fields in the machine's local time: the minute is `N` or
`*/N` (steps 5, 6, 10, 12, 15, 20 or 30), the hour is `N` or `*`, then `* * *`.
This is not a one-shot timer or a general cron runner. Schedules can be skipped
if the target session is absent or still has unread mail from the previous
firing.

]]
        end },
      { id = "codex", order = 25,
        agents_md = function()
          return [[Codex members: use the MCP `butler_*` tools first (`butler_inbox`,
`butler_send`, `butler_reply`, `butler_send_to_leader`, `butler_forward`,
`butler_sessions`; `matrix_download` and `matrix_upload` for Matrix files). The
`remuda butler` CLI fails inside the Codex sandbox by
design (`Operation not permitted`). If you must use the CLI and get that error,
re-run the command requesting escalated permissions.

]]
        end },
      { id = "opencode", order = 26,
        agents_md = function()
          return [[OpenCode members: use the Butler MCP `butler_*` tools for coordination
and mailbox work. The Butler MCP server is configured for this member; first run
`remuda butler inbox` to read the task and recent mail.

]]
        end },
      { id = "old-core", order = 30,
        agents_md = function()
          return [[CLI identity comes from the daemon's caller session, never environment variables.
If Butler cannot identify the caller, run from a registered Butler session or
upgrade Remuda core. Older cores without caller fields refuse CLI member actions;
use the MCP `butler_*` tools with the session's configured capability instead.
Caller attribution is advisory within one user account, not an isolation boundary.

]]
        end },
      { id = "delegation", order = 40,
        agents_md = function()
          return [[You may create a Remuda-managed child team with `remuda butler topic delegate
NAME TASK...` when useful. Internal agent subagents are separate from Butler
team members. `remuda butler send --from FROM TO MESSAGE...` is an operator form, not
the normal way for a member to communicate.

## Delegation: STICC

When directing a member, explain the assignment using STICC, scaled to the task:

- **Situation:** the relevant context and current state.
- **Task:** the concrete work and expected deliverable.
- **Intent:** the objective and why it matters.
- **Concern:** constraints, risks, and known uncertainties.
- **Calibrate:** ask the member to confirm their understanding, raise concerns,
  and report progress or results so the plan can be adjusted.

Give enough context for independent action without unnecessary ceremony. If you
direct your own members, use STICC and tell them to propagate it.

### 5W1H as a planning aid

STICC frames a delegation. When the task is broad or ambiguous, use 5W1H inside it:

- **What:** the concrete deliverable and the done test.
- **Why:** the objective and the decision it supports.
- **Who:** the owner, requester, recipients, and who must approve.
- **When:** the deadline, ETA, and checkpoints.
- **Where:** the repo, path, environment, and where the result goes.
- **How:** the approach, constraints, and verification.

This is an optional thinking aid, not a required message format. Do not pad a
short or sensitive task with ceremony; ask only the questions that change the work.

### ETA and self-reminder

When you accept a delegated task, estimate a rough ETA before you start and state
it in your first progress note. If the work will likely take more than about 15
minutes or has an external wait, add a reminder to your own session at the ETA:

```
remuda butler schedule add eta-check "<M> <H> * * *" \
  "ETA reached: report progress to your leader or the owner, then remove this reminder: remuda butler schedule rm eta-check" --once
```

Use a short unique name in place of `eta-check`. This is a self-targeted reminder:
do not pass `--to`. With `--once` it delivers at the next matching time and then
disables itself; until it delivers it retries if your session is absent or its
previous mail is unread. It is still a minute/hour slot, not an absolute deadline:
use it only when the next matching minute/hour is within 24 hours, and pick the
next future minute (the current minute waits for the next day). For a longer ETA
use a nearer checkpoint or state the date in your report. Remove it after reporting
to keep the list clean, and replace it if the ETA moves. Skip it for short,
sensitive, or no-report tasks; state the ETA in the first report instead. Only your
own session is in scope; ask the owner for another session. This ETA reminder
is a separate deadline check from the milestone self-check; neither requires
reporting to a human at every firing.

]]
        end,
        prompt = function()
          return "When you direct your own members, explain the assignment using STICC "
            .. "(Situation, Task, Intent, Concern, Calibrate) and tell them to propagate it. "
            .. "Use 5W1H as an optional planning aid when a task is broad. When you accept a "
            .. "task, estimate an ETA and, for work over about 15 minutes, add a self-targeted "
            .. "`remuda butler schedule` reminder; remove it after reporting. "
        end },
      { id = "matrix", order = 50,
        agents_md = function()
          return [[Matrix is the human-facing adapter: never call the homeserver REST API or curl directly; use `remuda butler matrix [OPTIONS] VERB ARGS`. Options go BEFORE the verb (`--json` for machine output; `--room ROOM` defaults to the configured room).
- `status`: whoami, joined rooms, and the sync cursor.
- `[-n N] history`: recent messages in the room.
- `rooms`: joined rooms (read-only).
- `thread EVENT_ID`: all replies in a thread.
- `follow EVENT_ID` / `unfollow EVENT_ID`: manage thread replies; HOME always delivers replies, while other rooms require a follow or mention. Replying, sending and a mention from an allowlisted sender follow automatically.
- `event EVENT_ID` (alias `get`): one event.
- `send TEXT`: start a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send.
- `reply EVENT_ID TEXT` / `react EVENT_ID KEY`: answer or react (same room only).
- `upload PATH`: post a file (up to 20 MB). `[-o PATH] download MXC`: fetch media.
- `redact EVENT_ID [--reason TEXT]`: remove your message.
]]
        end,
        prompt = function()
          return "For Matrix, use `remuda butler matrix VERB`; never call Matrix REST or curl directly. `send TEXT` starts a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send. "
        end },
      { id = "prepared-text", order = 60,
        agents_md = function()
          return [[

## Prepared text for owner approval

Use the `butler_approve_text` MCP tool or
`remuda butler approve-text request SESSION -` with the exact text on stdin to
register up to 8 KiB of normalized text for the owner to review in Matrix.
Registration needs live Matrix sync and prepared-text approval on. The
allowlisted owner approves or denies the posted request by reply or reaction;
the terminal `remuda butler approve` does not approve prepared text. Register
only the intended content and target, explain its purpose to the owner, and
never treat a request as approval. The post shows the request's expiry (default
30 minutes; the owner can configure `approval_ttl_minutes`). On approval Butler
checks the target session and attempts to type the stored, normalized text
once. `typed (seen)` is a screen observation, not proof that the agent acted;
an uncertain outcome requires inspection before a new request. The owner
controls the `approve-text on|off` switch at a terminal; `remuda butler doctor`
reports it.
]]
        end },
      { id = "leader", order = 90,
        prompt = function(_, ctx) return "Your leader is " .. ctx.parent .. "." end },
    },
    -- The rule merged into the root Butler's settings.local.json; an extension adds its own row.
    ["butler.permission"] = {
      { id = "cli", order = 10, rules = function(_, ctx) return host._butler_permissions.builtin(ctx) end },
    },
    ["butler.command"] = {
      { id = "close", order = 8, verb = "close",
        usage = "  remuda butler close <name> [--force]\n  remuda butler close --force <name>",
        run = function(_, args, caller) return host._butler_command_run("close", args, caller) end },
      { id = "doctor", order = 5, verb = "doctor", usage = "  remuda butler doctor",
        run = function(_, args, caller) return host._butler_command_run("doctor", args, caller) end },
      -- commands.lua registers the verb, but the exported catalog is what the
      -- host dispatches; an unlisted verb is unreachable from `remuda butler`.
      -- The forwarded run keeps the root-only caller check inside commands.lua.
      { id = "native", order = 5.9, verb = "native",
        usage = "  remuda butler native adopt-codex ALIAS --socket PATH --thread UUID"
          .. " | adopt-opencode ALIAS --endpoint URL --conversation SES_ID --password-stdin",
        run = function(_, args, caller) return host._butler_command_run("native", args, caller) end },
      { id = "quota", order = 6, verb = "quota", usage = "  remuda butler quota [--report]",
        run = function(_, args, caller) return host._butler_command_run("quota", args, caller) end },
      { id = "compact", order = 16, verb = "compact", usage = "  remuda butler compact <session> [--dry-run|--force]",
        run = function(_, args, caller)
          local spec = {
            name = "remuda butler",
            verbs = { compact = {
              about = "Compact a Butler session. Example: remuda butler compact worker-1 --dry-run",
              options = {
                { long = "dry-run", help = "Show compaction changes without applying them" },
                { long = "force", help = "Compact even when automatic rules would defer" },
              },
              args = { { name = "SESSION", help = "Session to compact" } },
              next = "remuda butler compact --help",
            } },
          }
          local report = cli_parse(spec, args)
          if report.kind == "help" then return report.text end
          if not report.ok then
            if type(host.fail) == "function" then return host.fail(report.text, report.code) end
            error(report.text, 0)
          end
          local session = report.values.SESSION
          local dry_run, force = report.values["dry-run"] == true, report.values.force == true
          if dry_run and force then
            local message = "--dry-run and --force cannot be used together.\nNext: remuda butler compact --help"
            if type(host.fail) == "function" then return host.fail(message, 2) end
            error(message, 0)
          end
          if not host._butler_compaction_has_session(session) then
            local message = "unknown session: " .. (session == "" and "<empty>" or session)
            if type(host.fail) == "function" then return host.fail(message, 1) end
            error(message, 0)
          end
          if dry_run then return host._butler_compaction_tick(session, true) end
          host._butler_current_agent(caller)
          return host.butler.compact(session, force)
        end },
      { id = "sessions", order = 10, verb = "sessions", usage = "  remuda butler sessions",
        run = function(_, args, caller) return host._butler_command_run("sessions", args, caller) end },
      { id = "status", order = 12, verb = "status", usage = "  remuda butler status  (0=up, 75=launching, 1=failed)",
        run = function(_, args, caller) return host._butler_command_run("status", args, caller) end },
      { id = "guard", order = 21, verb = "guard", usage = "  remuda butler guard on|off|status | approvals on|off|status | deny on|off|status | grants [on|off|status] | stats | verify (guard and approvals are on by default; deny and grants are off)",
        run = function(_, args, caller) return host._butler_command_run("guard", args, caller) end },
      { id = "typed-lines", order = 13, verb = "typed-lines", usage = "  remuda butler typed-lines on|off",
        run = function(_, args, caller) return host._butler_command_run("typed-lines", args, caller) end },
      { id = "shell-lines", order = 14, verb = "shell-lines", usage = "  remuda butler shell-lines on|off",
        run = function(_, args, caller) return host._butler_command_run("shell-lines", args, caller) end },
      { id = "agents", order = 15, verb = "agents", usage = "  remuda butler agents [--all]",
        run = function(_, args, caller) return host._butler_command_run("agents", args, caller) end },
      { id = "status-commands", order = 17, verb = "status-commands", usage = "  remuda butler status-commands on|off",
        run = function(_, args, caller) return host._butler_command_run("status-commands", args, caller) end },
      { id = "approve-text", order = 19, verb = "approve-text", usage = "  remuda butler approve-text request SESSION - | on|off",
        run = function(_, args, caller) return host._butler_command_run("approve-text", args, caller) end },
      { id = "schedule", order = 18, verb = "schedule", usage = "  remuda butler schedule list\n"
          .. '  remuda butler schedule add <name> "<M H * * *>" <text> | - [--to SESSION] [--once]\n'
          .. "  remuda butler schedule rm <name>",
        run = function(_, args, caller) return host._butler_command_run("schedule", args, caller) end },
      { id = "input-queue", order = 22, verb = "input-queue", usage = "  remuda butler input-queue status [ID] | cancel ID | resolve ID not_sent|delivered",
        run = function(_, args, caller) return host._butler_command_run("input-queue", args, caller) end },
      { id = "launch", order = 20, verb = "launch", usage = "  remuda butler launch <claude|codex|monocle> [name] [--model M] [--writable DIR]... [--sandbox full]",
        run = function(_, args, caller) return host._butler_command_run("launch", args, caller) end },
      { id = "topic", order = 30, verb = "topic", usage = "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
          .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] [--cwd DIR] [--writable DIR]... [--sandbox full] <task...>",
        run = function(_, args, caller) return host._butler_command_run("topic", args, caller) end },
      { id = "send", order = 40, verb = "send", usage = '  remuda butler send <to> "<message>" | <to> - | <to> --file PATH\n'
          .. '  remuda butler send --from <from> <to> <message...> | --from <from> --file PATH <to>',
        run = function(_, args, caller) return host._butler_command_run("send", args, caller) end },
      { id = "send-to-leader", order = 50, verb = "send-to-leader", usage = "  remuda butler send-to-leader [--done] <message...> | - | --file PATH\n"
          .. "  Without --done, creates no new auto-close request and keeps an earlier one.\n"
          .. "  To send text that starts with -, put -- first: remuda butler send-to-leader -- -text",
        run = function(_, args, caller) return host._butler_command_run("send-to-leader", args, caller) end },
      { id = "inbox", order = 60, verb = "inbox", usage = "  remuda butler inbox [name]",
        run = function(_, args, caller) return host._butler_command_run("inbox", args, caller) end },
      { id = "reply", order = 70, verb = "reply", usage = "  remuda butler reply <message-id> <message...> | - | --file PATH\n"
          .. "  remuda butler reply <message-id> --attach PATH [caption...]",
        run = function(_, args, caller) return host._butler_command_run("reply", args, caller) end },
      { id = "forward", order = 80, verb = "forward", usage = "  remuda butler forward <message-id> <member> [note...]",
        run = function(_, args, caller) return host._butler_command_run("forward", args, caller) end },
      { id = "approvals", order = 90, verb = "approvals", usage = "  remuda butler approvals",
        run = function(_, args, caller) return host._butler_command_run("approvals", args, caller) end },
      { id = "approve", order = 91, verb = "approve", usage = "  remuda butler approve <ID>",
        run = function(_, args, caller) return host._butler_command_run("approve", args, caller) end },
      { id = "deny", order = 92, verb = "deny", usage = "  remuda butler deny <ID>",
        run = function(_, args, caller) return host._butler_command_run("deny", args, caller) end },
      { id = "matrix", order = 100, verb = "matrix",
        -- One source of truth: matrix_cli's own grouped help (commands.lua
        -- lists the pointer instead, via its Matrix section summary).
        usage = function() return host.butler.matrix.cli_usage() end,
        run = function(_, args, caller) return host._butler_command_run("matrix", args, caller) end },
    },
  },
}
