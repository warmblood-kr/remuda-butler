//! `butler_status` as a live MCP tool, ported from core native/tests/mcp.rs
//! (removed there in 36568f7). Helpers are copied from that file.

use remuda_core::protocol::{Request, Response};
use remuda_native::{client, daemon, mcp};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const PATIENCE: Duration = Duration::from_secs(10);

fn scratch(tag: &str) -> PathBuf {
    let configured = std::env::var_os("REMUDA_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let base = std::fs::canonicalize(&configured).unwrap_or(configured);
    let dir = base.join(format!("remuda-m{}-{tag}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Start a daemon and return once it actually answers, not once it was spawned.
fn daemon_at(path: &Path) -> impl Drop {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let serving = path.to_path_buf();
    std::thread::spawn(move || {
        let _ = daemon::serve(&serving);
    });
    let deadline = Instant::now() + PATIENCE;
    while remuda_native::ipc::connect(path).is_err() {
        assert!(Instant::now() < deadline, "daemon never bound {path:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
    Cleanup(path.to_path_buf())
}

struct Cleanup(PathBuf);
impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// One round trip through the real dispatch.
fn ask(path: &Path, request: Value) -> Value {
    let line = mcp::handle(path, &request.to_string()).expect("a request with an id gets a reply");
    serde_json::from_str(&line).expect("the reply is JSON")
}

fn call(path: &Path, name: &str, arguments: Value) -> Value {
    ask(
        path,
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": name, "arguments": arguments}}),
    )
}

fn text_of(reply: &Value) -> String {
    reply["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn listed(path: &Path) -> Vec<String> {
    let reply = ask(
        path,
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
    );
    let mut names: Vec<String> = reply["result"]["tools"]
        .as_array()
        .expect("tools is a list")
        .iter()
        .map(|t| t["name"].as_str().unwrap_or_default().to_string())
        .collect();
    names.sort();
    names
}

#[test]
fn butler_status_is_a_live_mcp_tool_not_a_terminal_scrape() {
    // Run the real built-in package, but substitute a harmless long-lived
    // process for Claude.  This exercises the same package registration and
    // MCP registry path without needing an authenticated Claude account.
    let dir = scratch("butler-status");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    let requested_status_path = dir.join("status.status").to_string_lossy().into_owned();
    let status_path = match client::request(
        &path,
        &Request::Eval {
            code: format!(
                "remuda._butler_status_path = {}; remuda._butler_argv = {{'sh'}}; remuda.exec('butler'); return remuda._butler_status_path",
                serde_json::to_string(&requested_status_path).unwrap()
            ),
            name: None,
        },
    )
    .expect("load butler")
    {
        Response::Value(value) => value,
        other => panic!("butler did not return its status path: {other:?}"),
    };

    assert!(listed(&path).contains(&"butler_status".to_string()));
    let settings_path = eval(
        &path,
        &format!(
            "return remuda._butler_agent_support.status_settings({})",
            serde_json::to_string(&status_path).unwrap()
        ),
    );
    let settings: Value = serde_json::from_str(
        &std::fs::read_to_string(settings_path).expect("read generated member settings"),
    )
    .expect("member settings are JSON");
    let status_settings = &settings["statusLine"];
    assert_eq!(status_settings["type"], "command");
    let command = status_settings["command"].as_str().expect("status command");
    assert_eq!(
        command.split_whitespace().next(),
        Some("remuda"),
        "status command must use the Remuda stdin bridge: {command}"
    );
    assert!(
        status_settings.get("refreshInterval").is_none(),
        "status refresh must use Claude events"
    );
    assert!(
        command.starts_with("remuda -s "),
        "status command must select Butler's server: {command}"
    );
    assert!(
        command.contains(" --stdin butler statusline "),
        "status command must forward stdin: {command}"
    );
    assert!(
        command.contains(&status_path),
        "status command must name the telemetry file: {command}"
    );

    let snapshot = r#"{"model":{"display_name":"Claude Opus 4.6"},"context_window":{"total_input_tokens":12345,"context_window_size":200000,"used_percentage":6}}"#;
    let status_line = eval(
        &path,
        &format!(
            "return remuda._dispatch_extension_command('butler', {{'statusline', {}}}, {{stdin = {}}})",
            serde_json::to_string(&status_path).unwrap(),
            serde_json::to_string(snapshot).unwrap(),
        ),
    );
    assert_eq!(
        status_line,
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6"
    );
    assert_eq!(
        std::fs::read_to_string(&status_path).expect("read status file"),
        format!("{status_line}\n")
    );
    let failed_write_path = dir.join("missing").join("write-fail.status");
    let failed_write_line = eval(
        &path,
        &format!(
            "return remuda._dispatch_extension_command('butler', {{'statusline', {}}}, {{stdin = {}}})",
            serde_json::to_string(&failed_write_path.display().to_string()).unwrap(),
            serde_json::to_string(snapshot).unwrap(),
        ),
    );
    assert_eq!(
        failed_write_line, status_line,
        "a telemetry write failure must keep status output"
    );
    let non_status_path = dir.join("not-a-status-file.txt");
    let non_status_line = eval(
        &path,
        &format!(
            "return remuda._dispatch_extension_command('butler', {{'statusline', {}}}, {{stdin = {}}})",
            serde_json::to_string(&non_status_path.display().to_string()).unwrap(),
            serde_json::to_string(snapshot).unwrap(),
        ),
    );
    assert_eq!(non_status_line, status_line);
    assert!(
        !non_status_path.exists(),
        "non-.status path must not be written"
    );
    let reply = call(&path, "butler_status", json!({}));
    assert_eq!(reply["result"]["isError"], false, "status failed: {reply}");
    assert_eq!(
        text_of(&reply),
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6 AGENT:claude"
    );
    eval(
        &path,
        "remuda._butler_bus.agents.butler.kind='codex'; remuda._butler_attempts={{kind='claude',reason='login'},{kind='codex',reason='ready'}}",
    );
    assert_eq!(
        text_of(&call(&path, "butler_status", json!({}))),
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6 AGENT:codex SKIPPED:claude=login"
    );
    eval(
        &path,
        "remuda._butler_bus.agents.butler.kind='claude'; remuda._butler_attempts={}",
    );

    let snapshot = r#"{"model":{"id":"sonnet"},"context_window":{"current_usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30},"context_window_size":200000,"used_percentage":30}}"#;
    let status_line = eval(
        &path,
        &format!(
            "return remuda._dispatch_extension_command('butler', {{'statusline', {}}}, {{stdin = {}}})",
            serde_json::to_string(&status_path).unwrap(),
            serde_json::to_string(snapshot).unwrap(),
        ),
    );
    assert_eq!(status_line, "MODEL:sonnet CTX:60 CTXWIN:200000 CTXPCT:30");

    // Missing context data remains explicit rather than being invented from
    // launch arguments or terminal rendering.
    let snapshot = r#"{"model":{"id":"sonnet"},"context_window":{}}"#;
    let status_line = eval(
        &path,
        &format!(
            "return remuda._dispatch_extension_command('butler', {{'statusline', {}}}, {{stdin = {}}})",
            serde_json::to_string(&status_path).unwrap(),
            serde_json::to_string(snapshot).unwrap(),
        ),
    );
    assert_eq!(status_line, "MODEL:sonnet CTX:? CTXWIN:? CTXPCT:?");
    assert_eq!(
        text_of(&call(&path, "butler_status", json!({}))),
        "MODEL:sonnet CTX:? CTXWIN:? CTXPCT:? AGENT:claude"
    );
}

#[test]
fn matrix_reply_is_not_registered_as_a_text_only_mcp_tool() {
    let dir = scratch("matrix-reply-tool");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    let token_path = dir.join("matrix-token");
    let config_path = dir.join("matrix-config");
    std::fs::write(&token_path, "fake-token").expect("write fake Matrix token");
    std::fs::write(
        &config_path,
        "http://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\n",
    )
    .expect("write fake Matrix config");
    let code = format!(
        r#"local getenv = os.getenv
        os.getenv = function(key)
          if key == 'REMUDA_BUTLER_TOKEN' then return {token_path} end
          if key == 'REMUDA_BUTLER_CONFIG' then return {config_path} end
          return getenv(key)
        end
        local http, request = remuda.http, remuda.http.request
        http.request = function(spec)
          spec.callback({{error='fake homeserver'}})
          return {{cancel=function() end}}
        end
        remuda._butler_argv = {{'sh'}}
        remuda.exec('butler')
        http.request = request
        os.getenv = getenv
        return 'loaded'"#,
        token_path = serde_json::to_string(&token_path.to_string_lossy()).unwrap(),
        config_path = serde_json::to_string(&config_path.to_string_lossy()).unwrap(),
    );
    assert_eq!(eval(&path, &code), "loaded");
    assert_eq!(
        eval(&path, "return tostring(remuda.butler and remuda.butler.matrix and remuda.butler.matrix.relay ~= nil)"),
        "true",
        "Matrix config must load its relay before checking matrix_reply absence"
    );
    let names = listed(&path);
    assert!(
        !names.contains(&"matrix_reply".to_string()),
        "the text-only matrix_reply MCP tool must not be registered: {names:?}"
    );
    eval(
        &path,
        "if remuda.butler and remuda.butler.matrix and remuda.butler.matrix.relay then remuda.butler.matrix.relay.stop() end; return 'stopped'",
    );
}

fn eval(path: &Path, code: &str) -> String {
    match client::request(path, &Request::Eval { code: code.into(), name: None }).expect("eval") {
        Response::Value(value) => value,
        other => panic!("eval {code:?} failed: {other:?}"),
    }
}

/// #24: an MCP caller Butler cannot identify (no capability token) must get a
/// tool error, not a child silently parented to `butler`.
#[test]
fn an_unknown_mcp_caller_cannot_launch_or_delegate() {
    let dir = scratch("unknown-caller");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        "for _, kind in ipairs({'claude', 'codex'}) do \
           remuda._butler_agent_builders[kind] = function() return {'sleep', '100'} end end",
    );
    let sessions = "local n = 0 for _ in pairs(remuda.ls()) do n = n + 1 end return n";
    let before = eval(&path, sessions);

    for (tool, arguments) in [
        ("butler_delegate", json!({"name": "e1", "task": "hi"})),
        ("butler_launch", json!({"kind": "claude", "name": "e2"})),
    ] {
        let reply = call(&path, tool, arguments);
        assert_eq!(reply["result"]["isError"], true, "{tool}: {reply}");
        assert!(
            text_of(&reply).contains("unknown caller: run from a Butler session"),
            "{tool}: {reply}"
        );
    }
    assert_eq!(eval(&path, sessions), before, "no session was created");
}

/// #24, CLI side: `remuda butler launch` from a member's shell parents the
/// child to that member, and an identity Butler cannot resolve fails loudly.
#[test]
fn cli_launch_parents_to_the_calling_member_not_butler() {
    let dir = scratch("cli-launch-parent");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        "remuda._butler_agent_builders.claude = function() return {'sleep', '100'} end; \
         remuda._butler_launch('claude', 'm1')",
    );
    let launch = |env: &str, name: &str| {
        format!(
            "return remuda._extension_commands.butler({{'launch', 'claude', '{name}'}}, {{ env = {env} }})"
        )
    };
    eval(&path, &launch("{ REMUDA_BUTLER_AGENT_ID = remuda._butler_bus.agents.m1.id }", "m2"));
    assert_eq!(eval(&path, "return remuda._butler_bus.agents.m2.parent"), "m1");
    eval(&path, &launch("{}", "m3"));
    assert_eq!(eval(&path, "return remuda._butler_bus.agents.m3.parent"), "butler");
    let unknown = client::request(
        &path,
        &Request::Eval { code: launch("{ REMUDA_BUTLER_AGENT_ID = 'ghost' }", "m4"), name: None },
    )
    .expect("eval");
    assert!(matches!(unknown, Response::Error(_)), "{unknown:?}");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.agents.m4)"), "nil");
}

#[test]
fn butler_close_is_limited_to_own_idle_members_unless_forced() {
    let dir = scratch("butler-close");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(&path, r#"
      remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end
      remuda._butler_launch('fake', 'lead')
      remuda._butler_launch('fake', 'kid', nil, 'lead')
      remuda._butler_launch('fake', 'other')
      remuda._butler_close_test_calls = {}
      remuda._butler_close_test_unread = 0
      remuda._butler_mail.unread = function() return remuda._butler_close_test_unread end
      remuda.fail = function(message) return message end
      remuda.close = function(name)
        table.insert(remuda._butler_close_test_calls, name)
        return 'closed ' .. name
      end
      remuda.butler.is_idle = function() return remuda._butler_close_test_idle, 'busy' end
      remuda._butler_close_test_idle = true
    "#);
    let leader_id = eval(&path, "return remuda._butler_bus.agents.lead.id");
    let other_id = eval(&path, "return remuda._butler_bus.agents.other.id");
    let cli = |caller_id: &str, args: &str| {
        eval(&path, &format!(
            "local old=remuda.caller; remuda.caller=function() \
             for _, agent in pairs(remuda._butler_bus.agents) do \
               if agent.id == {caller_id:?} then return {{kind='session', session=agent.session_name}} end \
             end; return {{kind='outside'}} end; \
             local result=remuda._extension_commands.butler({{'close', {args}}}, \
               {{env={{REMUDA_BUTLER_AGENT_ID={caller_id:?}}}}}); \
             remuda.caller=old; return result"
        ))
    };
    let not_owner = cli(&other_id, "'kid'");
    assert!(not_owner.contains("only your direct members") && not_owner.ends_with("Next: remuda butler sessions"), "{not_owner}");
    assert_eq!(eval(&path, "return #remuda._butler_close_test_calls"), "0");

    eval(&path, "remuda._butler_close_test_idle = false");
    let busy = cli(&leader_id, "'kid'");
    assert!(busy.contains("is busy") && busy.ends_with("Next: wait for it to become idle, or use --force"), "{busy}");
    assert_eq!(eval(&path, "return #remuda._butler_close_test_calls"), "0");

    eval(&path, "remuda._butler_send('butler', 'kid', 'unread close guard')");
    eval(&path, "remuda._butler_close_test_unread = 1");
    eval(&path, "remuda._butler_close_test_idle = true");
    let unread = cli(&leader_id, "'kid'");
    assert!(unread.contains("unread Butler mail") && unread.ends_with("Next: read the inbox, or use --force"), "{unread}");
    assert_eq!(eval(&path, "return #remuda._butler_close_test_calls"), "0");

    let forced = cli(&other_id, "'kid', '--force'");
    assert!(forced.contains("only your direct members"), "--force bypassed ownership: {forced}");
    assert_eq!(eval(&path, "return #remuda._butler_close_test_calls"), "0");
    let forced = cli(&leader_id, "'kid', '--force'");
    assert_eq!(forced, "Closed kid.\nNext: remuda butler sessions");
    assert_eq!(eval(&path, "return remuda._butler_close_test_calls[1]"), "kid");

    for name in ["lead", "butler", "missing"] {
        let result = cli(&leader_id, &format!("{name:?}"));
        assert!(result.contains("cannot close") && result.contains("Next: remuda butler sessions"), "{result}");
    }
}

#[test]
fn butler_close_cli_uses_core_caller_not_forwarded_env() {
    let dir = scratch("butler-close-caller");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(&path, r#"
      remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end
      remuda._butler_launch('fake', 'lead')
      remuda._butler_launch('fake', 'kid', nil, 'lead')
      remuda._butler_launch('fake', 'other')
      remuda._butler_launch('fake', 'other-kid', nil, 'other')
      remuda._butler_mail.unread = function() return 0 end
      remuda.butler.is_idle = function() return true end
      remuda._butler_close_test_calls = {}
      remuda._butler_close_test_native_close = remuda.close
      remuda.close = function(name)
        table.insert(remuda._butler_close_test_calls, name)
        return 'closed ' .. name
      end
      remuda.fail = function(message) return message end
    "#);
    let lead_id = eval(&path, "return remuda._butler_bus.agents.lead.id");
    let other_id = eval(&path, "return remuda._butler_bus.agents.other.id");
    let cli = |kind: &str, session: &str, env_id: &str, name: &str| {
        let env = if env_id.is_empty() { "{}".to_string() } else {
            format!("{{REMUDA_BUTLER_AGENT_ID={env_id:?}}}")
        };
        eval(&path, &format!(
            "local old=remuda.caller; remuda.caller=function() return {{kind={kind:?}, session={session:?}}} end; \
             local result=remuda._extension_commands.butler({{'close', {name:?}, '--force'}}, {{env={env}}}); \
             remuda.caller=old; return result"
        ))
    };

    let cleared = cli("session", "lead", "", "lead");
    assert!(cleared.contains("only your direct members"), "cleared env bypassed ownership: {cleared}");
    let spoofed = cli("session", "lead", &other_id, "other-kid");
    assert!(spoofed.contains("only your direct members"), "spoofed env bypassed ownership: {spoofed}");
    let unknown = cli("unknown", "", &lead_id, "kid");
    assert!(unknown.contains("unknown Butler caller") || unknown.contains("run from a Butler member session"),
        "unknown caller was not refused: {unknown}");
    assert_eq!(eval(&path, "return #remuda._butler_close_test_calls"), "0");

    let outside = eval(&path, &format!(
        "local old=remuda.caller; remuda.caller=function() return {{kind='outside'}} end; \
         local result=remuda._extension_commands.butler({{'close', 'lead', '--force'}}, {{env={{}}}}); \
         remuda.caller=old; return result"
    ));
    assert_eq!(outside, "Closed lead.\nNext: remuda butler sessions");
    assert_eq!(eval(&path, "return remuda._butler_close_test_calls[1]"), "lead");
    eval(&path, "local close=remuda._butler_close_test_native_close; \
      for _, name in ipairs({'kid', 'other-kid', 'lead', 'other'}) do pcall(close, name) end");
}

#[test]
fn butler_close_cli_invokes_real_close_path() {
    let dir = scratch("butler-close-real");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(&path, r#"
      remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end
      remuda._butler_launch('fake', 'real-kid')
      remuda._butler_mail.unread = function() return 0 end
      remuda.butler.is_idle = function() return true end
      remuda.caller = function() return {kind='outside'} end
    "#);
    let result = eval(&path,
        "return remuda._extension_commands.butler({'close', 'real-kid', '--force'}, {env={}})");
    assert_eq!(result, "Closed real-kid.\nNext: remuda butler sessions");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.agents['real-kid'] == nil)"), "true",
        "the real remuda.close path must remove the closed member from bus.agents");
}

#[test]
fn butler_close_is_registered_and_unknown_mcp_caller_cannot_close() {
    let dir = scratch("butler-close-tool");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(&path, "remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end; remuda._butler_launch('fake', 'm1')");
    assert!(listed(&path).contains(&"butler_close".to_string()));
    let reply = call(&path, "butler_close", json!({"name":"m1", "force":true}));
    assert_eq!(reply["result"]["isError"], true, "{reply}");
    assert!(text_of(&reply).contains("unknown caller: run from a Butler session"), "{reply}");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.agents.m1 ~= nil)"), "true");
}

fn screen_of(path: &Path, session: &str, until: &str) -> String {
    let deadline = Instant::now() + PATIENCE;
    loop {
        let screen = eval(path, &format!("return remuda.capture('{session}')"));
        if screen.contains(until) || Instant::now() > deadline {
            return screen;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// #29: a mail notice is typed only when `remuda._butler_notify_policy` lets
/// it; until then notices wait per recipient and arrive as one coalesced line.
#[test]
fn mail_notices_wait_for_the_policy_and_coalesce() {
    let dir = scratch("notice-queue");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        "remuda._butler_agent_builders.fake = function() return {'sh', '-c', 'stty -echo; cat'} end; \
         remuda._butler_launch('fake', 'm1'); \
         remuda._butler_notify_policy = function() return false end",
    );
    eval(&path, "remuda._butler_inbox('m1')"); // fixture Welcome mail never had a notice
    for n in 1..=3 {
        let sent = eval(&path, &format!("return remuda._butler_send('operator', 'm1', 'hi {n}')"));
        assert!(sent.contains("notice deferred"), "{sent}");
    }
    std::thread::sleep(Duration::from_millis(1500));
    assert!(!screen_of(&path, "m1", "").contains("Butler"), "typed while the policy said no");

    eval(&path, "remuda._butler_notify_policy = function() return true end");
    let screen = screen_of(&path, "m1", "3 new Butler messages");
    assert_eq!(screen.matches("3 new Butler messages").count(), 1, "{screen}");
    assert!(!screen.contains("Butler message message-"), "{screen}");
    let notices = "local n = 0 for _, s in pairs(remuda.schedules) do \
                   if s.name == 'butler-notices' then n = n + 1 end end return n";
    assert_eq!(eval(&path, notices), "1");
}

/// Matrix relay mail reaches the same mailbox deposit hook as other mail and
/// should produce its arrival notice there.
#[test]
fn relay_deposit_produces_one_mail_notice() {
    let (path, _daemon) = butler_with_member("relay-notice-deposit");
    let got = eval(
        &path,
        r#"
        local real_ls, real_capture, real_capture_styled, real_session =
          remuda.ls, remuda.capture, remuda.capture_styled, remuda.session
        local row = { name = 'butler', alive = true, attached = false }
        remuda.ls = function() return { row } end
        remuda.capture = function() return '> ' end
        remuda.capture_styled = nil
        remuda.session = function() return { is_busy = false } end
        local policy, t = remuda._butler_notify_policy, 0
        remuda._butler_notice_clock = function() return t end
        remuda._butler_notify_policy = function(session) return policy(session, t) end
        remuda._relay_notice_calls = 0
        remuda.type_text = function(_, text)
          remuda._relay_notice_calls = remuda._relay_notice_calls + 1
          remuda._relay_notice_text = text
          return true
        end
        local sender = '@alice:example.org'
        local delivered = remuda.emit_until_success('butler/deliver', {
          from = { host = 'matrix', id = '', alias = sender, session = sender,
            kind = 'matrix', leader = '' },
          to = 'butler', text = 'hello from Matrix', subject = 'Matrix message from ' .. sender,
          matrix = { sender = sender, room_id = '!notice:example.org', event_id = '$notice-deposit' },
        })
        t = 2
        remuda._butler_deliver_notices()
        local expected = 'Butler message ' .. delivered.id .. ' from ' .. sender
          .. ' arrived. Read it: remuda butler inbox'
        remuda.ls, remuda.capture, remuda.capture_styled, remuda.session =
          real_ls, real_capture, real_capture_styled, real_session
        return tostring(remuda._relay_notice_calls) .. '\n'
          .. tostring(remuda._relay_notice_text) .. '\n' .. expected
        "#,
    );
    let mut lines = got.lines();
    assert_eq!(lines.next(), Some("1"), "relay deposit should type exactly one notice: {got}");
    let actual = lines.next();
    let expected = lines.next();
    assert_eq!(actual, expected, "relay notice text should name its Matrix sender: {got}");
}

#[test]
fn forward_mail_notice_names_the_forwarder() {
    let (path, _daemon) = butler_with_member("notice-forwarder-text");
    setup_mail_notice_clock_for(&path, "m1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local root = remuda._butler_bus.agents.butler
        remuda._butler_send('operator', 'butler', 'original message')
        local ids = remuda._butler_mail.mailbox(root.id)
        local id = ids[#ids]
        remuda._butler_inbox('butler')
        remuda._butler_forward('operator', id, 'm1')
        state.now = 2
        remuda._butler_deliver_notices()
        return tostring(#state.typed) .. '\n' .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    let mut lines = got.lines();
    assert_eq!(lines.next(), Some("1"), "forward should type exactly one notice: {got}");
    assert!(
        lines.next().unwrap_or_default().contains("forwarded by operator"),
        "forward notice should name the forwarder: {got}"
    );
}

#[test]
fn notice_failure_does_not_fail_the_mail_deposit_hook() {
    let (path, _daemon) = butler_with_member("notice-deposit-error");
    let trace = path.parent().unwrap().join("session-trace.log");
    let got = eval(
        &path,
        &format!(
            r#"remuda._butler_session_trace_path = {trace:?}
            remuda._butler_notify = function() error('notify injected error') end
            local sender = '@alice:example.org'
            local delivered = remuda.emit_until_success('butler/deliver', {{
              from = {{ host = 'matrix', id = '', alias = sender, session = sender,
                kind = 'matrix', leader = '' }},
              to = 'butler', text = 'mail survives notice error', subject = 'Matrix message from ' .. sender,
              matrix = {{ sender = sender, room_id = '!notice:example.org', event_id = '$notice-error' }},
            }})
            return tostring(delivered.id) .. '|' .. tostring(remuda._butler_mail.is_unread(
              remuda._butler_bus.agents.butler.id, delivered.id))"#
        ),
    );
    assert!(got.ends_with("|true"), "notice failure turned deposit into a hook error or lost mail: {got}");
    let log = std::fs::read_to_string(&trace).expect("notice error trace");
    assert_eq!(log.lines().filter(|line| {
        line.contains("notice_delivery_error\tbutler ") && line.contains("notify injected error")
    }).count(), 1, "{log}");
}

#[test]
fn a_single_mail_notice_waits_for_two_quiet_seconds() {
    let (path, _daemon) = butler_with_member("notice-single-debounce");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        remuda._notice_test_send('m1', 'one')
        state.now = 1.99
        remuda._butler_deliver_notices()
        local early = #state.typed
        state.now = 2
        remuda._butler_deliver_notices()
        return tostring(early) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].at) .. '|'
          .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    assert!(got.starts_with("0|1|2|Butler message "), "single mail debounce timing: {got}");
}

#[test]
fn root_butler_seeds_three_unread_mails_when_its_pane_is_ready() {
    let dir = scratch("notice-unread-root");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    exec_isolated_butler(&path);
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.butler = true
        for i = 1, 3 do remuda._notice_test_send('butler', 'root restart ' .. i) end
        -- Fresh daemon state has lost the deposit notice, but not mailbox mail.
        remuda._butler_bus.notices = {}
        remuda._butler_bus.notice_seen = {}
        remuda._butler_bus.unread_seeded = {}
        remuda._butler_deliver_notices()
        local before_ready = #state.typed
        state.busy.butler = false
        remuda._butler_deliver_notices()
        local before_debounce = #state.typed
        state.now = 1.99
        remuda._butler_deliver_notices()
        local early = #state.typed
        state.now = 2
        remuda._butler_deliver_notices()
        return table.concat({ tostring(before_ready), tostring(before_debounce), tostring(early),
          tostring(#state.typed), tostring(state.typed[1] and state.typed[1].text) }, '|')
        "#,
    );
    assert_eq!(
        got,
        "0|0|0|1|3 new Butler messages arrived. Read them: remuda butler inbox"
    );
}

#[test]
fn root_butler_reseeds_after_in_daemon_relaunch_without_instance_ids() {
    let dir = scratch("notice-unread-root-relaunch");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    exec_isolated_butler(&path);
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        remuda.capture = function() return state.screen or '> ' end
        remuda.type_text = function(_, text)
          state.typed[#state.typed + 1] = { at = state.now, text = text }
          state.screen = text .. '\n> '
          return true
        end
        remuda._notice_test_send('butler', 'root unread mail')
        state.now = 2
        remuda._butler_deliver_notices()
        state.now = 3
        remuda._butler_deliver_notices()
        local first_count = #state.typed
        remuda._butler_reconcile = function() end
        remuda._butler_session_exited('butler')
        local exit_marker = remuda._butler_bus.unread_seeded.butler
        state.screen = '> '
        state.now = 4
        remuda._butler_deliver_notices()
        local after_exit_tick = #state.typed
        state.now = 6
        remuda._butler_deliver_notices()
        state.now = 7
        remuda._butler_deliver_notices()
        state.now = 20
        remuda._butler_deliver_notices()
        return table.concat({ tostring(first_count), tostring(exit_marker),
          tostring(after_exit_tick), tostring(#state.typed) }, '|')
        "#,
    );
    assert!(got.starts_with("1|exited|1|2"), "root relaunch should re-seed exactly once: {got}");
}

#[test]
fn a_lead_session_gets_one_seeded_notice_when_ready() {
    let (path, _daemon) = butler_with_named_agent("notice-unread-lead", "lead1", "fake");
    eval(
        &path,
        "remuda._butler_topic_delegate('report1', 'task', nil, 'fake', 'lead1'); \
         remuda._butler_inbox('report1')",
    );
    setup_mail_notice_clock_for(&path, "lead1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.lead1 = true
        remuda._notice_test_send('lead1', 'lead waiting mail')
        remuda._butler_bus.notices = {}
        remuda._butler_bus.notice_seen = {}
        remuda._butler_bus.unread_seeded = {}
        remuda._butler_deliver_notices()
        local before_ready = #state.typed
        state.busy.lead1 = false
        remuda._butler_deliver_notices()
        state.now = 2
        remuda._butler_deliver_notices()
        return tostring(before_ready) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].text:match(
            '^Butler message .+ from operator arrived%. Read it: remuda butler inbox$') ~= nil)
          .. '|' .. #remuda._butler_bus.agents.lead1.children
        "#,
    );
    assert_eq!(got, "0|1|true|1");
}

#[test]
fn a_codex_agent_gets_one_seeded_notice_when_ready() {
    let (path, _daemon) = butler_with_named_agent("notice-unread-codex", "codex1", "codex");
    setup_mail_notice_clock_for(&path, "codex1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.codex1 = true
        remuda._notice_test_send('codex1', 'codex waiting mail')
        remuda._butler_bus.notices = {}
        remuda._butler_bus.notice_seen = {}
        remuda._butler_bus.unread_seeded = {}
        remuda._butler_deliver_notices()
        local before_ready = #state.typed
        state.busy.codex1 = false
        remuda._butler_deliver_notices()
        state.now = 2
        remuda._butler_deliver_notices()
        return tostring(before_ready) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].text:match(
            '^Butler message .+ from operator arrived%. Read it: remuda butler inbox$') ~= nil)
          .. '|' .. remuda._butler_bus.agents.codex1.kind
        "#,
    );
    assert_eq!(got, "0|1|true|codex");
}

#[test]
fn restart_seeds_three_unread_mails_only_when_the_pane_is_ready() {
    let (path, _daemon) = butler_with_member("notice-unread-restart");
    eval(&path, "remuda._butler_inbox('m1')");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.m1 = true
        for i = 1, 3 do remuda._notice_test_send('m1', 'restart ' .. i) end
        -- A daemon restart loses the in-memory pending notice and dedupe state,
        -- but leaves the persisted unread mailbox intact.
        remuda._butler_bus.notices = {}
        remuda._butler_bus.notice_seen = {}
        remuda._butler_bus.unread_seeded = {}
        remuda._butler_deliver_notices()
        local before_ready = #state.typed
        state.busy.m1 = false
        remuda._butler_deliver_notices()
        local before_debounce = #state.typed
        state.now = 1.99
        remuda._butler_deliver_notices()
        local early = #state.typed
        state.now = 2
        remuda._butler_deliver_notices()
        return table.concat({ tostring(before_ready), tostring(before_debounce), tostring(early),
          tostring(#state.typed), tostring(state.typed[1] and state.typed[1].text) }, '|')
        "#,
    );
    assert_eq!(
        got,
        "0|0|0|1|3 new Butler messages arrived. Read them: remuda butler inbox"
    );
}

#[test]
fn a_relaunch_replays_already_noticed_unread_mail_once() {
    let (path, _daemon) = butler_with_member("notice-unread-relaunch-instance");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local rows = {
          { name = 'm1', alive = true, attached = false, instance_id = 'instance-a' },
          { name = 'butler', alive = true, attached = false, instance_id = 'root-instance' },
        }
        remuda.ls = function() return rows end
        remuda.capture = function() return state.screen or '> ' end
        remuda.type_text = function(_, text)
          state.typed[#state.typed + 1] = { at = state.now, text = text }
          state.screen = text .. '\n> '
          return true
        end
        remuda._notice_test_send('m1', 'already noticed but unread')
        state.now = 2
        remuda._butler_deliver_notices()
        state.now = 3
        remuda._butler_deliver_notices() -- verify the first notice left the composer
        local id = state.typed[1].text:match('Butler message ([^ ]+)')
        local seen_a = remuda._butler_bus.notice_seen[remuda._butler_bus.agents.m1.id][id]
        local typed_a = #state.typed
        rows[1].instance_id = 'instance-b'
        state.screen = '> '
        state.now = 4
        remuda._butler_deliver_notices()
        local typed_before_debounce = #state.typed
        state.now = 6
        remuda._butler_deliver_notices()
        state.now = 7
        remuda._butler_deliver_notices() -- verify the replayed notice
        state.now = 8
        remuda._butler_deliver_notices()
        state.now = 20
        remuda._butler_deliver_notices()
        return table.concat({ tostring(typed_a), tostring(seen_a),
          tostring(typed_before_debounce), tostring(#state.typed),
          tostring(state.typed[2] and state.typed[2].text),
          tostring(remuda._butler_bus.unread_seeded.m1 == 'instance-b') }, '|')
        "#,
    );
    assert!(got.starts_with("1|true|1|2|Butler message "), "relaunch replay: {got}");
    assert!(got.contains("|true"), "relaunch instance was not marked seeded: {got}");
}

#[test]
fn an_exit_tick_keeps_the_unread_seed_for_a_same_id_relaunch() {
    let (path, _daemon) = butler_with_member("notice-unread-exit-tick-relaunch");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local bus = remuda._butler_bus
        local rows = {
          { name = 'm1', alive = true, attached = false, instance_id = 'instance-a' },
          { name = 'butler', alive = true, attached = false, instance_id = 'root-instance' },
        }
        remuda.ls = function() return rows end
        remuda.capture = function() return state.screen or '> ' end
        remuda.type_text = function(_, text)
          state.typed[#state.typed + 1] = { at = state.now, text = text }
          state.screen = text .. '\n> '
          return true
        end
        remuda._notice_test_send('m1', 'same-id relaunch unread mail')
        state.now = 2
        remuda._butler_deliver_notices()
        state.now = 3
        remuda._butler_deliver_notices() -- verify the first notice left the composer
        local id = state.typed[1].text:match('Butler message ([^ ]+)')
        local saved_agent = bus.agents.m1
        local first_notice = #state.typed

        -- A real member exit clears its agent record and preserves this marker.
        bus.agents.m1 = nil
        bus.unread_seeded.m1 = 'exited'
        bus.notices.m1, bus.notice_screens.m1, bus.pending_tasks.m1 = nil, nil, nil
        bus.notice_recoveries.m1, bus.task_retry_screens.m1, bus.human_activity_screens.m1 = nil, nil, nil
        rows[1] = nil
        state.now = 4
        remuda._butler_deliver_notices() -- one tick during the relaunch gap

        -- Codex update restarts the member under the same Butler identity id.
        bus.agents.m1 = {
          id = saved_agent.id, alias = saved_agent.alias, kind = saved_agent.kind,
          parent = saved_agent.parent, children = {}, session_instance_id = 'instance-b',
        }
        rows[1] = { name = 'm1', alive = true, attached = false, instance_id = 'instance-b' }
        state.screen = '> '
        state.now = 8
        remuda._butler_deliver_notices()
        state.now = 10
        remuda._butler_deliver_notices()
        state.now = 11
        remuda._butler_deliver_notices() -- verify the replayed notice
        local second_notice = #state.typed
        local replay_id = state.typed[2] and state.typed[2].text:match('Butler message ([^ ]+)')
        local unread = remuda._butler_mail.unread(bus.agents.m1.id)
        return table.concat({ tostring(first_notice), tostring(second_notice),
          tostring(id == replay_id), tostring(bus.unread_seeded.m1 == 'instance-b'),
          tostring(unread), tostring(bus.notice_seen[bus.agents.m1.id][id]) }, '|')
        "#,
    );
    assert_eq!(got, "1|2|true|true|1|true", "same-id relaunch replay: {got}");
}

#[test]
fn unread_seed_waits_for_pending_task_and_codex_update_handoffs() {
    let (path, _daemon) = butler_with_member("notice-unread-seed-gates");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local bus = remuda._butler_bus
        remuda._notice_test_send('m1', 'waiting for startup gates')
        bus.notices, bus.notice_seen, bus.unread_seeded = {}, {}, {}
        local blocked = {}
        bus.pending_tasks.m1 = 'pending task'
        remuda._butler_deliver_notices()
        blocked[#blocked + 1] = #state.typed == 0 and bus.unread_seeded.m1 == nil
        bus.pending_tasks.m1 = nil
        bus.codex_update_state.owner = 'm1'
        remuda._butler_deliver_notices()
        blocked[#blocked + 1] = #state.typed == 0 and bus.unread_seeded.m1 == nil
        bus.codex_update_state.owner = nil
        bus.codex_update_state.waiting.m1 = true
        remuda._butler_deliver_notices()
        blocked[#blocked + 1] = #state.typed == 0 and bus.unread_seeded.m1 == nil
        bus.codex_update_state.waiting.m1 = nil
        bus.codex_update_state.restart_waiting.m1 = true
        remuda._butler_deliver_notices()
        blocked[#blocked + 1] = #state.typed == 0 and bus.unread_seeded.m1 == nil
        bus.codex_update_state.restart_waiting.m1 = nil
        bus.codex_update_relaunches.m1 = { version = 'test handoff' }
        remuda._butler_deliver_notices()
        blocked[#blocked + 1] = #state.typed == 0 and bus.unread_seeded.m1 == nil
        bus.codex_update_relaunches.m1 = nil
        remuda._butler_deliver_notices()
        state.now = 2
        remuda._butler_deliver_notices()
        local all_blocked = true
        for _, value in ipairs(blocked) do all_blocked = all_blocked and value end
        return tostring(all_blocked) .. '|' .. tostring(#state.typed) .. '|'
          .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    assert!(got.starts_with("true|1|Butler message "), "seed handoff gates: {got}");
}

#[test]
fn unread_seed_tokens_are_pruned_when_an_agent_disappears() {
    let (path, _daemon) = butler_with_member("notice-unread-seed-prune");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local bus = remuda._butler_bus
        bus.unread_seeded.gone = 'old agent record'
        remuda._butler_deliver_notices()
        local after_exit = bus.unread_seeded.gone
        local agent_record = bus.agents.gone
        remuda._notice_test_state.now = 30 * 24 * 60 * 60 + 1
        remuda._butler_deliver_notices()
        return table.concat({ tostring(after_exit), tostring(agent_record),
          tostring(bus.unread_seeded.gone), tostring(bus.agents.gone) }, '|')
        "#,
    );
    assert_eq!(got, "exited|nil|nil|nil", "exit marker cleanup: {got}");
}

#[test]
fn a_new_member_gets_waiting_mail_after_its_launch_brief() {
    let (path, _daemon) = butler_with_member("notice-unread-new-member");
    eval(&path, "remuda._butler_inbox('m1')");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        -- Model mail already waiting while the launch brief keeps the pane busy.
        state.busy.m1 = true
        remuda._notice_test_send('m1', 'waiting for launch')
        remuda._butler_bus.notices = {}
        remuda._butler_bus.notice_seen = {}
        remuda._butler_bus.unread_seeded = {}
        remuda._butler_deliver_notices()
        local before_brief = #state.typed
        state.busy.m1 = false -- the welcome/launch brief has settled
        remuda._butler_deliver_notices()
        state.now = 2
        remuda._butler_deliver_notices()
        local text = state.typed[1] and state.typed[1].text
        return tostring(before_brief) .. '|' .. #state.typed .. '|'
          .. tostring(text and text:match('^Butler message .+ from operator arrived%. Read it: remuda butler inbox$') ~= nil)
        "#,
    );
    assert_eq!(got, "0|1|true");
}

#[test]
fn no_unread_mail_does_not_seed_a_notice() {
    let (path, _daemon) = butler_with_member("notice-unread-empty");
    eval(&path, "remuda._butler_inbox('m1')");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local policies, captures = 0, 0
        remuda.capture = function()
          captures = captures + 1
          return '> '
        end
        remuda._butler_notify_policy = function()
          policies = policies + 1
          remuda.capture()
          return true
        end
        remuda._butler_deliver_notices()
        state.now = 10
        remuda._butler_deliver_notices()
        return table.concat({ tostring(#state.typed), tostring(remuda._butler_bus.notices.m1),
          tostring(policies), tostring(captures) }, '|')
        "#,
    );
    assert_eq!(got, "0|nil|0|0", "zero-unread startup should skip the pane policy: {got}");
}

#[test]
fn a_pending_deposit_notice_is_not_duplicated_by_unread_seeding() {
    let (path, _daemon) = butler_with_member("notice-unread-pending-deposit");
    eval(&path, "remuda._butler_inbox('m1')");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.m1 = true
        remuda._notice_test_send('m1', 'already pending')
        local count_before = remuda._butler_bus.notices.m1.count
        local notify, calls = remuda._butler_notify, 0
        remuda._butler_notify = function(...)
          calls = calls + 1
          return notify(...)
        end
        state.busy.m1 = false
        remuda._butler_deliver_notices()
        state.now = 2
        remuda._butler_deliver_notices()
        local text = state.typed[1] and state.typed[1].text
        return table.concat({ tostring(count_before), tostring(calls), tostring(#state.typed),
          tostring(text and text:match('^Butler message .+ from operator arrived%. Read it: remuda butler inbox$') ~= nil),
          tostring(remuda._butler_bus.unread_seeded.m1 ~= nil) }, '|')
        "#,
    );
    assert_eq!(got, "1|0|1|true|true");
}

#[test]
fn five_mail_notice_waits_for_two_quiet_seconds_after_the_last_mail() {
    let (path, _daemon) = butler_with_member("notice-burst-debounce");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        for i = 1, 5 do
          state.now = (i - 1) * 0.5
          remuda._notice_test_send('m1', tostring(i))
        end
        state.now = 3.99
        remuda._butler_deliver_notices()
        local early = #state.typed
        state.now = 4
        remuda._butler_deliver_notices()
        return tostring(early) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].at) .. '|'
          .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    assert_eq!(got, "0|1|4|5 new Butler messages arrived. Read them: remuda butler inbox");
}

#[test]
fn mail_arriving_each_second_fires_by_the_ten_second_maximum() {
    let (path, _daemon) = butler_with_member("notice-max-wait");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        for i = 1, 10 do
          state.now = i - 1
          remuda._notice_test_send('m1', tostring(i))
        end
        state.now = 9.99
        remuda._butler_deliver_notices()
        local early = #state.typed
        state.now = 10
        remuda._butler_deliver_notices()
        return tostring(early) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].at) .. '|'
          .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    assert_eq!(got, "0|1|10|10 new Butler messages arrived. Read them: remuda butler inbox");
}

#[test]
fn notices_arriving_during_verification_get_a_fresh_debounce_window() {
    let (path, _daemon) = butler_with_member("notice-verification-next-batch");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.screen = '> '
        remuda.capture = function() return state.screen end
        remuda.type_text = function(_, text)
          state.typed[#state.typed + 1] = { at = state.now, text = text }
          state.screen = text .. '\n> '
          return true
        end
        remuda._notice_test_send('m1', 'first batch')
        state.now = 2
        remuda._butler_deliver_notices()
        state.now = 9
        remuda._notice_test_send('m1', 'during verification')
        remuda._butler_deliver_notices()
        local pending = remuda._butler_bus.notices.m1
        local first_at, due_at = pending.first_at, pending.due_at
        state.now = 9.5
        remuda._notice_test_send('m1', 'trailing mail')
        state.now = 10
        remuda._butler_deliver_notices()
        local before_due = #state.typed
        state.now = 11.5
        remuda._butler_deliver_notices()
        return table.concat({ tostring(#state.typed - 1), tostring(first_at), tostring(due_at),
          tostring(before_due), tostring(#state.typed), tostring(state.typed[2] and state.typed[2].text) }, '|')
        "#,
    );
    assert_eq!(got, "1|9|11|1|2|2 new Butler messages arrived. Read them: remuda butler inbox");
}

#[test]
fn five_relay_mails_wait_until_a_busy_pane_is_free_and_coalesce() {
    let (path, _daemon) = butler_with_member("notice-relay-busy");
    setup_mail_notice_clock(&path);
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.busy.butler = true
        for i = 1, 5 do remuda._notice_test_relay('$busy-' .. i) end
        state.now = 2
        remuda._butler_deliver_notices()
        local busy = #state.typed
        state.busy.butler = false
        remuda._butler_deliver_notices()
        return tostring(busy) .. '|' .. #state.typed .. '|'
          .. tostring(state.typed[1] and state.typed[1].at) .. '|'
          .. tostring(state.typed[1] and state.typed[1].text)
        "#,
    );
    assert_eq!(got, "0|1|2|5 new Butler messages arrived. Read them: remuda butler inbox");
}

/// #29: one case per branch of `remuda._butler_notify_policy`, with `ls` and
/// `capture` stubbed and the clock passed in.
#[test]
fn notify_policy_types_only_into_a_detached_or_quiet_empty_prompt() {
    let dir = scratch("notice-policy");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    let trace = dir.join("session-trace.log");
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    let got = eval(
        &path,
        &format!(
            r#"remuda._butler_session_trace_path = {trace:?}
            local real_ls, real_capture, real_capture_styled, real_session = remuda.ls, remuda.capture, remuda.capture_styled, remuda.session
            remuda.capture_styled = nil
            local row, screen = {{ name = 'p1', alive = true, attached = true }}, ''
            remuda.ls = function() return {{ row }} end
            remuda.capture = function() return screen end
            remuda.session = function() return {{ is_busy = false }} end
            local policy, t = remuda._butler_notify_policy, 0
            local function settled(text) t = t + 100; screen = text; policy('p1', t); return policy('p1', t + 3) end
            local r = {{}}
            r[#r + 1] = 'half=' .. tostring(settled('history\n> co'))
            r[#r + 1] = 'empty_stable=' .. tostring(settled('history\n> '))
            r[#r + 1] = 'claude_box=' .. tostring(settled('──\n│ ❯     │\n  ? for shortcuts'))
            r[#r + 1] = 'claude_nbsp=' .. tostring(settled('──\n❯\u{{A0}}\n──'))
            r[#r + 1] = 'claude_nbsp_typed=' .. tostring(settled('──\n❯\u{{A0}}co\n──'))
            t = t + 100; screen = 'a\n> '; policy('p1', t); screen = 'b\n> '
            r[#r + 1] = 'empty_changing=' .. tostring(policy('p1', t + 3))
            r[#r + 1] = 'unparseable=' .. tostring(settled('Do you trust this folder?'))
            remuda._butler_bus.agents.p1 = {{ kind = 'codex' }}
            r[#r + 1] = 'codex_placeholder=' .. tostring(settled('› Ask Codex to do anything'))
            r[#r + 1] = 'codex_typed=' .. tostring(settled('› Ask Codex to do anything else'))
            remuda._butler_bus.agents.p1 = nil
            row.attached = false; screen = 'x\n> co'
            r[#r + 1] = 'detached=' .. tostring(policy('p1', t + 500))
            screen = 'x\n> '
            r[#r + 1] = 'detached_empty=' .. tostring(policy('p1', t + 501))
            remuda.session = function() return nil end
            r[#r + 1] = 'detached_unknown=' .. tostring(policy('p1', t + 502))
            remuda.session = function() error('busy state unavailable') end
            r[#r + 1] = 'detached_busy_error=' .. tostring(policy('p1', t + 503))
            remuda.ls, remuda.capture, remuda.capture_styled, remuda.session = real_ls, real_capture, real_capture_styled, real_session
            return table.concat(r, ' ')"#
        ),
    );
    assert_eq!(
        got,
        "half=false empty_stable=true claude_box=true claude_nbsp=true claude_nbsp_typed=false empty_changing=false unparseable=false \
         codex_placeholder=true codex_typed=false detached=false detached_empty=true detached_unknown=true detached_busy_error=true"
    );
    let log = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(log.contains("notice_prompt\tmessage_ids= session=p1 kind= decision=NON-EMPTY composer_bytes=2"), "{log}");
    assert!(log.contains("notice_prompt\tmessage_ids= session=p1 kind= decision=UNPARSEABLE composer_bytes=0"), "{log}");
}

#[test]
fn codex_trace_row_followed_by_user_draft_is_not_empty_or_typed_over() {
    let (path, _daemon) = butler_with_member("codex-trace-row-draft");
    let got = eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        local screen = '› 2026-10-01T12:00:00Z ERROR foo::bar: why?\nWhat is the status?'
        remuda.ls = function() return { row } end
        remuda.capture = function() return screen end
        remuda.capture_styled = nil
        remuda.session = function() return { is_busy = false } end
        remuda._butler_bus.agents.m1.kind = 'codex'
        remuda._notice_now = 0
        remuda._butler_notice_clock = function() return remuda._notice_now end
        remuda._notice_test_typed = 0
        remuda.type_text = function() remuda._notice_test_typed = remuda._notice_test_typed + 1 end
        local decision = remuda._butler_prompt_is_empty('codex', screen)
        remuda._butler_send('operator', 'm1', 'hello')
        remuda._notice_now = 2
        remuda._butler_deliver_notices()
        return decision .. '|' .. tostring(remuda._notice_test_typed)
        "#,
    );
    assert_eq!(got, "NON-EMPTY|0", "a trace-looking draft must be preserved: {got}");
}

fn butler_with_member(tag: &str) -> (PathBuf, impl Drop) {
    let dir = scratch(tag);
    let path = daemon::socket_path_in(&dir, "s");
    let daemon = daemon_at(&path);
    exec_isolated_butler(&path);
    eval(
        &path,
        "remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end; \
         remuda._butler_launch('fake', 'm1')",
    );
    // The Welcome mail is queued without a notice; read it so the unread seed
    // does not add it to the notices a test counts.
    eval(&path, "remuda._butler_inbox('m1')");
    (path, daemon)
}

fn butler_with_named_agent(tag: &str, alias: &str, kind: &str) -> (PathBuf, impl Drop) {
    let dir = scratch(tag);
    let path = daemon::socket_path_in(&dir, "s");
    let daemon = daemon_at(&path);
    exec_isolated_butler(&path);
    let launch = format!(
        "remuda._butler_agent_builders[{kind}] = function() return {{'sleep', '100'}} end; \
         remuda._butler_launch({kind}, {alias})",
        kind = serde_json::to_string(kind).unwrap(),
        alias = serde_json::to_string(alias).unwrap(),
    );
    eval(&path, &launch);
    let inbox = format!("remuda._butler_inbox({})", serde_json::to_string(alias).unwrap());
    eval(&path, &inbox);
    (path, daemon)
}

/// Test daemons share one process, so one XDG data home: skip loading its
/// agents.jsonl so this root Butler gets its own identity and unread mailbox.
fn exec_isolated_butler(path: &Path) {
    eval(path, "remuda._butler_bus = { agents = {}, tokens = {}, inboxes = {}, messages = {}, \
        objects = {}, next = 0, identities_loaded = true }; \
        remuda._butler_argv = {'sh'}; remuda.exec('butler')");
}

fn setup_mail_notice_clock(path: &Path) {
    eval(
        path,
        r#"
        local state = { now = 0, busy = {}, typed = {} }
        remuda._notice_test_state = state
        remuda._butler_notice_clock = function() return state.now end
        remuda.ls = function() return {
          { name = 'm1', alive = true, attached = false },
          { name = 'butler', alive = true, attached = false },
        } end
        remuda.session = function(name) return { is_busy = state.busy[name] == true } end
        remuda.capture = function() return '> ' end
        remuda.capture_styled = nil
        remuda._butler_notify_policy = function(name) return state.busy[name] ~= true end
        remuda.type_text = function(_, text)
          state.typed[#state.typed + 1] = { at = state.now, text = text }
          return true
        end
        remuda._notice_test_send = function(alias, text)
          return remuda._butler_send('operator', alias, text)
        end
        remuda._notice_test_relay = function(event_id)
          local sender = '@alice:example.org'
          return remuda.emit_until_success('butler/deliver', {
            from = { host = 'matrix', id = '', alias = sender, session = sender,
              kind = 'matrix', leader = '' },
            to = 'butler', text = 'relay ' .. event_id, subject = 'Matrix message from ' .. sender,
            matrix = { sender = sender, room_id = '!notice:example.org', event_id = event_id },
          })
        end
        "#,
    );
}

fn setup_mail_notice_clock_for(path: &Path, alias: &str) {
    setup_mail_notice_clock(path);
    let sessions = format!(
        "remuda.ls = function() return {{ {{ name = {alias}, alive = true, attached = false }}, \
         {{ name = 'butler', alive = true, attached = false }} }} end",
        alias = serde_json::to_string(alias).unwrap(),
    );
    eval(path, &sessions);
}

#[test]
fn prompt_parser_returns_multiline_task_and_stops_at_codex_footer() {
    let (path, _daemon) = butler_with_member("prompt-parser-multiline");
    let parsed = eval(
        &path,
        r#"local decision, text = remuda._butler_prompt_is_empty('codex',
          'Ask Codex\n› START task\nsecond task line\nEND task\nGPT-6-Luna medium · ~/projects/ids · task\n? for shortcuts\n98% context left')
        return decision .. '\n' .. text"#,
    );
    assert_eq!(parsed, "NON-EMPTY\nSTART task\nsecond task line\nEND task");
}

/// #29 review 1: a notice whose type_text fails stays queued for the retry.
#[test]
fn a_notice_that_fails_to_type_stays_queued() {
    let (path, _daemon) = butler_with_member("notice-type-fails");
    let sent = eval(
        &path,
        "remuda._notice_now = 0; \
         remuda._butler_notice_clock = function() return remuda._notice_now end; \
         remuda._butler_notify_policy = function() return true end; \
         remuda._real_type_text = remuda.type_text; \
         remuda.type_text = function() error('pty write failed') end; \
         local sent = remuda._butler_send('operator', 'm1', 'hi'); \
         remuda._notice_now = 2; remuda._butler_deliver_notices(); return sent",
    );
    assert!(sent.contains("notice deferred"), "{sent}");
    assert_eq!(eval(&path, "return remuda._butler_bus.notices.m1.count"), "1");
    eval(
        &path,
        "remuda.type_text = remuda._real_type_text; \
         remuda.capture = function() \
           return remuda._butler_bus.notices.m1.text .. '\\n❯ ' \
         end; \
         remuda._butler_deliver_notices()",
    );
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        assert!(Instant::now() < deadline, "successfully submitted notice was not verified");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1)"), "nil");
}

#[test]
fn a_busy_notice_input_retries_on_the_next_tick() {
    let (path, _daemon) = butler_with_member("notice-input-busy-retry");
    eval(
        &path,
        r#"
        remuda._butler_notify_policy = function() return true end
        remuda._notice_now = 0
        remuda._butler_notice_clock = function() return remuda._notice_now end
        remuda._notice_busy_calls = 0
        remuda.type_text = function(_, text)
          remuda._notice_busy_calls = remuda._notice_busy_calls + 1
          if remuda._notice_busy_calls == 1 then error('a session input write is already in flight') end
          remuda._notice_typed = text
          return true
        end
        remuda._butler_send('operator', 'm1', 'retry me')
        "#,
    );
    assert_eq!(eval(&path, "return tostring(remuda._notice_busy_calls)"), "0");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1.count)"), "1");
    eval(&path, "remuda._notice_now = 2; remuda._butler_deliver_notices()");
    assert_eq!(eval(&path, "return tostring(remuda._notice_busy_calls)"), "1");
    eval(&path, "remuda._butler_deliver_notices()");
    assert_eq!(eval(&path, "return tostring(remuda._notice_busy_calls)"), "2");
    assert_ne!(eval(&path, "return tostring(remuda._notice_typed)"), "nil");
}

#[test]
fn a_non_busy_error_containing_busy_is_not_retried_as_input_lock() {
    let (path, _daemon) = butler_with_member("notice-false-busy-error");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = false } end
        remuda._butler_human_active = function() return false end
        remuda.capture = function() return '❯ ' end
        remuda._notice_busy_error_calls = 0
        remuda.type_text = function()
          remuda._notice_busy_error_calls = remuda._notice_busy_error_calls + 1
          error('disk is busy while the terminal write failed')
        end
        remuda._notice_busy_error_report = nil
        remuda._butler_send = function(_, _, text)
          remuda._notice_busy_error_report = text
          return 'captured report'
        end
        remuda._butler_bus.notices.m1 = { count = 1, text = 'pending' }
        local recovery = {
          phase = 'retry_type', checks = 0, notice = 'pending', count = 1,
        }
        remuda._butler_bus.notice_recoveries.m1 = recovery
        remuda._butler_deliver_notices()
        remuda._notice_recovery_failed = recovery.failed
        "#,
    );
    assert_eq!(eval(&path, "return tostring(remuda._notice_busy_error_calls)"), "1");
    assert_eq!(eval(&path, "return tostring(remuda._notice_recovery_failed)"), "true");
    assert!(
        eval(&path, "return tostring(remuda._notice_busy_error_report)")
            .contains("the notice could not be typed"),
        "non-Busy type_text failure was not reported"
    );
    assert!(!eval(&path, "return tostring(remuda._notice_busy_error_report)").contains("disk is busy"));
}

/// #82: notice submit verification accepts Claude's soft-wrapped composer in
/// a narrow 27-column pane, then retries Return once if the draft remains.
#[test]
fn narrow_claude_wrapped_notice_is_verified_and_submitted() {
    let (path, _daemon) = butler_with_member("notice-narrow-wrap");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        local state = { columns = 27, events = {}, screen = '❯ \n', submitted = false, busy = false }
        remuda._notice_test_state = state
        remuda._butler_bus.agents.m1.kind = 'claude'
        remuda.capture_styled = nil
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = state.busy } end
        remuda.capture = function() return state.screen end
        remuda._butler_notify_policy = function() return true end
        local function render_notice(text)
          local rows, width, line = {}, state.columns - 2, '' -- ❯ and continuation indent each occupy two columns
          local function push(prefix, value)
            rows[#rows + 1] = prefix .. value .. string.rep(' ', state.columns - 2 - #value)
          end
          local function append_word(word)
            while #word > width do
              if line ~= '' then push(#rows == 0 and '❯ ' or '  ', line); line = '' end
              push(#rows == 0 and '❯ ' or '  ', word:sub(1, width))
              word = word:sub(width + 1)
            end
            if line == '' then line = word
            elseif #line + 1 + #word <= width then line = line .. ' ' .. word
            else push(#rows == 0 and '❯ ' or '  ', line); line = word end
          end
          for word in text:gmatch('%S+') do append_word(word) end
          push(#rows == 0 and '❯ ' or '  ', line)
          local rule = string.rep('─', state.columns)
          local empty_prompt = '❯ ' .. string.rep(' ', state.columns - 2)
          local status = '  MODEL:Opus-5.5 CTX:13925…\n  ⏵⏵ auto mode on      · ←…'
          local screen = rule .. '\n' .. table.concat(rows, '\n') .. '\n' .. rule
          if state.submitted then screen = screen .. '\n' .. empty_prompt .. '\n' .. rule end
          return screen .. '\n' .. status
        end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type')
          state.screen = render_notice(text)
        end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'RET' then
            state.submitted, state.busy = true, true
            state.screen = '❯ ' .. string.rep(' ', state.columns - 2)
            .. '\n' .. string.rep('─', state.columns) .. '\n  MODEL:Opus-5.5 CTX:13925…' end
        end
        remuda._butler_send('operator', 'm1', 'narrow pane notice')
        "#,
    );

    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        eval(&path, "remuda._butler_deliver_notices()");
        assert!(Instant::now() < deadline, "wrapped notice was not safely submitted: {}", eval(&path, "return table.concat(remuda._notice_test_state.events, ',')"));
        std::thread::sleep(Duration::from_millis(50));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, ',')");
    assert!(events.contains("key RET"), "wrapped notice was not submitted: {events}");
    assert_eq!(events.matches("type").count(), 1, "wrapped notice was retyped instead of verified: {events}");
    assert_eq!(events.matches("key RET").count(), 1, "notice submit used more than one Return retry: {events}");
    assert!(!events.contains("key C-u"), "recovery erased its own wrapped notice: {events}");

    eval(
        &path,
        r#"local state = remuda._notice_test_state
        state.events, state.submitted = {}, true
        remuda._butler_send('operator', 'm1', 'history layout notice')"#,
    );
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        eval(&path, "remuda._butler_deliver_notices()");
        assert!(Instant::now() < deadline, "wrapped notice in history was not verified: {}", eval(&path, "return table.concat(remuda._notice_test_state.events, ',')"));
        std::thread::sleep(Duration::from_millis(50));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, ',')");
    assert_eq!(events.matches("type").count(), 1, "history notice was retyped: {events}");
    assert!(!events.contains("key RET"), "already-submitted history notice was submitted twice: {events}");
}

/// #82 decision: a submitted notice in Claude history plus an approval
/// dialog is success even though the empty composer is no longer visible.
#[test]
fn submitted_claude_notice_followed_by_approval_dialog_clears_pending_notice() {
    let (path, _daemon) = butler_with_member("notice-followup-dialog");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        local state = { screen = '❯ \n', events = {}, submitted = false, busy = false }
        remuda._notice_dialog_test_state = state
        remuda._butler_bus.agents.m1 = remuda._butler_bus.agents.m1 or {
          id = '01ARZ3NDEKTSV4RRFFQ69G5FAV', kind = 'claude' }
        remuda._butler_bus.agents.m1.kind = 'claude'
        remuda.capture_styled = nil
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = state.busy } end
        remuda.capture = function() return state.screen end
        remuda._butler_notify_policy = function() return not state.submitted end
        local function box(text)
          return '❯ ' .. text .. string.rep(' ', math.max(0, 78 - #text))
            .. '\n' .. string.rep('─', 80)
        end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type')
          state.notice = text
          state.screen = box(text)
        end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'RET' then
            state.submitted = true
            state.busy = true
            state.screen = state.notice .. '\n'
              .. '⏺ Bash(remuda butler inbox)\n'
              .. '⎿ This command requires approval\n'
              .. '❯ 1. Yes\n  2. No\n'
              .. string.rep('─', 80)
          end
        end
        remuda._butler_bus.notices.m1 = { count = 1, text = 'dialog notice fixture' }
        "#,
    );

    for _ in 0..14 {
        eval(&path, "remuda._butler_deliver_notices()");
    }
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)"),
        "false",
        "notice remained queued after successful submit while Claude was busy on a follow-up dialog"
    );
    let events = eval(&path, "return table.concat(remuda._notice_dialog_test_state.events, ',')");
    assert_eq!(events.matches("type").count(), 1, "{events}");
    assert_eq!(events.matches("key RET").count(), 1, "{events}");
    assert!(eval(&path, "return tostring(remuda._notice_dialog_test_state.submitted)") == "true");
}

/// The core can show an empty composer after Return while Claude is already
/// working, before the accepted text is visible in the transcript capture.
#[test]
fn busy_claude_with_empty_composer_confirms_submitted_notice() {
    let (path, _daemon) = butler_with_member("notice-busy-empty");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        local state = { screen = '❯ \n', events = {}, busy = false }
        remuda._notice_busy_empty_state = state
        remuda._butler_bus.agents.m1.kind = 'claude'
        remuda.capture_styled = nil
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = state.busy } end
        remuda.capture = function() return state.screen end
        remuda._butler_notify_policy = function() return true end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type')
          state.notice = text
          state.screen = '❯ \n' .. string.rep('─', 80)
          state.busy = true
        end
        remuda.key = function(_, key) table.insert(state.events, 'key ' .. key) end
        remuda._butler_bus.notices.m1 = { count = 1, text = 'busy empty notice fixture' }
        "#,
    );

    for _ in 0..4 {
        eval(&path, "remuda._butler_deliver_notices()");
    }
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1 == nil)"), "true",
        "busy pane with an empty composer did not confirm the notice submit");
    let events = eval(&path, "return table.concat(remuda._notice_busy_empty_state.events, ',')");
    assert_eq!(events.matches("type").count(), 1, "notice was retyped: {events}");
    assert!(!events.contains("key RET"), "busy empty composer was submitted twice: {events}");
}

/// Repeated delivery of the same unread message must not increment notice counts;
/// reading it in the inbox must cancel any still-pending pane notice.
#[test]
fn notice_ids_are_deduplicated_and_read_messages_are_not_notified() {
    let (path, _daemon) = butler_with_member("notice-read-dedupe");
    eval(
        &path,
        r#"
        remuda._butler_notify_policy = function() return true end
        remuda.capture_styled = nil
        remuda.capture = function() return '❯ ' end
        remuda.type_text = function() end
        local sent = remuda._butler_send('operator', 'm1', 'dedupe fixture')
        remuda._notice_dedupe_id = sent:match('queued ([^ ]+)')
        assert(remuda._notice_dedupe_id)
        local notice = 'Butler message ' .. remuda._notice_dedupe_id .. ' from operator arrived. Read it: remuda butler inbox'
        remuda._butler_notify('m1', notice, remuda._notice_dedupe_id)
        remuda._butler_notify('m1', notice, remuda._notice_dedupe_id)
        "#,
    );
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1.count)"), "1",
        "the same message id inflated its pending notice count");
    eval(&path, "remuda._butler_inbox('m1'); remuda._butler_deliver_notices()");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1 == nil)"), "true",
        "reading the message left its pane notification queued");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notice_recoveries.m1 == nil)"), "true",
        "reading the message left its notice recovery active");
}

/// A notice that remains the exact Claude composer text gets one Return retry,
/// then the bounded verification failure is reported and its count cleared.
#[test]
fn claude_notice_still_in_composer_is_retried_once_then_reported() {
    let (path, _daemon) = butler_with_member("notice-still-in-composer");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        local state = { screen = '❯ \n', events = {}, report = '' }
        remuda._notice_stuck_test_state = state
        remuda._butler_bus.agents.m1 = remuda._butler_bus.agents.m1 or {
          id = '01ARZ3NDEKTSV4RRFFQ69G5FAV', kind = 'claude' }
        remuda._butler_bus.agents.m1.kind = 'claude'
        remuda.capture_styled = nil
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = false } end
        remuda.capture = function() return state.screen end
        remuda._butler_notify_policy = function() return not state.retried end
        local function box(text)
          return '❯ ' .. text .. string.rep(' ', math.max(0, 78 - #text))
            .. '\n' .. string.rep('─', 80)
        end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type')
          state.screen = box(text)
        end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          state.retried = true
        end
        local send = remuda._butler_send
        remuda._butler_send = function(from, to, text)
          if from == 'operator' then return send(from, to, text) end
          state.report = text
          return true
        end
        remuda._butler_bus.notices.m1 = { count = 1, text = 'stuck notice fixture' }
        "#,
    );

    for _ in 1..24 {
        eval(&path, "remuda._butler_deliver_notices()");
    }
    let events = eval(&path, "return table.concat(remuda._notice_stuck_test_state.events, ',')");
    assert_eq!(events.matches("type").count(), 1, "{events}");
    assert_eq!(events.matches("key RET").count(), 1, "{events}");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)"), "false",
        "a terminal notice failure left its pending count behind");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notice_recoveries.m1 == nil)"), "true",
        "a terminal notice failure left recovery state behind");
    assert!(eval(&path, "return remuda._notice_stuck_test_state.report").contains("could not be verified"));
}

/// #82: failed comparisons log sizes and a fixed reason, never pane or notice text.
#[test]
fn notice_verify_mismatch_logs_only_lengths_and_reason() {
    let (path, _daemon) = butler_with_member("notice-verify-trace");
    let trace = path.parent().unwrap().join("session-trace.log");
    eval(
        &path,
        &format!(
            r#"remuda._butler_session_trace_path = {trace:?}
            local now = 0
            remuda._butler_notice_clock = function() return now end
            local state = {{screen = string.rep('x', 9000) .. '\n❯ unrelated composer\n─', keys = 0}}
            remuda._notice_log_test_state = state
            remuda._butler_bus.agents.m1.kind = 'claude'
            remuda.ls = function() return {{ {{name = 'm1', alive = true, attached = false}} }} end
            remuda.session = function() return {{is_busy = false}} end
            remuda.capture = function() return state.screen end
            remuda._butler_notify_policy = function() return true end
            remuda.type_text = function(_, expected) state.expected = expected end
            remuda.key = function() state.keys = state.keys + 1 end
            remuda._butler_send('operator', 'm1', 'notice log fixture')
            now = 3"#
        ),
    );
    for _ in 0..13 {
        eval(&path, "remuda._butler_deliver_notices()");
    }
    let log = std::fs::read_to_string(&trace).expect("notice diagnostic trace");
    assert!(log.contains("notice_verify_mismatch\tmessage_ids="), "{log}");
    assert!(log.contains("session=m1 reason=notice submit could not be verified"), "{log}");
    assert!(log.contains("capture_bytes=9027 composer_bytes=18 expected_bytes="), "{log}");
    assert!(!log.contains("unrelated composer"), "{log}");
    assert!(!log.contains("Butler message"), "{log}");
    assert!(!log.contains(&"x".repeat(64)), "{log}");
    assert!(
        log.len() < 40_000,
        "notice diagnostic was not bounded: {} bytes",
        log.len()
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._notice_log_test_state.keys)"),
        "0",
        "diagnostic logging must not send keys to the pane"
    );
}

/// #64: an idle non-empty composer is redrawn, its draft is preserved,
/// cleared with a verified input key, and the queued notice is submitted.
#[test]
fn notice_recovery_preserves_idle_draft_and_respects_attached_human() {
    let (path, _daemon) = butler_with_member("notice-recovery-draft");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        remuda.ls = function() return { row } end
        remuda.capture_styled = nil
        remuda._butler_bus.agents.m1.kind = 'codex'
        local state = { screen = '› unsent draft text\nGPT-6-Luna medium · ~/projects/ids · task\n? for shortcuts\n98% context left', events = {}, after_type = 0 }
        remuda._notice_test_state = state
        remuda.capture = function()
          table.insert(state.events, 'capture')
          if state.after_type == 1 then state.after_type = 2; return '› ' .. remuda._butler_bus.notices.m1.text end
          if state.after_type == 2 then return '› ' end
          return state.screen
        end
        remuda.session = function() return { is_busy = false } end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'C-u' then state.screen = '› ' end
          if key == 'RET' then state.screen = '› ' end
        end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type ' .. text)
          state.after_type = 1
        end
        remuda._butler_send('operator', 'm1', 'notice')
        "#,
    );
    let deadline = Instant::now() + PATIENCE;
    loop {
        let queued = eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)");
        if queued == "false" { break; }
        assert!(Instant::now() < deadline, "notice recovery did not settle: {}", eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')"));
        std::thread::sleep(Duration::from_millis(100));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    assert!(events.contains("key C-l"), "recovery did not try a redraw first: {events}");
    assert!(events.contains("key C-u"), "recovery did not clear the draft safely: {events}");
    assert!(events.contains("type Butler message"), "notice was not typed: {events}");
    assert!(events.contains("Your unsent draft was: unsent draft text"), "draft was not preserved: {events}");
    assert!(!events.contains("C-c"), "recovery sent Ctrl-C: {events}");
    assert!(events.find("key C-l") < events.find("key C-u"), "draft cleared before redraw: {events}");
    assert_eq!(eval(&path, "return tostring(remuda.ls()[1].alive)"), "true");

    eval(
        &path,
        r#"remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› temporary text'
        remuda._butler_send('operator', 'm1', 'next notice')"#,
    );
    eval(&path, "remuda._notice_test_state.screen = '› ' .. remuda._butler_bus.notices.m1.text");
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        assert!(Instant::now() < deadline, "one-line existing Butler notice was not submitted");
        std::thread::sleep(Duration::from_millis(100));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    assert!(events.contains("key RET"), "one-line existing notice was not submitted: {events}");
    assert!(!events.contains("key C-u"), "one-line existing notice was cleared: {events}");

    eval(
        &path,
        r#"remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› temporary text'
        remuda._butler_send('operator', 'm1', 'wrapped notice')"#,
    );
    eval(&path, r#"local notice = remuda._butler_bus.notices.m1.text
        local split = assert(notice:find('Read it:', 1, true)) + #'Read it:'
        remuda._notice_test_state.screen = '› ' .. notice:sub(1, split) .. '\n' .. notice:sub(split + 1)"#);
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        assert!(Instant::now() < deadline, "wrapped existing Butler notice was not submitted");
        std::thread::sleep(Duration::from_millis(100));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    assert!(events.contains("key C-l"), "wrapped existing notice was not redrawn first: {events}");
    assert!(events.contains("key RET"), "wrapped existing notice was not submitted: {events}");
    assert!(!events.contains("key C-u"), "recovery erased the wrapped existing Butler notice: {events}");

    eval(
        &path,
        r#"remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› Butler message but this is user prose'
        remuda._butler_send('operator', 'm1', 'prefix draft notice')"#,
    );
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        assert!(Instant::now() < deadline, "Butler message prefix draft did not settle");
        std::thread::sleep(Duration::from_millis(100));
    }
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    assert!(events.contains("key C-u"), "prefix draft was mistaken for an existing notice: {events}");
    assert!(events.contains("Your unsent draft was: Butler message but this is user prose"), "prefix draft was not preserved: {events}");

    eval(
        &path,
        r#"local row = remuda.ls()[1]
        row.attached, row.human_idle = true, 15
        remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› human draft'
        remuda._butler_send('operator', 'm1', 'human-safe notice')"#,
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    let events = loop {
        let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
        if events.contains("capture") { break events; }
        assert!(Instant::now() < deadline, "attached composer was not inspected before notice deadline: {events}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(!events.contains("key ") && !events.contains("type "), "recovery sent a key or typed into a human-active pane: {events}");

    eval(&path, r#"remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› '
        remuda._butler_bus.notices.m1 = nil
        remuda._butler_bus.notice_recoveries.m1 = nil
        remuda._butler_send('operator', 'm1', 'attached empty composer notice')"#);
    std::thread::sleep(Duration::from_millis(2200));
    eval(&path, "remuda._butler_deliver_notices()");
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    assert!(events.contains("type Butler message"), "idle attached empty composer did not receive a normal notice: {events}");

    eval(&path, r#"local row = remuda.ls()[1]
        row.attached = false
        remuda._notice_test_state.events = {}
        remuda._notice_test_state.after_type = 0
        remuda._notice_test_state.screen = '› busy pane draft'
        remuda._notice_test_state.busy = false
        remuda.session = function() return { is_busy = remuda._notice_test_state.busy } end
        remuda._butler_bus.notices.m1 = nil
        remuda._butler_bus.notice_recoveries.m1 = nil
        remuda._butler_send('operator', 'm1', 'busy pane timeout notice')
        "#);
    std::thread::sleep(Duration::from_millis(2200));
    eval(&path, "remuda._butler_deliver_notices()");
    eval(&path, r#"
        assert(remuda._butler_bus.notice_recoveries.m1, 'busy timeout recovery was not created')
        remuda._butler_bus.notice_recoveries.m1.checks = 39
        remuda._butler_bus.notice_recoveries.m1.failed = false
        remuda._notice_test_state.busy = true"#);
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_bus.notice_recoveries.m1.failed)"),
        "false",
        "busy pane ticks incorrectly exhausted the recovery timeout",
    );
}

#[test]
fn partial_clear_escalation_reports_draft_length_without_draft_text() {
    let (path, _daemon) = butler_with_member("partial-clear");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        remuda.ls = function() return { row } end
        remuda.capture_styled = nil
        remuda._butler_bus.agents.m1.kind = 'codex'
        local state = { screen = '› first draft line\nsecond draft line', events = {} }
        remuda._partial_clear_state = state
        remuda.capture = function()
          table.insert(state.events, 'capture')
          return state.screen
        end
        remuda.session = function() return { is_busy = false } end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'C-u' then state.screen = '› second draft line' end
        end
        remuda.type_text = function(_, text) table.insert(state.events, 'type ' .. text) end
        local send = remuda._butler_send
        remuda._butler_send = function(from, to, text)
          if to == 'm1' then return send(from, to, text) end
          state.escalation = text
          return 'captured escalation'
        end
        remuda._butler_send('operator', 'm1', 'partial clear check')
        "#,
    );
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._partial_clear_state.escalation ~= nil)") != "true" {
        assert!(Instant::now() < deadline, "partial clear did not report its failure");
        std::thread::sleep(Duration::from_millis(100));
    }
    let escalation = eval(&path, "return remuda._partial_clear_state.escalation");
    assert!(escalation.contains("draft bytes: 34"), "escalation omitted draft length: {escalation}");
    assert!(!escalation.contains("first draft line"), "escalation leaked draft text: {escalation}");
    assert!(escalation.contains("composer did not become empty"), "partial clear reason was missing: {escalation}");
}

/// #29 review 2: an exited session's pending notice and screen record go too.
#[test]
fn session_exit_clears_the_notice_queue_and_screen_record() {
    let (path, _daemon) = butler_with_member("notice-exit");
    eval(
        &path,
        "remuda._butler_notify_policy = function() return false end; \
         remuda._butler_send('operator', 'm1', 'hi'); \
         remuda._butler_bus.notice_recoveries.m1 = { phase = 'probe' }; \
         remuda._butler_bus.notice_screens.m1 = { screen = '', since = 0 }; \
         local cwd = remuda._butler_bus.agents.m1.cwd; \
         remuda._butler_bus.trusted_launch_dirs = { [cwd] = true }; \
         remuda.emit('session_exited', 'm1'); \
         remuda._trust_path_cleared = remuda._butler_bus.trusted_launch_dirs[cwd] == nil",
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_bus.notices.m1) .. tostring(remuda._butler_bus.notice_screens.m1) .. tostring(remuda._butler_bus.notice_recoveries.m1)"),
        "nilnilnil"
    );
    assert_eq!(eval(&path, "return tostring(remuda._trust_path_cleared)"), "true");
}

/// #29 review 3: a task the policy keeps deferring times out, is logged, and
/// its leader is told, instead of waiting forever.
#[test]
fn a_task_deferred_too_long_times_out_and_tells_the_leader() {
    let dir = scratch("task-deferred");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    let trace = dir.join("session-trace.log");
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        &format!(
            "remuda._butler_session_trace_path = {trace:?}; \
             remuda.butler.project_home({projects:?}); \
             remuda._butler_agent_builders.fake = function() return {{'sleep', '100'}} end; \
             remuda._butler_agent_startup.fake = {{ ready = function() return true end }}; \
             remuda._butler_notify_policy = function() return false end; \
             remuda._butler_task_poke_deferrals = 3; \
             remuda._butler_topic_delegate('t1', 'the task', nil, 'fake', 'butler')",
            projects = dir.join("projects")
        ),
    );
    // A startup screen that never looks ready times out the same way.
    eval(
        &path,
        "remuda._butler_agent_startup.fake = { ready = function() return false end }; \
         remuda._butler_task_poke_attempts = 3; \
         remuda._butler_topic_delegate('t2', 'the task', nil, 'fake', 'butler')",
    );
    std::thread::sleep(Duration::from_secs(3));
    let log = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(log.contains("task_poke_timeout\tt1 deferred"), "{log}");
    assert!(log.contains("task_poke_timeout\tt2"), "{log}");
    let inbox = eval(&path, "return remuda._butler_inbox('butler')");
    for topic in ["t1", "t2"] {
        assert!(
            inbox.contains(&format!("Task for {topic} was not delivered")),
            "{inbox}"
        );
    }
}

/// #44: the fake agent drops the task's first Return. Butler must retry it
/// while keeping an immediate notice out of the still-populated composer.
#[test]
#[cfg(unix)]
fn a_topic_task_is_submitted_before_an_immediate_notice_is_typed() {
    let dir = scratch("topic-first-prompt-notice");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    let script = dir.join("fake-claude.sh");
    let submitted = dir.join("submitted.txt");
    std::fs::write(
        &script,
        "#!/bin/sh\n\
         submitted=$1\n\
         stty -echo\n\
         printf 'Claude Code\\n────────────────────\\n❯ '\n\
         IFS= read -r task || exit 0\n\
         # Drop the first Return while leaving the task in the composer.\n\
         printf '\\r\\033[2K❯ %s' \"$task\"\n\
         IFS= read -r line || exit 0\n\
         if [ -n \"$line\" ]; then task=\"$task$line\"; fi\n\
         printf '%s\\n' \"$task\" >> \"$submitted\"\n\
         printf '\\r\\033[2Kaccepted:%s\\n────────────────────\\n❯ ' \"$task\"\n\
         while IFS= read -r line; do\n\
           printf '%s\\n' \"$line\" >> \"$submitted\"\n\
           printf '\\r\\033[2Kaccepted:%s\\n────────────────────\\n❯ ' \"$line\"\n\
         done\n",
    )
    .expect("write fake Claude");
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        &format!(
            r#"
            remuda.butler.project_home({projects:?})
            remuda._butler_agent_builders.claude = function() return {{"sh", {script:?}, {submitted:?}}} end
            remuda.session = function() return {{is_busy = false}} end
            remuda._butler_topic_delegate("topic", "do the delegated task", nil, "claude", "butler")
            remuda._butler_send("operator", "topic", "immediate mail")
            "#,
            projects = dir.join("projects").to_string_lossy(),
            script = script.to_string_lossy(),
            submitted = submitted.to_string_lossy(),
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        let screen = eval(&path, "return remuda.capture('topic')");
        let composer = screen.rsplit('❯').next().unwrap_or("");
        assert!(
            !(composer.contains("delegated task") && composer.contains("Butler message")),
            "the delegated task and mail notice shared the unsubmitted composer:\n{screen}"
        );
        let received = std::fs::read_to_string(&submitted).unwrap_or_default();
        if received.lines().any(|line| line == "do the delegated task") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the delegated task was never submitted; received={received:?}; screen:\n{screen}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let received = std::fs::read_to_string(&submitted).expect("fake Claude submitted a turn");
    assert_eq!(
        received.lines().next(),
        Some("do the delegated task"),
        "an immediate mail notice must not take the delegated task's first turn: {received:?}"
    );
}

/// A dropped first Return leaves the task in the composer. Butler retries it,
/// waits for acceptance, then delivers the queued notice.
#[test]
#[cfg(unix)]
fn a_topic_task_retries_a_dropped_return_before_delivering_a_notice() {
    let dir = scratch("topic-dropped-return");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        r#"
        remuda.butler.project_home("/tmp")
        remuda._butler_agent_builders.claude = function() return {"sh", "-c", "sleep 30"} end
        local screen, events, first_poll_empty = "──────\n❯ ", {}, false
        remuda._topic_test_events = events
        remuda._topic_test_pending_at_notice = true
        remuda.capture = function()
          if first_poll_empty then
            first_poll_empty = false
            table.insert(events, "first poll blank while text paints")
            return "──────\n❯ "
          end
          return screen
        end
        remuda.type_text = function(n, text)
          if text == "finish immediately" then
            table.insert(events, "task typed; first Return dropped")
            screen = "──────\n❯ " .. text
            first_poll_empty = true
          else
            table.insert(events, "notice delivered")
            remuda._topic_test_pending_at_notice = remuda._butler_bus.pending_tasks[n] ~= nil
          end
        end
        remuda.key = function(_, key)
          if key == "RET" then
            table.insert(events, "retry Return accepted")
            screen = "──────\n❯ "
          end
        end
        remuda.session = function() return {is_busy = false} end
        remuda._butler_notify_policy = function() return true end
        remuda._butler_topic_delegate("fast", "finish immediately", nil, "claude", "butler")
        remuda._butler_send("operator", "fast", "immediate mail")
        "#,
    );

    let deadline = Instant::now() + PATIENCE;
    loop {
        let pending = eval(&path, "return tostring(remuda._butler_bus.pending_tasks.fast)");
        let events = eval(&path, "return table.concat(remuda._topic_test_events, '\\n')");
        if pending == "nil" && events.lines().any(|line| line == "notice delivered") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "fast task stayed pending: {pending}; events={}",
            eval(&path, "return table.concat(remuda._topic_test_events, '\\n')")
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let events = eval(&path, "return table.concat(remuda._topic_test_events, '\\n')");
    assert_eq!(
        events.lines().collect::<Vec<_>>(),
        [
            "task typed; first Return dropped",
            "first poll blank while text paints",
            "retry Return accepted",
            "notice delivered",
        ],
        "the dropped Enter must be retried and the notice must follow acceptance: {events}"
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._topic_test_pending_at_notice)"),
        "false",
        "the notice must be typed only after pending_tasks clears"
    );
}

/// #29(3): on a core with `ls().human_idle` (#136) and `capture_styled`
/// (#137), the policy waits on the human's own idle time and reads the cursor
/// row without dim ghost text. The old-core path is the test above.
#[test]
fn notify_policy_uses_human_idle_and_dim_spans_when_the_core_has_them() {
    let dir = scratch("notice-policy-new-core");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    let got = eval(
        &path,
        r#"local real_ls, real_capture, real_styled, real_session = remuda.ls, remuda.capture, remuda.capture_styled, remuda.session
        local row, spans = { name = 'p1', alive = true, attached = true }, {}
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = false } end
        remuda.capture = function() error('the new-core path must not need plain capture') end
        remuda.capture_styled = function()
          return { rows = { { { text = 'history', dim = false } }, spans }, cursor = { row = 2, col = 3, visible = true } }
        end
        local function case(idle, ...)
          row.human_idle = idle
          for i = #spans, 1, -1 do spans[i] = nil end
          for i, span in ipairs({ ... }) do spans[i] = span end
          return tostring(remuda._butler_notify_policy('p1'))
        end
        local plain = function(text) return { text = text, dim = false } end
        local dim = function(text) return { text = text, dim = true } end
        local r = {}
        r[#r + 1] = 'typing=' .. case(2, plain('❯ '))
        r[#r + 1] = 'ghost=' .. case(12, plain('❯ '), dim('Try "fix typecheck errors"'))
        -- butler-qa's real Claude frame: one dim run per word, plain spaces
        -- between them, NBSP after the glyph.
        r[#r + 1] = 'ghost_words=' .. case(12, plain('❯\u{A0}'), dim('Try'), plain(' '), dim('"fix'), plain(' '), dim('typecheck'), plain(' '), dim('errors"'))
        r[#r + 1] = 'typed=' .. case(12, plain('❯ co'))
        r[#r + 1] = 'never=' .. case(math.huge, plain('❯ '))
        r[#r + 1] = 'off_prompt=' .. case(12, plain('some output'))
        row.attached = false
        r[#r + 1] = 'detached_typed=' .. case(math.huge, plain('❯ co'))
        r[#r + 1] = 'detached_empty=' .. case(0, plain('❯ '))
        remuda._butler_notice_human_idle = 20
        row.attached = true
        r[#r + 1] = 'knob=' .. case(12, plain('❯ '))
        remuda.ls, remuda.capture, remuda.capture_styled, remuda.session = real_ls, real_capture, real_styled, real_session
        return table.concat(r, ' ')"#,
    );
    assert_eq!(
        got,
        "typing=false ghost=true ghost_words=true typed=false never=true off_prompt=false detached_typed=false detached_empty=true knob=false"
    );
}

#[test]
fn topic_names_cannot_escape_the_project_home() {
    let dir = scratch("topic-name-escape");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    let projects = dir.join("projects");
    let got = eval(
        &path,
        &format!(
            "remuda.butler.project_home({projects:?}); \
             remuda._butler_agent_builders.fake = function() return {{'sleep','20'}} end; \
             local rejected = {{}} \
             for _, name in ipairs({{'../escape', 'back\\\\slash', '.hidden', 'line\\nbreak'}}) do \
               local ok = pcall(remuda._butler_topic_new, name, nil, 'fake'); \
               rejected[#rejected + 1] = tostring(not ok) \
             end \
             return table.concat(rejected, ',')"
        ),
    );
    assert_eq!(got, "true,true,true,true", "unsafe topic name was accepted: {got}");
    assert!(
        !dir.join("escape").exists(),
        "traversal topic created a directory outside project_home"
    );
}

#[test]
fn launch_cwd_rejects_control_characters() {
    let dir = scratch("launch-cwd-controls");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    let cwd = dir.join("cwd\nnotice-injection");
    std::fs::create_dir_all(&cwd).expect("control-character cwd");
    let cwd_lua = format!("{:?}", cwd.to_string_lossy());
    let accepted = eval(
        &path,
        &format!(
            "remuda._butler_agent_builders.claude = function() return {{'sleep', '20'}} end; \
             local token = remuda._butler_bus.agents.butler.token; \
             pcall(remuda._call, 'butler_launch', \
               {{ kind = 'claude', name = 'badcwd', cwd = {cwd_lua} }}, \
               {{ capability = token }}); \
             return tostring(remuda._butler_bus.agents.badcwd ~= nil)"
        ),
    );
    assert_eq!(accepted, "false", "launch accepted a control character in cwd");
}

#[test]
#[cfg(unix)]
fn trust_dialogs_on_external_or_reused_directories_wait_for_a_human() {
    let dir = scratch("untrusted-launch-cwd");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh', '-c', 'sleep 30'}; remuda.exec('butler')");
    let projects = dir.join("projects");
    let reused = projects.join("reused");
    let external = dir.join("external");
    let fresh = projects.join("fresh");
    std::fs::create_dir_all(&reused).expect("pre-existing topic directory");
    std::fs::create_dir_all(&external).expect("external cwd");
    eval(
        &path,
        &format!(
            r#"remuda.butler.project_home({projects:?})
            remuda._butler_readiness_timeout = 30
            remuda._butler_test_force_launch_probe = {{ outside = true, outside_codex = true, reused = true, three = true, templated = true, fresh = true }}
            remuda._butler_agent_builders.claude = function() return {{'sh', '-c', 'sleep 20'}} end
            remuda._butler_agent_builders.codex = function() return {{'sh', '-c', 'sleep 20'}} end
            local real_ls = remuda.ls
            remuda.ls = function()
              local rows = real_ls()
              for _, row in ipairs(rows) do row.attached = false end
              return rows
            end
            local selected_yes = "Accessing workspace:\n❯ Yes, I trust this folder\n  No, exit"
            local safe_modal = "Accessing workspace:\n❯ No, exit\n  Yes, I trust this folder"
            local three_options = safe_modal .. "\n  Inspect first"
            local codex_modal = "Trust this folder?\n› 1. Trust and continue\n  2. Don't trust"
            remuda.capture = function(name)
              if name == 'outside' then return selected_yes end
              if name == 'outside_codex' then return codex_modal end
              if name == 'reused' then return safe_modal end
              if name == 'fresh' then return "Accessing workspace:\n" .. {fresh:?} .. "\n❯ No, exit\n  Yes, I trust this folder" end
              return three_options
            end
            remuda._trust_test_keys, remuda._trust_test_reports = {{}}, {{}}
            remuda.key = function(name, key) table.insert(remuda._trust_test_keys, name .. ':' .. key) end
            remuda._butler_send = function(_, _, text) table.insert(remuda._trust_test_reports, text); return 'captured' end
            local cap = remuda._butler_bus.agents.butler.token
            remuda._call('butler_launch', {{ kind = 'claude', name = 'outside', cwd = {external:?} }}, {{ capability = cap }})
            remuda._call('butler_launch', {{ kind = 'codex', name = 'outside_codex', cwd = {external:?} }}, {{ capability = cap }})
            remuda._butler_topic_new('reused', nil, 'claude')
            remuda._butler_topic_new('three', nil, 'claude')
            remuda.butler.template('clone', function(topic) topic.write('repo.txt', 'third-party source') end)
            remuda._butler_topic_new('templated', 'clone', 'claude')
            remuda._butler_topic_new('fresh', nil, 'claude')"#
        ),
    );
    std::thread::sleep(Duration::from_secs(2));
    let keys = eval(&path, "return table.concat(remuda._trust_test_keys, '\\n')");
    assert!(keys.lines().all(|key| key.starts_with("fresh:")), "a human trust dialog was answered automatically: {keys}");
    assert!(keys.contains("fresh:"), "fresh trust dialog was not answered: {keys}; state={}",
        eval(&path, "local a=remuda._butler_bus.agents.fresh; return tostring(a and a.cwd)..':'..tostring(a and a.trust_allowed)..':'..tostring(a and a.trust_reported)..':'..tostring(a and a.launch_attempts[1].reason)..':'..tostring(remuda._butler_bus.trusted_launch_dirs)"));
    let reports = eval(&path, "return table.concat(remuda._trust_test_reports, '\\n')");
    assert!(reports.contains("waiting for a human: trust dialog"), "leader was not asked for human trust: {reports}");
    assert!(reports.contains(&external.to_string_lossy().to_string()), "external cwd missing from trust report: {reports}");
    assert!(reports.contains(&reused.to_string_lossy().to_string()), "reused topic path missing from trust report: {reports}");
    assert!(reports.contains(&projects.join("three").to_string_lossy().to_string()), "three-option topic path missing from trust report: {reports}");
    assert!(reports.contains(&projects.join("templated").to_string_lossy().to_string()), "template topic path missing from trust report: {reports}");
    let fresh_path = projects.join("fresh").to_string_lossy().to_string();
    assert_eq!(
        eval(&path, &format!("return tostring(remuda._butler_bus.trusted_launch_dirs[{fresh_path:?}])")),
        "nil",
        "trusted-launch record was not consumed after answering"
    );
}

#[test]
fn dismissed_claude_model_modal_is_rechecked_and_notice_is_delivered() {
    let (path, _daemon) = butler_with_member("notice-dismissed-model-modal");
    let trace = scratch("notice-dismissed-model-modal-trace").join("session-trace.log");
    eval(
        &path,
        &format!(
            r#"
        local state = {{ now = 0, screen = '❯ 1. Yes, switch to Opus 5.5\n──', events = {{}} }}
        local row = {{ name = 'm1', alive = true, attached = false }}
        remuda._notice_test_state = state
        remuda._butler_session_trace_path = {trace:?}
        remuda._butler_bus.agents.m1.kind = 'claude'
        remuda._butler_notice_clock = function() return state.now end
        remuda._butler_human_active = function() return false end
        remuda.ls = function() return {{ row }} end
        remuda.session = function() return {{ is_busy = false }} end
        remuda.capture_styled = nil
        remuda.capture = function() table.insert(state.events, 'capture'); return state.screen end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type ' .. text)
          state.screen = '❯ ' .. text .. '\n──'
          return true
        end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'RET' then state.screen = '❯ \n──' end
        end
        remuda._notice_test_sent = remuda._butler_send('operator', 'm1', 'modal dismissed notice')
        state.id = remuda._notice_test_sent:match('queued ([^ ]+)')
        "#,
            trace = trace.to_string_lossy(),
        ),
    );
    eval(
        &path,
        "local state = remuda._notice_test_state; state.now = 2; remuda._butler_deliver_notices()",
    );
    // Replay the captured post-modal composer: the trace line from the model
    // chooser is gone and Claude now shows its empty prompt.
    eval(&path, "remuda._notice_test_state.screen = '❯ \\n──'");
    let deadline = Instant::now() + Duration::from_secs(10);
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        eval(
            &path,
            "remuda._notice_test_state.now = remuda._notice_test_state.now + 1; remuda._butler_deliver_notices()",
        );
        assert!(
            Instant::now() < deadline,
            "dismissed Claude modal did not release its queued notice: {}",
            eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')")
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let sent = eval(&path, "return remuda._notice_test_sent");
    let id = eval(&path, "return remuda._notice_test_state.id");
    let events = eval(&path, "return table.concat(remuda._notice_test_state.events, '\\n')");
    let trace = std::fs::read_to_string(trace).unwrap_or_default();
    assert!(events.contains("type Butler message"), "notice was not typed: {events}");
    assert!(events.contains("key RET"), "notice was not submitted: {events}");
    assert!(
        sent.contains("notice deferred:")
            && sent.contains("m1")
            && trace.contains(&id)
            && trace.contains("m1")
            && trace.contains("NON-EMPTY"),
        "deferred result and retry trace must identify reason, session, and message id {id}; result={sent}; trace={trace}"
    );
}

#[test]
fn codex_router_trace_on_prompt_row_is_not_preserved_as_a_user_draft() {
    let (path, _daemon) = butler_with_member("notice-codex-router-trace");
    eval(
        &path,
        r#"
        local state = {
          now = 0,
          screen = '› 2026-09-30T14:23:28Z ERROR codex_core::tools::router: error=failed to refresh available mode\n? for shortcuts',
          events = {}, typed = nil,
        }
        local row = { name = 'm1', alive = true, attached = false }
        remuda._notice_test_state = state
        remuda._butler_bus.agents.m1.kind = 'codex'
        remuda._butler_notice_clock = function() return state.now end
        remuda._butler_human_active = function() return false end
        remuda.ls = function() return { row } end
        remuda.session = function() return { is_busy = false } end
        remuda.capture_styled = nil
        remuda.capture = function() return state.screen end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'C-l' or key == 'C-u' or key == 'RET' then state.screen = '› ' end
        end
        remuda.type_text = function(_, text)
          state.typed = text
          table.insert(state.events, 'type ' .. text)
          state.screen = '› ' .. text
          return true
        end
        remuda._butler_send('operator', 'm1', 'router trace notice')
        "#,
    );
    eval(&path, "remuda._notice_test_state.now = 2; remuda._butler_deliver_notices()");
    let deadline = Instant::now() + Duration::from_secs(10);
    while eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)") != "false" {
        eval(&path, "remuda._notice_test_state.now = remuda._notice_test_state.now + 1; remuda._butler_deliver_notices()");
        assert!(Instant::now() < deadline, "Codex router trace blocked the queued notice");
        std::thread::sleep(Duration::from_millis(50));
    }
    let typed = eval(&path, "return remuda._notice_test_state.typed or ''");
    let decision = eval(
        &path,
        r#"local d,t=remuda._butler_prompt_is_empty('codex',
          '› 2026-09-30T14:23:28Z ERROR codex_core::tools::router: error=failed to refresh available mode\n? for shortcuts'); return d..'|'..t"#,
    );
    assert_eq!(decision, "EMPTY|");
    assert!(typed.contains("Butler message"), "notice was not delivered: {typed}");
    assert!(!typed.contains("Your unsent draft was:"), "router diagnostics were preserved as user text: {typed}");
    assert!(!typed.contains("codex_core::tools::router"), "router diagnostics leaked into the notice: {typed}");
}

#[test]
fn attached_notice_recovery_progresses_or_times_out_with_a_reason() {
    let (path, _daemon) = butler_with_member("notice-attached-recovery-bound");
    let trace = scratch("notice-attached-recovery-trace").join("session-trace.log");
    eval(
        &path,
        &format!(
            r#"
        local state = {{ now = 0, screen = '❯ ', events = {{}} }}
        local row = {{ name = 'm1', alive = true, attached = true, human_idle = 20 }}
        remuda._notice_test_state = state
        remuda._butler_session_trace_path = {trace:?}
        remuda._butler_bus.agents.m1.kind = 'codex'
        remuda._butler_notice_clock = function() return state.now end
        remuda._butler_human_active = function() return false end
        remuda.ls = function() return {{ row }} end
        remuda.session = function() return {{ is_busy = false }} end
        remuda.capture_styled = nil
        remuda.capture = function() table.insert(state.events, 'capture'); return state.screen end
        remuda.type_text = function(_, text)
          table.insert(state.events, 'type ' .. text)
          state.screen = '› ' .. text
          return true
        end
        remuda.key = function(_, key)
          table.insert(state.events, 'key ' .. key)
          if key == 'RET' then state.screen = '› ' end
        end
        local sent = remuda._butler_send('operator', 'm1', 'attached recovery notice')
        state.id = sent:match('queued ([^ ]+)')
        local recovery = {{ phase = 'verify_notice', checks = 0, notice = 'pending', count = 1,
          message_ids = {{ state.id }} }}
        remuda._butler_bus.notice_recoveries.m1 = recovery
        remuda._notice_test_recovery = recovery
        "#,
            trace = trace.to_string_lossy(),
        ),
    );
    for _ in 0..25 {
        eval(
            &path,
            "remuda._notice_test_state.now = remuda._notice_test_state.now + 1; remuda._butler_deliver_notices()",
        );
    }
    let pending = eval(&path, "return tostring(remuda._butler_bus.notices.m1 ~= nil)");
    let recovery = eval(&path, "return tostring(remuda._butler_bus.notice_recoveries.m1 ~= nil)");
    let id = eval(&path, "return remuda._notice_test_state.id");
    let trace_contents = std::fs::read_to_string(trace).unwrap_or_default();
    assert!(trace_contents.contains("cap reached; prompt-empty; falling back to normal delivery"),
        "empty prompt at the check cap did not fall back to normal delivery: {trace_contents}");
    assert!(!trace_contents.contains("notice_verify_mismatch"),
        "successful empty-prompt fallback emitted a failure diagnostic: {trace_contents}");
    assert!(trace_contents.matches("notice_retry").count() <= 4,
        "routine retries should log only when the reason changes: {trace_contents}");
    assert!(!trace_contents.contains("attached recovery notice"),
        "routine retry traces must not include composer or message text: {trace_contents}");
    assert!(!trace_contents.contains("reason=prompt-NON-EMPTY:"),
        "routine retry trace included prompt text after the decision: {trace_contents}");
    assert!(
        pending == "false" && recovery == "false",
        "attached recovery remained pending without progress or a logged reason; pending={pending}, recovery={recovery}, trace={trace_contents}"
    );
    assert!(trace_contents.contains(&id) && trace_contents.contains("session=m1"),
        "retry trace omitted message ID or session: {trace_contents}");
}

#[test]
fn empty_prompt_fallback_types_once_per_notice_then_alerts() {
    let (path, _daemon) = butler_with_member("notice-fallback-once");
    eval(
        &path,
        r#"
        local state = { now = 0, typed = 0, alerts = {} }
        local row = { name = 'm1', alive = true, attached = false }
        remuda._notice_fallback_test = state
        remuda._butler_notice_clock = function() return state.now end
        remuda.ls = function() return { row } end
        remuda.capture = function() return '› ' end
        remuda.capture_styled = nil
        remuda.session = function() return { is_busy = false } end
        remuda._butler_human_active = function() return false end
        remuda._butler_notify_policy = function() return true end
        remuda.type_text = function() state.typed = state.typed + 1; return true end
        local send = remuda._butler_send
        remuda._butler_send = function(from, to, text)
          if from == 'butler' then table.insert(state.alerts, text); return 'alerted' end
          return send(from, to, text)
        end
        remuda._butler_send('operator', 'm1', 'fallback bound test')
        state.now = 2
        remuda._butler_deliver_notices()
        "#,
    );
    for _ in 0..30 {
        eval(
            &path,
            "remuda._notice_fallback_test.now = remuda._notice_fallback_test.now + 1; remuda._butler_deliver_notices()",
        );
    }
    assert_eq!(
        eval(&path, "return tostring(remuda._notice_fallback_test.typed)"),
        "2",
        "notice was typed more than once after initial delivery plus its one fallback",
    );
    assert_eq!(
        eval(&path, "return tostring(#remuda._notice_fallback_test.alerts)"),
        "1",
        "fallback exhaustion must send one leader alert",
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_bus.notices.m1 == nil)"),
        "true",
    );
}

#[test]
fn recovery_alert_dedupes_until_a_notice_is_delivered() {
    let (path, _daemon) = butler_with_member("notice-alert-dedupe");
    eval(
        &path,
        r#"
        local state = { now = 0, alerts = {}, screen = '' }
        local row = { name = 'm1', alive = true, attached = false }
        remuda._notice_alert_test = state
        remuda._butler_bus.pending_tasks.m1 = nil
        remuda._butler_notice_clock = function() return state.now end
        remuda.ls = function() return { row } end
        remuda.capture = function()
          if state.screen == 'error' then error('private capture detail') end
          return state.screen
        end
        remuda.capture_styled = nil
        remuda.session = function() return { is_busy = false } end
        remuda._butler_human_active = function() return false end
        remuda._butler_notify_policy = function() return state.screen ~= 'error' end
        remuda.type_text = function(_, text)
          state.screen = text .. '\n❯ '
          return true
        end
        local send = remuda._butler_send
        remuda._butler_send = function(from, to, text)
          if from == 'butler' then table.insert(state.alerts, text); return 'alerted' end
          return send(from, to, text)
        end
        state.screen = 'error'
        local first = remuda._butler_send('operator', 'm1', 'first recovery failure')
        local first_id = first:match('queued ([^ ]+)')
        remuda._butler_bus.notice_recoveries.m1 = { phase = 'verify_notice', checks = 0,
          message_ids = { first_id }, started_at = 0 }
        state.now = 2
        remuda._butler_deliver_notices()
        state.now = 3
        local second = remuda._butler_send('operator', 'm1', 'same recovery failure')
        local second_id = second:match('queued ([^ ]+)')
        remuda._butler_bus.notice_recoveries.m1 = { phase = 'verify_notice', checks = 0,
          message_ids = { second_id }, started_at = 3 }
        state.now = 5
        remuda._butler_deliver_notices()
        "#,
    );
    let first_alerts = eval(&path, "return tostring(#remuda._notice_alert_test.alerts)");
    assert_eq!(first_alerts, "1", "the same session and reason should alert only once");
    eval(
        &path,
        r#"
        remuda._notice_alert_test.screen = ''
        remuda._butler_notify_policy = function() return true end
        remuda._notice_alert_test.now = 6
        remuda._butler_send('operator', 'm1', 'successful recovery')
        remuda._notice_alert_test.now = 8
        remuda._butler_deliver_notices()
        remuda._butler_deliver_notices()
        "#,
    );
    eval(
        &path,
        r#"
        remuda._notice_alert_test.screen = 'error'
        remuda._notice_alert_test.now = 10
        local sent = remuda._butler_send('operator', 'm1', 'new recovery after delivery')
        local id = sent:match('queued ([^ ]+)')
        remuda._butler_bus.notice_recoveries.m1 = { phase = 'verify_notice', checks = 0,
          message_ids = { id }, started_at = 10 }
        remuda._notice_alert_test.now = 12
        remuda._butler_deliver_notices()
        "#,
    );
    assert_eq!(
        eval(&path, "return tostring(#remuda._notice_alert_test.alerts)"),
        "2",
        "a delivered notice should reset the alert dedupe window",
    );
    let alert = eval(&path, r#"return table.concat(remuda._notice_alert_test.alerts, '\n')"#);
    assert!(!alert.contains("private capture detail"), "alert leaked capture error text: {alert}");
    assert!(!alert.contains("first recovery failure"), "alert leaked message text: {alert}");
}

#[test]
fn unknown_busy_state_advances_notice_recovery_timeout() {
    let (path, _daemon) = butler_with_member("unknown-busy-recovery");
    eval(
        &path,
        r#"
        local row = { name = 'm1', alive = true, attached = false }
        remuda.ls = function() return { row } end
        remuda.session = function() error('output idle unavailable') end
        remuda.capture = function() return '› Butler message pending' end
        remuda._butler_bus.notices.m1 = { count = 1, text = 'Butler message pending' }
        remuda._butler_bus.notice_recoveries.m1 = {
          phase = 'verify_notice', checks = 0, notice = 'Butler message pending', count = 1,
        }
        remuda._butler_deliver_notices()
        "#,
    );
    let checks = eval(&path, "return tostring(remuda._butler_bus.notice_recoveries.m1.checks)");
    assert_eq!(checks, "1", "unknown busy state stalled notice verification");
}

#[test]
fn reading_mail_mid_notice_recovery_reports_draft_length_without_text() {
    let (path, _daemon) = butler_with_member("notice-read-mid-recovery");
    eval(
        &path,
        r#"
        remuda._butler_send('operator', 'm1', 'notice whose recovery is active')
        remuda._butler_bus.notice_recoveries.m1 = {
          phase = 'verify_notice', checks = 1, notice = 'notice', count = 1,
          draft = 'important unsent draft',
        }
        local send = remuda._butler_send
        remuda._notice_read_recovery_report = nil
        remuda._butler_send = function(from, to, text)
          if to == 'm1' then return send(from, to, text) end
          remuda._notice_read_recovery_report = text
          return 'captured report'
        end
        remuda._butler_inbox('m1')
        "#,
    );
    let report = eval(&path, "return tostring(remuda._notice_read_recovery_report)");
    assert!(report.contains("draft bytes: 22"), "read cleared recovery without reporting draft length: {report}");
    assert!(!report.contains("important unsent draft"), "read recovery alert leaked draft text: {report}");
}

/// #23a: an ended member's unread mail stays readable by its alias, not only
/// by ULID, and a never-known alias still errors.
#[test]
fn an_ended_aliases_unread_mail_is_readable_by_alias() {
    let dir = scratch("ended-alias-inbox");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        "remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end; \
         remuda._butler_launch('fake', 'lead1'); \
         remuda._butler_send('operator', 'lead1', 'unread-after-end'); \
         remuda.emit('session_exited', 'lead1')",
    );
    let inbox = eval(&path, "return remuda._butler_inbox('lead1')");
    assert!(inbox.contains("unread-after-end"), "{inbox}");
    let unknown = client::request(
        &path,
        &Request::Eval { code: "return remuda._butler_inbox('nobody')".into(), name: None },
    )
    .expect("eval");
    assert!(matches!(unknown, Response::Error(_)), "{unknown:?}");
}

/// §7 step 3: another channel can claim delivery before Butler's inbox hook.
#[test]
fn lower_depth_delivery_channel_can_claim_butler_mail() {
    let channel = format!("test-channel-{}", std::process::id());
    let data = std::env::var_os("XDG_DATA_HOME").expect("rust_tests sets XDG_DATA_HOME");
    let install = PathBuf::from(data).join("remuda/mods").join(&channel);
    let entry = install.join(format!("packages/{channel}/init.lua"));
    std::fs::create_dir_all(entry.parent().unwrap()).expect("create channel package");
    std::fs::write(
        install.join("extension.toml"),
        format!(
            "name = \"{channel}\"\napi = \"remuda-lua-v1\"\nentry = \"packages/{channel}/init.lua\"\nlifecycle = \"remuda-module-v1\"\n"
        ),
    )
    .expect("write channel manifest");
    std::fs::write(
        entry,
        r#"return { api = "remuda-module-v1", state_version = 1,
          initialize = function() return {} end,
          hooks = {{ event = "butler/deliver", id = "alternate", depth = -10,
            run = function(state, msg)
              return { id = "alternate-message", from = msg.from, to = { msg.to }, text = msg.text }
            end }} }
        "#,
    )
    .expect("write channel module");

    let dir = scratch("channel-inversion");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    if eval(&path, "return tostring(type(remuda.emit_until_success) == 'function')") != "true" {
        eprintln!("skipping lower_depth_delivery_channel_can_claim_butler_mail: core lacks remuda.emit_until_success");
        return;
    }
    let parent_id = eval(
        &path,
        r#"remuda._butler_argv = { 'sh' }; remuda.exec('butler')
        remuda._butler_agent_builders.fake = function() return { 'sleep', '100' } end
        remuda._butler_launch('fake', 'm1')
        local sent = remuda._butler_send('m1', 'butler', 'reply parent')
        return sent:match('^queued ([^ ]+)')"#,
    );
    eval(&path, &format!("remuda.exec('{channel}')"));
    let got = eval(
        &path,
        &format!(
            r#"local notify = remuda._butler_notify
        remuda._butler_notify = function() return true end
        local inbox_owner = false
        for _, hook in ipairs(remuda.hook_list("butler/deliver")) do
          if hook.id == "inbox" and (hook.group == "remuda-module:butler" or hook.owner == "butler") then inbox_owner = true end
        end
        local sent = remuda._butler_send("operator", "butler", "through another channel")
        local report = remuda._butler_report("m1", "report through another channel")
        local reply = remuda._butler_reply("operator", "{parent_id}", "reply through another channel")
        local forward = remuda._butler_forward("operator", "{parent_id}", "m1", "forward through another channel")
        remuda._butler_notify = notify
        return table.concat({{ tostring(inbox_owner), sent, report, reply, forward }}, "|")"#
        ),
    );
    assert_eq!(
        got,
        format!(
            "true|queued alternate-message and notified butler|queued alternate-message and notified butler|queued alternate-message and notified m1|forwarded {parent_id} to m1; queued alternate-message and notified m1"
        )
    );
}

#[test]
fn missing_delivery_channel_is_reported_to_the_sender() {
    let dir = scratch("channel-missing");
    let path = daemon::socket_path_in(&dir, "s");
    let _daemon = daemon_at(&path);
    if eval(&path, "return tostring(type(remuda.emit_until_success) == 'function')") != "true" {
        eprintln!("skipping missing_delivery_channel_is_reported_to_the_sender: core lacks remuda.emit_until_success");
        return;
    }
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    let got = eval(
        &path,
        r#"local emit = remuda.emit_until_success
        remuda.emit_until_success = function() return nil end
        local ok, err = pcall(remuda._butler_send, "operator", "butler", "no channel")
        remuda.emit_until_success = emit
        return tostring(ok) .. "|" .. tostring(err)"#,
    );
    assert_eq!(
        got,
        "false|no Butler channel installed (try remuda-butler-inbox)"
    );
}

/// Shared prelude for the re-notice tests: a member `alias` whose leader is
/// the root Butler, a context-size stub per alias (`state.ctx`), a tick helper,
/// and `_rn_lead(text)` returning the id of a leader message to the member.
fn setup_renotice(path: &Path, alias: &str) {
    setup_mail_notice_clock_for(path, alias);
    eval(
        path,
        &format!(
            r#"
        local state = remuda._notice_test_state
        local alias = {alias}
        state.ctx = {{}}
        remuda._butler_telemetry_for = function(agent)
          return {{ context_used = state.ctx[agent and agent.alias or ''] }}
        end
        remuda._rn_tick = function(now) state.now = now; remuda._butler_deliver_notices() end
        -- Notices typed into this member's pane only (the stub records every pane).
        state.to = {{}}
        -- The pane shows what was typed, as in the #137 tests, so a notice
        -- verifies instead of hitting the retype fallback.
        remuda.capture = function() return state.screen or '> ' end
        local prior_type = remuda.type_text
        remuda.type_text = function(name, text)
          local ok = prior_type(name, text)
          state.to[#state.typed] = name
          state.screen = text .. '\n> '
          return ok
        end
        remuda._rn_mine = function()
          local mine = {{}}
          for i, entry in ipairs(state.typed) do
            if state.to[i] == alias then mine[#mine + 1] = entry.text end
          end
          return mine
        end
        remuda._rn_lead = function(text)
          return (remuda._butler_send('butler', alias, text):match('^queued (%S+)'))
        end
        remuda._rn_inbox_id = function(id)
          local agent = remuda._butler_bus.agents[alias]
          local ok, out = pcall(remuda._butler_command_run, 'inbox', {{ 'inbox', id }},
            {{ env = {{ REMUDA_BUTLER_AGENT_ID = agent.id }} }})
          return tostring(out)
        end
        "#,
            alias = serde_json::to_string(alias).unwrap()
        ),
    );
}

// The t3-timers / mx-render case: the leader message was read before an
// auto-compact, so the inbox reads empty, yet the member gets one re-shown
// notice for it and can open it by id; read state does not change.
#[test]
fn codex_auto_compact_reshows_the_last_read_leader_message_once() {
    let (path, _daemon) = butler_with_named_agent("renotice-codex-auto", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.ctx.cx1 = 170000
        local id = remuda._rn_lead('task for cx1')
        remuda._rn_tick(0); remuda._rn_tick(2)
        local first = #state.typed
        remuda._butler_inbox('cx1')
        local empty_before = remuda._butler_inbox('cx1')
        remuda._rn_tick(3)
        state.ctx.cx1 = 60000
        remuda._rn_tick(4); remuda._rn_tick(6)
        local after_drop = #state.typed
        local text = tostring(state.typed[2] and state.typed[2].text)
        for t = 7, 20 do remuda._rn_tick(t) end
        local opened = remuda._rn_inbox_id(id)
        local agent_id = remuda._butler_bus.agents.cx1.id
        return table.concat({ tostring(first), empty_before, tostring(after_drop), tostring(#state.typed),
          tostring(text:find(id, 1, true) ~= nil), tostring(text:find('re-shown after compaction', 1, true) ~= nil),
          tostring(text:sub(-#('remuda butler inbox ' .. id)) == 'remuda butler inbox ' .. id),
          tostring(opened:find('task for cx1', 1, true) ~= nil),
          tostring(remuda._butler_mail.is_unread(agent_id, id)), remuda._butler_inbox('cx1') }, '|')
        "#,
    );
    assert_eq!(got, "1|inbox empty|2|2|true|true|true|true|false|inbox empty",
        "auto-compact must re-show the read leader message once, openable by id: {got}");
}

// Our compaction: the half-drop heuristic stays quiet while compaction is in
// progress; the compaction path itself calls the re-notice hook once.
#[test]
fn claude_our_compaction_reshows_the_leader_message_once_via_the_hook() {
    let (path, _daemon) = butler_with_named_agent("renotice-claude-ours", "cl1", "claude");
    setup_renotice(&path, "cl1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.ctx.cl1 = 170000
        local id = remuda._rn_lead('task for cl1')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('cl1')
        remuda._rn_tick(3)
        local agent_id = remuda._butler_bus.agents.cl1.id
        remuda._butler_compaction_members_state = remuda._butler_compaction_members_state or {}
        remuda._butler_compaction_members_state[agent_id] = { compaction_in_progress = true }
        state.ctx.cl1 = 60000
        remuda._rn_tick(4); remuda._rn_tick(6)
        local during = #state.typed
        remuda._butler_compaction_members_state[agent_id].compaction_in_progress = false
        remuda._butler_notice_compacted('cl1')
        for t = 7, 20 do remuda._rn_tick(t) end
        local text = tostring(state.typed[2] and state.typed[2].text)
        return table.concat({ tostring(during), tostring(#state.typed),
          tostring(text:find('remuda butler inbox ' .. id, 1, true) ~= nil) }, '|')
        "#,
    );
    assert_eq!(got, "1|2|true", "our compaction: quiet while in progress, then exactly one re-show: {got}");
}

// Unread leader mail is re-noticed after a compaction (a plain unread
// notice, not a re-show), exactly once.
#[test]
fn unread_leader_mail_is_renoticed_once_after_a_compaction() {
    let (path, _daemon) = butler_with_named_agent("renotice-unread", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.ctx.cx1 = 170000
        local id = remuda._rn_lead('unread task')
        -- Settle: the arrival notice and any follow-up typing happen here.
        for t = 0, 20 do remuda._rn_tick(t) end
        local settled = #remuda._rn_mine()
        -- Control window, no drop: nothing more for the still-unread mail.
        for t = 21, 40 do remuda._rn_tick(t) end
        local control = #remuda._rn_mine() - settled
        state.ctx.cx1 = 60000
        for t = 41, 60 do remuda._rn_tick(t) end
        local mine = remuda._rn_mine()
        local text = tostring(mine[settled + control + 1])
        return table.concat({ tostring(control), tostring(#mine - settled - control),
          tostring(text:find(id, 1, true) ~= nil), tostring(text:find('re-shown', 1, true) == nil),
          tostring(text:sub(-#'remuda butler inbox') == 'remuda butler inbox') }, '|')
        "#,
    );
    assert_eq!(got, "0|1|true|true|true",
        "unread mail: no notice without a drop, exactly one plain re-notice after it: {got}");
}

// A leader message the member already answered is not re-shown.
#[test]
fn an_answered_leader_message_is_not_reshown_after_a_compaction() {
    let (path, _daemon) = butler_with_named_agent("renotice-answered", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.ctx.cx1 = 170000
        local id = remuda._rn_lead('answer me')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('cx1')
        remuda._butler_reply('cx1', id, 'done')
        for t = 3, 20 do remuda._rn_tick(t) end
        local settled = #remuda._rn_mine()
        state.ctx.cx1 = 60000
        for t = 21, 40 do remuda._rn_tick(t) end
        return tostring(#remuda._rn_mine() - settled) .. '|' .. tostring(remuda._butler_notice_compacted ~= nil)
        "#,
    );
    assert_eq!(got, "0|true", "an answered leader message must not be re-shown after the drop: {got}");
}

// Restart: the read leader message is re-shown once, coalesced with the
// unread-count notice into a single notice.
#[test]
fn restart_reshows_the_read_leader_message_coalesced_with_unread_mail() {
    let (path, _daemon) = butler_with_member("renotice-restart");
    setup_renotice(&path, "m1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local bus = remuda._butler_bus
        local id = remuda._rn_lead('restart task')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('m1')
        remuda._notice_test_send('m1', 'other mail')
        -- A daemon restart loses the in-memory notice state.
        bus.notices, bus.notice_seen, bus.unread_seeded = {}, {}, {}
        local before = #state.typed
        for t = 10, 30 do remuda._rn_tick(t) end
        local text = tostring(state.typed[before + 1] and state.typed[before + 1].text)
        return table.concat({ tostring(#state.typed - before),
          tostring(text:find('remuda butler inbox ' .. id, 1, true) ~= nil),
          tostring(text:find('re-shown after restart', 1, true) ~= nil),
          tostring(remuda._rn_inbox_id(id):find('restart task', 1, true) ~= nil) }, '|')
        "#,
    );
    assert_eq!(got, "1|true|true|true", "restart: one coalesced notice naming the leader message: {got}");
}

// Heuristic guards: nil -> value is not a drop; one notice per drop,
// re-armed only after the context rises again.
#[test]
fn half_drop_heuristic_guards_and_rearms_after_a_rise() {
    let (path, _daemon) = butler_with_named_agent("renotice-guards", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local id = remuda._rn_lead('guard task')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('cx1')
        state.ctx.cx1 = nil
        remuda._rn_tick(3)
        state.ctx.cx1 = 60000
        for t = 4, 9 do remuda._rn_tick(t) end
        local after_nil = #state.typed
        state.ctx.cx1 = 170000
        remuda._rn_tick(10)
        state.ctx.cx1 = 60000
        for t = 11, 20 do remuda._rn_tick(t) end
        local after_drop = #state.typed
        state.ctx.cx1 = 25000
        for t = 21, 30 do remuda._rn_tick(t) end
        local no_rearm = #state.typed
        state.ctx.cx1 = 180000
        remuda._rn_tick(31)
        state.ctx.cx1 = 50000
        for t = 32, 40 do remuda._rn_tick(t) end
        return table.concat({ tostring(after_nil), tostring(after_drop), tostring(no_rearm),
          tostring(#state.typed) }, '|')
        "#,
    );
    assert_eq!(got, "1|2|2|3", "guards: nil start, one per drop, re-arm after rise: {got}");
}

// First sight of a new member: a brief it read and has not answered while
// still unseeded (busy with its task) is not re-shown as "after restart".
#[test]
fn a_fresh_launch_with_a_read_unanswered_brief_gets_no_reshow() {
    let (path, _daemon) = butler_with_named_agent("renotice-fresh-launch", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        local bus = remuda._butler_bus
        local launched = tostring(bus.unread_seeded.cx1)
        bus.unread_seeded.cx1 = 'launched' -- as right after launch, before any tick
        state.busy.cx1 = true
        local id = remuda._rn_lead('brief for cx1')
        for t = 0, 3 do remuda._rn_tick(t) end
        remuda._butler_inbox('cx1')
        state.busy.cx1 = false
        for t = 4, 20 do remuda._rn_tick(t) end
        return launched .. '|' .. tostring(#remuda._rn_mine())
        "#,
    );
    assert!(got.ends_with("|0"), "a fresh launch must not re-show its read brief: {got}");
}

// inbox ID: own mailbox only; another member's message is refused with a
// Next: line; the help names the id form.
#[test]
fn inbox_id_opens_only_the_callers_own_messages() {
    let (path, _daemon) = butler_with_named_agent("renotice-inbox-id", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local foreign = remuda._butler_send('operator', 'butler', 'root only'):match('^queued (%S+)')
        local refused = remuda._rn_inbox_id(foreign)
        local help = tostring(remuda._butler_command_run('inbox', { 'inbox', '--help' }, { env = {} }))
        return table.concat({ tostring(refused:find('root only', 1, true) == nil),
          tostring(refused:find('Next:', 1, true) ~= nil),
          tostring(help:find('message-id', 1, true) ~= nil) }, '|')
        "#,
    );
    assert_eq!(got, "true|true|true", "inbox ID owner check and help: {got}");
}

// SEC #159 M1: a daemon restart empties the in-memory messages; the member's
// earlier answer is still on disk, so its answered leader message is not
// re-shown.
#[test]
fn restart_does_not_reshow_a_leader_message_answered_before_it() {
    let (path, _daemon) = butler_with_member("renotice-restart-answered");
    setup_renotice(&path, "m1");
    let got = eval(
        &path,
        r#"
        local bus = remuda._butler_bus
        local id = remuda._rn_lead('answered before restart')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('m1')
        remuda._butler_reply('m1', id, 'done')
        for t = 3, 9 do remuda._rn_tick(t) end
        -- A daemon restart: in-memory mail and notice state are gone.
        bus.messages, bus.mail_delivered, bus.mail_loaded = {}, {}, {}
        bus.notices, bus.notice_seen, bus.unread_seeded = {}, {}, {}
        local before = #remuda._rn_mine()
        for t = 10, 30 do remuda._rn_tick(t) end
        local found = remuda._butler_mail.find_message(id) ~= nil
        return tostring(found) .. '|' .. tostring(#remuda._rn_mine() - before)
        "#,
    );
    assert_eq!(got, "true|0", "an answered leader message must not be re-shown after a restart: {got}");
}

// SEC #159 M2: `inbox <arg>` validates the id before any lookup: a path or a
// non-ULID never reaches a file open and is never cached.
#[test]
fn inbox_with_a_non_ulid_opens_no_message_file() {
    let (path, _daemon) = butler_with_named_agent("renotice-inbox-path", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local opened = {}
        local real_open = io.open
        io.open = function(name, ...)
          if tostring(name):find('../../x', 1, true) or tostring(name):find('not-a-ulid', 1, true) then
            opened[#opened + 1] = name
          end
          return real_open(name, ...)
        end
        remuda._rn_inbox_id('../../x')
        remuda._rn_inbox_id('not-a-ulid')
        io.open = real_open
        local bus = remuda._butler_bus
        return tostring(#opened) .. '|' .. tostring(bus.messages['../../x'] == nil)
          .. '|' .. tostring(bus.messages['not-a-ulid'] == nil)
        "#,
    );
    assert_eq!(got, "0|true|true", "a non-ULID must not reach a message file or the cache: {got}");
}

// SEC #159 L1: a rise during Butler's own compaction does not re-arm the
// half-drop heuristic.
#[test]
fn a_rise_during_our_compaction_does_not_rearm_the_heuristic() {
    let (path, _daemon) = butler_with_named_agent("renotice-l1-rearm", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local state = remuda._notice_test_state
        state.ctx.cx1 = 170000
        local id = remuda._rn_lead('l1 task')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('cx1')
        for t = 3, 9 do remuda._rn_tick(t) end
        local before = #remuda._rn_mine()
        local agent_id = remuda._butler_bus.agents.cx1.id
        remuda._butler_compaction_members_state = remuda._butler_compaction_members_state or {}
        remuda._butler_compaction_members_state[agent_id] = { compaction_in_progress = true }
        state.ctx.cx1 = 60000; remuda._rn_tick(10)
        state.ctx.cx1 = 170000; remuda._rn_tick(11) -- telemetry lag: a rise mid-compaction
        remuda._butler_compaction_members_state[agent_id].compaction_in_progress = false
        state.ctx.cx1 = 60000
        for t = 12, 30 do remuda._rn_tick(t) end
        return tostring(#remuda._rn_mine() - before)
        "#,
    );
    assert_eq!(got, "0", "a rise during our compaction must not re-arm the heuristic");
}

// SEC #159 L2: `inbox <message-id>` outside an agent session says why, with
// a Next: line.
#[test]
fn operator_inbox_with_a_message_id_gets_a_next_line() {
    let (path, _daemon) = butler_with_named_agent("renotice-l2-operator", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local id = remuda._rn_lead('operator view')
        local ok, out = pcall(remuda._butler_command_run, 'inbox', { 'inbox', id }, { env = {} })
        return tostring(out):find('Next:', 1, true) ~= nil and 'next' or tostring(out)
        "#,
    );
    assert_eq!(got, "next", "an operator inbox <message-id> needs a Next: line");
}

// SEC #159 L3: reading other mail (unread reaches 0) does not drop a queued
// re-show.
#[test]
fn reading_other_mail_keeps_a_queued_reshow() {
    let (path, _daemon) = butler_with_named_agent("renotice-l3-keep", "cx1", "codex");
    setup_renotice(&path, "cx1");
    let got = eval(
        &path,
        r#"
        local id = remuda._rn_lead('keep me')
        remuda._rn_tick(0); remuda._rn_tick(2)
        remuda._butler_inbox('cx1')
        for t = 3, 9 do remuda._rn_tick(t) end
        remuda._butler_notice_compacted('cx1')
        remuda._rn_tick(10) -- the re-show is queued, due at 12
        remuda._notice_test_send('cx1', 'other mail')
        remuda._butler_inbox('cx1') -- unread reaches 0 before the re-show is typed
        for t = 11, 30 do remuda._rn_tick(t) end
        local reshown = 0
        for _, text in ipairs(remuda._rn_mine()) do
          if text:find('remuda butler inbox ' .. id, 1, true) then reshown = reshown + 1 end
        end
        return tostring(reshown)
        "#,
    );
    assert_eq!(got, "1", "the queued re-show must survive reading other mail");
}
