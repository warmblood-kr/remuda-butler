local normalize = assert(remuda.butler.matrix.mention_normalization).normalize
local alice, alice2 = "@alice:example.org", "@alice2:example.org"

local body, ids = normalize({
  body = "Hello Alice and Alice", format = "org.matrix.custom.html",
  formatted_body = "Hello <a href='https://matrix.to/#/@alice:example.org'>Alice</a> and "
    .. '<a href="https://matrix.to/#/@alice2:example.org">Alice</a>',
  ["m.mentions"] = { user_ids = { alice, alice2 } },
})
assert(body == "Hello @Alice and @Alice", tostring(body))
assert(ids[1] == alice and ids[2] == alice2, "same-display-name pills must retain their target MXIDs")

body, ids = normalize({
  body = "@Alice and Alice", format = "org.matrix.custom.html",
  formatted_body = "<a href='https://matrix.to/#/@alice:example.org'>@Alice</a> and "
    .. "<a href='https://matrix.to/#/@alice:example.org'>Alice</a>",
  ["m.mentions"] = { user_ids = { alice } },
})
assert(body == "@Alice and @Alice" and ids[1] == alice and ids[2] == alice,
  "an existing @ must not double, and repeated IDs stay repeated in metadata")

body = normalize({
  body = "jeongsoo: hello", format = "org.matrix.custom.html",
  formatted_body = "<a href='https://matrix.to/#/@jeongsoo:example.org'>jeongsoo</a>: hello",
  ["m.mentions"] = { user_ids = { "@jeongsoo:example.org" } },
})
assert(body == "@jeongsoo: hello", "a start-of-message mention keeps its target marker")

local unchanged = {
  { body = "Alice", format = "org.matrix.custom.html",
    formatted_body = "<a href='https://example.org/@alice:example.org'>Alice</a>",
    ["m.mentions"] = { user_ids = { alice } } },
  { body = "Alice", format = "org.matrix.custom.html",
    formatted_body = "<code><a href='https://matrix.to/#/@alice:example.org'>Alice</a></code>",
    ["m.mentions"] = { user_ids = { alice } } },
  { body = "Hello Alice", format = "org.matrix.custom.html",
    formatted_body = "Hello <a href='https://matrix.to/#/@alice:example.org'>Ally</a>",
    ["m.mentions"] = { user_ids = { alice } } },
  { body = "@Alice hello", format = "org.matrix.custom.html", formatted_body = "@Alice hello",
    ["m.mentions"] = { room = true } },
  { body = "<a href='https://matrix.to/#/@alice:example.org'>Alice</a>",
    format = "org.matrix.custom.html",
    formatted_body = "&lt;a href='https://matrix.to/#/@alice:example.org'&gt;Alice&lt;/a&gt;",
    ["m.mentions"] = { user_ids = { alice } } },
  { body = "Alice", format = "org.matrix.custom.html",
    formatted_body = "<a href='https://matrix.to/#/@alice:example.org'>Alice</a>",
    ["m.mentions"] = { user_ids = { alice2 } } },
  { body = "Alice", format = "org.matrix.custom.html",
    formatted_body = "<a href='https://matrix.to/#/@alice:example.org' "
      .. "href='https://matrix.to/#/@alice2:example.org'>Alice</a>",
    ["m.mentions"] = { user_ids = { alice, alice2 } } },
  { body = "Alice", format = "org.matrix.custom.html",
    formatted_body = "<a href='https://matrix.to/#/@alice:example.org' data-label=unquoted>Alice</a>",
    ["m.mentions"] = { user_ids = { alice } } },
}
for index, content in ipairs(unchanged) do
  local raw = content.body
  local normalized, mentions = normalize(content)
  assert(normalized == raw and #mentions == 0, "unconfirmed or ambiguous case " .. index .. " changed")
end

local plain = "Alice Alice"
body, ids = normalize({ body = plain, format = "org.matrix.custom.html",
  formatted_body = "Alice Alice", ["m.mentions"] = { user_ids = { alice } } })
assert(body == plain and #ids == 0, "display names without linked mention positions stay unchanged")

do
  local old_config, old_mail, old_ulid = remuda._butler_mail_config, remuda._butler_mail, remuda._butler_new_ulid
  local root = os.tmpname()
  os.remove(root)
  assert(os.execute("mkdir -p " .. string.format("%q", root)))
  local bus = { inboxes = {}, messages = {}, objects = {} }
  local counter = 0
  remuda._butler_new_ulid = function() counter = counter + 1 return "MENTION" .. tostring(counter) end
  remuda._butler_mail_config = { bus = bus, root = root,
    json_quote = remuda.butler.matrix.encode_json }
  local ok, err = pcall(function()
    dofile("packages/butler/mail.lua")
    local queued = assert(remuda._butler_mail.queue({ host = "matrix", alias = alice, session = alice },
      { id = "butler", alias = "butler" }, "@Alice and @Alice", "Matrix mention fixture", nil, nil,
      { sender = alice, room_id = "!room:example.org", event_id = "$mention-fixture",
        mentions = { alice, alice2 } }))
    bus.messages[queued.id], bus.inboxes.butler = nil, {}
    bus.mail_loaded.butler = nil
    remuda._butler_mail.inbox("butler")
    local reloaded = assert(bus.messages[queued.id], "queued Matrix mail did not reload")
    assert(reloaded.matrix.mentions[1] == alice and reloaded.matrix.mentions[2] == alice2,
      "actual MXIDs must survive mail envelope persistence in occurrence order")
  end)
  remuda._butler_mail_config, remuda._butler_mail, remuda._butler_new_ulid = old_config, old_mail, old_ulid
  os.execute("rm -rf " .. string.format("%q", root))
  assert(ok, err)
end

print("ok: Matrix mention normalization")
