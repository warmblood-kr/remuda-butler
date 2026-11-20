remuda._butler_telemetry_adapters = remuda._butler_telemetry_adapters or {}
-- Per-agent payload identity: an observation time is assigned when the payload
-- first changes, never renewed merely because the same values are read again.
remuda._butler_telemetry_observed = remuda._butler_telemetry_observed or {}

function remuda._butler_telemetry_for(agent)
  local adapter = remuda._butler_telemetry_adapters[agent.kind]
  local telemetry = adapter and adapter.read and adapter.read(agent.telemetry or {}) or {}
  local model = telemetry.model or agent.model or "?"
  local used = telemetry.context_used or "?"
  local window = telemetry.context_window or "?"
  local percent = telemetry.context_percent or "?"
  local observed = remuda._butler_telemetry_observed
  local key = tostring(agent.id or agent)
  local signature = table.concat(
    { tostring(model), tostring(used), tostring(window), tostring(percent),
      tostring(telemetry.hook_state), tostring(telemetry.hook_at) }, "\0")
  local prior = observed[key]
  if not prior or prior.signature ~= signature then
    prior = { signature = signature, observed_at = os.time() }
    observed[key] = prior
  end
  return {
    model = model,
    context_used = used,
    context_window = window,
    context_percent = percent,
    rate_limits = telemetry.rate_limits,
    hook_state = telemetry.hook_state,
    hook_at = telemetry.hook_at,
    observed_at = tonumber(telemetry.observed_at) or prior.observed_at,
  }
end
