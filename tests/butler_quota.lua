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
  codex = { mode = "subscription", limits = nil, unknown_reason = "no idle codex session to ask" },
}
local unavailable_body = table.concat({
  "⚠️ Agent accounts, 2026-10-01 04:40Z",
  "claude: not logged in",
  "codex: subscription, account: not exposed by codex",
  "  quota: unknown (no idle codex session to ask)",
  "Not logged in: claude.",
}, "\n")
local old_reading = {
  at = at,
  claude = { mode = "subscription", plan = "max", email = "jeongsoo@warmblood.kr", read_at = 1790827800,
    limits = {
      { name = "5-hour limit", used = 40, resets_at = 1790838000 },
      { name = "Weekly limit", used = 71, resets_at = 1791072000 },
    } },
  codex = { mode = "subscription", limits = nil, unknown_reason = "no idle codex session to ask" },
}
local old_reading_body = table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (max), jeongsoo@warmblood.kr",
  "  5-hour limit: 40% used, resets 2026-10-01 07:00Z",
  "  Weekly limit: 71% used, resets 2026-10-04 00:00Z",
  "  as of 2026-10-01 04:10Z",
  "codex: subscription, account: not exposed by codex",
  "  quota: unknown (no idle codex session to ask)",
}, "\n")
local ordinary_next = "Next: run `remuda butler quota --report` to send this to Matrix."
local codex_idle_next = "Next: start a codex member with `remuda butler launch codex` (or wait until one is idle), then run `remuda butler quota` again."

-- render: the three UX examples, excluding their terminal ending.
eq("render subscription near limit", quota.render(normal), normal_body)
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
  .. "Could not post to Matrix: network down\nNext: remuda butler doctor")
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
  "Next: log in with `claude auth login`, then run `remuda butler quota` again.",
}, "\n"))
eq("terminal UX case 4", quota.terminal(old_reading), old_reading_body .. "\n" .. codex_idle_next)
eq("terminal sent with no idle codex", quota.terminal(old_reading, { sent = true }), old_reading_body .. "\n"
  .. "Sent to the Matrix home room.\n" .. codex_idle_next)

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
eq("usage error text", quota.usage_error("--bogus"), "unknown argument: --bogus\n"
  .. "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report\n"
  .. "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix.")
eq("help text", quota.help(), "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report\n"
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
  "claude: unknown (unrecognised status output)",
  "codex: unknown (unrecognised status output)",
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
local newer_screen = screen:gsub("40%% left", "20%% left"):gsub("100%% left", "75%% left")
local twice = quota.parse_codex_status(screen .. "\n" .. newer_screen, 32400, at)
eq("codex repeated card deduplicates limits", #twice.limits, 2)
eq("codex repeated card keeps last weekly value", twice.limits[1].used, 80)
eq("codex repeated card keeps last reserve value", twice.limits[2].used, 25)
eq("codex repeated card preserves limit order", table.concat({ twice.limits[1].name, twice.limits[2].name }, ","),
  "Weekly limit,Luna Reserve Weekly limit")
eq("codex screen no limits", quota.parse_codex_status("Account: Pro\n", 32400, at), nil)
local strange = quota.parse_codex_status("Account: Pro\nWeekly limit: [x] 40% left\n  (resets someday)\n", 32400, at)
eq("codex unparseable reset text", strange.limits[1].resets_text, "someday")
eq("codex unparseable reset render", quota.render({ at = at,
  claude = { mode = "api_key" }, codex = { mode = "subscription", plan = strange.plan, limits = strange.limits } }), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: API key (no subscription, no quota to report)",
  "codex: subscription (Pro), account: not exposed by codex",
  "  Weekly limit: 60% used, resets someday (local time)",
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
  "no idle codex session to ask",
  "codex did not show its limits in time",
}) do
  local body = quota.render({ at = at, claude = { mode = "subscription", plan = "max", email = "a@b.c",
    limits = nil, unknown_reason = reason }, codex = { mode = "api_key" } })
  ok("unknown quota reason: " .. reason, body:find("  quota: unknown (" .. reason .. ")", 1, true) ~= nil)
end

-- Untrusted status values never add terminal control lines or exceed 80 bytes.
eq("render replaces controls in account and limit values", quota.render({ at = at,
  claude = { mode = "subscription", plan = "max\nplan", email = "owner@example.test\n@room:evil",
    limits = { { name = "Weekly\tlimit", used = 60, resets_text = "tomorrow\r@all" } } },
  codex = { mode = "api_key" },
}), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (max plan), owner@example.test @room:evil",
  "  Weekly limit: 60% used, resets tomorrow @all (local time)",
  "codex: API key (no subscription, no quota to report)",
}, "\n"))
local eighty_p = string.rep("P", 80)
local eighty_e = string.rep("E", 80)
local eighty_n = string.rep("N", 80)
local eighty_r = string.rep("R", 80)
eq("render cuts every untrusted value to 80 bytes", quota.render({ at = at,
  claude = { mode = "subscription", plan = eighty_p .. "P", email = eighty_e .. "E",
    limits = { { name = eighty_n .. "N", used = 1, resets_text = eighty_r .. "R" } } },
  codex = { mode = "api_key" },
}), table.concat({
  "Agent accounts, 2026-10-01 04:40Z",
  "claude: subscription (" .. eighty_p .. "), " .. eighty_e,
  "  " .. eighty_n .. ": 1% used, resets " .. eighty_r .. " (local time)",
  "codex: API key (no subscription, no quota to report)",
}, "\n"))

local invalid_names = "Account: Pro\n"
  .. string.rep("L", 41) .. ": [x] 90% left\n  (resets 2:30 AM on 4 Oct)\n"
  .. "Bad/Name: [x] 90% left\n  (resets 2:30 AM on 4 Oct)\n"
  .. "Weekly limit: [x] 40% left\n  (resets 2:30 AM on 4 Oct)\n"
local valid_beside_invalid = quota.parse_codex_status(invalid_names, 32400, at)
eq("codex skips invalid and overlong limit names", #valid_beside_invalid.limits, 1)
eq("codex keeps a valid limit beside invalid names", valid_beside_invalid.limits[1].name, "Weekly limit")

eq("usage", quota.usage(), "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report")
print(("butler_quota ok: %d cases"):format(count))
