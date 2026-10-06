-- RED unit tests for packages/butler/quota.lua. Run from the repository root:
--   luajit tests/butler_quota.lua
local quota = dofile("packages/butler/quota.lua")
local count = 0

local function eq(name, got, want)
  count = count + 1
  if got ~= want then
    error(("case %d: %s\n want: %s\n  got: %s"):format(count, name, tostring(want), tostring(got)), 2)
  end
end

local function ok(name, value)
  count = count + 1
  if not value then error(("case %d: %s"):format(count, name), 2) end
end

local at = 1790829600
local claude_limits = {
  { name = "5-hour limit", used = 92, resets_at = 1790838000 },
  { name = "Weekly limit", used = 71, resets_at = 1791072000 },
}
local codex_limits = {
  { name = "Weekly limit", used = 60, resets_at = 1791048600 },
  { name = "Luna Reserve Weekly limit", used = 0, resets_at = 1791433920 },
}
local normal = {
  at = at,
  claude = { mode = "subscription", plan = "max", email = "jeongsoo@warmblood.kr", limits = claude_limits },
  codex = { mode = "subscription", plan = "Pro", limits = codex_limits },
}
local normal_body = table.concat({
  "⚠️ Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (max), jeongsoo@warmblood.kr",
  "  5-hour limit: 92% used, resets 2026-10-01 07:00Z",
  "  Weekly limit: 71% used, resets 2026-10-04 00:00Z",
  "codex: subscription (Pro), account: not exposed by codex",
  "  Weekly limit: 60% used, resets 2026-10-03 17:30Z",
  "  Luna Reserve Weekly limit: 0% used, resets 2026-10-08 04:32Z",
  "Near limit: claude 5-hour limit (92%).",
}, "\n")
local keys = {
  at = at,
  claude = { mode = "api_key" },
  codex = { mode = "api_key" },
}
local keys_body = table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: API key (no subscription, no quota to report)",
  "codex: API key (no subscription, no quota to report)",
}, "\n")
local unavailable = {
  at = at,
  claude = { mode = "not_logged_in" },
  codex = { mode = "subscription", limits = nil,
    unknown_reason = "codex limits need core nightly d47a845 or newer" },
}
local unavailable_body = table.concat({
  "⚠️ Agent accounts, 2026-10-01 04:40Z",
  "claude: not logged in",
  "codex: subscription, account: not exposed by codex",
  "  quota: unknown (codex limits need core nightly d47a845 or newer)",
  "Not logged in: claude.",
}, "\n")
local old_reading = {
  at = at,
  claude = { mode = "subscription", plan = "max", email = "jeongsoo@warmblood.kr", read_at = 1790827800,
    limits = {
      { name = "5-hour limit", used = 40, resets_at = 1790838000 },
      { name = "Weekly limit", used = 71, resets_at = 1791072000 },
    } },
  codex = { mode = "subscription", limits = nil,
    unknown_reason = "codex limits need core nightly d47a845 or newer" },
}
local old_reading_body = table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (max), jeongsoo@warmblood.kr",
  "  5-hour limit: 40% used, resets 2026-10-01 07:00Z",
  "  Weekly limit: 71% used, resets 2026-10-04 00:00Z",
  "  as of 2026-10-01 04:10Z",
  "codex: subscription, account: not exposed by codex",
  "  quota: unknown (codex limits need core nightly d47a845 or newer)",
}, "\n")
local ordinary_next = "Next: run `remuda butler quota --report` to send this to Matrix."
local codex_core_next = "Next: update Remuda core to nightly d47a845 or newer, then run `remuda butler quota` again."

-- render: the three UX examples, excluding their terminal ending.
eq("render subscription near limit", quota.render(normal), normal_body)
local codex_last_known = quota.render({ at = at, claude = { mode = "api_key" },
  codex = { mode = "subscription", plan = "prolite", limits = {
    { name = "Weekly limit", used = 9, resets_at = 1791048660 },
  }, read_at = at - 180, last_known = true } })
ok("Codex fallback identifies last known age", codex_last_known:find("  quota: last known (3 min ago)", 1, true) ~= nil)
eq("render API keys", quota.render(keys), keys_body)
eq("render not logged in and unknown quota", quota.render(unavailable), unavailable_body)

-- terminal: each full UX example and the --report outcomes.
eq("terminal UX case 1", quota.terminal(normal), normal_body .. "\n" .. ordinary_next)
eq("terminal UX case 2", quota.terminal(keys), keys_body .. "\n" .. ordinary_next)
eq("terminal UX case 3", quota.terminal(unavailable), unavailable_body .. "\n"
  .. "Next: log in with `claude auth login`, then run `remuda butler quota` again.")
eq("terminal sent", quota.terminal(keys, { sent = true }), keys_body .. "\n"
  .. "Sent to the Matrix home room.\nNext: run `remuda butler quota` any time for a fresh reading.")
eq("terminal failed", quota.terminal(keys, { failed = "network down" }), keys_body .. "\n"
  .. "Could not post to Matrix: network down\nNext: remuda butler matrix setup")
local codex_out = { at = at, claude = { mode = "api_key" }, codex = { mode = "not_logged_in" } }
eq("terminal codex login hint", quota.terminal(codex_out), table.concat({
  "⚠️ Agent accounts, 2026-10-01 04:40Z",
  "claude: API key (no subscription, no quota to report)",
  "codex: not logged in",
  "Not logged in: codex.",
  "Next: log in with `codex login`, then run `remuda butler quota` again.",
}, "\n"))
local both_out = { at = at, claude = { mode = "not_logged_in" }, codex = { mode = "not_logged_in" } }
eq("terminal both login hint", quota.terminal(both_out), table.concat({
  "⚠️ Agent accounts, 2026-10-01 04:40Z",
  "claude: not logged in",
  "codex: not logged in",
  "Not logged in: claude, codex.",
  "Next: log in with `claude auth login` and `codex login`, then run `remuda butler quota` again.",
}, "\n"))
eq("terminal UX case 4", quota.terminal(old_reading), old_reading_body .. "\n" .. codex_core_next)
eq("terminal sent with no idle codex", quota.terminal(old_reading, { sent = true }), old_reading_body .. "\n"
  .. "Sent to the Matrix home room.\n" .. codex_core_next)

-- Attention is exactly 80% or more, and only then prefixes the header.
local function one_limit(used)
  return { at = at, claude = { mode = "subscription", plan = "max", email = "a@b.c",
    limits = { { name = "5-hour limit", used = used, resets_at = 1790838000 } } }, codex = { mode = "api_key" } }
end
ok("79 percent has no warning header", quota.render(one_limit(79)):sub(1, #"⚠️") ~= "⚠️")
ok("79 percent has no attention line", not quota.render(one_limit(79)):find("Near limit:", 1, true))
ok("80 percent has warning header", quota.render(one_limit(80)):sub(1, #"⚠️") == "⚠️")
ok("80 percent has attention line", quota.render(one_limit(80)):find("Near limit: claude 5-hour limit (80%).", 1, true) ~= nil)
local fresh = one_limit(40)
fresh.claude.read_at = at - 540
ok("nine-minute-old Claude reading has no as-of line", not quota.render(fresh):find("  as of ", 1, true))
local stale = one_limit(40)
stale.claude.read_at = at - 1800
ok("30-minute-old Claude reading has as-of line", quota.render(stale):find("  as of 2026-10-01 04:10Z", 1, true) ~= nil)

-- Account detection copies only the public Claude subscription fields.
local ca = quota.claude_account({ loggedIn = true, authMethod = "claude.ai", subscriptionType = "max",
  email = "owner@example.test", orgId = "secret-org", orgName = "Secret Organization" })
eq("claude subscription mode", ca.mode, "subscription")
eq("claude subscription plan", ca.plan, "max")
eq("claude subscription email", ca.email, "owner@example.test")
local hidden = quota.render({ at = at, claude = ca, codex = { mode = "api_key" } })
ok("Claude organization fields never render", not hidden:find("secret%-org") and not hidden:find("Secret Organization", 1, true))
eq("claude API key", quota.claude_account({ loggedIn = true, authMethod = "api_key" }).mode, "api_key")
eq("claude logged out", quota.claude_account({ loggedIn = false }).mode, "not_logged_in")
-- Measured on claude 2.1.286 in a logged-out home (2026-10-01).
eq("claude logged out, measured shape", quota.claude_account({ loggedIn = false, authMethod = "none",
  apiProvider = "firstParty" }).mode, "not_logged_in")
eq("usage error text", quota.usage_error("--bogus"), "unknown option: --bogus\n"
  .. "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report\n"
  .. "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix.")
eq("help text", quota.help(), "remuda butler quota reports, for claude and codex, how each is logged in, the subscription account and how much of each limit is used.\n"
  .. "With --report it also posts the report to this Butler's Matrix home room.\n"
  .. "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report\n"
  .. "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix.")
eq("claude unrecognised auth method", quota.claude_account({ loggedIn = true, authMethod = "sso" }).mode, "unknown")
eq("claude missing auth", quota.claude_account(nil).mode, "unknown")

eq("codex ChatGPT login", quota.codex_account("Logged in using ChatGPT").mode, "subscription")
eq("codex API key login", quota.codex_account("Logged in using an API key - sk-...").mode, "api_key")
eq("codex not logged in", quota.codex_account("Not logged in").mode, "not_logged_in")
eq("codex empty output", quota.codex_account("").mode, "unknown")
eq("codex missing output", quota.codex_account(nil).mode, "unknown")
eq("codex unrecognised output", quota.codex_account("something else").mode, "unknown")
eq("unknown status render", quota.render({ at = at, claude = { mode = "unknown" }, codex = { mode = "unknown" } }), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: unknown (could not understand what `claude auth status` answered)",
  "codex: unknown (could not understand what `codex login status` answered)",
}, "\n"))

-- Claude statusline cache format is rounded and strictly parseable.
local snapshot = { rate_limits = { five_hour = { used_percentage = 23.5, resets_at = 100 },
  seven_day = { used_percentage = 71, resets_at = 200 } } }
local rl = "RL:1790829600 five_hour=24@100 seven_day=71@200"
eq("rate limits round trip source", quota.rate_limits_line(snapshot, at), rl)
local parsed_rl = quota.parse_rate_limits_line(rl)
eq("parsed rate limit timestamp", parsed_rl.at, at)
eq("parsed five-hour name", parsed_rl.limits[1].name, "5-hour limit")
eq("parsed five-hour rounded used", parsed_rl.limits[1].used, 24)
eq("parsed weekly name", parsed_rl.limits[2].name, "Weekly limit")
eq("parsed weekly reset", parsed_rl.limits[2].resets_at, 200)
eq("rate limits one window", quota.rate_limits_line({ rate_limits = {
  seven_day = { used_percentage = 1, resets_at = 2 } } }, at), "RL:1790829600 seven_day=1@2")
eq("rate limits absent", quota.rate_limits_line({}, at), nil)
eq("rate limits garbage", quota.parse_rate_limits_line("RL:bad five_hour=2@3"), nil)

local seven_day_only = "RL:1790829600 seven_day=71@200"
eq("rate limits omit string used percentage", quota.rate_limits_line({ rate_limits = {
  five_hour = { used_percentage = "92", resets_at = 100 }, seven_day = snapshot.rate_limits.seven_day,
} }, at), seven_day_only)
eq("rate limits omit string reset", quota.rate_limits_line({ rate_limits = {
  five_hour = { used_percentage = 92, resets_at = "100" }, seven_day = snapshot.rate_limits.seven_day,
} }, at), seven_day_only)
eq("rate limits omit missing reset", quota.rate_limits_line({ rate_limits = {
  five_hour = { used_percentage = 92 }, seven_day = snapshot.rate_limits.seven_day,
} }, at), seven_day_only)
for _, unexpected in ipairs({ "limits", 92, true }) do
  eq("rate limits rejects non-table container " .. tostring(unexpected),
    quota.rate_limits_line({ rate_limits = unexpected }, at), nil)
end
for _, unexpected in ipairs({ "limit", 5 }) do
  eq("rate limits omits non-table five-hour window " .. tostring(unexpected), quota.rate_limits_line({ rate_limits = {
    five_hour = unexpected, seven_day = snapshot.rate_limits.seven_day,
  } }, at), seven_day_only)
end
eq("rate limits rejects nested windows", quota.rate_limits_line({ rate_limits = {
  limits = { five_hour = snapshot.rate_limits.five_hour },
} }, at), nil)
eq("rate limits rejects all malformed windows", quota.rate_limits_line({ rate_limits = {
  five_hour = { used_percentage = "92", resets_at = "100" }, seven_day = true,
} }, at), nil)

local no_reading = quota.render({ at = at,
  claude = { mode = "subscription", plan = "max", email = "owner@example.test", limits = nil,
    unknown_reason = "no reading yet; it appears after a claude session's first reply" },
  codex = { mode = "api_key" },
})
local claude_block = no_reading:match("claude:.-\ncodex:")
ok("no Claude reading prints unknown quota", claude_block:find("  quota: unknown %(no reading yet; it appears after a claude session's first reply%)") ~= nil)
ok("no Claude reading block has no percentage", claude_block:find("%%") == nil)

local f = assert(io.open("tests/fixtures/quota-codex-status-0.159.3.txt", "rb"))
local screen = assert(f:read("*a")); f:close()
local cs = quota.parse_codex_status(screen, 32400, at)
eq("codex screen plan", cs.plan, "Pro")
eq("codex screen first limit name", cs.limits[1].name, "Weekly limit")
eq("codex screen first used", cs.limits[1].used, 60)
eq("codex screen first reset", cs.limits[1].resets_at, 1791048600)
eq("codex screen second limit name", cs.limits[2].name, "Luna Reserve Weekly limit")
eq("codex screen second used", cs.limits[2].used, 0)
eq("codex screen second reset", cs.limits[2].resets_at, 1791433920)

-- Decoded copy of the relevant fields from quota-codex-app-server.json.
-- This standalone test has no remuda.json decoder.
local app_result = { rateLimitsByLimitId = {
  codex = { planType = "prolite", primary = { usedPercent = 62,
    windowDurationMins = 10080, resetsAt = 1791048656 } },
  base_model_inference = { limitName = "gpt-reserve", planType = "prolite",
    primary = { usedPercent = 0, windowDurationMins = 10080, resetsAt = 1791460487 } },
} }
local parsed_app = type(quota.parse_codex_rate_limits) == "function"
    and quota.parse_codex_rate_limits(app_result) or nil
ok("codex app-server rate-limit parser is implemented", parsed_app ~= nil)
eq("codex app-server preserves planType", parsed_app and parsed_app.plan, "prolite")
eq("codex app-server limit count matches /status", parsed_app and #parsed_app.limits, 2)
eq("codex app-server first limit name matches /status", parsed_app and parsed_app.limits[1].name, "Weekly limit")
eq("codex app-server first limit used comes from fixture", parsed_app and parsed_app.limits[1].used, 62)
eq("codex app-server first limit reset comes from fixture", parsed_app and parsed_app.limits[1].resets_at, 1791048656)
eq("codex app-server reserve name matches /status", parsed_app and parsed_app.limits[2].name, "Luna Reserve Weekly limit")
eq("codex app-server reserve used comes from fixture", parsed_app and parsed_app.limits[2].used, 0)
eq("codex app-server reserve reset comes from fixture", parsed_app and parsed_app.limits[2].resets_at, 1791460487)
for _, resets_at in ipairs({ 1e300, 5000000000 }) do
  app_result.rateLimitsByLimitId.codex.primary.resetsAt = resets_at
  local rejected_reset = quota.parse_codex_rate_limits(app_result)
  eq("codex app-server rejects out-of-range reset " .. tostring(resets_at),
    rejected_reset and #rejected_reset.limits or 0, 1)
end
app_result.rateLimitsByLimitId.codex.primary.resetsAt = 1791048656
local accepted_reset = quota.parse_codex_rate_limits(app_result)
eq("codex app-server accepts normal reset", accepted_reset and accepted_reset.limits[1].resets_at, 1791048656)
local newer_screen = screen:gsub("40%% left", "20%% left"):gsub("100%% left", "75%% left")
local twice = quota.parse_codex_status(screen .. "\n" .. newer_screen, 32400, at)
eq("codex repeated card deduplicates limits", #twice.limits, 2)
eq("codex repeated card keeps last weekly value", twice.limits[1].used, 80)
eq("codex repeated card keeps last reserve value", twice.limits[2].used, 25)
eq("codex repeated card preserves limit order", table.concat({ twice.limits[1].name, twice.limits[2].name }, ","),
  "Weekly limit,Luna Reserve Weekly limit")
eq("codex screen no limits", quota.parse_codex_status("Account: Pro\n", 32400, at), nil)
local strange = quota.parse_codex_status("Account: Pro\nWeekly limit: [x] 40% left\n  (resets someday @all)\n", 32400, at)
eq("codex unparseable reset has no text", strange.limits[1].resets_text, nil)
eq("codex unparseable reset render", quota.render({ at = at,
  claude = { mode = "api_key" }, codex = { mode = "subscription", plan = strange.plan, limits = strange.limits } }), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: API key (no subscription, no quota to report)",
  "codex: subscription (Pro), account: not exposed by codex",
  "  Weekly limit: 60% used, resets unknown",
}, "\n"))
local rollover = quota.parse_codex_status("Account: Pro\nWeekly limit: [x] 100% left\n  (resets 12:30 AM on 1 Jan)\n", 0, 1798758000)
eq("codex December rollover", rollover.limits[1].resets_at, 1798763400)

eq("not installed line", quota.render({ at = at, claude = { mode = "not_installed" }, codex = { mode = "api_key" } }), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: not installed",
  "codex: API key (no subscription, no quota to report)",
}, "\n"))
for _, reason in ipairs({
  "no reading yet; it appears after a claude session's first reply",
  "codex did not show its limits in time",
  "codex limits need core nightly d47a845 or newer",
}) do
  local body = quota.render({ at = at, claude = { mode = "subscription", plan = "max", email = "a@b.c",
    limits = nil, unknown_reason = reason }, codex = { mode = "api_key" } })
  ok("unknown quota reason: " .. reason, body:find("  quota: unknown (" .. reason .. ")", 1, true) ~= nil)
end
eq("unknown quota reason not copied from pane", quota.render({ at = at,
  claude = { mode = "subscription", plan = "max", email = "a@b.c", limits = nil,
    unknown_reason = "untrusted @room text" }, codex = { mode = "api_key" },
}), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (max), a@b.c",
  "  quota: unknown (could not be read)",
  "codex: API key (no subscription, no quota to report)",
}, "\n"))


local invalid_names = "Account: Pro\n"
  .. string.rep("L", 41) .. ": [x] 90% left\n  (resets 2:30 AM on 4 Oct)\n"
  .. "Bad/Name: [x] 90% left\n  (resets 2:30 AM on 4 Oct)\n"
  .. "Weekly limit: [x] 40% left\n  (resets 2:30 AM on 4 Oct)\n"
local valid_beside_invalid = quota.parse_codex_status(invalid_names, 32400, at)
eq("codex skips invalid and overlong limit names", #valid_beside_invalid.limits, 1)
eq("codex keeps a valid limit beside invalid names", valid_beside_invalid.limits[1].name, "Weekly limit")

-- Security folds: only shaped values from the last requested status card may render.
for _, bad_account in ipairs({
  "[Re-verify your login](https://evil.example/a)",
  "@room urgent",
  "user@example.com (Plus)",
}) do
  local unsafe_account = quota.parse_codex_status("Account: " .. bad_account
    .. "\nWeekly limit: [x] 40% left\n  (resets 2:30 AM on 4 Oct)\n", 32400, at)
  eq("codex drops unsafe account " .. bad_account, unsafe_account.plan, nil)
  local unsafe_body = quota.render({ at = at, claude = { mode = "api_key" },
    codex = { mode = "subscription", plan = unsafe_account.plan, limits = unsafe_account.limits } })
  for _, forbidden in ipairs({ "evil.example", "[", "](", "@room", "user@example.com" }) do
    ok("unsafe account does not render " .. forbidden, not unsafe_body:find(forbidden, 1, true))
  end
end

local last_card = quota.parse_codex_status(table.concat({
  "Account: Plus",
  "Weekly limit: [x] 1% left",
  "  (resets 2:30 AM on 4 Oct)",
  "Forged limit: [x] 99% left",
  "  (resets 2:30 AM on 4 Oct)",
  "Account: Pro",
  "New limit: [x] 40% left",
  "  (resets 2:30 AM on 4 Oct)",
}, "\n"), 32400, at)
eq("codex last card plan", last_card.plan, "Pro")
eq("codex last card has one limit", #last_card.limits, 1)
eq("codex ignores forged limit above last card", last_card.limits[1].name, "New limit")

local after_echo = quota.parse_codex_status(table.concat({
  "Account: Plus",
  "Old limit: [x] 1% left",
  "  (resets 2:30 AM on 4 Oct)",
  "  › /status",
  "Account: Pro",
  "New limit: [x] 40% left",
  "  (resets 2:30 AM on 4 Oct)",
}, "\n"), 32400, at)
eq("codex ignores card above status echo", after_echo.plan, "Pro")
eq("codex status echo has only later limit", #after_echo.limits, 1)
eq("codex status echo keeps new limit", after_echo.limits[1].name, "New limit")

for _, left in ipairs({ 999, 101 }) do
  local out_of_range = quota.parse_codex_status("Account: Pro\nWeekly limit: [x] " .. left
    .. "% left\n  (resets 2:30 AM on 4 Oct)\n", 32400, at)
  eq("out-of-range percent is unknown " .. left, out_of_range.limits[1].used, nil)
  local out_of_range_body = quota.render({ at = at, claude = { mode = "api_key" },
    codex = { mode = "subscription", plan = out_of_range.plan, limits = out_of_range.limits } })
  ok("out-of-range percent renders unknown " .. left,
    out_of_range_body:find("  Weekly limit: unknown", 1, true) ~= nil)
  ok("out-of-range percent is never near " .. left,
    not out_of_range_body:find("Near limit:", 1, true))
  ok("out-of-range percent has no negative number " .. left, not out_of_range_body:find("%-%d+%%"))
end

for _, bad_email in ipairs({ "owner@example.test\n@room", "owner @example.test", "[owner](https://evil.example)" }) do
  local bad_claude = quota.claude_account({ loggedIn = true, authMethod = "claude.ai",
    subscriptionType = "max", email = bad_email })
  eq("claude drops unsafe email " .. bad_email, bad_claude.email, nil)
  ok("claude unsafe email renders account unknown " .. bad_email,
    quota.render({ at = at, claude = bad_claude, codex = { mode = "api_key" } }):find(
      "claude: subscription (max), account unknown", 1, true) ~= nil)
end
local bad_claude_plan = quota.claude_account({ loggedIn = true, authMethod = "claude.ai",
  subscriptionType = "max @room", email = "owner@example.test" })
eq("claude drops unsafe plan", bad_claude_plan.plan, nil)

eq("render reused header", quota.render({ at = at, reused = true,
  claude = { mode = "api_key" }, codex = { mode = "api_key" } }), table.concat({
  "Agent accounts, as of 2026-10-01 04:40Z",
  "claude: API key (no subscription, no quota to report)",
  "codex: API key (no subscription, no quota to report)",
}, "\n"))

local function terminal_case(name, report, outcome, ending)
  eq(name, quota.terminal(report, outcome), quota.render(report) .. "\n" .. ending)
end
terminal_case("terminal failure takes priority", unavailable, { failed = "bad\1\226\128\174\195\169" },
  "Could not post to Matrix: bad??????\nNext: remuda butler matrix setup")
terminal_case("terminal unknown mode takes priority", {
  at = at, claude = { mode = "unknown" },
  codex = { mode = "subscription", limits = nil,
    unknown_reason = "codex limits need core nightly d47a845 or newer" },
}, nil, "Next: run `claude auth status` yourself to see what it answers, then `remuda butler doctor`.")
terminal_case("terminal timeout retry", {
  at = at, claude = { mode = "api_key" },
  codex = { mode = "subscription", limits = nil, unknown_reason = "codex did not show its limits in time" },
}, nil, "Next: run `remuda butler quota` again in a minute.")
terminal_case("terminal core minimum retry", {
  at = at, claude = { mode = "api_key" },
  codex = { mode = "subscription", limits = nil,
    unknown_reason = "codex limits need core nightly d47a845 or newer" },
}, nil, codex_core_next)
terminal_case("terminal claude first reply hint", {
  at = at, claude = { mode = "subscription", plan = "max", email = "a@b.c", limits = nil },
  codex = { mode = "api_key" },
}, nil, "Next: let a claude session answer once, then run `remuda butler quota` again.")
local long_failure = string.rep("x", 201)
terminal_case("terminal failure cuts reason at 200", keys, { failed = long_failure },
  "Could not post to Matrix: " .. string.rep("x", 200) .. "\nNext: remuda butler matrix setup")

-- Stub the app-server process and decoder while exercising the production callback path.
local saved_remuda = remuda
local claude_auth_status = [[{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "email": "owner@example.test",
  "orgId": "secret-org",
  "orgName": "Secret Organization",
  "subscriptionType": "max"
}]]
local claude_auth = {
  loggedIn = true,
  authMethod = "claude.ai",
  apiProvider = "firstParty",
  email = "owner@example.test",
  orgId = "secret-org",
  orgName = "Secret Organization",
  subscriptionType = "max",
}
remuda = {
  _butler_doctor = { probe = function()
    return { claude = { stdout = claude_auth_status } }
  end },
  json = { decode = function(text)
    if text ~= '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty",'
        .. '"email":"owner@example.test","orgId":"secret-org","orgName":"Secret Organization",'
        .. '"subscriptionType":"max"}' then
      error("unexpected Claude auth status fixture")
    end
    return claude_auth
  end },
}
quota = dofile("packages/butler/quota.lua")
local claude_account = quota.accounts().claude
eq("pretty Claude auth status mode", claude_account.mode, "subscription")
eq("pretty Claude auth status plan", claude_account.plan, "max")
eq("pretty Claude auth status email", claude_account.email, "owner@example.test")
remuda._butler_doctor = { probe = function() return { claude = {} } end }
eq("Claude auth status without stdout stays unknown", quota.accounts().claude.mode, "unknown")
remuda._butler_doctor = { probe = function() return { claude = { stdout = claude_auth_status:gsub("^{", "{\v", 1) } } end }
eq("Claude auth status with VT stays unknown", quota.accounts().claude.mode, "unknown")
remuda = saved_remuda

local wire_init = '{"id":1}'
local wire_remote = '{"method":"remoteControl/status/changed"}'
local wire_account = '{"method":"account/updated"}'
local wire_model_refresh = '{"method":"model/list/refreshing"}'
local wire_rate_limits = '{"id":2}'
local wire_delayed_rate_limits = '{"id":2,"method":"account/rateLimits/read"}'
local decoded_lines = {
  [wire_init] = { id = 1 },
  [wire_remote] = { method = "remoteControl/status/changed" },
  [wire_account] = { method = "account/updated" },
  [wire_model_refresh] = { method = "model/list/refreshing" },
  [wire_rate_limits] = { id = 2, result = app_result },
  [wire_delayed_rate_limits] = { id = 2, result = { rateLimitsByLimitId = {
    codex = { planType = "prolite", primary = { usedPercent = 9,
      windowDurationMins = 10080, resetsAt = 1791580260 } },
  } } },
}
local stubbed_result, process_options, process_calls, scheduled
remuda = {
  process = { run = function(options)
    process_options = options
    process_calls = (process_calls or 0) + 1
    return stubbed_result
  end },
  _butler_system = { after = function(_, callback) scheduled = callback; return "quota-retry" end },
  schedule = function(options) scheduled = options.run; return "quota-retry" end,
  cancel = function() end,
  json = { decode = function(line)
    local decoded = decoded_lines[line]
    if not decoded then error("invalid JSON") end
    return decoded
  end },
}
quota = dofile("packages/butler/quota.lua")
local function codex_read_case(name, stdout, timed_out, expected, failure_reason, simulated_delay, expected_used)
  process_calls, scheduled = 0, nil
  remuda._butler_quota_state.codex_reading = nil
  if stdout == nil then
    stubbed_result = nil
  else
    stubbed_result = { stdout = stdout, timed_out = timed_out, elapsed = simulated_delay }
  end
  if simulated_delay then
    ok(name .. " fixture arrives within the new deadline", stubbed_result.elapsed <= 8)
  end
  local reading, reason
  quota.codex_read(function(value, failure)
    reading, reason = value, failure
  end)
  if not expected and type(scheduled) == "function" then scheduled() end
  eq(name .. " argv executable", process_options.argv[1], "codex")
  eq(name .. " argv subcommand", process_options.argv[2], "app-server")
  eq(name .. " waits for complete response", process_options.timeout, 8)
  eq(name .. " holds stdin through startup chatter", process_options.stdin_hold_until_lines, 64)
  if expected then
    ok(name .. " reads the fixture response", reading ~= nil)
    eq(name .. " preserves plan", reading and reading.plan, "prolite")
    eq(name .. " reads fixture usage", reading and reading.limits[1].used, expected_used or 62)
    eq(name .. " has no failure reason", reason, nil)
  else
    eq(name .. " uses unknown-reason path", reading, nil)
    eq(name .. " gives expected unknown reason", reason,
      failure_reason or "codex did not show its limits in time")
  end
end
codex_read_case("app-server id 2 third", table.concat({ wire_init, wire_remote, wire_rate_limits }, "\n"), false, true)
codex_read_case("app-server id 2 fourth", table.concat({ wire_init, wire_remote, wire_account, wire_rate_limits }, "\n"), false, true)
local delayed_fixture = assert(io.open("tests/fixtures/quota-codex-app-server-0160-delayed.txt", "rb"))
local delayed_output = assert(delayed_fixture:read("*a")):gsub("\n$", "")
delayed_fixture:close()
codex_read_case("app-server delayed id 2 after model refresh", delayed_output, false, true, nil, 6, 9)
codex_read_case("app-server timed out with id 2", table.concat({
  wire_init, wire_remote, wire_account, wire_rate_limits,
}, "\n"), true, true)
codex_read_case("app-server timed out without id 2", table.concat({ wire_init, wire_remote, wire_account }, "\n"), true, false,
  "codex did not show its limits in time")
codex_read_case("app-server garbage", "not JSON\nstill not JSON", false, false)
codex_read_case("old core initialize only", wire_init, false, false,
  "codex limits need core nightly d47a845 or newer")

-- Empty output gets the old-core hint and does not trigger a synchronous second run.
process_calls, scheduled = 0, nil
stubbed_result = { stdout = "", timed_out = true }
local empty_output_reading, empty_output_reason
quota.codex_read(function(value, failure)
  empty_output_reading, empty_output_reason = value, failure
end)
eq("empty app-server output gets old-core hint", empty_output_reason,
  "codex limits need core nightly d47a845 or newer")
eq("empty app-server output runs once", process_calls, 1)
eq("empty app-server output does not schedule retry", scheduled, nil)

process_calls, scheduled = 0, nil
stubbed_result = nil
local nil_result_reading, nil_result_reason
quota.codex_read(function(value, failure) nil_result_reading, nil_result_reason = value, failure end)
eq("missing app-server result keeps generic reason", nil_result_reason,
  "codex did not show its limits in time")
eq("missing app-server result runs once", process_calls, 1)
eq("missing app-server result does not schedule retry", scheduled, nil)

process_calls, scheduled = 0, nil
stubbed_result = { code = 127, stdout = wire_init, timed_out = false }
local missing_codex_reading, missing_codex_reason
quota.codex_read(function(value, failure) missing_codex_reading, missing_codex_reason = value, failure end)
eq("missing Codex executable keeps generic reason", missing_codex_reason,
  "codex did not show its limits in time")
eq("missing Codex executable runs once", process_calls, 1)
eq("missing Codex executable does not schedule retry", scheduled, nil)

-- A transient first probe gets exactly one event-loop retry.
process_calls, scheduled = 0, nil
stubbed_result = { stdout = table.concat({ wire_init, wire_account }, "\n"), timed_out = true }
local retried_reading, retried_reason
quota.codex_read(function(value, failure) retried_reading, retried_reason = value, failure end)
eq("failed first probe defers its retry", retried_reading, nil)
ok("failed first probe schedules a retry", type(scheduled) == "function")
local first_options = process_options
stubbed_result = { stdout = table.concat({ wire_init, wire_model_refresh, wire_rate_limits }, "\n"), timed_out = false }
scheduled()
eq("retry starts a second probe", process_calls, 2)
eq("retry keeps 8 second ceiling", process_options.timeout, 8)
eq("retry gets fixture id 2 response", retried_reading and retried_reading.limits[1].used, 62)
eq("retry clears failure", retried_reason, nil)
ok("retry uses fresh process options", first_options ~= process_options)

-- A response can follow extra startup chatter without changing the parser result.
local extra_chatter = {}
for i = 1, 12 do extra_chatter[#extra_chatter + 1] = '{"method":"startup/chatter"}' end
extra_chatter[#extra_chatter + 1] = wire_init
extra_chatter[#extra_chatter + 1] = wire_model_refresh
extra_chatter[#extra_chatter + 1] = wire_rate_limits
stubbed_result = { stdout = table.concat(extra_chatter, "\n"), timed_out = false }
local chatter_reading
quota.codex_read(function(value) chatter_reading = value end)
eq("extra startup chatter leaves response readable", chatter_reading and chatter_reading.limits[1].used, 62)

-- The last successful Codex result stays available after a partial-output retry fails.
stubbed_result = { stdout = table.concat({ wire_init, wire_rate_limits }, "\n"), timed_out = false }
local fresh_reading
quota.codex_read(function(value) fresh_reading = value end)
ok("successful probe timestamps cached reading", fresh_reading and fresh_reading.read_at ~= nil)
process_calls, scheduled = 0, nil
stubbed_result = { stdout = wire_init, timed_out = true }
local old_reading
quota.codex_read(function(value) old_reading = value end)
ok("failed probe schedules cache fallback retry", type(scheduled) == "function")
scheduled()
ok("failed retry returns last known result", old_reading and old_reading.last_known == true)
eq("last known reading preserves timestamp", old_reading and old_reading.read_at,
  fresh_reading and fresh_reading.read_at)
remuda = saved_remuda

eq("usage error unexpected argument", quota.usage_error("claude"), "unexpected argument: claude\n"
  .. "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report\n"
  .. "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix.")
eq("report denied text", quota.report_denied(), "only the Butler itself or a person at the terminal can send the report to Matrix.\n"
  .. "Next: ask the Butler to run `remuda butler quota --report`, or run `remuda butler quota` to read it here.")
eq("unavailable text", quota.unavailable("bad\1\195\169"), "quota is unavailable: bad???\nNext: remuda butler doctor")

eq("usage", quota.usage(), "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report")
print(("butler_quota ok: %d cases"):format(count))
