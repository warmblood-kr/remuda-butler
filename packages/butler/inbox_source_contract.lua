-- ABSTRACT source adapter v1. Not loaded by daemon; product: inbox_source.lua.
-- Meaningful positive fixtures MUST fail until a real source adapter exists.
local M = { contract_version = 1 }
local function missing(operation)
  return nil, { code = "contract_unimplemented", operation = operation }
end
function M.open(config) return missing("open") end
local Source = {}
function Source:recipients(root) return missing("recipients") end
function Source:snapshot(root, recipient) return missing("snapshot") end
function Source:witness(root, recipient) return missing("witness") end
-- Additive resumable migration API; synchronous snapshot v1 stays unchanged.
function Source:advance(root, recipient, budget) return missing("advance") end
M.Source = Source
-- Adapter DOT signatures; bounded records specified in inbox-source-staging.md.
local Progress = {}
function Progress.load(root, recipient) return missing("progress.load") end
function Progress.commit(root, recipient, revision, cursor, delta)
  return missing("progress.commit")
end
function Progress.scan(root, recipient, generation, kind, after_key, limit)
  return missing("progress.scan")
end
function Progress.get(root, recipient, generation, kind, key)
  return missing("progress.get")
end
M.Progress = Progress
return M
