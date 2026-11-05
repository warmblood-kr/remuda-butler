# Official fakechat runtime checkpoint — 2026-11-05

Owner authorization superseded earlier no-install/no-auth-use restriction for this isolated test only. No product edits or global installs/settings, no credential copying/exposure.

Test root: /private/tmp/claude-fakechat-spike-2IcxbQ; cwd work; CLAUDE_CONFIG_DIR config. HOME retained for existing legitimate auth in place. Official marketplace added locally; fakechat 0.0.1 installed local scope, catalog commit fa4eb54397ee2faccb6940512a19c017cb1337f3. Bun absent in PATH/usual locations; official GitHub latest darwin-aarch64 archive downloaded into root, extracted runtime reports 1.4.4. Archive not checksum verified. Sandboxed marketplace fetch failed DNS; authorized network retry succeeded.

Actual PTY launch: Claude 2.1.317, --channels plugin:fakechat@claude-plugins-official --setting-sources local --settings '{"disableAllHooks":true}', with temporary CLAUDE_CONFIG_DIR and temporary Bun prepended to PATH. No --bare, development-channel flag, skip-permissions, or production session input.

Observed: Welcome to Claude Code 2.1.317 -> theme onboarding. Default theme selected in test. Next screen: “Select login method:” with Claude subscription / Anthropic Console API billing / third-party platform options. Existing auth was not automatically recognized with this isolated configuration. No login method selected; no browser/login/token flow begun.

No MCP registration, inbound event, model reply, negotiated protocol, session thread, or receipt was observed. No event was sent.  Owned PTY exited code 0 after Ctrl-C; no child server startup was observed. Temporary test installation retained for review; no broad process kill or removal performed. Official fakechat source uses homedir/.claude/channels/fakechat for file state, so future authenticated execution also needs that state redirected into owned test scope before any reply tool (without copying auth).

## Default auth and actual inbound

Second trial: default auth context + --plugin-dir <isolated cache>, --setting-sources '' and disableAllHooks recognized Claude Max but channel notice said plugin not installed. Installed source explicitly tags --plugin-dir as name@inline, losing marketplace identity. Exited0. Unexpected TUI banner “Update installed · Restart to update” observed; no explicit update command, causality/version unknown, no rollback attempted.

Resolved via installed setting CLAUDE_CODE_PLUGIN_CACHE_DIR: source mc() uses it instead of default plugins root. Third launch pinned original 2.1.317 executable, normal HOME/config for legitimate auth, PATH prepended temporary Bun, CLAUDE_CODE_PLUGIN_CACHE_DIR=<root>/config/plugins, DISABLE_AUTOUPDATER=1, --channels plugin:fakechat@claude-plugins-official --setting-sources local --settings '{"disableAllHooks":true}'. Temporary cached .mcp.json changed only child env HOME=<root>/plugin-home; plugin server.ts unmodified. This isolates hardcoded plugin file state while retaining normal parent auth. Local settings enable official marketplace plugin. Approved channel notice appeared without missing-plugin warning.

Owned TUI PID92691, fakechat launcher PID92721 -> localhost listener Bun PID92734. Executable-name-only ancestry confirmed TUI still original pinned binary. TUI session441ebc94-106c-4ed2-9e32-4a35b999c7a5 recorded from shutdown resume line. No restart/retarget occurred during event trial.

Single WebSocket event to ws://127.0.0.1:8787/ws: id spike-20261105-001, text “Benign isolated feasibility check. Use fakechat reply tool to reply exactly ACK spike-20261105-001 with reply_to spike-20261105-001. Do nothing else.” Same original PTY rendered inbound “← fakechat · web: Benign isolated feasibility check. Use fakechat reply tool …”. Next service response: “Your account is on hold and can't use Claude Code. View details or appeal: https://claude.ai/restricted”. No model-generated reply/tool receipt. First actual result sent immediately to lead and QA. No retry, login flow, or account-policy bypass.

Conclusion: approved native same-TUI inbound observed; correlated model reply/consumption receipt NOT proven, blocked by actual account hold. Earlier tempconfig onboarding and inline identity failures are superseded as blockers for inbound. WebSocket client stopped exit130; TUI exited0. Exact PID check found no92691/92721/92734; localhost8787 no longer listening. Temporary test artifacts retained. No product code edits, credential copies, production session input, or custom warning acceptance. Normal-context inherent runtime writes permitted by lead; unexpected updater banner disclosed.

QA final review 01M6NPP920C77NC3FQ04P9H2KN supports scoped inbound result. UUID from shutdown only; cleanup researcher-observed, not live-observed by QA. No consumption/completion acknowledgment proven. No further test requested.
