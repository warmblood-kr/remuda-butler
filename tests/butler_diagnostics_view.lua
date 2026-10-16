-- Run with: luajit tests/butler_diagnostics_view.lua
-- Synthetic observations only; never touches a live daemon or its inbox.
local text, shown, calls = "", nil, 0
local buffer = { set = function(_, value) text = value end }
_G.remuda = {
  buffer = { new = function(name)
    assert(name == "*diagnostics*")
    return buffer
  end },
  window = { current = function()
    return { show = function(_, target)
      assert(target == buffer)
      shown, calls = target, calls + 1
    end }
  end },
}
-- Every attempted control operation is a regression failure.
for _, name in ipairs({ "key", "type_text", "approve", "resume", "retry", "close" }) do
  remuda[name] = function() error("viewer attempted control: " .. name) end
end

local diagnostics = dofile("packages/butler/diagnostics.lua")
assert(type(diagnostics) == "table", "diagnostics module must return its API")
for i = 1, 25 do
  diagnostics.record("matrix", "deferred", "delivery_deferred", "event-" .. i)
end
local snapshot = diagnostics.snapshot()
assert(type(snapshot) == "table", "snapshot must be structured")
assert(snapshot.scope == "node-local" and snapshot.node == "local")
assert(snapshot.retention == "memory" and snapshot.capacity == 200)
assert(#snapshot.events == 25)
local original = diagnostics.format()
assert(type(original) == "string" and original:find("matrix", 1, true))
assert(original:find("delivery_deferred", 1, true), "reason must remain visible")
diagnostics.show(1)
assert(shown == buffer and calls == 1, "show must only select the text buffer")
assert(text == diagnostics.format(nil, 1), "shown first page differs from formatter")
local first = text
diagnostics.show(2)
assert(calls == 2 and text ~= first, "older page must display different observations")
assert(text == diagnostics.format(nil, 2), "shown second page differs from formatter")

-- Rendering a snapshot must not destructively consume retained events.
diagnostics.format(snapshot, 1)
assert(diagnostics.format(nil, 1) == original, "format mutated the retained observations")
snapshot.events[1].reason = "MUTATED-SNAPSHOT"
assert(not diagnostics.format_all():find("MUTATED-SNAPSHOT", 1, true),
  "snapshot returned a live reference to retained events")
diagnostics.refresh()
assert(calls == 2, "refresh must not reclaim the owner's selected window")
assert(text == diagnostics.format(nil, 2), "refresh must preserve the chosen page")
print("butler diagnostics viewer: ok")
