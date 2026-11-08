-- Executable ABSTRACT contract, not a backend and never loaded by main.lua.
-- Product implementation supplies this exact API in inbox_authority.lua.
-- Deliberate RED stubs: no fixture can be certified by an unimplemented seam.
local M = { contract_version = 1 }

local function unimplemented(operation)
  return nil, { code = "contract_unimplemented", operation = operation }
end

-- Ordered delivery rows plus exact read membership; see companion document.
function M.certify(source, actual, context)
  return unimplemented("certify")
end

-- Inspect the external authority marker BEFORE opening SQLite.
function M.open(config)
  return unimplemented("open")
end

local Store = {}
function Store:status() return unimplemented("status") end
function Store:close() return unimplemented("close") end
function Store:lookup_matrix(recipient, room, event)
  return unimplemented("lookup_matrix")
end
function Store:hydrate(message_id) return unimplemented("hydrate") end
function Store:page(recipient, query, cursor) return unimplemented("page") end
function Store:deliver(intent) return unimplemented("deliver") end
function Store:accept_external(stable_source_key, immutable_payload)
  return unimplemented("accept_external")
end
function Store:mark_read(intent, ids, snapshot)
  return unimplemented("mark_read")
end
function Store:advance(budget) return unimplemented("advance") end
function Store:transition(expected, target, proof)
  return unimplemented("transition")
end
function Store:reconcile(operation_id) return unimplemented("reconcile") end

M.Store = Store
return M
