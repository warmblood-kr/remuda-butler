//! `butler_status` as a live MCP tool, ported from core native/tests/mcp.rs
//! (removed there in 36568f7). Helpers are copied from that file.

use remuda_core::protocol::{Request, Response};
use remuda_native::{client, daemon, mcp};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const PATIENCE: Duration = Duration::from_secs(10);

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("remuda-m{}-{tag}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// Start a daemon and return once it actually answers, not once it was spawned.
fn daemon_at(path: &Path) -> impl Drop {
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
    let status_path = match client::request(
        &path,
        &Request::Eval {
            code: "remuda._butler_argv = {'sh'}; remuda.exec('butler'); return remuda._butler_status_path".into(),
            name: None,
        },
    )
    .expect("load butler")
    {
        Response::Value(value) => value,
        other => panic!("butler did not return its status path: {other:?}"),
    };

    assert!(listed(&path).contains(&"butler_status".to_string()));
    let source = match client::request(
        &path,
        &Request::Eval {
            code: "return remuda._butler_statusline_src".into(),
            name: None,
        },
    )
    .expect("read embedded status helper")
    {
        Response::Value(value) => value,
        other => panic!("butler has no embedded status helper: {other:?}"),
    };
    let mut helper = Command::new("python3")
        .args(["-c", &source, &status_path])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("start embedded status helper");
    helper
        .stdin
        .take()
        .expect("helper stdin")
        .write_all(br#"{"model":{"display_name":"Claude Opus 4.6"},"context_window":{"total_input_tokens":12345,"context_window_size":200000,"used_percentage":6}}"#)
        .expect("write Claude status snapshot");
    let output = helper.wait_with_output().expect("wait for status helper");
    assert!(output.status.success(), "status helper failed: {output:?}");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6"
    );
    let reply = call(&path, "butler_status", json!({}));
    assert_eq!(reply["result"]["isError"], false, "status failed: {reply}");
    assert_eq!(
        text_of(&reply),
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6"
    );

    // Missing context data remains explicit rather than being invented from
    // launch arguments or terminal rendering.
    let mut helper = Command::new("python3")
        .args(["-c", &source, &status_path])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("start status helper without context data");
    helper
        .stdin
        .take()
        .expect("helper stdin")
        .write_all(br#"{"model":{"id":"sonnet"},"context_window":{}}"#)
        .expect("write partial Claude status snapshot");
    let output = helper.wait_with_output().expect("wait for status helper");
    assert!(output.status.success(), "status helper failed: {output:?}");
    assert_eq!(
        text_of(&call(&path, "butler_status", json!({}))),
        "MODEL:sonnet CTX:? CTXWIN:? CTXPCT:?"
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
            local real_ls, real_capture, real_capture_styled = remuda.ls, remuda.capture, remuda.capture_styled
            remuda.capture_styled = nil
            local row, screen = {{ name = 'p1', alive = true, attached = true }}, ''
            remuda.ls = function() return {{ row }} end
            remuda.capture = function() return screen end
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
            remuda.ls, remuda.capture, remuda.capture_styled = real_ls, real_capture, real_capture_styled
            return table.concat(r, ' ')"#
        ),
    );
    assert_eq!(
        got,
        "half=false empty_stable=true claude_box=true claude_nbsp=true claude_nbsp_typed=false empty_changing=false unparseable=false \
         codex_placeholder=true codex_typed=false detached=false detached_empty=true"
    );
    let log = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(log.contains("notice_prompt\tp1  NON-EMPTY co"), "{log}");
    assert!(log.contains("notice_prompt\tp1  UNPARSEABLE"), "{log}");
}

fn butler_with_member(tag: &str) -> (PathBuf, impl Drop) {
    let dir = scratch(tag);
    let path = daemon::socket_path_in(&dir, "s");
    let daemon = daemon_at(&path);
    eval(&path, "remuda._butler_argv = {'sh'}; remuda.exec('butler')");
    eval(
        &path,
        "remuda._butler_agent_builders.fake = function() return {'sleep', '100'} end; \
         remuda._butler_launch('fake', 'm1')",
    );
    (path, daemon)
}

/// #29 review 1: a notice whose type_text fails stays queued for the retry.
#[test]
fn a_notice_that_fails_to_type_stays_queued() {
    let (path, _daemon) = butler_with_member("notice-type-fails");
    let sent = eval(
        &path,
        "remuda._butler_notify_policy = function() return true end; \
         remuda._real_type_text = remuda.type_text; \
         remuda.type_text = function() error('pty write failed') end; \
         return remuda._butler_send('operator', 'm1', 'hi')",
    );
    assert!(sent.contains("terminal delivery deferred"), "{sent}");
    assert_eq!(eval(&path, "return remuda._butler_bus.notices.m1.count"), "1");
    eval(
        &path,
        "remuda.type_text = remuda._real_type_text; remuda._butler_deliver_notices()",
    );
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.notices.m1)"), "nil");
}

/// #29 review 2: an exited session's pending notice and screen record go too.
#[test]
fn session_exit_clears_the_notice_queue_and_screen_record() {
    let (path, _daemon) = butler_with_member("notice-exit");
    eval(
        &path,
        "remuda._butler_notify_policy = function() return false end; \
         remuda._butler_send('operator', 'm1', 'hi'); \
         remuda._butler_bus.notice_screens.m1 = { screen = '', since = 0 }; \
         remuda.emit('session_exited', 'm1')",
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_bus.notices.m1) .. tostring(remuda._butler_bus.notice_screens.m1)"),
        "nilnil"
    );
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
        r#"local real_ls, real_capture, real_styled = remuda.ls, remuda.capture, remuda.capture_styled
        local row, spans = { name = 'p1', alive = true, attached = true }, {}
        remuda.ls = function() return { row } end
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
        remuda.ls, remuda.capture, remuda.capture_styled = real_ls, real_capture, real_styled
        return table.concat(r, ' ')"#,
    );
    assert_eq!(
        got,
        "typing=false ghost=true ghost_words=true typed=false never=true off_prompt=false detached_typed=false detached_empty=true knob=false"
    );
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
