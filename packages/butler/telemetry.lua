remuda._butler_telemetry_adapters = remuda._butler_telemetry_adapters or {}

function remuda._butler_telemetry_for(agent)
  local adapter = remuda._butler_telemetry_adapters[agent.kind]
  local telemetry = adapter and adapter.read and adapter.read(agent.telemetry or {}) or {}
  if telemetry.model_id and telemetry.model_id ~= "?" then agent.model_id = telemetry.model_id end
  return {
    model = telemetry.model or agent.model or "?",
    model_id = agent.model_id or telemetry.model_id or telemetry.model or agent.model or "?",
    context_used = telemetry.context_used or "?",
    context_window = telemetry.context_window or "?",
    context_percent = telemetry.context_percent or "?",
  }
end
