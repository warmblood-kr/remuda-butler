-- Member guidance for Matrix names each member verb and omits the operator
-- verbs.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval("remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true")
T.eval('return remuda.exec("butler")')

local expected = {
  "Matrix is the human-facing adapter: never call the homeserver REST API or curl directly; use `remuda butler matrix [OPTIONS] VERB ARGS`. Options go BEFORE the verb (`--json` for machine output; `--room ROOM` defaults to the configured room).",
  "- `status`: whoami, joined rooms, and the sync cursor.",
  "- `[-n N] history`: recent messages in the room.",
  "- `rooms`: joined rooms (read-only).",
  "- `thread EVENT_ID`: all replies in a thread.",
  "- `event EVENT_ID` (alias `get`): one event.",
  "- `send TEXT`: start a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send.",
  "- `reply EVENT_ID TEXT` / `react EVENT_ID KEY`: answer or react (same room only).",
  "- `upload PATH`: post a file (up to 20 MB). `[-o PATH] download MXC`: fetch media.",
  "- `redact EVENT_ID [--reason TEXT]`: remove your message.",
}

T.test("butler_matrix_guidance_covers_each_member_verb_and_omits_operator_verbs", function()
  local guidance = T.eval([[
    for _, item in ipairs(remuda.contributions("butler.guidance")) do
      if item.owner == "butler" and item.id == "matrix" then
        return item.entry.agents_md({ parent = "leader" })
      end
    end
    return "missing Matrix guidance contribution"
  ]])
  for _, line in ipairs(expected) do
    T.ok(guidance:find(line, 1, true), "Matrix guidance omitted: " .. line .. "\n" .. guidance)
  end
  T.ok(not guidance:find("join ROOM", 1, true), "operator join leaked into member guidance")
  T.ok(not guidance:find("leave ROOM", 1, true), "operator leave leaked into member guidance")
end)
