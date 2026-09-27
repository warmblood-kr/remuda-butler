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
