T.test("Butler handoff prompt and unread mail", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")

  local root_id = T.eval("return remuda._butler_bus.agents.butler.id")
  T.expect(#root_id == 26 and root_id:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil,
    "root id is not a ULID: '" .. root_id .. "'")

  local prompt = T.eval("return remuda._butler_system_prompt")
  local handoff_line = "If the inbox has a mail whose first line is `HANDOFF`, read it before anything else and take over its open items."
  T.expect(prompt:find(handoff_line, 1, true) ~= nil,
    "root prompt lacks the HANDOFF line",
    "ok - root prompt tells Butler to read a HANDOFF mail first")
  T.expect(prompt:find("_butler_register_compaction_schedule", 1, true) == nil,
    "root prompt must not depend on a run_script compaction registration")

  T.eval('return remuda._butler_send("operator", "butler", "HANDOFF\\nopen: PR 12")')
  local first_inbox = T.eval("return remuda._butler_inbox(" .. string.format("%q", root_id) .. ")")
  T.expect(first_inbox:find("open: PR 12", 1, true) ~= nil,
    "HANDOFF mail is not in the root inbox")

  T.eval('return remuda._butler_send("operator", "butler", "HANDOFF\\nopen: PR 13")')
  T.eval('return remuda.exec("butler")')
  T.eq(T.eval("return remuda._butler_bus.agents.butler.id"), root_id,
    "relaunch changed the root ULID")
  local after = T.eval("return remuda._butler_inbox(" .. string.format("%q", root_id) .. ")")
  T.expect(after:find("open: PR 13", 1, true) ~= nil,
    "HANDOFF mail did not stay unread across the relaunch")
  T.expect(after:find("open: PR 12", 1, true) == nil,
    "an already-read HANDOFF mail came back",
    "ok - an unread HANDOFF mail survives a relaunch of the same ULID")
end)
