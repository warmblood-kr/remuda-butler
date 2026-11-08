-- SQL record backend for approval state.
--
-- The relay store writer is the authority after activation. This adapter does
-- not read or write the legacy JSON map: `record` mirrors one exact approval
-- record through the bounded store writer, and `load` returns a bounded page
-- decoded from relay_records. A missing/stale writer is a refusal, never an
-- empty approval list.
local M = {}

local function identifier(value) return type(value) == 'string' and value ~= '' end

function M.new(store, writer_fn)
  if type(store) ~= 'table' then return nil, 'store' end
  local adapter = {}

  local function writer()
    local value = writer_fn
    if type(writer_fn) == 'function' then value = writer_fn() end
    if type(value) ~= 'table' then return nil, 'writer_unavailable' end
    return value
  end

  local function operation_for(rec, text)
    local stamp = rec.updated_at or rec.answered_at or rec.expires_at or 0
    return 'approval:' .. tostring(rec.id) .. ':' .. tostring(rec.status or '') ..
      ':' .. tostring(stamp) .. ':' .. tostring(rec.delivery_started == true) ..
      ':' .. tostring(#text)
  end

  -- record(rec) -> true | nil, reason
  function adapter.record(rec)
    if type(rec) ~= 'table' or not identifier(rec.id) then return nil, 'record' end
    local cap, cap_why = writer()
    if not cap then return nil, cap_why end
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then
      return nil, 'json'
    end
    local ok, text = pcall(json.encode, rec)
    if not ok or type(text) ~= 'string' then return nil, 'encode' end
    local result, why = store:put(cap, 'approvals', rec.id, text, operation_for(rec, text))
    if not result then return nil, why end
    return true
  end

  -- load(limit, after_key) -> {records}, next_after | nil, reason
  function adapter.load(limit, after_key)
    if type(store.page) ~= 'function' then return nil, 'page_unavailable' end
    local rows, why = store:page('approvals', { limit = limit or 64,
      after_key = after_key })
    if not rows then return nil, why end
    local records, last = {}, nil
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then
      return nil, 'json'
    end
    for _, row in ipairs(rows) do
      local ok, rec = pcall(json.decode, row.payload_json)
      if not ok or type(rec) ~= 'table' then return nil, 'record_decode' end
      records[#records + 1] = rec
      last = row.record_key
    end
    return records, last
  end

  -- get(id) -> record | nil, reason
  function adapter.get(id)
    if not identifier(id) then return nil, 'id' end
    local row, why = store:get('approvals', '', id)
    if not row then return nil, why end
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then
      return nil, 'json'
    end
    local ok, rec = pcall(json.decode, row.payload_json)
    if not ok or type(rec) ~= 'table' then return nil, 'record_decode' end
    return rec
  end

  return adapter
end

return M
