-- QA owner: open the shadow inbox index from mod code against a missing
-- database. The shell wrapper copies this over packages/butler/init.lua in a
-- disposable tree, so remuda.db.open runs in the mod's own context.
local host = getmetatable(_G).__index.remuda

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = function()
    local root = assert(os.getenv("QA_MAIL_ROOT"), "QA_MAIL_ROOT is required")
    host._butler_inbox_db_path = assert(loadfile("packages/butler/inbox_db_path.lua"))()
    host._butler_diagnostics = { record = function() end }
    host.exec("butler/inbox_open")
    local open = assert(host._butler_inbox_open)

    local function attempt(label)
      host._butler_inbox_db_config = { root = root, open = host.db.open }
      host.exec("butler/inbox_db")
      local index = assert(host._butler_inbox_db)
      local options, refusal = open.prepare(host.db)
      if not options or options.must_exist ~= true then
        error(label .. ": must_exist was not selected: " .. tostring(refusal), 0)
      end
      local ok, why = index.deliver("aa", "shadow-" .. label)
      if ok then error(label .. ": the shadow index opened a missing database", 0) end
      print(label .. " REFUSED " .. tostring(why))
    end

    open.observe("present")
    attempt("active")
    -- Losing the marker must not re-enable the create path.
    open.observe("absent")
    attempt("vanished")
    -- An unknown marker state refuses before any open.
    open.observe(nil, "denied: test")
    local options, refusal = open.prepare(host.db)
    if options ~= nil or not refusal then
      error("unknown marker state selected an open", 0)
    end
    print("unknown REFUSED " .. tostring(refusal))
  end,
}
