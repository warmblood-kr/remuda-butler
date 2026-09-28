//! The daemon end to end: over a real socket, and through a real terminal.
//!
//! 정수님, 2026-09-10: *"a tmux like pty manager, which support daemon mode.
//! with session list so that user can select a session to attach."* These are
//! the three claims in that sentence — sessions outlive their client, they can
//! be listed, and one can be attached — each exercised rather than asserted.
//!
//! The attach test runs the shipped `remuda` binary **inside a pty of our own**,
//! which is the only way to exercise raw mode and the detach key at all: those
//! paths are unreachable without a controlling terminal. remuda is used to test
//! remuda, and that is not circular — the pty under the test is this crate's,
//! the terminal under test is the binary's.

use remuda_core::protocol::{Request, Response};
use remuda_core::{Session, Size};
use remuda_native::{client, daemon, ipc, CommandBuilder, PtyAgent, SystemClock};
use std::path::{Path, PathBuf};
use std::os::unix::process::CommandExt;
use std::sync::Arc;
use std::time::{Duration, Instant};

const PATIENCE: Duration = Duration::from_secs(10);

/// A runtime directory of our own. Short enough for `sun_path` (~108 bytes) —
/// a long path fails at bind with a message no caller would guess from a
/// timeout, which is what the binary's startup-error handling exists for.
fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("remuda-t{}-{tag}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// The address, derived the way the shipped binary derives it. Hand-building
/// one that merely resembles it is what made the attach test fail first time.
fn scratch(tag: &str) -> PathBuf {
    daemon::socket_path_in(&scratch_dir(tag), "s")
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

fn new_session(path: &Path, name: &str) {
    let response = client::request(
        path,
        &Request::New {
            name: Some(name.to_string()),
            command: vec!["sh".into()],
            size: Size::new(80, 24),
            cwd: None,
            env: None,
        },
    )
    .expect("new");
    assert_eq!(
        response,
        Response::Value(name.to_string()),
        "New answers with the name it gave the session"
    );
}

fn capture(path: &Path, name: &str) -> String {
    match client::request(
        path,
        &Request::Capture {
            name: name.to_string(),
        },
    ) {
        Ok(Response::Screen(text)) => text,
        other => panic!("capture failed: {other:?}"),
    }
}

const FAKE_COMPACTION_EXPECT: &str = r#"
  local fake_ctx, fake_model = "500000", "Opus"
  remuda._butler_telemetry_for = function() return { context_used = fake_ctx, model = fake_model } end
  remuda.capture = function() return "MODEL:" .. fake_model .. " CTX:" .. fake_ctx .. "\nmock screen" end
  remuda._butler_prompt_is_empty = function() return "EMPTY" end
  remuda.expect_option = function() return "1" end
  remuda.expect = function(_, branches)
    local branch = branches[1]
    if branch.id == "restore-dialog" then
      branch.action("Switch model?\n1. Yes, switch to Sonnet\n2. No")
    elseif branch.id == "compact-complete" or branch.id == "verified" then
      fake_ctx, fake_model = "200000", "Opus"
      if branch.match() then branch.action() end
    end
    return { state = { status = "matched" } }
  end
"#;

fn wait_for(path: &Path, name: &str, needle: &str) -> String {
    let deadline = Instant::now() + PATIENCE;
    loop {
        let screen = capture(path, name);
        if screen.contains(needle) {
            return screen;
        }
        assert!(
            Instant::now() < deadline,
            "{needle:?} never appeared in {name}. screen:\n{screen}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_second_listener_cannot_unlink_a_live_daemons_socket() {
    let path = scratch("live-listener");
    let _first = ipc::listen(&path).expect("first listener binds");

    let second = ipc::listen(&path).expect_err("a live listener must keep its address");
    assert_eq!(second.kind(), std::io::ErrorKind::AddrInUse);
    assert!(
        ipc::connect(&path).is_ok(),
        "the first daemon remains reachable"
    );
}

#[test]
fn sessions_are_listed_and_kept_apart() {
    let path = scratch("list");
    let _daemon = daemon_at(&path);

    // Negative control: the list is empty before anything is started, so a
    // "sessions appear" assertion cannot be satisfied by a list that is simply
    // always full.
    match client::request(&path, &Request::List).expect("list") {
        Response::Sessions(s) => assert!(s.is_empty(), "a fresh daemon holds nothing"),
        other => panic!("unexpected: {other:?}"),
    }

    new_session(&path, "alpha");
    new_session(&path, "bravo");

    let names = match client::request(&path, &Request::List).expect("list") {
        Response::Sessions(s) => s.into_iter().map(|s| s.name).collect::<Vec<_>>(),
        other => panic!("unexpected: {other:?}"),
    };
    assert_eq!(names, ["alpha", "bravo"]);

    // Instructions must land in the session they name and nowhere else — the
    // property a shared pty would break.
    client::request(
        &path,
        &Request::SendLine {
            name: "alpha".into(),
            text: "echo $((6*7))-alpha".into(),
        },
    )
    .expect("send");

    wait_for(&path, "alpha", "42-alpha");
    let bravo = capture(&path, "bravo");
    assert!(
        !bravo.contains("42-alpha"),
        "bravo saw alpha's output:\n{bravo}"
    );
}

#[test]
fn an_unnamed_session_names_itself_after_the_program_and_dedupes() {
    // Bug A by construction: the person types the program, never a name, so no
    // leading positional can eat the word they meant to run.
    let path = scratch("generated");
    let _daemon = daemon_at(&path);

    let make = || {
        client::request(
            &path,
            &Request::New {
                name: None,
                command: vec!["sh".into()],
                size: Size::new(80, 24),
                cwd: None,
                env: None,
            },
        )
        .expect("new")
    };

    assert_eq!(make(), Response::Value("sh".into()));
    assert_eq!(make(), Response::Value("sh-2".into()));
    assert_eq!(make(), Response::Value("sh-3".into()));

    // And the caller can address what it just made, which is the whole reason
    // `New` had to start answering with a value.
    let seen: Vec<String> = match client::request(&path, &Request::List).expect("ls") {
        Response::Sessions(sessions) => sessions.into_iter().map(|s| s.name).collect(),
        other => panic!("unexpected: {other:?}"),
    };
    assert_eq!(seen, vec!["sh", "sh-2", "sh-3"]);
}

#[test]
fn a_taken_name_is_refused_in_words() {
    let path = scratch("dup");
    let _daemon = daemon_at(&path);
    new_session(&path, "only");

    let again = client::request(
        &path,
        &Request::New {
            name: Some("only".into()),
            command: vec!["sh".into()],
            size: Size::new(80, 24),
            cwd: None,
            env: None,
        },
    )
    .expect("second new");

    match again {
        Response::Error(reason) => assert!(
            reason.contains("name taken"),
            "the reason must say what went wrong, got: {reason}"
        ),
        other => panic!("a duplicate name must be refused, got {other:?}"),
    }
}

#[test]
fn a_session_launches_into_the_cwd_it_is_given() {
    // Without a `cwd`, a session inherits the daemon's own directory — this
    // proves the caller can override that, not merely that the daemon starts.
    let path = scratch("cwd");
    let _daemon = daemon_at(&path);

    let dir = scratch_dir("cwd-target");
    let response = client::request(
        &path,
        &Request::New {
            name: Some("in-tmp".into()),
            command: vec!["pwd".into()],
            size: Size::new(80, 24),
            cwd: Some(dir.to_string_lossy().into_owned()),
            env: None,
        },
    )
    .expect("new");
    assert_eq!(response, Response::Value("in-tmp".into()));

    // `pwd`'s own rendering of a path is platform-specific (Windows' shell
    // spells it `\\?\C:\...`, a POSIX shell `/c/...`) — the directory's own
    // name is the one substring both agree on, so that is what we look for.
    let needle = dir
        .file_name()
        .and_then(|n| n.to_str())
        .expect("scratch dir has a name")
        .to_string();
    wait_for(&path, "in-tmp", &needle);
}

#[test]
fn a_live_session_resizes_and_reports_its_new_size() {
    let path = scratch("resize");
    let _daemon = daemon_at(&path);
    new_session(&path, "resizable");

    let target = Size::new(120, 36);
    assert_eq!(
        client::request(
            &path,
            &Request::Resize {
                name: "resizable".into(),
                size: target
            },
        )
        .expect("resize"),
        Response::Ok
    );
    let sessions = match client::request(&path, &Request::List).expect("list") {
        Response::Sessions(sessions) => sessions,
        other => panic!("unexpected: {other:?}"),
    };
    assert_eq!(sessions[0].size, target);
    client::request(
        &path,
        &Request::SendLine {
            name: "resizable".into(),
            text: "stty size".into(),
        },
    )
    .expect("ask terminal size");
    wait_for(&path, "resizable", "36 120");
}

#[test]
fn a_topic_directory_can_be_made_listed_and_removed_even_with_a_space_in_its_name() {
    // A space in the name is the whole point: `os.execute("mkdir -p ...")`
    // would mangle this, real `std::fs` calls do not.
    let path = scratch("dirverbs");
    let _daemon = daemon_at(&path);

    let base = scratch_dir("dirverbs-base");
    let target = base.join("topic with a space");
    let target_str = target.to_string_lossy().into_owned();

    let response = client::request(
        &path,
        &Request::Mkdir {
            path: target_str.clone(),
        },
    )
    .expect("mkdir");
    assert_eq!(response, Response::Ok);
    assert!(target.is_dir());

    std::fs::write(target.join("note.txt"), b"hi").expect("write");

    match client::request(
        &path,
        &Request::ListDir {
            path: target_str.clone(),
        },
    )
    .expect("list_dir")
    {
        Response::Entries(names) => assert_eq!(names, vec!["note.txt".to_string()]),
        other => panic!("unexpected: {other:?}"),
    }

    let response = client::request(&path, &Request::RemoveDirAll { path: target_str })
        .expect("remove_dir_all");
    assert_eq!(response, Response::Ok);
    assert!(!target.exists());
}

#[test]
fn a_wire_size_below_the_floor_is_clamped_not_honoured() {
    // A constructor that clamps is worth nothing if a peer can post JSON around
    // it. 11 columns is the width that silently ate keystrokes in the
    // implementation this replaces.
    let request: Request =
        serde_json::from_str(r#"{"New":{"name":"tiny","command":[],"size":{"cols":11,"rows":2}}}"#)
            .expect("parse");

    match request {
        Request::New { size, .. } => {
            assert_eq!(
                (size.cols(), size.rows()),
                (80, 24),
                "clamped on the way in"
            );
        }
        other => panic!("unexpected: {other:?}"),
    }
}

#[test]
fn a_human_attaches_through_a_real_terminal_and_detaches_with_ctrl_backslash() {
    // The binary derives its socket as $REMUDA_RUNTIME_DIR/remuda/default.sock,
    // so the daemon must listen exactly there. Pointing the test somewhere else
    // is what made the first run fail — and it failed as "no repaint", which
    // names the wrong wall just like the swallowed startup error did.
    let dir = scratch_dir("attach");
    let path = daemon::socket_path_in(&dir, "default");
    let _daemon = daemon_at(&path);
    new_session(&path, "target");

    // Put something on screen BEFORE attaching, so the repaint has something to
    // prove. A viewer that only streams would show a blank terminal here.
    client::request(
        &path,
        &Request::SendLine {
            name: "target".into(),
            text: "echo $((11*11))-before".into(),
        },
    )
    .expect("send");
    wait_for(&path, "target", "121-before");

    // The real binary, on a real pty, so raw mode is actually entered.
    let mut cmd = CommandBuilder::new(env!("CARGO_BIN_EXE_remuda"));
    cmd.arg("attach");
    cmd.arg("target");
    cmd.env("REMUDA_RUNTIME_DIR", &dir);
    let viewer = Session::new(
        "viewer",
        Box::new(PtyAgent::spawn(cmd, Size::new(80, 24)).expect("spawn viewer")),
        Arc::new(SystemClock::new()),
    );

    // 1. Repaint: what was already there arrives without the program redrawing.
    let deadline = Instant::now() + PATIENCE;
    loop {
        let screen = viewer.screen_text().expect("viewer screen");
        if screen.contains("121-before") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "attach did not repaint the existing screen. viewer saw:\n{screen}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    // 2. Keystrokes reach the far session, and its output comes back.
    let held = viewer.attach();
    held.write_raw(b"echo $((6*7))-typed\r").expect("type");
    wait_for(&path, "target", "42-typed");

    // 3. Ctrl-\ detaches. The proof is on the far side: the core is refused
    //    while attached and accepted afterwards, so this cannot pass by the
    //    client merely exiting for some other reason.
    assert!(
        matches!(
            client::request(
                &path,
                &Request::SendLine {
                    name: "target".into(),
                    text: "echo LEAKED".into()
                }
            ),
            Ok(Response::Error(_))
        ),
        "while a human holds it, the core must be refused"
    );

    held.write_raw(&[client::DETACH]).expect("Ctrl-\\");
    drop(held);

    let deadline = Instant::now() + PATIENCE;
    loop {
        let resumed = client::request(
            &path,
            &Request::SendLine {
                name: "target".into(),
                text: "echo $((9*9))-after".into(),
            },
        );
        if matches!(resumed, Ok(Response::Ok)) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the core never regained the session after detach: {resumed:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    let screen = wait_for(&path, "target", "81-after");
    assert!(
        !screen.contains("LEAKED"),
        "a refused instruction reached the process anyway:\n{screen}"
    );
}

#[test]
fn a_registered_schedule_actually_fires_through_a_real_daemon() {
    let path = scratch("schedule");
    let _daemon = daemon_at(&path);

    // `every` is seconds on native's own clock, kept tiny so the test's
    // PATIENCE window covers many ticks rather than racing a single one.
    let register = Request::Eval {
        code: r#"
            remuda.fired = 0
            remuda.schedule({
              name = "test-schedule",
              every = 0.01,
              run = function() remuda.fired = remuda.fired + 1 end,
            })
        "#
        .to_string(),
        name: None,
    };
    match client::request(&path, &register).expect("register") {
        Response::Value(_) => {}
        other => panic!("unexpected: {other:?}"),
    }

    let deadline = Instant::now() + PATIENCE;
    loop {
        let fired = client::request(
            &path,
            &Request::Eval {
                code: "return remuda.fired".to_string(),
                name: None,
            },
        )
        .expect("read fired");
        // >= 2, not != "0" — the name promises PERIODIC firing, and a
        // scheduler that fires once and stops must fail this test.
        if matches!(&fired, Response::Value(v) if v.parse::<u32>().is_ok_and(|n| n >= 2)) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the schedule did not fire at least twice: {fired:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn eval(path: &Path, code: &str) -> String {
    match client::request(
        path,
        &Request::Eval {
            code: code.to_string(),
            name: None,
        },
    )
    .expect("eval")
    {
        Response::Value(v) => v,
        other => panic!("unexpected: {other:?}"),
    }
}

fn read_count(path: &Path, code: &str) -> u32 {
    eval(path, code).parse().expect("a number")
}

#[test]
fn a_session_exited_hook_fires_when_a_real_session_dies() {
    // `session_exited` is remuda's own first real event: fired once for each
    // session the daemon's ticker notices has died. Nothing calls
    // `remuda.emit("session_exited", ...)` anywhere yet, so this must fail red.
    let path = scratch("session-exited");
    let _daemon = daemon_at(&path);

    eval(
        &path,
        r#"
            remuda._session_exited_names = {}
            remuda.on("session_exited", function(name)
                table.insert(remuda._session_exited_names, name)
            end)
        "#,
    );

    // Exits on its own almost immediately, so the ticker's very next tick
    // (TICK_PERIOD is 1s, see daemon.rs) has something dead to reap well
    // inside PATIENCE.
    let response = client::request(
        &path,
        &Request::New {
            name: Some("short-lived".into()),
            command: vec!["sh".into(), "-c".into(), "exit 0".into()],
            size: Size::new(80, 24),
            cwd: None,
            env: None,
        },
    )
    .expect("new");
    assert_eq!(response, Response::Value("short-lived".into()));

    // Negative control: a session that stays alive throughout must never be
    // named — this is fine to trivially hold today too, since nothing fires
    // the event for anyone yet.
    new_session(&path, "long-lived");

    let deadline = Instant::now() + PATIENCE;
    loop {
        let seen = eval(
            &path,
            "return table.concat(remuda._session_exited_names, ',')",
        );
        if seen.split(',').any(|n| n == "short-lived") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "session_exited never fired for short-lived. seen so far: {seen:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let seen = eval(
        &path,
        "return table.concat(remuda._session_exited_names, ',')",
    );
    assert!(
        !seen.split(',').any(|n| n == "long-lived"),
        "a still-alive session must never appear in session_exited names: {seen:?}"
    );
}

#[test]
fn a_session_exited_hook_still_fires_once_when_ls_reaps_before_the_tick() {
    // `Registry::reap()` removes what it finds and hands it only to whoever
    // calls first. A `List` that reaps well inside TICK_PERIOD must not make
    // the ticker's own later reap silently find nothing to emit for — and it
    // must not double-emit either, once every reap site funnels through one
    // notifying path.
    let path = scratch("session-exited-race");
    let _daemon = daemon_at(&path);

    eval(
        &path,
        r#"
            remuda._race_exited_names = {}
            remuda.on("session_exited", function(name)
                table.insert(remuda._race_exited_names, name)
            end)
        "#,
    );

    let response = client::request(
        &path,
        &Request::New {
            name: Some("race-short-lived".into()),
            command: vec!["sh".into(), "-c".into(), "exit 0".into()],
            size: Size::new(80, 24),
            cwd: None,
            env: None,
        },
    )
    .expect("new");
    assert_eq!(response, Response::Value("race-short-lived".into()));

    // Well inside TICK_PERIOD (1s) — this reaps the session before the
    // ticker's own tick has a chance to.
    std::thread::sleep(Duration::from_millis(80));
    client::request(&path, &Request::List).expect("list");

    // Give the ticker a full period too, so a double-emit (both paths firing)
    // would have every chance to show up if the funnel were not idempotent.
    std::thread::sleep(Duration::from_millis(1200));

    let names = eval(&path, "return table.concat(remuda._race_exited_names, ',')");
    let count = names
        .split(',')
        .filter(|n| *n == "race-short-lived")
        .count();
    assert_eq!(
        count, 1,
        "expected exactly one session_exited for race-short-lived, got {count}: {names:?}"
    );
}

#[test]
fn a_hostile_session_name_reaches_the_hook_byte_for_byte() {
    // `Request::New`'s name has no validation at all beyond uniqueness (see
    // `spawn`/`Registry::register`) — a caller may hand over anything. The
    // emit path splices it into a Lua source string via `mcp::lua_string`, so
    // a quote or backslash proves that escaping is real, not merely untested.
    let path = scratch("session-exited-hostile");
    let _daemon = daemon_at(&path);
    let hostile = r#"it's a "test" \with\backslashes"#;

    eval(&path, "remuda._hostile_exited_names = {}");
    eval(
        &path,
        "remuda.on(\"session_exited\", function(name) \
            table.insert(remuda._hostile_exited_names, name) \
         end)",
    );

    let response = client::request(
        &path,
        &Request::New {
            name: Some(hostile.to_string()),
            command: vec!["sh".into(), "-c".into(), "exit 0".into()],
            size: Size::new(80, 24),
            cwd: None,
            env: None,
        },
    )
    .expect("new");
    assert_eq!(response, Response::Value(hostile.to_string()));

    let deadline = Instant::now() + PATIENCE;
    loop {
        let count = read_count(&path, "return #remuda._hostile_exited_names");
        if count >= 1 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "session_exited never fired for the hostile name"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Exact match, not a substring or a count — proof the name arrived intact
    // rather than truncated or escaped-then-left-escaped by a naive splice.
    assert_eq!(
        eval(&path, "return remuda._hostile_exited_names[1]"),
        hostile,
        "the hostile name did not survive the emit path unchanged"
    );
    assert_eq!(
        read_count(&path, "return #remuda._hostile_exited_names"),
        1,
        "no injected code should have run more than once, nor duplicated the entry"
    );
}

#[test]
fn cancelling_one_same_label_schedule_leaves_the_other_firing() {
    // The gap measured on 09-13: a name-keyed table means a second
    // registrant under the same label silently replaces the first. A handle
    // fixes it — two schedules can share a label and coexist, and only the
    // handle that was actually cancelled stops.
    let path = scratch("schedule-cancel");
    let _daemon = daemon_at(&path);

    eval(
        &path,
        r#"
            remuda.fired_a, remuda.fired_b = 0, 0
            remuda.handle_a = remuda.schedule({
              name = "dup",
              every = 0.01,
              run = function() remuda.fired_a = remuda.fired_a + 1 end,
            })
            remuda.handle_b = remuda.schedule({
              name = "dup",
              every = 0.01,
              run = function() remuda.fired_b = remuda.fired_b + 1 end,
            })
        "#,
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.fired_a") < 2
        || read_count(&path, "return remuda.fired_b") < 2
    {
        assert!(
            Instant::now() < deadline,
            "both same-label schedules must fire independently"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    eval(&path, "remuda.cancel(remuda.handle_a)");
    let a_at_cancel = read_count(&path, "return remuda.fired_a");

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.fired_b") < a_at_cancel + 2 {
        assert!(
            Instant::now() < deadline,
            "the surviving schedule must keep firing"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        read_count(&path, "return remuda.fired_a"),
        a_at_cancel,
        "the cancelled schedule must not fire again"
    );
}

#[test]
fn event_counts_reads_zero_before_any_emit_and_n_after_real_fires() {
    // `remuda.event_counts()` does not exist yet — this must fail red with a
    // Lua "attempt to call a nil value" error, not a compile error.
    let path = scratch("event-counts");
    let _daemon = daemon_at(&path);

    eval(&path, r#"remuda.on("counter_test_event", function() end)"#);

    // A name `emit` has never been called with is absent, not zero — Lua's
    // `nil` is the only value that says so.
    assert_eq!(
        eval(&path, "return remuda.event_counts()['counter_test_event']"),
        "nil",
        "an event never emitted must be absent from event_counts(), not zero"
    );

    for _ in 0..3 {
        eval(&path, "remuda.emit('counter_test_event')");
    }

    assert_eq!(
        read_count(&path, "return remuda.event_counts()['counter_test_event']"),
        3,
        "event_counts() must count every real emit call"
    );
}

#[test]
fn schedule_fires_reads_zero_before_any_run_and_n_after_real_ticks() {
    // `remuda.schedule_fires()` does not exist yet — same nil-call failure
    // expected as `event_counts()` above.
    let path = scratch("schedule-fires");
    let _daemon = daemon_at(&path);

    eval(
        &path,
        r#"
            remuda.schedule({
              name = "counter_test_schedule",
              every = 1,
              run = function() end,
            })
        "#,
    );

    // Before any tick has elapsed, an unfired named schedule is absent too.
    assert_eq!(
        eval(
            &path,
            "return remuda.schedule_fires()['counter_test_schedule']"
        ),
        "nil",
        "a schedule that has never fired must be absent, not zero"
    );

    let deadline = Instant::now() + PATIENCE;
    loop {
        let fires = eval(
            &path,
            "return remuda.schedule_fires()['counter_test_schedule']",
        );
        if fires.parse::<u32>().is_ok_and(|n| n >= 3) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "counter_test_schedule did not fire at least 3 times: {fires:?}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // An unnamed schedule (`spec.name` left nil) must never appear as a key
    // at all — `t[nil] = x` is a Lua error, so the increment must be skipped
    // rather than crash the daemon. A side-channel counter proves it really
    // fired even though `schedule_fires()` must stay silent about it.
    eval(&path, "remuda._unnamed_fired = 0");
    eval(
        &path,
        r#"
            remuda.schedule({
              every = 1,
              run = function() remuda._unnamed_fired = remuda._unnamed_fired + 1 end,
            })
        "#,
    );

    let before_keys = eval(
        &path,
        "local n = 0 for _ in pairs(remuda.schedule_fires()) do n = n + 1 end return n",
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda._unnamed_fired") < 3 {
        assert!(
            Instant::now() < deadline,
            "the unnamed schedule never fired"
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    let after_keys = eval(
        &path,
        "local n = 0 for _ in pairs(remuda.schedule_fires()) do n = n + 1 end return n",
    );
    assert_eq!(
        before_keys, after_keys,
        "an unnamed schedule must add no key to schedule_fires(), even after firing"
    );
}

#[test]
fn mutating_the_returned_event_counts_table_does_not_change_internal_state() {
    // Both accessors must hand back a snapshot, the same guarantee
    // `remuda.emit`'s own hook snapshot already keeps for `remuda.hooks`
    // (see tools.lua) — a caller mutating what it was handed must never
    // reach back into the daemon's own counters.
    let path = scratch("counters-are-copies");
    let _daemon = daemon_at(&path);

    eval(&path, r#"remuda.on("copy_test_event", function() end)"#);
    eval(&path, "remuda.emit('copy_test_event')");
    eval(
        &path,
        "local t = remuda.event_counts() t['copy_test_event'] = 9999",
    );
    assert_eq!(
        read_count(&path, "return remuda.event_counts()['copy_test_event']"),
        1,
        "event_counts() must return a copy, not a live reference"
    );

    eval(
        &path,
        r#"
            remuda.schedule({
              name = "copy_test_schedule",
              every = 1,
              run = function() end,
            })
        "#,
    );
    let deadline = Instant::now() + PATIENCE;
    loop {
        let fires = eval(
            &path,
            "return remuda.schedule_fires()['copy_test_schedule']",
        );
        if fires.parse::<u32>().is_ok_and(|n| n >= 1) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "copy_test_schedule never fired: {fires:?}"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    let before = read_count(
        &path,
        "return remuda.schedule_fires()['copy_test_schedule']",
    );
    eval(
        &path,
        "local t = remuda.schedule_fires() t['copy_test_schedule'] = 9999",
    );
    assert_eq!(
        read_count(
            &path,
            "return remuda.schedule_fires()['copy_test_schedule']"
        ),
        before,
        "schedule_fires() must return a copy, not a live reference"
    );
}

#[test]
fn the_daemon_names_the_build_it_was_started_from() {
    let path = scratch("version");
    let _daemon = daemon_at(&path);

    match client::request(&path, &Request::Version).expect("version") {
        Response::Value(said) => assert_eq!(said, remuda_native::dist::BUILD_VERSION),
        other => panic!("unexpected: {other:?}"),
    }
}

/// A daemon as its own PROCESS, with its streams pointed at nothing. Inheriting
/// the harness's stdout would let a leaked daemon hold cargo's pipe open, which
/// turns any failure below into a hung job instead of a red one.
struct Daemon(std::process::Child);

impl Daemon {
    fn spawn(dir: &Path) -> Self {
        let child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
            .args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .process_group(0)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let path = daemon::socket_path_in(dir, "s");
        let deadline = Instant::now() + PATIENCE;
        while remuda_native::ipc::connect(&path).is_err() {
            assert!(Instant::now() < deadline, "daemon never bound {path:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }

    /// Like `spawn`, but pins the daemon process's own `PWD` -- `None` unsets
    /// it entirely, rather than leaving whatever the test runner happened to
    /// have, so a directory-derived name test is not at the mercy of `cargo
    /// test`'s own working directory.
    fn spawn_with_pwd(dir: &Path, pwd: Option<&str>) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .process_group(0);
        match pwd {
            Some(p) => cmd.env("PWD", p),
            None => cmd.env_remove("PWD"),
        };
        let child = cmd
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let path = daemon::socket_path_in(dir, "s");
        let deadline = Instant::now() + PATIENCE;
        while remuda_native::ipc::connect(&path).is_err() {
            assert!(Instant::now() < deadline, "daemon never bound {path:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }

    /// Like `spawn`, but layers extra environment variables onto the daemon
    /// process itself -- not the CLI client that later asks it to `exec`
    /// something. `os.getenv` inside `init.lua` reads the daemon's own
    /// environment, so a real (non-`_butler_test_mode`) run needs
    /// `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG` set here, additive to
    /// `spawn`'s existing behavior.
    fn spawn_with_env(dir: &Path, extra_env: &[(&str, &str)]) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .process_group(0);
        for (k, v) in extra_env {
            cmd.env(k, v);
        }
        let child = cmd
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let path = daemon::socket_path_in(dir, "s");
        let deadline = Instant::now() + PATIENCE;
        while remuda_native::ipc::connect(&path).is_err() {
            assert!(Instant::now() < deadline, "daemon never bound {path:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }

    /// Like `spawn_with_env`, but for the birth-environment-poisoning
    /// scenario itself: a daemon born with `HOME` pinned to a scratch
    /// directory and NEITHER `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG`
    /// nor `XDG_CONFIG_HOME` present at all (`env_remove`, not merely
    /// unset-by-omission -- `cargo test`'s own process could otherwise leak
    /// either through, making the test non-deterministic on a machine where
    /// they happen to be set).
    fn spawn_with_home(dir: &Path, home: &Path) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .process_group(0)
            .env("HOME", home)
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("REMUDA_BUTLER_TOKEN")
            .env_remove("REMUDA_BUTLER_CONFIG");
        let child = cmd
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");
        let path = daemon::socket_path_in(dir, "s");
        let deadline = Instant::now() + PATIENCE;
        while remuda_native::ipc::connect(&path).is_err() {
            assert!(Instant::now() < deadline, "daemon never bound {path:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
        Self(child)
    }

    /// Bounded on purpose: an unbounded `wait` on a daemon that did not stop is
    /// the same hang this whole struct exists to avoid.
    fn left_on_its_own(&mut self) -> bool {
        let deadline = Instant::now() + PATIENCE;
        while Instant::now() < deadline {
            if let Ok(Some(status)) = self.0.try_wait() {
                return status.success();
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let process_group = -(self.0.id() as i32);
        unsafe { libc::kill(process_group, libc::SIGKILL); }
        let _ = self.0.kill();
        let _ = self.0.wait();

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut survivors = matrix_relays_in_process_group(-process_group);
        while !survivors.is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            survivors = matrix_relays_in_process_group(-process_group);
        }
        if !survivors.is_empty() {
            if std::thread::panicking() {
                eprintln!("Matrix relay children survived private daemon teardown: {survivors:?}");
            } else {
                panic!("Matrix relay children survived private daemon teardown: {survivors:?}");
            }
        }
    }
}

fn matrix_relays_in_process_group(group: i32) -> Vec<String> {
    let output = std::process::Command::new("ps")
        .args(["-ww", "-axo", "pid=,pgid=,command="])
        .output()
        .expect("scan processes for surviving Matrix relay children");
    assert!(output.status.success(), "ps failed while checking Matrix relay cleanup");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            fields.get(1).and_then(|value| value.parse::<i32>().ok()) == Some(group)
                && line.contains("MAX_PROCESSED_EVENT_IDS = 5000")
        })
        .map(str::to_owned)
        .collect()
}

fn matrix_relays_matching(marker: &Path) -> Vec<String> {
    let output = std::process::Command::new("ps")
        .args(["-ww", "-axo", "pid=,ppid=,command="])
        .output()
        .expect("scan processes for Matrix relay marker argv");
    assert!(output.status.success(), "ps failed while scanning Matrix relay marker argv");
    let marker = marker.to_string_lossy();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| line.contains("MAX_PROCESSED_EVENT_IDS = 5000") && line.contains(marker.as_ref()))
        .map(str::to_owned)
        .collect()
}

/// What a person types, with its own pipes and no terminal — so `restart`
/// reaches the "nothing to ask on" branch rather than blocking on a prompt.
fn remuda(dir: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(args)
        .env("REMUDA_RUNTIME_DIR", dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .output()
        .expect("run remuda")
}

/// Bounded on purpose, like `Daemon::left_on_its_own` — an unbounded wait on
/// a command that hangs is the same failure this exists to catch, fast.
fn remuda_timed(dir: &Path, args: &[&str]) -> std::process::Output {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(args)
        .env("REMUDA_RUNTIME_DIR", dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn remuda");

    let deadline = Instant::now() + PATIENCE;
    loop {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "{args:?} did not exit within PATIENCE"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().expect("collect output")
}

/// `restart` drives the SHIPPED BINARY, not `daemon::serve` on a thread: the
/// stop is a `process::exit`, so an in-process daemon would take the test
/// runner with it — which is also why this is the only honest way to test it.
#[test]
fn restart_stops_a_daemon_and_leaves_the_next_command_free_to_start_one() {
    let dir = scratch_dir("restart");
    let path = daemon::socket_path_in(&dir, "s");
    let mut daemon = Daemon::spawn(&dir);

    // Positive control: it is answering before we ask it to stop, so "the
    // socket is silent" below cannot pass on a daemon that never came up.
    assert!(
        String::from_utf8_lossy(&remuda(&dir, &["-s", "s", "ls"]).stdout).contains("no sessions"),
        "the daemon was not answering to begin with"
    );

    let out = remuda(&dir, &["-s", "s", "restart"]);
    let said = String::from_utf8_lossy(&out.stderr).to_string();
    assert!(out.status.success(), "restart failed: {said}");
    assert!(said.contains("stopped the daemon"), "{said}");
    assert!(
        remuda_native::ipc::connect(&path).is_err(),
        "the daemon is still answering after restart"
    );
    assert!(daemon.left_on_its_own(), "it did not exit 0 on its own");
}

#[test]
fn restart_with_no_daemon_running_is_not_an_error() {
    let dir = scratch_dir("restart-empty");
    let out = remuda(&dir, &["-s", "s", "restart"]);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("no daemon running"));
}

/// A live herd must not be thrown away by a command that was typed by habit.
/// With no terminal to ask on, the refusal names the flag rather than prompting
/// into a pipe that will never answer.
#[test]
fn restart_refuses_to_kill_a_live_session_without_being_told_twice() {
    let dir = scratch_dir("restart-live");
    let path = daemon::socket_path_in(&dir, "s");
    let mut daemon = Daemon::spawn(&dir);
    new_session(&path, "keeper");

    let out = remuda(&dir, &["-s", "s", "restart"]);
    let said = String::from_utf8_lossy(&out.stderr).to_string();
    assert!(
        !out.status.success(),
        "it killed a live herd unasked: {said}"
    );
    assert!(
        said.contains("keeper"),
        "it did not name what it would lose: {said}"
    );
    assert!(
        remuda_native::ipc::connect(&path).is_ok(),
        "the daemon died despite refusing"
    );

    // -f is the way past it, and the same daemon now goes.
    let forced = remuda(&dir, &["-s", "s", "restart", "-f"]);
    assert!(
        forced.status.success(),
        "{}",
        String::from_utf8_lossy(&forced.stderr)
    );
    assert!(daemon.left_on_its_own(), "-f did not stop it");
}

/// `exec` runs a built-in package's entry file in the daemon's own image —
/// not a fresh interpreter — so a global it sets is visible to a later `-e`
/// against the same daemon. The daemon is pre-started here (rather than
/// relying on `with_daemon`'s auto-start) to avoid its piped stderr, which a
/// leaked auto-started daemon can inherit on Windows. That means `remuda
/// exec`'s real-life auto-start path — invoked from a script with no daemon
/// already running — is deliberately NOT covered by this test on Windows;
/// see warmblood-kr/remuda#54.
///
/// `packages/butler/init.lua` now needs real Matrix config to run past this
/// point (`REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG`), which this test
/// deliberately never provides — `remuda._butler_test_mode` is exactly the
/// escape hatch it exposes for that (see `native/tests/daemon.rs`'s own
/// `butler_test_daemon` and the tests around it for the full package), so
/// this test asserts only that the package's internal Matrix module and MCP
/// source share the daemon image.
#[test]
fn exec_butler_runs_the_builtin_package_in_the_daemons_image() {
    let dir = scratch_dir("exec-butler");
    let _daemon = Daemon::spawn(&dir);

    let mode = remuda_timed(&dir, &["-s", "s", "-e", "remuda._butler_test_mode = true"]);
    assert!(
        mode.status.success(),
        "{}",
        String::from_utf8_lossy(&mode.stderr)
    );

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let path = daemon::socket_path_in(&dir, "s");
    let matrix_entry = eval(&path, "local ok, err = pcall(remuda.exec, 'butler/matrix'); return tostring(ok) .. '|' .. tostring(err)");
    assert!(matrix_entry.starts_with("true|"), "Butler's internal Matrix package failed to load: {matrix_entry}");

    let deadline = Instant::now() + PATIENCE;
    let read = loop {
        let read = remuda_timed(
            &dir,
            &[
                "-s",
                "s",
                "-e",
                "return (remuda._butler_helper_src ~= nil and remuda._butler_reply_src ~= nil) \
                 and 'ok' or 'missing'",
            ],
        );
        if String::from_utf8_lossy(&read.stdout).trim() == "ok" {
            break read;
        }
        assert!(Instant::now() < deadline, "Butler package did not load its internal sources");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(
        read.status.success(),
        "{}",
        String::from_utf8_lossy(&read.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&read.stdout).trim(),
        "ok",
        "the butler package did not set its embedded-source globals in this image"
    );
}

#[test]
fn butler_lifecycle_reload_replaces_hooks_and_schedules_and_rolls_back() {
    let path = scratch("butler-lifecycle-reload");
    let _daemon = daemon_at(&path);
    eval(
        &path,
        "remuda._butler_test_mode = 'lifecycle'; remuda.exec('butler')",
    );

    let main = include_str!("../../packages/butler/main.lua");
    assert!(
        !main.contains("remuda.clear_hooks(") && !main.contains("remuda.hooks[event]"),
        "Butler registrations must be lifecycle-owned, without file-scope clearing or hand-purging"
    );

    let counts = r#"
        local inbox, owned, notices, reconcile, compaction, owned_contributions = 0, 0, 0, 0, 0, -1
        for _, hook in ipairs(remuda.hook_list()) do
          if hook.group == "remuda-module:butler" then owned = owned + 1 end
          if hook.event == "butler/deliver" and hook.id == "inbox"
            and hook.group == "remuda-module:butler" then inbox = inbox + 1 end
        end
        for _, schedule in pairs(remuda.schedules) do
          if schedule.name == "butler-notices" then notices = notices + 1 end
          if schedule.name == "butler-reconcile" then reconcile = reconcile + 1 end
          if schedule.name == "butler-compaction" then compaction = compaction + 1 end
        end
        if type(remuda.contributions) == "function" then
          owned_contributions = 0
          for _, point in ipairs({ "butler.command", "butler.guidance" }) do
            for _, item in ipairs(remuda.contributions(point)) do
              if item.owner == "butler" then owned_contributions = owned_contributions + 1 end
            end
          end
        end
        return table.concat({ inbox, owned, notices, reconcile, compaction, owned_contributions }, "|")
    "#;
    let initial = eval(&path, counts);
    assert!(
        initial == "1|7|1|1|1|15" || initial == "1|7|1|1|1|-1",
        "unexpected Butler lifecycle registrations: {initial}"
    );

    // Simulate the dynamic schedule handle created by a pre-step-4 Butler.
    // The first lifecycle start must migrate its enabled state and replace it.
    eval(
        &path,
        r#"remuda._butler_compaction_schedule = remuda.schedule({
          name = "butler-compaction", every = 60, run = function() end
        })"#,
    );

    for _ in 0..3 {
        eval(&path, "remuda.reload('butler')");
        assert_eq!(
            eval(&path, counts),
            initial,
            "reload duplicated Butler registrations"
        );
        assert_eq!(
            eval(
                &path,
                "return tostring(remuda._butler_state.compaction_enabled)"
            ),
            "true",
            "reload did not preserve the previously enabled compaction schedule"
        );
        assert!(
            read_count(
                &path,
                r#"local n = 0 for _, s in pairs(remuda.schedules) do
                  if s.name == "butler-start-fallback" then n = n + 1 end
                end return n"#,
            ) <= 1,
            "reload duplicated the one-shot start compatibility schedule"
        );
    }

    let failed = eval(
        &path,
        r#"
            local original = remuda.emit
            remuda.emit = function(event, ...)
              if event == "butler-start" then error("injected Butler start failure") end
              return original(event, ...)
            end
            local ok, err = pcall(remuda.reload, "butler")
            remuda.emit = original
            return tostring(ok) .. "|" .. tostring(err)
        "#,
    );
    assert!(
        failed.starts_with("false|"),
        "reload should report its failed start: {failed}"
    );
    assert!(
        failed.contains("injected Butler start failure"),
        "wrong start error: {failed}"
    );
    assert_eq!(
        eval(&path, counts),
        initial,
        "failed reload did not restore Butler registrations"
    );
    assert!(
        read_count(
            &path,
            r#"local n = 0 for _, s in pairs(remuda.schedules) do
              if s.name == "butler-start-fallback" then n = n + 1 end
            end return n"#,
        ) <= 1,
        "failed reload left multiple start compatibility schedules"
    );
}

/// `remuda._butler_initial_name` is set before the test-mode return (see
/// `init.lua`), so this reaches real code without needing the live `claude`
/// launch that `remuda._butler_test_mode` exists to avoid.
#[test]
fn butler_initial_name_is_butler_even_with_a_launch_directory() {
    let dir = scratch_dir("butler-name-basename");
    let _daemon = Daemon::spawn_with_pwd(&dir, Some("/home/x/my-project/"));

    let mode = remuda_timed(&dir, &["-s", "s", "-e", "remuda._butler_test_mode = true"]);
    assert!(
        mode.status.success(),
        "{}",
        String::from_utf8_lossy(&mode.stderr)
    );

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let name = remuda_timed(
        &dir,
        &["-s", "s", "-e", "return remuda._butler_initial_name"],
    );
    assert!(
        name.status.success(),
        "{}",
        String::from_utf8_lossy(&name.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&name.stdout).trim(), "butler");
}

/// A daemon without `PWD` has the same stable service name.
#[test]
fn butler_initial_name_falls_back_to_butler_without_a_pwd() {
    let dir = scratch_dir("butler-name-fallback");
    let _daemon = Daemon::spawn_with_pwd(&dir, None);

    let mode = remuda_timed(&dir, &["-s", "s", "-e", "remuda._butler_test_mode = true"]);
    assert!(
        mode.status.success(),
        "{}",
        String::from_utf8_lossy(&mode.stderr)
    );

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let name = remuda_timed(
        &dir,
        &["-s", "s", "-e", "return remuda._butler_initial_name"],
    );
    assert!(
        name.status.success(),
        "{}",
        String::from_utf8_lossy(&name.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&name.stdout).trim(), "butler");
}

/// A name with no matching arm is a plain error naming the package, not a
/// panic or a silent no-op. Daemon pre-started for the same reason as above
/// (auto-start on Windows not covered here; see warmblood-kr/remuda#54).
#[test]
fn exec_of_an_unknown_package_fails_and_names_it() {
    let dir = scratch_dir("exec-unknown");
    let _daemon = Daemon::spawn(&dir);

    let out = remuda_timed(&dir, &["-s", "s", "exec", "definitely-not-a-real-package"]);
    assert!(
        !out.status.success(),
        "an unknown package should not succeed"
    );
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("no such package"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// Lua's long-bracket string form has no escape processing at all — safe
/// for embedding a raw filesystem path (backslashes included) into eval
/// source text without escaping it first.
fn lua_raw_string(s: &str) -> String {
    format!("[[{s}]]")
}

#[test]
fn process_delivers_stdout_lines_in_order_then_an_exit_event() {
    let dir = scratch_dir("process-lines");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let exe = lua_raw_string(env!("CARGO_BIN_EXE_remuda"));

    eval(&path, "remuda.t1_lines = {}");
    eval(&path, "remuda.t1_exit = nil");
    eval(
        &path,
        "remuda.on('t1-line', function(l) table.insert(remuda.t1_lines, l) end)",
    );
    eval(
        &path,
        "remuda.on('t1-exit', function(c) remuda.t1_exit = c end)",
    );
    eval(
        &path,
        &format!(
            "remuda.process{{argv = {{{exe}, '_print_lines', '5', '0'}}, on_line = 't1-line', on_exit = 't1-exit'}}"
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.t1_exit and 1 or 0") == 0 {
        assert!(Instant::now() < deadline, "exit event never arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        eval(&path, "return table.concat(remuda.t1_lines, ',')"),
        "1,2,3,4,5"
    );
}

#[test]
fn a_silent_process_yields_only_the_exit_event() {
    let dir = scratch_dir("process-silent");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let exe = lua_raw_string(env!("CARGO_BIN_EXE_remuda"));

    eval(&path, "remuda.silent_lines = 0");
    eval(&path, "remuda.silent_exit = nil");
    eval(
        &path,
        "remuda.on('silent-line', function() remuda.silent_lines = remuda.silent_lines + 1 end)",
    );
    eval(
        &path,
        "remuda.on('silent-exit', function() remuda.silent_exit = true end)",
    );
    eval(
        &path,
        &format!(
            "remuda.process{{argv = {{{exe}, '_print_lines', '0', '0'}}, on_line = 'silent-line', on_exit = 'silent-exit'}}"
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.silent_exit and 1 or 0") == 0 {
        assert!(Instant::now() < deadline, "exit event never arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(read_count(&path, "return remuda.silent_lines"), 0);
}

/// A pid this daemon spawned is gone: `kill(pid, 0)` — no signal delivered,
/// only whether one *could* be — is ESRCH once the pid is reaped. Anything
/// else (success, or a permission error) means it is still around.
#[cfg(target_os = "linux")]
fn pid_alive(pid: i32) -> bool {
    let rc = unsafe { libc::kill(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// Find a pid's own child, by exact pid, one time — never a glob/grep
/// pattern (this investigation's own history: zsh's globber has produced a
/// false "no matches" from `ps -ef | grep [r]emuda` more than once).
#[cfg(target_os = "linux")]
fn child_pid_of(parent: i32, deadline: Instant) -> Option<i32> {
    loop {
        let out = std::process::Command::new("ps")
            .args(["-o", "pid=", "--ppid", &parent.to_string()])
            .output()
            .expect("ps");
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(pid) = text.split_whitespace().next().and_then(|s| s.parse().ok()) {
            return Some(pid);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// [MEASURED, Linux] This is the actual leak (`process.rs`'s plain-pipe
/// children, "ALWAYS survive daemon death... zero process-group isolation,
/// zero signal handling anywhere") and this is `child_guard::harden`'s fix
/// for it: a real out-of-process daemon, SIGKILLed for real, and its DIRECT
/// `remuda.process` child is gone within PATIENCE — not by any daemon code
/// running (none does, on SIGKILL), but because the kernel itself delivers
/// PDEATHSIG the moment the daemon dies.
///
/// The GRANDCHILD (`sleep`, forked by the `sh` direct child before the kill)
/// is asserted to *survive* the same SIGKILL, on purpose: PDEATHSIG is
/// registered on the direct child alone and is cleared across fork(2), so it
/// cannot reach a process it never touched, and nothing else runs on a raw
/// SIGKILL to sweep the group. This pins the exact boundary named in
/// child_guard.rs's own doc comment and in steps/ "Known ceilings", rather
/// than asserting past it. See
/// `a_clean_shutdown_reaps_a_processs_whole_group_including_a_grandchild`
/// for the one path that DOES reach this grandchild.
///
/// Negative control, run by hand for this round (see steps/ writeup): with
/// `child_guard::harden`'s call in `process.rs::spawn` commented out, this
/// test's first `while pid_alive(direct_pid)` loop times out — nothing tells
/// the kernel to kill the direct child when the daemon dies. Restoring the
/// call makes it pass again.
#[cfg(target_os = "linux")]
#[test]
fn a_sigkilled_daemon_reaps_its_direct_process_child_but_not_an_already_forked_grandchild() {
    let dir = scratch_dir("orphan-reap");
    let daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");

    eval(&path, "remuda.og_lines = {}");
    eval(
        &path,
        "remuda.on('og-line', function(l) table.insert(remuda.og_lines, l) end)",
    );
    eval(
        &path,
        "remuda.process{argv = {'sh', '-c', 'echo $$; sleep 60'}, on_line = 'og-line'}",
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.og_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "the direct child never printed its own pid"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let direct_pid: i32 = eval(&path, "return remuda.og_lines[1]")
        .trim()
        .parse()
        .expect("the printed $$ is a pid");

    let deadline = Instant::now() + PATIENCE;
    let grandchild_pid = child_pid_of(direct_pid, deadline)
        .unwrap_or_else(|| panic!("sleep never forked as a child of {direct_pid}"));
    assert!(
        pid_alive(direct_pid),
        "sanity: direct child must be alive before the kill"
    );
    assert!(
        pid_alive(grandchild_pid),
        "sanity: grandchild must be alive before the kill"
    );

    let daemon_pid = daemon.0.id() as libc::pid_t;
    assert_eq!(
        unsafe { libc::kill(daemon_pid, libc::SIGKILL) },
        0,
        "SIGKILL of the real daemon pid must succeed"
    );

    let deadline = Instant::now() + PATIENCE;
    while pid_alive(direct_pid) {
        assert!(
            Instant::now() < deadline,
            "the direct child ({direct_pid}) outlived a SIGKILLed daemon — child_guard::harden \
             did not reap it"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    // Pin the ceiling: give the kernel a beat, then confirm the grandchild
    // is still here — a raw SIGKILL of the daemon runs no code, so nothing
    // built this round could have reached it.
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        pid_alive(grandchild_pid),
        "a grandchild dying too would mean either this test's premise changed or something \
         now reaps process groups on a signal this round never wired that to — worth knowing, \
         not assuming"
    );

    // Clean up the leak this test just proved exists, so it doesn't actually
    // linger on the machine that ran it.
    unsafe {
        libc::kill(grandchild_pid, libc::SIGKILL);
    }
}

/// [MEASURED, Linux] The one path that DOES reach a grandchild: a clean
/// `remuda restart` sends `Request::Shutdown`, which runs
/// `reap_processes_before_exit` (daemon.rs) before the process exits —
/// `remuda.processes()` + `remuda._process_killpg(id)`, which `killpg`s the
/// whole process group `child_guard::harden` put the direct child in. Both
/// the direct child and the grandchild it already forked are gone.
#[cfg(target_os = "linux")]
#[test]
fn a_clean_shutdown_reaps_a_processs_whole_group_including_a_grandchild() {
    let dir = scratch_dir("orphan-reap-clean");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");

    eval(&path, "remuda.cg_lines = {}");
    eval(
        &path,
        "remuda.on('cg-line', function(l) table.insert(remuda.cg_lines, l) end)",
    );
    eval(
        &path,
        "remuda.process{argv = {'sh', '-c', 'echo $$; sleep 60'}, on_line = 'cg-line'}",
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.cg_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "the direct child never printed its own pid"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let direct_pid: i32 = eval(&path, "return remuda.cg_lines[1]")
        .trim()
        .parse()
        .expect("the printed $$ is a pid");

    let deadline = Instant::now() + PATIENCE;
    let grandchild_pid = child_pid_of(direct_pid, deadline)
        .unwrap_or_else(|| panic!("sleep never forked as a child of {direct_pid}"));
    assert!(
        pid_alive(direct_pid) && pid_alive(grandchild_pid),
        "sanity: both alive pre-restart"
    );

    // No live pty session was ever created here, so `remuda restart` (no
    // `-f`) proceeds straight to `Request::Shutdown` without a confirmation
    // prompt — see `confirm_losses` in src/bin/remuda.rs.
    let out = remuda(&dir, &["-s", "s", "restart"]);
    assert!(
        out.status.success(),
        "restart failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let deadline = Instant::now() + PATIENCE;
    while pid_alive(direct_pid) || pid_alive(grandchild_pid) {
        assert!(
            Instant::now() < deadline,
            "a clean shutdown left something behind: direct {direct_pid} alive={}, grandchild \
             {grandchild_pid} alive={}",
            pid_alive(direct_pid),
            pid_alive(grandchild_pid)
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_line_flood_does_not_starve_the_schedule_ticker() {
    let dir = scratch_dir("process-flood");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let exe = lua_raw_string(env!("CARGO_BIN_EXE_remuda"));
    const FLOOD_LINES: u32 = 3000;
    // A per-line delay, not a bare line count: `daemon.rs`'s own `TICK_PERIOD`
    // is a fixed 1 real second (see its doc comment), independent of the
    // Lua schedule's own `every`, so the ticker's very first wakeup cannot
    // come sooner than that regardless of how this test paces its flood. A
    // delay-free flood of any size a modern machine can push drains in well
    // under one second — measured at ~0.2s for 100k lines — which starves
    // the observation window, not the ticker: there is no failure to see if
    // the flood is already over before the first tick could possibly fire.
    // Pacing by wall-clock sleep (not raw throughput) makes the minimum
    // flood duration (here, >= 6s) independent of the machine's speed.
    const FLOOD_LINE_DELAY_MS: u32 = 2;
    let flood_deadline = Instant::now() + Duration::from_secs(60);

    eval(&path, "remuda.flood_count = 0");
    eval(
        &path,
        "remuda.on('flood-line', function() remuda.flood_count = remuda.flood_count + 1 end)",
    );
    eval(&path, "remuda.ticks = 0");
    eval(
        &path,
        "remuda.schedule{every = 0.05, run = function() remuda.ticks = remuda.ticks + 1 end}",
    );
    eval(
        &path,
        &format!(
            "remuda.process{{argv = {{{exe}, '_print_lines', '{FLOOD_LINES}', '{FLOOD_LINE_DELAY_MS}'}}, on_line = 'flood-line'}}"
        ),
    );

    let mut last_ticks = read_count(&path, "return remuda.ticks");
    let mut ticker_advanced_during_flood = false;
    loop {
        let count = read_count(&path, "return remuda.flood_count");
        if count >= FLOOD_LINES {
            break;
        }
        assert!(
            Instant::now() < flood_deadline,
            "flood never finished ({count}/{FLOOD_LINES})"
        );
        std::thread::sleep(Duration::from_millis(100));
        let ticks = read_count(&path, "return remuda.ticks");
        if ticks > last_ticks {
            ticker_advanced_during_flood = true;
        }
        last_ticks = ticks;
    }
    assert!(
        ticker_advanced_during_flood,
        "the schedule ticker never advanced during the flood"
    );
    assert_eq!(read_count(&path, "return remuda.flood_count"), FLOOD_LINES);

    // A named, generous bound — this asserts "not starved," not a specific
    // performance target.
    let consecutive_skips = read_count(&path, "return remuda.schedule_skips().consecutive");
    assert!(
        consecutive_skips < 20,
        "consecutive schedule skips too high under flood: {consecutive_skips}"
    );
}

#[test]
fn killing_a_process_mid_stream_yields_exit_and_nothing_after() {
    let dir = scratch_dir("process-kill");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let exe = lua_raw_string(env!("CARGO_BIN_EXE_remuda"));

    eval(&path, "remuda.km_lines = 0");
    eval(&path, "remuda.km_exit = nil");
    eval(
        &path,
        "remuda.on('km-line', function() remuda.km_lines = remuda.km_lines + 1 end)",
    );
    eval(
        &path,
        "remuda.on('km-exit', function() remuda.km_exit = true end)",
    );
    // A slow trickle so there is a real window to kill it mid-stream rather
    // than racing its own natural exit.
    eval(
        &path,
        &format!(
            "remuda.km_handle = remuda.process{{argv = {{{exe}, '_print_lines', '100000', '10'}}, on_line = 'km-line', on_exit = 'km-exit'}}"
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.km_lines") < 3 {
        assert!(
            Instant::now() < deadline,
            "process never started producing lines"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    eval(&path, "remuda.kill(remuda.km_handle)");

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.km_exit and 1 or 0") == 0 {
        assert!(
            Instant::now() < deadline,
            "exit event never arrived after kill"
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    let lines_at_exit = read_count(&path, "return remuda.km_lines");
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(&path, "return remuda.km_lines"),
        lines_at_exit,
        "a line arrived after the exit event"
    );
}

/// The paced flood above (`a_line_flood_does_not_starve_the_schedule_ticker`)
/// is deliberately slow enough that `process.rs`'s 4096-line `BUFFER_CAP`
/// never fills, so backpressure itself is never exercised there. This test
/// writes as fast as `_print_lines` can (delay 0) and gives it 5x
/// `BUFFER_CAP` worth of lines, so the buffer must fill — and proves it did,
/// three independent ways:
///
/// 1. The child is *still running* (`remuda.processes()` still lists its id)
///    well after an unblocked 20000-tiny-line write would already have
///    exited on its own — it can only still be alive because its own
///    `write()` is blocked on a full pipe.
/// 2. Total wall-clock time to drain is far longer than an unpaced write of
///    20000 short lines takes with no consumer at all (well under 100ms,
///    unmeasured here, but self-evidently near-instant) — the elapsed time
///    is explainable only by the child being made to wait.
/// 3. The schedule ticker keeps advancing throughout, so none of the above
///    comes at the cost of starving the Image's own FIFO — the property the
///    paced flood test already covers, still held even under real pressure.
///
/// The `on_line` hook itself is a busy loop, not a sleep — Lua has no
/// builtin sleep, and this is simplest thing that reliably costs enough
/// real wall time per line to keep the buffer pinned near `BUFFER_CAP` for
/// long enough to observe, rather than draining in a blink.
#[test]
fn an_unpaced_flood_exercises_real_backpressure_and_the_child_blocks() {
    let dir = scratch_dir("process-unpaced-flood");
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let exe = lua_raw_string(env!("CARGO_BIN_EXE_remuda"));
    const FLOOD_LINES: u32 = 20_000;

    eval(&path, "remuda.up_count = 0");
    eval(&path, "remuda.up_last = 0");
    eval(&path, "remuda.up_broken = false");
    eval(&path, "remuda.up_exit = nil");
    eval(
        &path,
        // Ordering is checked inline, one line at a time, rather than
        // buffered into a 20000-entry table and checked after: `up_broken`
        // catches any gap or repeat the instant it happens, and `up_last`
        // at the end is proof every line 1..N arrived, not a sample of them.
        "remuda.on('up-line', function(l)
            local n = tonumber(l)
            if n ~= remuda.up_last + 1 then remuda.up_broken = true end
            remuda.up_last = n
            local busy = 0
            for i = 1, 10000 do busy = busy + i end
            remuda.up_count = remuda.up_count + 1
        end)",
    );
    eval(
        &path,
        "remuda.on('up-exit', function() remuda.up_exit = true end)",
    );
    eval(&path, "remuda.up_ticks = 0");
    eval(
        &path,
        "remuda.schedule{every = 0.05, run = function() remuda.up_ticks = remuda.up_ticks + 1 end}",
    );

    let spawned_at = Instant::now();
    eval(
        &path,
        &format!(
            "remuda.up_handle = remuda.process{{argv = {{{exe}, '_print_lines', '{FLOOD_LINES}', '0'}}, on_line = 'up-line', on_exit = 'up-exit'}}"
        ),
    );

    // Proof #1: still alive well after an unblocked flood of this size would
    // have finished. `BUFFER_CAP` (4096) plus a typical OS pipe (tens of
    // thousands of bytes, a few thousand lines of this size) is nowhere near
    // 20000 lines, so a child that is still running here is blocked on a
    // full pipe, not merely "still working".
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(
            &path,
            "return (function() \
                for _, id in ipairs(remuda.processes()) do \
                    if id == remuda.up_handle then return 1 end \
                end \
                return 0 \
             end)()"
        ),
        1,
        "the flooding process had already exited after 300ms — \
         backpressure did not hold it, so the buffer/pipe never filled"
    );

    let flood_deadline = Instant::now() + Duration::from_secs(60);
    let mut last_ticks = read_count(&path, "return remuda.up_ticks");
    let mut ticker_advanced_during_flood = false;
    loop {
        let count = read_count(&path, "return remuda.up_count");
        if count >= FLOOD_LINES {
            break;
        }
        assert!(
            Instant::now() < flood_deadline,
            "flood never finished ({count}/{FLOOD_LINES})"
        );
        std::thread::sleep(Duration::from_millis(50));
        let ticks = read_count(&path, "return remuda.up_ticks");
        if ticks > last_ticks {
            ticker_advanced_during_flood = true;
        }
        last_ticks = ticks;
    }

    // Proof #2: it took distinctly longer than an unpaced, unblocked write
    // of 20000 short lines could possibly take on its own. Generous enough
    // to survive a slow CI runner (including Windows), tight enough that
    // "no backpressure" (near-instant) cannot pass it by accident.
    let elapsed = spawned_at.elapsed();
    assert!(
        elapsed > Duration::from_millis(500),
        "the flood drained in {elapsed:?} — too fast to have been backpressured"
    );

    assert!(
        ticker_advanced_during_flood,
        "the schedule ticker never advanced during the unpaced flood"
    );

    assert_eq!(
        read_count(&path, "return remuda.up_broken and 1 or 0"),
        0,
        "a line arrived out of order or was skipped"
    );
    assert_eq!(
        read_count(&path, "return remuda.up_last"),
        FLOOD_LINES,
        "the last line received was not the expected final line"
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.up_exit and 1 or 0") == 0 {
        assert!(Instant::now() < deadline, "exit event never arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
}

// --- packages/butler: the Matrix bridge helpers --------------------------
//
// Everything below runs against a stub HTTP server of our own
// (`tests/support/matrix_stub_server.py`), never a real Matrix homeserver.
// `HELPER_SRC`/`REPLY_SRC` are read from the internal Matrix module by running
// the Butler package in test mode in a daemon's
// living image via `remuda exec butler`, then referenced BY NAME
// (`remuda._butler_helper_src` / `remuda._butler_reply_src`) from later
// `remuda.process` calls against that same image — with no separate string
// round-trip through Rust needed.

/// The stub Matrix homeserver, as its own process — plain
/// `std::process::Command`, not `remuda.process`: this is test
/// infrastructure standing in for a homeserver, not part of the package
/// under test.
struct StubServer {
    child: std::process::Child,
    port: u16,
}

impl StubServer {
    fn spawn(fixture: &Path, get_log: &Path, put_log: &Path, send_status: u16) -> Self {
        let mut child = std::process::Command::new("python3")
            .arg(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/support/matrix_stub_server.py"
            ))
            .arg(fixture)
            .arg(get_log)
            .arg(put_log)
            .arg(send_status.to_string())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn stub matrix server");
        let stdout = child.stdout.take().expect("stub stdout piped");
        let mut reader = std::io::BufReader::new(stdout);
        let mut line = String::new();
        std::io::BufRead::read_line(&mut reader, &mut line).expect("read stub port line");
        let port: u16 = line
            .trim()
            .parse()
            .expect("stub printed a port on its first line");
        Self { child, port }
    }

    fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
}

impl Drop for StubServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One canned `/sync` response per line, in the shape the stub expects.
fn write_fixture(path: &Path, responses: &[serde_json::Value]) {
    let mut text = String::new();
    for r in responses {
        text.push_str(&r.to_string());
        text.push('\n');
    }
    std::fs::write(path, text).expect("write fixture");
}

/// The token file and config file (`homeserver`, `room id`, `self mxid`,
/// comma-separated allowed sender mxids, optional messages fallback, and a
/// short sync timeout for deterministic long-poll tests) used by the relay.
fn butler_config(
    dir: &Path,
    tag: &str,
    homeserver: &str,
    room: &str,
    self_mxid: &str,
    allowed_senders: &str,
) -> (PathBuf, PathBuf) {
    let token_path = dir.join(format!("{tag}.token"));
    let config_path = dir.join(format!("{tag}.config"));
    std::fs::write(&token_path, "test-token\n").expect("write token");
    std::fs::write(
        &config_path,
        format!("{homeserver}\n{room}\n{self_mxid}\n{allowed_senders}\n\n100\n"),
    )
    .expect("write config");
    (token_path, config_path)
}

/// Pre-start a daemon, then run the real Butler package inside
/// it with `remuda._butler_test_mode` set — the same `remuda exec`
/// invocation `exec_butler_runs_the_builtin_package_in_the_daemons_image`
/// uses, then load the internal Matrix entry point — so
/// `remuda._butler_helper_src`/`remuda._butler_reply_src` hold the exact
/// package source, without starting a real Claude session or needing
/// `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG`. Both globals stay
/// live in this same image afterward, so a later `eval` can reference them
/// by name directly inside a `remuda.process{argv = {...}}` call.
fn butler_test_daemon(dir: &Path) -> (Daemon, PathBuf) {
    let daemon = Daemon::spawn(dir);
    let path = daemon::socket_path_in(dir, "s");
    eval(&path, "remuda._butler_test_mode = true");
    let out = remuda_timed(dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    eval(&path, "remuda.exec('butler/matrix')");
    (daemon, path)
}

#[test]
fn butler_helper_filters_to_the_allowlisted_room() {
    let dir = scratch_dir("butler-allowlist");
    let (_daemon, path) = butler_test_daemon(&dir);

    let allowed_room = "!allowed:example.org";
    let other_room = "!other:example.org";
    let self_mxid = "@bot:example.org";

    let get_log = dir.join("allowlist-get.log");
    let put_log = dir.join("allowlist-put.log");
    let fixture = dir.join("allowlist-fixture.jsonl");
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    write_fixture(
        &fixture,
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "aw-0"}),
            serde_json::json!({
                "rooms": {"join": {
                    allowed_room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$1", "sender": "@alice:example.org",
                         "content": {"msgtype": "m.text", "body": "hello from allowed room"}}
                    ]}},
                    other_room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$2", "sender": "@bob:example.org",
                         "content": {"msgtype": "m.text", "body": "hello from other room"}}
                    ]}}
                }},
                "next_batch": "aw-1"
            }),
        ],
    );

    let stub = StubServer::spawn(&fixture, &get_log, &put_log, 200);
    let (token_path, config_path) = butler_config(
        &dir,
        "allowlist",
        &stub.base_url(),
        allowed_room,
        self_mxid,
        "@alice:example.org",
    );

    eval(&path, "remuda.allow_lines = {}");
    eval(
        &path,
        "remuda.on('allow-line', function(l) table.insert(remuda.allow_lines, l) end)",
    );
    eval(
        &path,
        &format!(
            "remuda.allow_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'allow-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.allow_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "no line ever arrived from the allowlisted room"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // A message from the non-allowlisted room must produce ZERO emits, not
    // just "the count happens to work out" — give it a real window to show
    // up wrongly before checking.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(&path, "return #remuda.allow_lines"),
        1,
        "exactly one emit was expected — the non-allowlisted room's event leaked through"
    );
    let line = eval(&path, "return remuda.allow_lines[1]");
    assert!(
        line.starts_with("@alice:example.org\t"),
        "wrong event emitted: {line}"
    );

    eval(&path, "remuda.kill(remuda.allow_handle)");
}

#[test]
fn butler_helper_drops_a_non_allowlisted_sender_in_the_same_room() {
    let dir = scratch_dir("butler-sender-allowlist");
    let (_daemon, path) = butler_test_daemon(&dir);

    let room = "!senders:example.org";
    let self_mxid = "@bot:example.org";
    let allowed_sender = "@alice:example.org";
    let other_member = "@mallory:example.org";

    let get_log = dir.join("senders-get.log");
    let put_log = dir.join("senders-put.log");
    let fixture = dir.join("senders-fixture.jsonl");
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    write_fixture(
        &fixture,
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "sa-0"}),
            serde_json::json!({
                "rooms": {"join": {
                    room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$1", "sender": other_member,
                         "content": {"msgtype": "m.text", "body": "not on the allowlist"}},
                        {"type": "m.room.message", "event_id": "$2", "sender": allowed_sender,
                         "content": {"msgtype": "m.text", "body": "hello from the allowed sender"}}
                    ]}}
                }},
                "next_batch": "sa-1"
            }),
        ],
    );

    let stub = StubServer::spawn(&fixture, &get_log, &put_log, 200);
    let (token_path, config_path) = butler_config(
        &dir,
        "senders",
        &stub.base_url(),
        room,
        self_mxid,
        allowed_sender,
    );

    eval(&path, "remuda.sender_lines = {}");
    eval(
        &path,
        "remuda.on('sender-line', function(l) table.insert(remuda.sender_lines, l) end)",
    );
    eval(
        &path,
        &format!(
            "remuda.sender_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'sender-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.sender_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "no line ever arrived from the allowlisted sender"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    // The non-allowlisted member's message must produce ZERO emits, not just
    // "the count happens to work out" -- give it a real window to show up
    // wrongly before checking.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(&path, "return #remuda.sender_lines"),
        1,
        "exactly one emit was expected -- the non-allowlisted sender's event leaked through"
    );
    let line = eval(&path, "return remuda.sender_lines[1]");
    assert!(
        line.starts_with("@alice:example.org\t"),
        "wrong event emitted: {line}"
    );

    eval(&path, "remuda.kill(remuda.sender_handle)");
}

#[test]
fn butler_helper_ignores_its_own_messages() {
    let dir = scratch_dir("butler-self");
    let (_daemon, path) = butler_test_daemon(&dir);

    let room = "!self:example.org";
    let self_mxid = "@bot:example.org";

    let get_log = dir.join("self-get.log");
    let put_log = dir.join("self-put.log");
    let fixture = dir.join("self-fixture.jsonl");
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    write_fixture(
        &fixture,
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "sf-0"}),
            serde_json::json!({
                "rooms": {"join": {
                    room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$1", "sender": self_mxid,
                         "content": {"msgtype": "m.text", "body": "an echo of my own reply"}}
                    ]}}
                }},
                "next_batch": "sf-1"
            }),
        ],
    );

    let stub = StubServer::spawn(&fixture, &get_log, &put_log, 200);
    let (token_path, config_path) =
        butler_config(&dir, "self", &stub.base_url(), room, self_mxid, "");

    eval(&path, "remuda.self_lines = {}");
    eval(
        &path,
        "remuda.on('self-line', function(l) table.insert(remuda.self_lines, l) end)",
    );
    eval(
        &path,
        &format!(
            "remuda.self_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'self-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    // Proof the fixture's event was actually reached (not just "nothing ran
    // yet"): wait for the stub to have answered both the baseline call and
    // the one carrying the self-authored event.
    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&get_log)
        .unwrap_or_default()
        .lines()
        .count()
        < 2
    {
        assert!(
            Instant::now() < deadline,
            "the helper never even polled past the baseline"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(&path, "return #remuda.self_lines"),
        0,
        "a message from the bridge's own account must never be re-ingested"
    );

    eval(&path, "remuda.kill(remuda.self_handle)");
}

#[test]
fn butler_helper_escapes_a_multiline_message_into_exactly_one_line() {
    let dir = scratch_dir("butler-escape");
    let (_daemon, path) = butler_test_daemon(&dir);

    let room = "!escape:example.org";
    let self_mxid = "@bot:example.org";
    // Includes a real newline, a standalone backslash, AND a literal
    // backslash-then-"n" (not a real newline) — the last one is what a
    // naive two-pass unescape (newline-pass then backslash-pass) gets
    // wrong, since the backslash it doubles for its own escaping can end
    // up immediately before a literal "n" and be misread as a newline
    // escape on the first pass.
    let original_body = "line one\nline two with a \\ backslash and a literal \\n as text";

    let get_log = dir.join("escape-get.log");
    let put_log = dir.join("escape-put.log");
    let fixture = dir.join("escape-fixture.jsonl");
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    write_fixture(
        &fixture,
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "es-0"}),
            serde_json::json!({
                "rooms": {"join": {
                    room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$1", "sender": "@carol:example.org",
                         "origin_server_ts": 1790000000000_i64,
                         "content": {"msgtype": "m.text", "body": original_body}}
                    ]}}
                }},
                "next_batch": "es-1"
            }),
        ],
    );

    let stub = StubServer::spawn(&fixture, &get_log, &put_log, 200);
    let (token_path, config_path) = butler_config(
        &dir,
        "escape",
        &stub.base_url(),
        room,
        self_mxid,
        "@carol:example.org",
    );

    eval(&path, "remuda.esc_lines = {}");
    eval(
        &path,
        "remuda.on('esc-line', function(l) table.insert(remuda.esc_lines, l) end)",
    );
    eval(
        &path,
        &format!(
            "remuda.esc_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'esc-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.esc_lines") == 0 {
        assert!(Instant::now() < deadline, "no line ever arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    // Exactly one emit for one Matrix event — not two, not a parse error —
    // even though the body contains a real newline.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(
        read_count(&path, "return #remuda.esc_lines"),
        1,
        "one Matrix event with an embedded newline must become exactly one physical line"
    );

    let raw_line = eval(&path, "return remuda.esc_lines[1]");
    assert!(
        !raw_line.contains('\n'),
        "the delivered line itself contained a raw newline: {raw_line:?}"
    );
    let fields: Vec<&str> = raw_line.splitn(5, '\t').collect();
    assert_eq!(fields.len(), 5, "relay output did not carry a complete mail envelope: {raw_line}");
    assert_eq!(fields[0], "@carol:example.org");
    assert_eq!(fields[1], room);
    assert_eq!(fields[2], "$1");
    assert!(fields[3].starts_with("2026-") && fields[3].ends_with('Z'), "timestamp was not UTC: {}", fields[3]);

    // Round-trip: the exact unescape logic `init.lua`'s own `butler-matrix-line`
    // hook uses, run against the raw received line.
    let reconstructed = eval(
        &path,
        &format!(
            r#"
            local line = {raw}
            local _, _, _, _, body = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            body = body:gsub("\\(.)", function(c)
              if c == "n" then return "\n" elseif c == "r" then return "\r"
              elseif c == "t" then return "\t" else return c end
            end)
            return body
            "#,
            raw = lua_raw_string(&raw_line)
        ),
    );
    assert_eq!(
        reconstructed, original_body,
        "the round trip through escape/unescape did not reproduce the original body"
    );

    eval(&path, "remuda.kill(remuda.esc_handle)");
}

/// Writes an empty get/put log and a fixture, then starts a stub server on
/// it. Shared by tests that need more than one stub instance in sequence
/// (e.g. proving persistence across a restart), so each instance is one
/// line instead of the six it takes to set up by hand.
fn spawn_stub(dir: &Path, tag: &str, responses: &[serde_json::Value]) -> (StubServer, PathBuf) {
    let get_log = dir.join(format!("{tag}-get.log"));
    let put_log = dir.join(format!("{tag}-put.log"));
    let fixture = dir.join(format!("{tag}-fixture.jsonl"));
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    write_fixture(&fixture, responses);
    (
        StubServer::spawn(&fixture, &get_log, &put_log, 200),
        get_log,
    )
}

#[test]
fn matrix_relay_restarts_after_unexpected_exit_and_records_it() {
    let dir = scratch_dir("matrix-supervise");
    let marker = dir.join("relay-starts.log");
    let trace = dir.join("matrix-trace.log");
    let (token_path, config_path) = butler_config(
        &dir, "supervise", "http://127.0.0.1:1", "!room:example.org", "@bot:example.org", "",
    );
    let source = format!(
        "import pathlib; pathlib.Path({}).open('a').write('start\\n'); raise SystemExit(7)",
        serde_json::to_string(&marker.to_string_lossy()).unwrap(),
    );
    let token_env = token_path.to_string_lossy().to_string();
    let config_env = config_path.to_string_lossy().to_string();
    let _daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", &token_env),
            ("REMUDA_BUTLER_CONFIG", &config_env),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        &format!(
            "remuda._butler_test_mode = 'lifecycle'; remuda._butler_argv = {{'sh','-c','sleep 60'}}; remuda._butler_helper_src_override = {}; remuda._butler_matrix_trace_path = {}",
            lua_raw_string(&source), lua_raw_string(&trace.to_string_lossy()),
        ),
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&marker).unwrap_or_default().lines().count() < 2 {
        assert!(Instant::now() < deadline, "relay did not restart after exit");
        std::thread::sleep(Duration::from_millis(20));
    }
    eval(&path, "remuda._butler_matrix_stop()");
    let trace = std::fs::read_to_string(&trace).expect("matrix restart trace");
    assert!(trace.contains("relay_restart"), "missing restart trace: {trace}");
    assert!(trace.contains("backoff=1"), "first restart should use 1-second backoff: {trace}");
    assert!(
        include_str!("../../packages/butler/matrix.lua").contains("math.min(60"),
        "relay restart backoff must have a 60-second cap"
    );
}

#[test]
fn matrix_relay_restart_waits_for_backoff_after_daemon_uptime_exceeds_delay() {
    let dir = scratch_dir("matrix-backoff-gap");
    let marker = dir.join("relay-starts.log");
    let trace = dir.join("matrix-trace.log");
    let (token_path, config_path) = butler_config(
        &dir, "backoff-gap", "http://127.0.0.1:1", "!room:example.org", "@bot:example.org", "",
    );
    let source = format!(
        "import pathlib,time; pathlib.Path({}).open('a').write(str(time.monotonic())+'\\n'); time.sleep(60)",
        serde_json::to_string(&marker.to_string_lossy()).unwrap(),
    );
    let token_env = token_path.to_string_lossy().to_string();
    let config_env = config_path.to_string_lossy().to_string();
    let _daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", &token_env),
            ("REMUDA_BUTLER_CONFIG", &config_env),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        &format!(
            "remuda._butler_test_mode = 'lifecycle'; remuda._butler_argv = {{'sh','-c','sleep 60'}}; remuda._butler_helper_src_override = {}; remuda._butler_matrix_trace_path = {}",
            lua_raw_string(&source), lua_raw_string(&trace.to_string_lossy()),
        ),
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let started = Instant::now() + Duration::from_secs(9);
    while std::fs::read_to_string(&marker).unwrap_or_default().lines().count() < 1 {
        assert!(Instant::now() < started, "relay did not start");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_secs(9));
    let crash_at = Instant::now();
    eval(
        &path,
        "remuda._butler_matrix_restart_attempts = 3; remuda.kill(remuda._butler_matrix_relay)",
    );

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let starts = std::fs::read_to_string(&marker).unwrap_or_default();
        if starts.lines().count() >= 2 { break; }
        assert!(Instant::now() < deadline, "relay did not restart after the 8-second delay: {starts}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let gap = crash_at.elapsed().as_secs_f64();
    assert!(gap >= 7.0, "8-second backoff was shortened while daemon uptime already exceeded it: {gap}s");
    let trace = std::fs::read_to_string(&trace).expect("matrix restart trace");
    assert!(trace.contains("attempt=4 backoff=8"), "expected an 8-second restart: {trace}");
    eval(&path, "remuda._butler_matrix_stop()");
}

#[test]
fn matrix_relay_recovery_resets_accumulated_restart_backoff() {
    let dir = scratch_dir("matrix-backoff-reset");
    let trace = dir.join("matrix-trace.log");
    let (token_path, config_path) = butler_config(
        &dir, "backoff-reset", "http://127.0.0.1:1", "!room:example.org", "@bot:example.org", "",
    );
    let token_env = token_path.to_string_lossy().to_string();
    let config_env = config_path.to_string_lossy().to_string();
    let _daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", &token_env),
            ("REMUDA_BUTLER_CONFIG", &config_env),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        &format!(
            "remuda._butler_test_mode = 'lifecycle'; remuda._butler_argv = {{'sh','-c','sleep 60'}}; remuda._butler_helper_src_override = 'import time; time.sleep(60)'; remuda._butler_matrix_trace_path = {}",
            lua_raw_string(&trace.to_string_lossy()),
        ),
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    // Exercise five failed relay exits, then the same success marker emitted
    // by the relay after a completed /sync response.
    eval(
        &path,
        "for _ = 1, 5 do remuda._butler_matrix_sync_exit(7) end; remuda._butler_matrix_line('__REMUDA_MATRIX_HEALTHY__'); remuda._butler_matrix_sync_exit(7)",
    );
    let traces = std::fs::read_to_string(&trace).expect("matrix restart trace");
    assert!(traces.contains("attempt=5 backoff=16"), "expected five accumulated failures: {traces}");
    assert!(traces.contains("attempt=1 backoff=1"), "recovered relay should restart with fast backoff: {traces}");
    eval(&path, "remuda._butler_matrix_stop()");
}

#[test]
fn matrix_relay_treats_wrongly_typed_processed_ids_as_corrupt_state() {
    let dir = scratch_dir("matrix-typed-state");
    let (token_path, config_path) = butler_config(
        &dir, "typed-state", "http://127.0.0.1:1", "!room:example.org", "@bot:example.org", "",
    );
    std::fs::write(format!("{}.since", config_path.display()), r#"{"processed_event_ids":5}"#)
        .unwrap();
    let relay = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../packages/butler/matrix_relay.py");
    let probe = format!(
        "import runpy,sys; sys.argv=['relay',{},{}]; m=runpy.run_path({},run_name='matrix_test'); s,p,ms,pending=m['load_state'](); assert s is None and not p and ms is None and not pending",
        serde_json::to_string(&token_path.to_string_lossy()).unwrap(),
        serde_json::to_string(&config_path.to_string_lossy()).unwrap(),
        serde_json::to_string(&relay.to_string_lossy()).unwrap(),
    );
    let result = std::process::Command::new("python3").arg("-c").arg(probe).status().unwrap();
    assert!(result.success(), "wrongly typed processed IDs were not reset to a fresh state");
}

#[test]
fn matrix_relay_drops_incomplete_and_wrongly_typed_pending_envelopes() {
    let dir = scratch_dir("matrix-pending-state-types");
    let (token_path, config_path) = butler_config(
        &dir, "pending-state-types", "http://127.0.0.1:1", "!room:example.org", "@bot:example.org", "",
    );
    let valid = serde_json::json!({
        "sender": "@alice:example.org", "room_id": "!room:example.org",
        "created_at": "2026-09-28T00:00:00Z", "body": "still deliverable"
    });
    let state = serde_json::json!({
        "since": "resume-here", "processed_event_ids": [],
        "pending_events": {
            "$valid": valid,
            "$missing": {"sender": "@alice:example.org"},
            "$wrong-type": {
                "sender": 123, "room_id": "!room:example.org",
                "created_at": "2026-09-28T00:00:00Z", "body": "bad"
            }
        }
    });
    std::fs::write(format!("{}.since", config_path.display()), state.to_string()).unwrap();
    let relay = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../packages/butler/matrix_relay.py");
    let probe = format!(
        "import runpy,sys; sys.argv=['relay',{},{}]; m=runpy.run_path({},run_name='matrix_test'); s,p,ms,pending=m['load_state'](); assert s == 'resume-here' and pending == {{'$valid': {}}}",
        serde_json::to_string(&token_path.to_string_lossy()).unwrap(),
        serde_json::to_string(&config_path.to_string_lossy()).unwrap(),
        serde_json::to_string(&relay.to_string_lossy()).unwrap(),
        serde_json::to_string(&valid).unwrap(),
    );
    let result = std::process::Command::new("python3").arg("-c").arg(probe).status().unwrap();
    assert!(result.success(), "load_state did not keep only the well-formed pending envelope");
}

#[test]
fn matrix_relay_retries_an_unreachable_first_sync_baseline() {
    let dir = scratch_dir("matrix-baseline-retry");
    let (_daemon, path) = butler_test_daemon(&dir);
    let (stub, get_log) = spawn_stub(
        &dir,
        "baseline-retry",
        &[
            serde_json::json!({"__http_status": 503}),
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "retried-baseline"}),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir, "baseline-retry", &stub.base_url(), "!room:example.org", "@bot:example.org", "",
    );
    eval(
        &path,
        &format!(
            "remuda.baseline_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&get_log).unwrap_or_default().lines().count() < 2 {
        assert!(Instant::now() < deadline, "baseline request did not retry after transport error");
        std::thread::sleep(Duration::from_millis(20));
    }
    let state: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(format!("{}.since", config_path.display())).unwrap(),
    ).unwrap();
    assert_eq!(state.get("since").and_then(serde_json::Value::as_str), Some("retried-baseline"));
    eval(&path, "remuda.kill(remuda.baseline_handle)");
}

#[test]
fn matrix_stub_honors_sync_timeout_instead_of_busy_looping() {
    let dir = scratch_dir("matrix-long-poll");
    let (_daemon, path) = butler_test_daemon(&dir);
    let (stub, get_log) = spawn_stub(&dir, "long-poll", &[]);
    let (token_path, config_path) = butler_config(
        &dir, "long-poll", &stub.base_url(), "!room:example.org", "@bot:example.org", "",
    );
    eval(
        &path,
        &format!(
            "remuda.long_poll_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&get_log).unwrap_or_default().lines().count() < 2 {
        assert!(Instant::now() < deadline, "relay did not start the idle long poll");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(400));
    let requests = std::fs::read_to_string(&get_log).unwrap_or_default();
    assert!(requests.lines().count() <= 7, "idle sync fixture busy-looped: {requests}");
    eval(&path, "remuda.kill(remuda.long_poll_handle)");
}

#[test]
fn matrix_relay_exits_when_its_parent_daemon_dies() {
    let dir = scratch_dir("matrix-parent-death");
    let (mut daemon, path) = butler_test_daemon(&dir);
    let (stub, get_log) = spawn_stub(&dir, "parent-death", &[]);
    let (token_path, config_path) = butler_config(
        &dir, "parent-death", &stub.base_url(), "!room:example.org", "@bot:example.org", "",
    );
    eval(
        &path,
        &format!(
            "remuda.parent_death_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let started_deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&get_log).unwrap_or_default().lines().count() < 2 {
        assert!(Instant::now() < started_deadline, "Matrix relay did not begin polling");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!matrix_relays_matching(&config_path).is_empty(), "relay marker argv was not visible to the test");

    let _ = daemon.0.kill();
    let _ = daemon.0.wait();
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut survivors = matrix_relays_matching(&config_path);
    while !survivors.is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
        survivors = matrix_relays_matching(&config_path);
    }
    assert!(survivors.is_empty(), "Matrix relay survived the death of its parent daemon: {survivors:?}");
}

#[test]
fn matrix_reload_replaces_the_relay_once_per_reload() {
    let dir = scratch_dir("matrix-reload");
    let (stub, _) = spawn_stub(
        &dir,
        "reload",
        &[serde_json::json!({"rooms": {"join": {}}, "next_batch": "reload-cursor"})],
    );
    let (token_path, config_path) = butler_config(
        &dir, "reload", &stub.base_url(), "!room:example.org", "@bot:example.org", "",
    );
    let trace_path = dir.join("matrix-reload.trace");
    let token_env = token_path.to_string_lossy().to_string();
    let config_env = config_path.to_string_lossy().to_string();
    let _daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", &token_env),
            ("REMUDA_BUTLER_CONFIG", &config_env),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        &format!(
            "remuda._butler_test_mode = 'lifecycle'; remuda._butler_argv = {{'sh','-c','sleep 60'}}; remuda._butler_matrix_trace_path = {}; remuda.exec('butler')",
            lua_raw_string(&trace_path.to_string_lossy()),
        ),
    );
    let initial_deadline = Instant::now() + PATIENCE;
    while eval(&path, "return tostring(remuda._butler_matrix_relay)") == "nil" {
        assert!(Instant::now() < initial_deadline, "initial Matrix relay did not start");
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut prior = eval(&path, "return tostring(remuda._butler_matrix_relay)");
    assert_ne!(prior, "nil", "initial relay did not start");
    for _ in 0..3 {
        eval(&path, "remuda.reload('butler')");
        let deadline = Instant::now() + PATIENCE;
        let current = loop {
            let id = eval(&path, "return tostring(remuda._butler_matrix_relay)");
            if id != prior { break id; }
            assert!(Instant::now() < deadline, "reload retained the old Matrix relay process; trace={}; stopping={}",
                std::fs::read_to_string(&trace_path).unwrap_or_default(),
                eval(&path, "return tostring(remuda._butler_matrix_stopping)"));
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_ne!(current, prior, "reload retained the old Matrix relay process");
        assert_eq!(
            read_count(&path, "local n=0 for _,id in ipairs(remuda.processes()) do if id == remuda._butler_matrix_relay then n=n+1 end end return n"),
            1,
            "reload must leave exactly one active Matrix relay",
        );
        prior = current;
    }
    eval(&path, "remuda._butler_matrix_stop()");
}

#[test]
fn matrix_relay_drops_malformed_pending_entries_and_acknowledges_mail() {
    let dir = scratch_dir("matrix-corrupt-state");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!corrupt:example.org";
    let (stub, get_log) = spawn_stub(
        &dir,
        "corrupt-state",
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "corrupt-0"}),
            serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [
                {"type": "m.room.message", "event_id": "$corrupt", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "survives corrupt state"}}
            ]}}}}, "next_batch": "corrupt-1"}),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir, "corrupt-state", &stub.base_url(), room, "@bot:example.org", "@alice:example.org",
    );
    let since_path = format!("{}.since", config_path.display());
    std::fs::write(
        &since_path,
        r#"{"since":null,"processed_event_ids":[],"pending_events":{"$missing":{"sender":"a"},"$wrong":{"sender":123,"room_id":"!bad","created_at":"2026-09-28T00:00:00Z","body":"bad"}}}"#,
    ).unwrap();
    let ack_path = format!("{}.acks", config_path.display());
    eval(&path, "remuda.corrupt_lines = {};");
    eval(
        &path,
        &format!(
            "remuda.on('corrupt-line', function(l) table.insert(remuda.corrupt_lines,l); local id=l:match('^[^\\t]*\\t[^\\t]*\\t([^\\t]*)'); local f=assert(io.open({},'a')); assert(f:write(id,'\\n')); assert(f:close()) end)",
            lua_raw_string(&ack_path),
        ),
    );
    eval(
        &path,
        &format!(
            "remuda.corrupt_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'corrupt-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    let deadline = Instant::now() + PATIENCE;
    loop {
        let state: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&since_path).unwrap_or_default(),
        ).unwrap_or_default();
        if state.get("processed_event_ids").and_then(serde_json::Value::as_array)
            .is_some_and(|ids| ids.contains(&serde_json::json!("$corrupt")))
        {
            break;
        }
        assert!(Instant::now() < deadline, "relay failed to acknowledge mail after corrupt state; requests={}",
            std::fs::read_to_string(&get_log).unwrap_or_default());
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(read_count(&path, "return #remuda.corrupt_lines"), 1);
    eval(&path, "remuda.kill(remuda.corrupt_handle)");
}

#[test]
fn butler_helper_bounds_processed_matrix_event_ids_on_load() {
    let dir = scratch_dir("butler-matrix-bounded-ids");
    let (_daemon, path) = butler_test_daemon(&dir);
    let (stub, get_log) = spawn_stub(
        &dir,
        "bounded-ids",
        &[serde_json::json!({"rooms": {"join": {}}, "next_batch": "bounded-cursor"})],
    );
    let (token_path, config_path) = butler_config(
        &dir, "bounded-ids", &stub.base_url(), "!room:example.org", "@bot:example.org", "",
    );
    let since_path = format!("{}.since", config_path.display());
    let old_ids: Vec<String> = (0..5007).map(|i| format!("$old-{i:04}")).collect();
    std::fs::write(
        &since_path,
        serde_json::json!({"since": null, "processed_event_ids": old_ids}).to_string(),
    )
    .unwrap();
    eval(
        &path,
        &format!(
            "remuda.bounded_lines = {{}}; remuda.on('bounded-line', function(l) table.insert(remuda.bounded_lines, l) end); remuda.bounded_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'bounded-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(&get_log)
        .unwrap_or_default()
        .lines()
        .count()
        < 1
    {
        assert!(Instant::now() < deadline, "helper did not poll Matrix stub");
        std::thread::sleep(Duration::from_millis(20));
    }
    loop {
        let state_text = std::fs::read_to_string(&since_path).unwrap_or_default();
        let state: serde_json::Value = serde_json::from_str(&state_text).unwrap_or_default();
        let ids = state
            .get("processed_event_ids")
            .and_then(serde_json::Value::as_array);
        if ids.is_some_and(|ids| ids.len() <= 5000) {
            assert_eq!(ids.unwrap().len(), 5000);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "helper did not rewrite bounded processed ids; ids={}, requests={}",
            state.get("processed_event_ids").and_then(serde_json::Value::as_array).map_or(0, Vec::len),
            std::fs::read_to_string(&get_log).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    eval(&path, "remuda.kill(remuda.bounded_handle)");
}

#[test]
// The 4th config line (sender allowlist) pushed this back over clippy's
// too-many-lines threshold; the two-instance restart scenario this proves
// doesn't split further without losing the point of the test.
#[allow(clippy::too_many_lines)]
fn butler_helper_persists_since_across_a_restart() {
    let dir = scratch_dir("butler-persist");
    let (_daemon, path) = butler_test_daemon(&dir);

    let room = "!persist:example.org";
    let self_mxid = "@bot:example.org";

    // First instance: a baseline, then one qualifying event.
    let (stub1, _get_log1) = spawn_stub(
        &dir,
        "persist1",
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "d-since-0"}),
            serde_json::json!({
                "rooms": {"join": {
                    room: {"timeline": {"events": [
                        {"type": "m.room.message", "event_id": "$1", "sender": "@dave:example.org",
                         "content": {"msgtype": "m.text", "body": "first batch"}}
                    ]}}
                }},
                "next_batch": "d-since-1"
            }),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir,
        "persist",
        &stub1.base_url(),
        room,
        self_mxid,
        "@dave:example.org",
    );
    let since_path = format!("{}.since", config_path.display());

    eval(&path, "remuda.persist_lines = {}");
    eval(
        &path,
        &format!(
            "remuda.on('persist-line', function(l) table.insert(remuda.persist_lines, l); local id = l:match('^[^\\t]*\\t[^\\t]*\\t([^\\t]*)'); local f = assert(io.open({}, 'a')); assert(f:write(id, '\\n')); assert(f:close()) end)",
            lua_raw_string(&format!("{}.acks", config_path.display()))
        ),
    );
    eval(
        &path,
        &format!(
            "remuda.persist_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'persist-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.persist_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "the first instance never emitted its line"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let state_deadline = Instant::now() + PATIENCE;
    loop {
        let state_text = std::fs::read_to_string(&since_path).unwrap_or_default();
        let state: serde_json::Value = serde_json::from_str(&state_text).unwrap_or_default();
        let acknowledged = state
            .get("processed_event_ids")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|ids| ids.contains(&serde_json::json!("$1")));
        if acknowledged {
            break;
        }
        assert!(Instant::now() < state_deadline, "helper did not persist the acknowledged event id");
        std::thread::sleep(Duration::from_millis(20));
    }
    eval(&path, "remuda.kill(remuda.persist_handle)");
    std::thread::sleep(Duration::from_millis(200));
    drop(stub1);

    let since_before = std::fs::read_to_string(&since_path).expect("since file exists");
    assert!(
        since_before.contains("d-since-1"),
        "unexpected since file contents: {since_before}"
    );

    // Second instance: same config path (so the same since file), a fresh
    // stub with its own second batch, and the config file repointed at it.
    let (stub2, get_log2) = spawn_stub(
        &dir,
        "persist2",
        &[serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [
            {"type": "m.room.message", "event_id": "$1", "sender": "@dave:example.org",
             "content": {"msgtype": "m.text", "body": "first batch"}}
        ]}}}}, "next_batch": "d-since-2"})],
    );
    std::fs::write(
        &config_path,
        format!(
            "{}\n{}\n{}\n@dave:example.org\n",
            stub2.base_url(),
            room,
            self_mxid
        ),
    )
    .expect("repoint config at the second stub");

    eval(
        &path,
        &format!(
            "remuda.persist_handle2 = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    loop {
        if !std::fs::read_to_string(&get_log2)
            .unwrap_or_default()
            .trim()
            .is_empty()
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the second instance never called the new stub"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let first_request = std::fs::read_to_string(&get_log2).expect("get log2");
    let first_line = first_request.lines().next().expect("at least one request");
    assert!(
        first_line.contains("since=d-since-1"),
        "the second instance did not resume from the persisted since token: {first_line}"
    );
    assert!(
        !first_line.contains("since=d-since-0") && !first_line.contains("timeout=0"),
        "the second instance replayed the baseline instead of resuming: {first_line}"
    );
    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(
        read_count(&path, "return #remuda.persist_lines"),
        1,
        "a processed event_id must not be delivered again after restart"
    );

    eval(&path, "remuda.kill(remuda.persist_handle2)");
}

#[test]
fn butler_helper_deduplicates_repeated_matrix_event_ids() {
    let dir = scratch_dir("butler-matrix-event-dedupe");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!dedupe:example.org";
    let self_mxid = "@bot:example.org";
    let (stub, _get_log) = spawn_stub(
        &dir,
        "dedupe",
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "dd-0"}),
            serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [
                {"type": "m.room.message", "event_id": "$same", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "deliver once"}}
            ]}}}}, "next_batch": "dd-1"}),
            serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [
                {"type": "m.room.message", "event_id": "$same", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "deliver once"}}
            ]}}}}, "next_batch": "dd-2"}),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir,
        "dedupe",
        &stub.base_url(),
        room,
        self_mxid,
        "@alice:example.org",
    );

    eval(&path, "remuda.dedupe_lines = {}");
    eval(
        &path,
        "remuda.on('dedupe-line', function(l) table.insert(remuda.dedupe_lines, l) end)",
    );
    eval(
        &path,
        &format!(
            "remuda.dedupe_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'dedupe-line'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while std::fs::read_to_string(dir.join("dedupe-get.log"))
        .unwrap_or_default()
        .lines()
        .count()
        < 3
    {
        assert!(Instant::now() < deadline, "helper did not consume duplicate fixture events");
        std::thread::sleep(Duration::from_millis(20));
    }
    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(
        read_count(&path, "return #remuda.dedupe_lines"),
        1,
        "a repeated Matrix event_id must only be delivered once"
    );
    eval(&path, "remuda.kill(remuda.dedupe_handle)");
}

#[test]
fn butler_helper_uses_messages_endpoint_when_fallback_is_configured() {
    let dir = scratch_dir("matrix-msg-fb");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!fallback:example.org";
    let (stub, get_log) = spawn_stub(
        &dir,
        "fallback",
        &[
            serde_json::json!({"start": "messages-0", "end": "messages-old", "chunk": [
                {"type": "m.room.message", "event_id": "$baseline", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "old history"}}
            ]}),
            serde_json::json!({"start": "messages-0", "end": "messages-1", "chunk": [
                {"type": "m.room.message", "event_id": "$baseline", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "old history"}},
                {"type": "m.room.message", "event_id": "$fallback", "sender": "@alice:example.org",
                 "origin_server_ts": 1790000000000_i64,
                 "content": {"msgtype": "m.text", "body": "from messages"}}
            ]}),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir,
        "fallback",
        &stub.base_url(),
        room,
        "@bot:example.org",
        "@alice:example.org",
    );
    std::fs::write(
        &config_path,
        format!(
            "{}\n{}\n@bot:example.org\n@alice:example.org\nmessages\n100\n",
            stub.base_url(), room
        ),
    )
    .unwrap();

    eval(&path, "remuda.fallback_lines = {}; remuda.fallback_exit = nil");
    eval(
        &path,
        "remuda.on('fallback-line', function(l) table.insert(remuda.fallback_lines, l) end)",
    );
    eval(
        &path,
        "remuda.on('fallback-exit', function(code) remuda.fallback_exit = code end)",
    );
    eval(
        &path,
        &format!(
            "remuda.fallback_handle = remuda.process{{argv = {{'python3', '-c', remuda._butler_helper_src, {}, {}}}, on_line = 'fallback-line', on_exit = 'fallback-exit'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return #remuda.fallback_lines") == 0 {
        assert!(
            Instant::now() < deadline,
            "fallback poll delivered no Matrix event; requests: {}; exit: {}",
            std::fs::read_to_string(&get_log).unwrap_or_default(),
            eval(&path, "return tostring(remuda.fallback_exit)")
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let requests = std::fs::read_to_string(&get_log).expect("fallback request log");
    assert!(requests.contains("/rooms/"), "fallback did not call /rooms/{room}/messages: {requests}");
    assert!(requests.contains("from=messages-0"), "fallback did not resume with its persisted cursor: {requests}");
    assert!(!requests.contains("/_matrix/client/v3/sync"), "fallback unexpectedly called /sync: {requests}");
    let line = eval(&path, "return remuda.fallback_lines[1]");
    assert!(line.ends_with("from messages"), "unexpected fallback delivery: {line}");
    eval(&path, "remuda.kill(remuda.fallback_handle)");
}

#[test]
#[cfg(unix)]
fn matrix_extension_delivers_a_durable_mail_envelope_once() {
    let dir = scratch_dir("mx-inbound");
    let room = "!inbound:example.org";
    let event = serde_json::json!({
        "type": "m.room.message", "event_id": "$inbound-once", "sender": "@alice:example.org",
        "origin_server_ts": 1790000000000_i64,
        "content": {"msgtype": "m.text", "body": "mail from Matrix"}
    });
    let (stub, get_log) = spawn_stub(
        &dir,
        "inbound",
        &[
            serde_json::json!({"rooms": {"join": {}}, "next_batch": "in-0"}),
            serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [event.clone()]}}}}, "next_batch": "in-1"}),
            serde_json::json!({"rooms": {"join": {room: {"timeline": {"events": [event]}}}}, "next_batch": "in-2"}),
        ],
    );
    let (token_path, config_path) = butler_config(
        &dir,
        "inbound",
        &stub.base_url(),
        room,
        "@bot:example.org",
        "@alice:example.org",
    );
    let token = token_path.to_string_lossy().to_string();
    let config = config_path.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token.as_str()),
            ("REMUDA_BUTLER_CONFIG", config.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "sleep 60"}"#);
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    eval(&path, "remuda.exec('butler/matrix')");
    let envelope = r#"
      local bus = remuda._butler_bus
      local count, found = 0, nil
      for _, message in pairs(bus.messages) do
        if message.matrix and message.matrix.event_id == "$inbound-once" then
          count = count + 1
          found = message
        end
      end
      if not found then return tostring(count) end
      local object = bus.objects[found.body.object_id]
      return table.concat({ tostring(count), found.from.host, found.from.alias,
        found.matrix.room_id, found.matrix.event_id, found.created_at, object.content }, "\n")
    "#;
    let deadline = Instant::now() + PATIENCE;
    let result = loop {
        let current = eval(&path, envelope);
        if current.contains("$inbound-once") {
            break current;
        }
        assert!(
            Instant::now() < deadline,
            "Matrix event never reached Butler mail; relay requests: {}; current mail probe: {current}; runtime: {}",
            std::fs::read_to_string(&get_log).unwrap_or_default(),
            eval(&path, "local c = remuda._butler_matrix_config; return tostring(c and c.config_path) .. '|' .. type(remuda._butler_helper_src) .. '|' .. tostring(remuda._butler_matrix_relay)")
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    let fields: Vec<&str> = result.lines().collect();
    assert_eq!(fields, [
        "1", "matrix", "@alice:example.org", room, "$inbound-once",
        "2026-09-21T14:13:20Z", "mail from Matrix",
    ]);

    let state_path = format!("{}.since", config_path.display());
    let state_deadline = Instant::now() + PATIENCE;
    loop {
        let state_text = std::fs::read_to_string(&state_path).unwrap_or_default();
        let state: serde_json::Value = serde_json::from_str(&state_text).unwrap_or_default();
        let acknowledged = state
            .get("processed_event_ids")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|ids| ids.contains(&serde_json::json!("$inbound-once")));
        if acknowledged {
            break;
        }
        assert!(Instant::now() < state_deadline, "relay did not persist acknowledged event id: {state_text}");
        std::thread::sleep(Duration::from_millis(20));
    }
    let requests = std::fs::read_to_string(get_log).expect("local stub request log");
    assert!(requests.lines().count() >= 3, "duplicate sync response was not consumed: {requests}");
    drop(daemon);
}

// `REPLY_SRC` is a bash script by design (packages/butler/init.lua) -- the
// real deployment target is a single Linux host, and there is no plan to
// run this specific package's helpers on Windows. Windows CI does have a
// `bash` on PATH (Git Bash), but the script's coreutils-flavored pieces
// (`date +%s%N`, `sed -n`) are not guaranteed to behave identically there,
// and that gap is not worth chasing for a component that will never run on
// that platform in practice.
#[test]
#[cfg(unix)]
fn matrix_reply_tool_queues_a_send_and_reports_its_own_exit() {
    let dir = scratch_dir("butler-reply");
    let (_daemon, path) = butler_test_daemon(&dir);

    let room = "!reply:example.org";
    let self_mxid = "@bot:example.org";
    let empty_fixture = dir.join("reply-fixture.jsonl");
    std::fs::write(&empty_fixture, "").expect("write empty fixture");

    // Success case.
    let get_log = dir.join("reply-get.log");
    let put_log = dir.join("reply-put.log");
    std::fs::write(&get_log, "").unwrap();
    std::fs::write(&put_log, "").unwrap();
    let stub_ok = StubServer::spawn(&empty_fixture, &get_log, &put_log, 200);
    let (token_path, config_path) =
        butler_config(&dir, "reply-ok", &stub_ok.base_url(), room, self_mxid, "");

    eval(&path, "remuda.reply_exit_ok = nil");
    eval(
        &path,
        "remuda.on('reply-exit-ok', function(c) remuda.reply_exit_ok = c end)",
    );
    eval(
        &path,
        &format!(
            "remuda.process{{argv = {{'bash', '-c', remuda._butler_reply_src, '_', {}, {}, 'hello'}}, on_exit = 'reply-exit-ok'}}",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.reply_exit_ok and 1 or 0") == 0 {
        assert!(
            Instant::now() < deadline,
            "on_exit never fired for the successful send"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        read_count(&path, "return remuda.reply_exit_ok"),
        0,
        "a successful send must exit 0"
    );
    let sent = std::fs::read_to_string(&put_log).expect("put log");
    assert!(
        sent.contains("hello"),
        "the stub never received the reply body: {sent}"
    );

    // Failure case: a fresh stub configured to answer 400.
    let get_log2 = dir.join("reply-get2.log");
    let put_log2 = dir.join("reply-put2.log");
    std::fs::write(&get_log2, "").unwrap();
    std::fs::write(&put_log2, "").unwrap();
    let stub_fail = StubServer::spawn(&empty_fixture, &get_log2, &put_log2, 400);
    let (token_path2, config_path2) = butler_config(
        &dir,
        "reply-fail",
        &stub_fail.base_url(),
        room,
        self_mxid,
        "",
    );

    eval(&path, "remuda.reply_exit_fail = nil");
    eval(
        &path,
        "remuda.on('reply-exit-fail', function(c) remuda.reply_exit_fail = c end)",
    );
    eval(
        &path,
        &format!(
            "remuda.process{{argv = {{'bash', '-c', remuda._butler_reply_src, '_', {}, {}, 'hello'}}, on_exit = 'reply-exit-fail'}}",
            lua_raw_string(&token_path2.to_string_lossy()),
            lua_raw_string(&config_path2.to_string_lossy()),
        ),
    );

    let deadline = Instant::now() + PATIENCE;
    while read_count(&path, "return remuda.reply_exit_fail and 1 or 0") == 0 {
        assert!(
            Instant::now() < deadline,
            "on_exit never fired for the failing send"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        read_count(&path, "return remuda.reply_exit_fail") != 0,
        "a failing send (HTTP 400) must be observably distinguishable from success via a nonzero exit code"
    );
}

// Fix for "TOKEN IN ARGV": the reply script must never pass the bearer
// token as a curl argument, since a process's argv is visible to any other
// user via `ps`. Proven by intercepting curl itself: a fake `curl` on a
// PATH of our own logs exactly the argv and stdin it received, then exits
// 0 without ever making a network call -- REPLY_SRC's own token-handling is
// what's under test here, not the network path (already covered by
// `matrix_reply_tool_queues_a_send_and_reports_its_own_exit`).
#[test]
#[cfg(unix)]
fn matrix_reply_tool_never_puts_the_token_in_curls_argv() {
    use std::os::unix::fs::PermissionsExt;

    let dir = scratch_dir("butler-reply-token");
    let (_daemon, path) = butler_test_daemon(&dir);
    let reply_src = eval(&path, "return remuda._butler_reply_src");

    let token_path = dir.join("token-argv.token");
    let config_path = dir.join("token-argv.config");
    let token = "s3cr3t-token-value";
    std::fs::write(&token_path, format!("{token}\n")).expect("write token");
    std::fs::write(
        &config_path,
        "http://127.0.0.1:1\n!room:example.org\n@bot:example.org\n",
    )
    .expect("write config");

    let fake_curl_dir = dir.join("fake-bin");
    std::fs::create_dir_all(&fake_curl_dir).expect("fake bin dir");
    let argv_log = dir.join("curl-argv.log");
    let stdin_log = dir.join("curl-stdin.log");
    std::fs::write(&argv_log, "").expect("init argv log");
    let fake_curl = fake_curl_dir.join("curl");
    std::fs::write(
        &fake_curl,
        format!(
            "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> '{}'; done\ncat > '{}'\nexit 0\n",
            argv_log.display(),
            stdin_log.display(),
        ),
    )
    .expect("write fake curl");
    std::fs::set_permissions(&fake_curl, std::fs::Permissions::from_mode(0o755))
        .expect("chmod fake curl");

    let path_with_fake_curl = format!(
        "{}:{}",
        fake_curl_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    let status = std::process::Command::new("bash")
        .arg("-c")
        .arg(&reply_src)
        .arg("_")
        .arg(&token_path)
        .arg(&config_path)
        .arg("hello")
        .env("PATH", path_with_fake_curl)
        .status()
        .expect("run REPLY_SRC with the fake curl on PATH");
    assert!(
        status.success(),
        "REPLY_SRC exited nonzero against the fake curl"
    );

    let logged_argv = std::fs::read_to_string(&argv_log).expect("read fake curl's argv log");
    assert!(
        !logged_argv.contains(token),
        "the token appeared in curl's own argv: {logged_argv:?}"
    );

    let logged_stdin = std::fs::read_to_string(&stdin_log).unwrap_or_default();
    assert!(
        logged_stdin.contains(&format!("Authorization: Bearer {token}")),
        "the Authorization header was never delivered to curl via stdin: {logged_stdin:?}"
    );
}

#[test]
fn butler_claude_builder_keeps_its_noninteractive_cli_hint() {
    let adapter = include_str!("../../packages/butler/agents/claudecode.lua");

    let permission_mode_idx = adapter
        .find("\"--permission-mode\"")
        .expect("butler launch argv lost --permission-mode");
    let append_system_prompt_idx = adapter
        .find("\"--append-system-prompt\"")
        .expect("butler launch argv lost --append-system-prompt");

    assert!(
        permission_mode_idx < append_system_prompt_idx,
        "expected --permission-mode before --append-system-prompt"
    );
}

#[test]
fn butler_codex_builder_uses_automatic_approval() {
    let path = scratch("butler-codex-builder");
    let _daemon = daemon_at(&path);
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 1"}; remuda.exec("butler")"#,
    );
    let argv = eval(
        &path,
        r#"local a = remuda._butler_agent_builders.codex({name="codex", token="token", telemetry={status_path="/tmp/status"}}); return table.concat(a, "\n")"#,
    );
    let argv: Vec<&str> = argv.lines().collect();
    assert_eq!(&argv[..2], ["remuda", "_codex_tui"]);
    assert!(argv
        .windows(2)
        .any(|pair| pair == ["--status", "/tmp/status"]));
}

/// A delegated task must survive the agent's startup dialogs: Butler answers
/// each kind's known modals (agents/*.lua) and types the task only once the
/// composer is ready. Screens are real captures (Claude's workspace-trust
/// modal, Codex's update prompt), fed through a fake `remuda.capture`; a
/// screen no table knows must time out into the trace, never be typed into.
#[test]
#[cfg(unix)]
fn butler_task_poke_answers_startup_modals_before_typing() {
    let dir = scratch_dir("butler-startup-modals");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).expect("test home");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 30"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let trace = dir.join("session-trace.log");
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({home:?})
          remuda._butler_session_trace_path = {trace:?}
          remuda._butler_task_poke_attempts = 6
          remuda._butler_agent_builders.claude = function() return {{"sh"}} end
          remuda._butler_agent_builders.codex = function() return {{"sh", "-c", "sleep 30"}} end
          local rule = string.rep("─", 20)
          local screens = {{
            ["t-claude"] = {{
              rule .. "\n Accessing workspace:\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel",
              rule .. "\n❯ \n" .. rule,
            }},
            ["t-codex"] = {{
              "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version\n› Ask Codex to do anything",
              "› Ask Codex to do anything",
            }},
            ["t-codex-peer"] = {{
              "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version\n› Ask Codex to do anything",
              "› Ask Codex to do anything",
            }},
            ["t-codex-timeout"] = {{
              "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version\n› Ask Codex to do anything",
              "› Ask Codex to do anything",
            }},
            ["t-codex-unanswerable"] = {{ "Update available\n› 1. Install update\n  2. Later" }},
            ["t-codex-human"] = {{ "Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip" }},
            ["t-codex-close"] = {{ "Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip" }},
            ["t-codex-skip-label"] = {{ "Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip for now\n  3. Skip until next version" }},
            ["t-codex-versionless"] = {{ "Update available\n› 1. Update now\n  2. Skip", "› Ask Codex to do anything" }},
            ["t-codex-human-owner"] = {{ "Update available\n› 1. Update now\n  2. Skip" }},
            ["t-codex-gui-close"] = {{ "Update available · 0.157.1 → 0.158.0\n› 1. Update now\n  2. Skip" }},
            ["t-codex-running"] = {{ "› Ask Codex to do anything" }},
            ["t-claude-human-trust"] = {{ "Accessing workspace:\n ❯ No, exit\n   Yes, I trust this folder" }},
            ["t-stuck"] = {{ " Some unknown dialog\n ❯ 1. No, exit" }},
          }}
          local log = {{}}
          local human_owner_update_started = false
          local versionless_launches = 0
          remuda._t = log
          remuda._butler_bus.codex_update_state = {{claimed=false, done=false}}
          remuda._butler_codex_update_timeout = 2
          remuda._butler_modal_timeout = 3
          local native_close = remuda.close
          -- remuda.close is reported as reason "closed" by cores with #258; a
          -- simulated natural exit substitutes the exit the real process would report.
          local exit_infos = {{}}
          local session_exited = remuda._butler_session_exited
          remuda._butler_session_exited = function(n, info)
            local natural = exit_infos[n]
            exit_infos[n] = nil
            return session_exited(n, natural or info)
          end
          local function natural_exit(n, info)
            exit_infos[n] = info
            native_close(n)
            remuda._butler_bus.close_requested[n] = nil
          end
          local native_ls = remuda.ls
          remuda.ls = function(...)
            local rows = native_ls(...)
            for _, row in ipairs(rows) do
              if row.name == "t-codex-human" or row.name == "t-claude-human-trust" then row.attached, row.human_idle = true, 0 end
              if row.name == "t-codex-human-owner" then
                row.attached, row.human_idle = true, human_owner_update_started and 0 or 10
              end
            end
            return rows
          end
          local native_new = remuda.new
          remuda.new = function(name, ...)
            local actual = native_new(name, ...)
            if name:match("^t%-codex") then log[#log + 1] = name .. " launch" end
            if name == "t-codex-versionless" then
              versionless_launches = versionless_launches + 1
              if versionless_launches > 1 then screens[name] = {{ "› Ask Codex to do anything" }} end
            end
            if name == "t-codex-timeout" then
              log[#log + 1] = name .. " launch"
              screens[name] = {{ "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version\n› Ask Codex to do anything" }}
            end
            return actual
          end
          remuda.capture = function(n)
            local q = screens[n]
            if #q > 1 then return table.remove(q, 1) end
            return q[1]
          end
          remuda.capture_styled = nil
          remuda.key = function(n, k)
            log[#log + 1] = n .. " key " .. k
            if (n == "t-codex" or n == "t-codex-peer") and k == "1" then
              screens[n] = {{ "› Ask Codex to do anything" }}
            elseif (n == "t-codex" or n == "t-codex-peer") and k == "2" then
              screens[n] = {{ "› Ask Codex to do anything" }}
            elseif n == "t-codex-timeout" and k == "1" then
              screens[n] = {{ "Updating Codex..." }} -- update never finishes
            elseif n == "t-codex-timeout" and k == "2" then
              screens[n] = {{ "› Ask Codex to do anything" }}
            elseif n == "t-codex-close" and k == "1" then
              screens[n] = {{ "Updating Codex..." }}
              native_close(n) -- explicit leader close must not trigger a restart
            elseif n == "t-codex-skip-label" and k == "2" then
              screens[n] = {{ "› Ask Codex to do anything" }}
            elseif n == "t-codex-skip-label" and k == "3" then
              screens[n] = {{ "› Ask Codex to do anything" }}
            elseif n == "t-codex-versionless" and k == "1" then
              screens[n] = {{ "🎉 Update ran successfully! Please restart Codex." }}
              local restart = remuda._butler_bus.codex_update_relaunches[n]
              restart.last_screen = remuda.capture(n) -- captured immediately before Codex exits
              natural_exit(n, {{ reason = "exited", exit_code = 0 }})
            elseif n == "t-codex-human-owner" and k == "1" then
              human_owner_update_started = true
              screens[n] = {{ "› Ask Codex to do anything" }} -- update completed in place
            elseif n == "t-codex-gui-close" and k == "1" then
              screens[n] = {{ "Updating Codex..." }}
              natural_exit(n) -- raw session-screen close has no Lua close marker
            end
          end
          remuda.type_text = function(n, t)
            log[#log + 1] = n .. " type " .. t
            local glyph = n == "t-codex" and "› " or "❯ "
            screens[n] = {{ glyph .. t, glyph }}
          end
          local policy = remuda._butler_notify_policy
          remuda._butler_notify_policy = function(n, now)
            if n == "butler" then return true end
            return policy(n, now)
          end
          local leader = remuda._butler_initial_name
          local update_screen = screens["t-codex"][1]
          assert(not remuda._butler_agent_startup.codex.ready(update_screen), "update dialog counted as ready")
          remuda._butler_topic_delegate("t-claude", "task one", nil, "claude", leader)
          remuda._butler_topic_delegate("t-codex", "task two", nil, "codex", leader)
          remuda._butler_topic_delegate("t-codex-peer", "task peer", nil, "codex", leader)
          remuda._butler_topic_delegate("t-codex-unanswerable", "task unanswerable", nil, "codex", leader)
          remuda._butler_topic_new("t-codex-running", nil, "codex")
          remuda._butler_topic_delegate("t-codex-human", "task human", nil, "codex", leader)
          remuda._butler_topic_delegate("t-claude-human-trust", "task human trust", nil, "claude", leader)
          remuda._butler_topic_delegate("t-stuck", "task three", nil, "claude", leader)
        "#,
            home = home.to_string_lossy(),
            trace = trace.to_string_lossy(),
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(25);
    let log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        let traced = std::fs::read_to_string(&trace).unwrap_or_default();
        // The leader's "task not delivered" notice is typed too; count only
        // the topic sessions' own lines.
        let typed = log.lines().filter(|l| l.starts_with("t-") && l.contains(" type ")).count();
        if typed == 3 && traced.contains("task_poke_timeout\tt-stuck")
            && eval(&path, "return tostring(remuda._butler_bus.pending_tasks['t-codex-unanswerable'] == nil and remuda._butler_bus.pending_tasks['t-codex-human'] == nil)") == "true" {
            break log;
        }
        assert!(
            Instant::now() < deadline,
            "pokes never settled: {log}\n{traced}"
        );
        std::thread::sleep(Duration::from_millis(100));
    };
    let claude: Vec<&str> = log.lines().filter(|l| l.starts_with("t-claude ")).collect();
    assert_eq!(claude, ["t-claude key <down>", "t-claude key RET", "t-claude type task one"]);
    let codex_key_one = log.lines().find(|l| l.ends_with(" key 1")).unwrap();
    let update_owner = codex_key_one.split_whitespace().next().unwrap();
    assert_eq!(log.lines().filter(|l| l.ends_with(" key 1")).count(), 1, "more than one member upgraded: {log}");
    assert_eq!(log.lines().filter(|l| l.ends_with(" key 2")).count(), 0, "a concurrent member skipped before the owner update finished: {log}");
    for (member, task) in [("t-codex", "task two"), ("t-codex-peer", "task peer")] {
        let rows: Vec<&str> = log.lines().filter(|l| l.starts_with(&format!("{member} "))).collect();
        let launches = rows.iter().filter(|l| l.ends_with(" launch")).count();
        assert_eq!(launches, 2, "owner and waiter should both relaunch after update: {log}");
        assert_eq!(rows.iter().filter(|l| l.ends_with(&format!(" type {task}"))).count(), 1, "task was not delivered exactly once: {log}");
        if member == update_owner {
            assert!(rows.iter().any(|l| l.ends_with(" key 1")), "owner did not select Update now: {log}");
        } else {
            assert!(!rows.iter().any(|l| l.ends_with(" key 1") || l.ends_with(" key 2")), "waiter acted before the owner update: {log}");
        }
    }
    assert!(!log.contains("t-stuck "), "typed into an unknown dialog: {log}");
    assert!(log.contains(" type Butler message "), "the leader is told about t-stuck: {log}");
    assert_eq!(log.lines().filter(|l| l.starts_with("t-codex-unanswerable key ")).count(), 0, "an unknown update menu was answered: {log}");
    assert_eq!(log.lines().filter(|l| l.starts_with("t-codex-human key ")).count(), 0, "a human-attached pane was changed: {log}");
    assert_eq!(log.lines().filter(|l| l.starts_with("t-claude-human-trust key ")).count(), 0, "modal keys were pressed after give_up: {log}");
    eval(
        &path,
        r#"
          remuda._butler_bus.codex_update_state = {claimed=false, done=false, waiting={}}
          remuda._butler_topic_delegate("t-codex-close", "task closed", nil, "codex", remuda._butler_initial_name)
        "#,
    );
    let close_deadline = Instant::now() + Duration::from_secs(10);
    let closed_log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        if log.contains("t-codex-close key 1") && log.lines().filter(|l| l.starts_with("t-codex-close launch")).count() == 1
            && eval(&path, "return tostring(remuda._butler_bus.agents['t-codex-close'] == nil)") == "true" { break log; }
        assert!(Instant::now() < close_deadline, "explicit close relaunched the updating member: {log}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(closed_log.lines().filter(|l| l.starts_with("t-codex-close launch")).count(), 1);
    eval(
        &path,
        r#"
          remuda._butler_bus.codex_update_state = {claimed=true, done=false, owner="external-updater",
            version="0.156.0->0.157.1", waiting={}}
          remuda._butler_codex_update_timeout = -1
          remuda._butler_topic_delegate("t-codex-skip-label", "task after skip label", nil, "codex", remuda._butler_initial_name)
        "#,
    );
    let skip_deadline = Instant::now() + Duration::from_secs(10);
    let skip_label_log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        if log.contains("t-codex-skip-label type task after skip label") { break log; }
        assert!(Instant::now() < skip_deadline, "prefix Skip label was not handled: {log}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(skip_label_log.contains("t-codex-skip-label key 2"), "did not choose Skip for now: {skip_label_log}");
    assert!(!skip_label_log.contains("t-codex-skip-label key 3"), "preferred Skip until next version: {skip_label_log}");
    eval(
        &path,
        r#"
          remuda._butler_bus.codex_update_state = {claimed=false, done=false}
          remuda._butler_topic_delegate("t-codex-timeout", "task after timeout", nil, "codex", remuda._butler_initial_name)
        "#,
    );
    let deadline = Instant::now() + Duration::from_secs(15);
    let after_timeout = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        let traced = std::fs::read_to_string(&trace).unwrap_or_default();
        if traced.contains("codex_update_timeout\tt-codex-timeout") {
            break log;
        }
        assert!(Instant::now() < deadline, "slow update timeout did not report while leaving its pane open: {log}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let timed_out_member: Vec<&str> = after_timeout.lines()
        .filter(|l| l.starts_with("t-codex-timeout "))
        .collect();
    assert!(timed_out_member.iter().any(|l| l.ends_with(" key 1")), "update was not selected: {after_timeout}");
    assert!(!timed_out_member.iter().any(|l| l.ends_with(" key 2") || l.ends_with(" type task after timeout")), "slow update was skipped or task typed into its old pane: {after_timeout}");
    assert!(after_timeout.contains("type Butler message"), "timeout did not notify the leader: {after_timeout}");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.pending_tasks['t-codex-timeout'] == nil)"), "true");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.codex_update_relaunches['t-codex-timeout'] ~= nil)"), "true", "slow update pane was closed or lost its restart record");
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.codex_update_state.waiting['t-codex-running'] == nil and next(remuda._butler_bus.codex_update_state.waiting) == nil)"), "true", "already-running Codex aliases remained in the waiting set");
    assert_eq!(eval(&path, "local n=0; for _,v in ipairs(remuda._t) do if v == 't-codex-running launch' then n=n+1 end end; return tostring(n)"), "1", "an already-running Codex alias was relaunched");
    eval(&path, r#"remuda._butler_bus.codex_update_state={claimed=false,done=false,waiting={},restart_waiting={}}; remuda._butler_topic_delegate("t-codex-versionless", "versionless task", nil, "codex", remuda._butler_initial_name)"#);
    let versionless_deadline = Instant::now() + Duration::from_secs(10);
    let versionless_log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        if log.contains("t-codex-versionless type versionless task") { break log; }
        assert!(Instant::now() < versionless_deadline, "versionless update dialog did not select Update now: {log}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(versionless_log.lines().filter(|l| l.starts_with("t-codex-versionless key 1")).count(), 1, "versionless update did not select Update now: {versionless_log}");
    assert_eq!(versionless_log.lines().filter(|l| l.starts_with("t-codex-versionless type versionless task")).count(), 1, "versionless task delivery duplicated: {versionless_log}");
    assert_eq!(versionless_log.lines().filter(|l| l.starts_with("t-codex-versionless launch")).count(), 2, "successful exiting update was not relaunched: {versionless_log}");
    eval(&path, r#"remuda._butler_bus.codex_update_state={claimed=false,done=false,waiting={},restart_waiting={}}; remuda._butler_topic_delegate("t-codex-human-owner", "task after human", nil, "codex", remuda._butler_initial_name)"#);
    let human_owner_deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let traced = std::fs::read_to_string(&trace).unwrap_or_default();
        if traced.contains("codex_update_timeout\tt-codex-human-owner") { break; }
        assert!(Instant::now() < human_owner_deadline, "human-attached completed update did not escalate: {traced}");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.codex_update_state.claimed == false and remuda._butler_bus.pending_tasks['t-codex-human-owner'] == nil)"), "true", "human-blocked update retained its claim or pending task");
    let human_owner_log = eval(&path, "return table.concat(remuda._t, '\\n')");
    assert_eq!(human_owner_log.lines().filter(|l| l.starts_with("t-codex-human-owner key ")).count(), 1, "unexpected key count for attached update pane: {human_owner_log}");
    assert_eq!(human_owner_log.lines().filter(|l| l.starts_with("t-codex-human-owner launch")).count(), 1, "closed/relaunched an attached update pane: {human_owner_log}");
    eval(&path, r#"remuda._butler_bus.codex_update_state={claimed=false,done=false,waiting={},restart_waiting={}}; remuda._butler_topic_delegate("t-codex-gui-close", "task gui close", nil, "codex", remuda._butler_initial_name)"#);
    let gui_close_deadline = Instant::now() + Duration::from_secs(10);
    while eval(&path, "return tostring(remuda._butler_bus.agents['t-codex-gui-close'] == nil)") != "true" {
        assert!(Instant::now() < gui_close_deadline, "screen close was not observed");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(eval(&path, "return tostring(remuda._butler_bus.codex_update_state.done_version ~= '0.157.1->0.158.0' and remuda._butler_bus.codex_update_state.claimed == false and remuda._butler_bus.codex_update_relaunches['t-codex-gui-close'] == nil)"), "true", "screen close was mistaken for update completion");
    assert_eq!(eval(&path, "local found=false; for _,o in pairs(remuda._butler_bus.objects) do if (o.content or ''):find('Task for t-codex-gui-close was not delivered', 1, true) then found=true end end; return tostring(found)"), "true", "aborted update silently lost its task");
    eval(&path, r#"remuda.capture_styled=function() return {rows={[2]={{text="",dim=false}},[3]={{text="",dim=false}}},cursor={row=3}} end"#);
    eval(&path, r#"remuda._butler_notify("t-codex-timeout", "Butler message 01M3MX8NCGV5GVSGN104YP4TFT arrived. Read them: remuda butler inbox")"#);
    let modal_notice_log = eval(&path, "return table.concat(remuda._t, '\\n')");
    assert!(!modal_notice_log.contains("t-codex-timeout type Butler message"), "mail notice was typed into an update progress dialog: {modal_notice_log}");
    drop(daemon);
}

#[test]
#[cfg(unix)]
fn reexecuting_butler_keeps_the_root_telemetry_identity() {
    let dir = scratch_dir("butler-telemetry-reexec");
    let home = dir.join("home");
    std::fs::create_dir_all(&home).expect("test home");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"
          remuda._butler_argv = {"sh", "-c", "sleep 30"}
          remuda._butler_skip_relay = true
        "#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let before = eval(
        &path,
        r#"
          local a = remuda._butler_bus.agents.butler
          return a.token .. "\n" .. a.telemetry.status_path
        "#,
    );
    let mut before_lines = before.lines();
    let token = before_lines.next().expect("root token").to_owned();
    let status_path = before_lines.next().expect("status path").to_owned();
    std::fs::write(&status_path, "MODEL:claude CTX:1234 CTXWIN:200000 CTXPCT:1")
        .expect("status record");

    let again = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        again.status.success(),
        "{}",
        String::from_utf8_lossy(&again.stderr)
    );
    assert_eq!(
        eval(
            &path,
            r#"
              local a = remuda._butler_bus.agents.butler
              local t = remuda._butler_telemetry_for(a)
              return a.token .. "\n" .. a.telemetry.status_path .. "\n"
                .. t.model .. ":" .. t.context_used .. ":" .. t.context_window .. ":" .. t.context_percent
            "#,
        ),
        format!("{token}\n{status_path}\nclaude:1234:200000:1")
    );
    drop(daemon);
}

fn test_ulid_stub() -> &'static str {
    r#"remuda._butler_new_ulid = remuda._butler_new_ulid or function()
      remuda._mail_test_ulid = (remuda._mail_test_ulid or 0) + 1
      return string.format("0000000000%016X", remuda._mail_test_ulid)
    end"#
}

#[test]
fn butler_mail_separates_the_envelope_from_its_body_object() {
    let path = scratch("butler-mail");
    let _daemon = daemon_at(&path);
    eval(
        &path,
        &(test_ulid_stub().to_owned()
            + r#"
          remuda._butler_mail_config = {
            bus = { agents = { fixer = { id = "01FIXER" } }, inboxes = {}, messages = {}, objects = {}, next = 0 },
            json_quote = function(value) return '"' .. value .. '"' end,
          }
          remuda.exec("butler/mail")
        "#),
    );
    let result = eval(
        &path,
        r#"
          local message = remuda._butler_mail.queue("butler", "fixer", "private body")
          local object = remuda._butler_mail_config.bus.objects[message.body.object_id]
          return message.from.host .. ":" .. message.from.session .. "\n"
            .. message.body.object_id .. "\n" .. object.content .. "\n"
            .. remuda._butler_mail.inbox("01FIXER")
        "#,
    );
    let lines: Vec<&str> = result.lines().collect();
    assert_eq!(lines[0], "local:butler");
    assert!(lines[1].starts_with("object-"));
    assert_eq!(lines[2], "private body");
    assert!(result.contains("Message from butler\nprivate body"));
}

/// A mail root holding one delivered message (`message-a`) for `id`, and the
/// hex inbox/read paths mail.lua derives from that id.
fn seeded_mail_root(dir: &Path, id: &str) -> (PathBuf, PathBuf, PathBuf) {
    let root = dir.join("mail");
    for sub in ["inboxes", "read", "messages", "objects"] {
        std::fs::create_dir_all(root.join(sub)).expect("mail dirs");
    }
    std::fs::write(
        root.join("messages/message-a.json"),
        r#"{"id":"message-a","from":{"host":"local","session":"old"},"subject":"Seeded A","body":{"object_id":"object-a"}}"#,
    )
    .expect("envelope a");
    std::fs::write(root.join("objects/object-a"), "body of a").expect("object a");
    let hex: String = id.bytes().map(|b| format!("{b:02x}")).collect();
    let inbox = root.join(format!("inboxes/{hex}.jsonl"));
    let read = root.join(format!("read/{hex}.jsonl"));
    (root, inbox, read)
}

fn mail_config_lua(root: &Path) -> String {
    format!(
        r#"{stub}
           remuda._butler_mail_config = {{
             bus = {{ agents = {{}}, inboxes = {{}}, messages = {{}}, objects = {{}}, next = 0 }},
             root = {root}, json_quote = function(value) return '"' .. value .. '"' end,
           }}
           remuda.exec("butler/mail")"#,
        stub = test_ulid_stub(),
        root = lua_raw_string(&root.to_string_lossy())
    )
}

/// A crash mid-append leaves a row with no newline; the next delivery must
/// not be glued onto it and lost (NOTES.md §1 finding 1).
#[test]
fn butler_mail_torn_inbox_tail_does_not_swallow_the_next_delivery() {
    let id = "01TORNTA1L000000000000000A";
    let dir = scratch_dir("butler-mail-torn");
    let (root, inbox, _) = seeded_mail_root(&dir, id);
    std::fs::write(
        &inbox,
        "{\"message_id\":\"message-a\"}\n{\"message_id\":\"message-to",
    )
    .expect("torn");
    let path = scratch("butler-mail-torn");
    let _daemon = daemon_at(&path);
    eval(
        &path,
        &format!(
            r#"{}
               local to = {{ host = "local", id = "{id}", alias = "fixer", session = "fixer" }}
               assert(remuda._butler_mail.queue("butler", to, "the new delivery"))"#,
            mail_config_lua(&root)
        ),
    );
    // A fresh mailbox reads the inbox back from disk, as after a restart.
    let out = eval(
        &path,
        &format!(
            "{}\nreturn remuda._butler_mail.inbox(\"{id}\")",
            mail_config_lua(&root)
        ),
    );
    assert!(
        out.contains("body of a"),
        "the torn row's neighbour was lost: {out:?}"
    );
    assert!(
        out.contains("the new delivery"),
        "the delivery after a torn row was lost: {out:?}"
    );
}

/// An inbox row whose envelope is missing or corrupt must stay unread and be
/// reported, never silently marked read (NOTES.md §1 finding 2).
#[test]
fn butler_mail_unloadable_envelope_stays_unread_and_is_reported() {
    let id = "01UN10ADAB1E00000000000000";
    let dir = scratch_dir("butler-mail-unloadable");
    let (root, inbox, read) = seeded_mail_root(&dir, id);
    std::fs::write(root.join("messages/message-corrupt.json"), "{not json").expect("corrupt");
    std::fs::write(
        &inbox,
        "{\"message_id\":\"message-a\"}\n{\"message_id\":\"message-missing\"}\n{\"message_id\":\"message-corrupt\"}\n",
    )
    .expect("inbox rows");
    let path = scratch("butler-mail-unloadable");
    let _daemon = daemon_at(&path);
    let first = eval(
        &path,
        &format!(
            "{}\nreturn remuda._butler_mail.inbox(\"{id}\")",
            mail_config_lua(&root)
        ),
    );
    assert!(first.contains("body of a"), "{first:?}");
    for bad in ["message-missing", "message-corrupt"] {
        assert!(
            first.contains(&format!("message {bad}: envelope unreadable, left unread")),
            "{bad} was not reported: {first:?}"
        );
    }
    let read_ids = std::fs::read_to_string(&read).unwrap_or_default();
    assert!(
        read_ids.contains("message-a"),
        "the shown message was not marked read"
    );
    assert!(
        !read_ids.contains("message-missing"),
        "an unloadable row was marked read"
    );
    assert!(
        !read_ids.contains("message-corrupt"),
        "an unloadable row was marked read"
    );
    let again = eval(
        &path,
        &format!(
            "{}\nreturn remuda._butler_mail.inbox(\"{id}\")",
            mail_config_lua(&root)
        ),
    );
    assert!(
        again.contains("message message-missing: envelope unreadable"),
        "{again:?}"
    );
    assert!(
        !again.contains("body of a"),
        "a read message came back: {again:?}"
    );
}

/// Within ONE live bus: an envelope that becomes readable later is delivered
/// on the next inbox(), not reported unreadable until a restart.
#[test]
fn butler_mail_unreadable_envelope_is_retried_in_the_same_bus() {
    let id = "01RETRYUNREADAB1E000000000";
    let dir = scratch_dir("butler-mail-retry");
    let (root, inbox, read) = seeded_mail_root(&dir, id);
    std::fs::write(&inbox, "{\"message_id\":\"message-late\"}\n").expect("inbox row");
    let path = scratch("butler-mail-retry");
    let _daemon = daemon_at(&path);
    let first = eval(
        &path,
        &format!(
            "{}\nreturn remuda._butler_mail.inbox(\"{id}\")",
            mail_config_lua(&root)
        ),
    );
    assert!(
        first.contains("message message-late: envelope unreadable, left unread"),
        "{first:?}"
    );
    let count = eval(
        &path,
        &format!("return tostring(remuda._butler_mail.unread(\"{id}\"))"),
    );
    assert_eq!(count, "0", "an unreadable id is not counted");

    std::fs::write(
        root.join("messages/message-late.json"),
        r#"{"id":"message-late","from":{"host":"local","session":"slow"},"subject":"Late","body":{"object_id":"object-late"}}"#,
    )
    .expect("late envelope");
    std::fs::write(root.join("objects/object-late"), "late body").expect("late object");
    let count = eval(
        &path,
        &format!("return tostring(remuda._butler_mail.unread(\"{id}\"))"),
    );
    assert_eq!(count, "1", "a now-readable id is counted");
    let second = eval(
        &path,
        &format!("return remuda._butler_mail.inbox(\"{id}\")"),
    );
    assert!(
        second.contains("late body"),
        "the late envelope was not delivered: {second:?}"
    );
    assert!(!second.contains("envelope unreadable"), "{second:?}");
    let read_ids = std::fs::read_to_string(&read).unwrap_or_default();
    assert!(
        read_ids.contains("message-late"),
        "the delivered id was not marked read"
    );
}

const REPLY_B: &str = "01REP1YBUT1ER0000000000000";
const REPLY_F: &str = "01REP1YF1XER00000000000000";

fn hex_component(id: &str) -> String {
    id.bytes().map(|b| format!("{b:02x}")).collect()
}

/// `mail.lua` plus two addresses, `B` (butler) and `F` (fixer), in Lua.
fn reply_prelude(root: &Path) -> String {
    format!(
        r#"{}
           local M = remuda._butler_mail
           local B = {{ host = "local", id = "{REPLY_B}", alias = "butler", session = "butler" }}
           local F = {{ host = "local", id = "{REPLY_F}", alias = "fixer", session = "fixer" }}"#,
        mail_config_lua(root)
    )
}

/// RFC 5322 §3.6.4: a reply carries in_reply_to = parent and references =
/// parent's references + parent; it goes to the parent's sender.
#[test]
fn butler_mail_reply_threads_with_in_reply_to_and_references() {
    let dir = scratch_dir("butler-mail-thread");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = scratch("butler-mail-thread");
    let _daemon = daemon_at(&path);
    let out = eval(
        &path,
        &format!(
            r#"{}
               local a = assert(M.queue(B, F, "question"))
               local b = assert(M.reply(F, a.id, "answer"))
               local c = assert(M.reply(B, b.id, "thanks"))
               return table.concat({{ a.id, b.id, c.id, b.to[1].alias, c.to[1].alias, b.subject,
                 c.subject, table.concat(c.references, ","), c.in_reply_to }}, "\n")"#,
            reply_prelude(&root)
        ),
    );
    let v: Vec<&str> = out.lines().collect();
    let (a, b, c) = (v[0], v[1], v[2]);
    assert_eq!(v[3], "butler", "a reply goes to the parent's sender");
    assert_eq!(v[4], "fixer");
    assert_eq!(v[5], "Re: Message from butler");
    assert_eq!(v[6], "Re: Message from butler", "Re: is not doubled");
    assert_eq!(
        v[7],
        format!("{a},{b}"),
        "references = parent's references + parent"
    );
    assert_eq!(v[8], b);
    let envelope = std::fs::read_to_string(root.join(format!("messages/{c}.json"))).unwrap();
    assert!(
        envelope.contains(&format!(r#""in_reply_to":"{b}""#)),
        "{envelope}"
    );
    assert!(
        envelope.contains(&format!(r#""references":["{a}","{b}"]"#)),
        "{envelope}"
    );

    let fresh = eval(
        &path,
        &format!("{}\nreturn M.inbox(F.id)", reply_prelude(&root)),
    );
    assert!(
        fresh.contains(&format!("  in reply to {b} (thread {a})")),
        "{fresh}"
    );
    assert!(
        fresh.contains("thanks") && fresh.contains("question"),
        "{fresh}"
    );
}

/// JWZ safety: a missing parent keeps the thread, a self-reference is
/// dropped; an envelope from before threading replies like a root.
#[test]
fn butler_mail_reply_tolerates_old_missing_and_self_referencing_parents() {
    let dir = scratch_dir("butler-mail-jwz");
    let (root, f_inbox, _) = seeded_mail_root(&dir, REPLY_F);
    let from_b = format!(
        r#""from":{{"host":"local","id":"{REPLY_B}","alias":"butler","kind":"","leader":"","session":"butler"}}"#
    );
    for (id, extra) in [
        ("message-old", String::new()),
        (
            "message-orphan",
            r#","in_reply_to":"message-gone""#.to_string(),
        ),
        (
            "message-selfref",
            r#","in_reply_to":"message-selfref","references":["message-selfref"]"#.to_string(),
        ),
        ("message-op", String::new()),
    ] {
        let from = if id == "message-op" {
            r#""from":{"host":"local","id":"","alias":"operator","kind":"","leader":"","session":"operator"}"#.to_string()
        } else {
            from_b.clone()
        };
        std::fs::write(
            root.join(format!("messages/{id}.json")),
            format!(r#"{{"id":"{id}",{from},"subject":"S {id}"{extra},"body":{{"object_id":"object-a"}}}}"#),
        )
        .unwrap();
    }
    std::fs::write(
        &f_inbox,
        "{\"message_id\":\"message-old\"}\n{\"message_id\":\"message-orphan\"}\n{\"message_id\":\"message-selfref\"}\n{\"message_id\":\"message-op\"}\n",
    )
    .unwrap();
    let path = scratch("butler-mail-jwz");
    let _daemon = daemon_at(&path);
    let out = eval(
        &path,
        &format!(
            r#"{}
               local function refs(id) local m = assert(M.reply(F, id, "r")); return table.concat(m.references, ",") .. "|" .. m.to[1].alias end
               local _, not_mine = M.reply(B, "message-old", "x")
               local _, from_op = M.reply(F, "message-op", "x")
               return table.concat({{ refs("message-old"), refs("message-orphan"), refs("message-selfref"),
                 tostring(not_mine), tostring(from_op) }}, "\n")"#,
            reply_prelude(&root)
        ),
    );
    let v: Vec<&str> = out.lines().collect();
    assert_eq!(
        v[0], "message-old|butler",
        "an old envelope is a thread root"
    );
    assert_eq!(
        v[1], "message-gone,message-orphan|butler",
        "a missing parent still threads"
    );
    assert_eq!(
        v[2], "message-selfref|butler",
        "a self-reference is dropped, never looped"
    );
    assert!(
        v[3].contains("not delivered"),
        "reply is only for mail delivered to you: {out}"
    );
    assert!(
        v[4].contains("no Butler inbox"),
        "operator has no inbox to reply to: {out}"
    );
    let b_view = eval(
        &path,
        &format!("{}\nreturn M.inbox(B.id)", reply_prelude(&root)),
    );
    assert!(
        b_view.contains("in reply to message-orphan (thread message-gone)"),
        "{b_view}"
    );
}

const REPLY_W: &str = "01REP1YW0RKER0000000000000";

/// RFC 5322 §3.6.6 + postfix redirection: forward re-delivers the SAME message
/// (id, sender, body untouched) with a resent row; a second delivery is refused.
#[test]
fn butler_mail_forward_redelivers_the_original_with_a_resent_row() {
    let dir = scratch_dir("butler-mail-forward");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = scratch("butler-mail-forward");
    let _daemon = daemon_at(&path);
    let prelude = format!(
        r#"{}
           local W = {{ host = "local", id = "{REPLY_W}", alias = "worker", session = "worker" }}"#,
        reply_prelude(&root)
    );
    let a = eval(
        &path,
        &format!("{prelude}\nreturn assert(M.queue(B, F, \"question\")).id"),
    );
    let envelope = root.join(format!("messages/{a}.json"));
    let before = std::fs::read(&envelope).unwrap();
    let out = eval(
        &path,
        &format!(
            r#"{prelude}
               assert(M.forward(F, "{a}", W, "see para 2"))
               local _, again = M.forward(F, "{a}", W)
               local _, back = M.forward(W, "{a}", F)
               local _, stranger = M.forward(W, "message-nope", B)
               return table.concat({{ tostring(again), tostring(back), tostring(stranger) }}, "\n")"#
        ),
    );
    let v: Vec<&str> = out.lines().collect();
    assert!(
        v[0].contains("already delivered to worker"),
        "loop guard: {out}"
    );
    assert!(
        v[1].contains("already delivered to fixer"),
        "loop guard back: {out}"
    );
    assert!(v[2].contains("not delivered"), "only your own mail: {out}");
    assert_eq!(
        std::fs::read(&envelope).unwrap(),
        before,
        "the original envelope is never rewritten"
    );
    let row =
        std::fs::read_to_string(root.join(format!("inboxes/{}.jsonl", hex_component(REPLY_W))))
            .unwrap();
    assert!(
        row.contains(&format!(r#""message_id":"{a}","resent":{{"#))
            && row.contains("note_object_id"),
        "{row}"
    );

    let fresh = eval(&path, &format!("{prelude}\nreturn M.inbox(W.id)"));
    assert!(
        fresh.contains(&format!("[{a} from local/butler ")),
        "original sender kept: {fresh}"
    );
    assert!(
        fresh.contains("  forwarded by fixer to worker at ") && fresh.contains(": see para 2"),
        "{fresh}"
    );
    assert!(fresh.contains("question"), "original body kept: {fresh}");
}

/// Butler's approval (a) and (b): read state is per inbox, and a reply to a
/// forwarded message goes to the ORIGINAL sender, not the forwarder.
#[test]
fn butler_mail_forwarded_read_state_is_per_inbox_and_replies_reach_the_original_sender() {
    let dir = scratch_dir("butler-mail-fwd-read");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = scratch("butler-mail-fwd-read");
    let _daemon = daemon_at(&path);
    let out = eval(
        &path,
        &format!(
            r#"{}
               local W = {{ host = "local", id = "{REPLY_W}", alias = "worker", session = "worker" }}
               local a = assert(M.queue(B, F, "question"))
               assert(M.forward(F, a.id, W))
               M.inbox(F.id)
               local w_unread_after_f_read = M.unread(W.id)
               local w_view = M.inbox(W.id)
               local f_again = M.inbox(F.id)
               local r = assert(M.reply(W, a.id, "answer from worker"))
               return table.concat({{ tostring(w_unread_after_f_read), tostring(w_view:find("question", 1, true) ~= nil),
                 f_again, r.to[1].alias, r.in_reply_to == a.id and "threaded" or "not" }}, "\n")"#,
            reply_prelude(&root)
        ),
    );
    let v: Vec<&str> = out.lines().collect();
    assert_eq!(
        v[0], "1",
        "the forwarder reading it leaves the target unread"
    );
    assert_eq!(v[1], "true", "the target still sees it");
    assert_eq!(
        v[2], "inbox empty",
        "the target reading it does not re-open the forwarder's copy"
    );
    assert_eq!(
        v[3], "butler",
        "a reply to forwarded mail goes to the original sender"
    );
    assert_eq!(v[4], "threaded");
}

/// rename() replaces silently; an id collision must fail loudly instead of
/// clobbering the earlier message (NOTES.md checklist #6, Maildir/nmh link()).
#[test]
fn butler_mail_refuses_to_overwrite_an_existing_message_on_an_id_collision() {
    let dir = scratch_dir("butler-mail-collide");
    let (root, f_inbox, _) = seeded_mail_root(&dir, REPLY_F);
    let collision_id = "00000000000000000000000000";
    std::fs::write(
        root.join(format!("messages/{collision_id}.json")),
        "ORIGINAL",
    )
    .unwrap();
    let path = scratch("butler-mail-collide");
    let _daemon = daemon_at(&path);
    let out = eval(
        &path,
        &format!(
            r#"{}
               remuda._butler_new_ulid = function() return "{collision_id}" end
               local ok, message, err = pcall(M.queue, B, F, "second")
               return tostring(ok) .. "|" .. tostring(message) .. "|" .. tostring(err)"#,
            reply_prelude(&root)
        ),
    );
    assert!(
        out.starts_with("true|nil|") && out.contains("already exists"),
        "not refused loudly: {out}"
    );
    assert_eq!(
        std::fs::read_to_string(root.join(format!("messages/{collision_id}.json"))).unwrap(),
        "ORIGINAL"
    );
    assert!(
        !std::fs::read_to_string(&f_inbox)
            .unwrap_or_default()
            .contains(collision_id),
        "a row was committed"
    );
}

/// Only an explicit operator skips the delivered check; an id-less caller
/// (an unknown MCP client) is refused and writes nothing (review of #39).
#[test]
fn butler_mail_an_unidentified_caller_cannot_reply_or_forward_but_the_operator_can() {
    let dir = scratch_dir("butler-mail-authz");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = scratch("butler-mail-authz");
    let _daemon = daemon_at(&path);
    let out = eval(
        &path,
        &format!(
            r#"{}
               local W = {{ host = "local", id = "{REPLY_W}", alias = "worker", session = "worker" }}
               local OUT = {{ host = "local", id = "", alias = "outside", session = "outside" }}
               local a = assert(M.queue(B, F, "secret"))
               local r1, e1 = M.forward(OUT, a.id, W)
               local r2, e2 = M.reply(OUT, a.id, "x")
               local w_rows = M.unread(W.id)
               local op = M.reply({{ host = "local", id = "", alias = "operator", session = "operator" }}, a.id, "from op", true)
               return table.concat({{ tostring(r1), tostring(e1), tostring(r2), tostring(e2), tostring(w_rows),
                 op and op.to[1].alias or "refused" }}, "\n")"#,
            reply_prelude(&root)
        ),
    );
    let v: Vec<&str> = out.lines().collect();
    assert_eq!(v[0], "nil", "an unidentified forward went through: {out}");
    assert!(v[1].contains("unknown caller"), "{out}");
    assert_eq!(v[2], "nil", "an unidentified reply went through: {out}");
    assert!(v[3].contains("unknown caller"), "{out}");
    assert_eq!(v[4], "0", "nothing reached the target");
    assert_eq!(v[5], "butler", "the explicit operator may still reply");
}

#[test]
fn butler_mail_survives_a_fresh_lua_mailbox_and_remembers_reads() {
    let dir = scratch_dir("butler-mail-reload");
    let root = dir.join("mail");
    let root_lua = lua_raw_string(&root.to_string_lossy());
    let path = scratch("butler-mail-reload");
    let _daemon = daemon_at(&path);
    eval(
        &path,
        &format!(
            r#"{stub}
              remuda._butler_mail_config = {{
                bus = {{ agents = {{ fixer = {{ id = "01FIXER" }} }}, inboxes = {{}}, messages = {{}}, objects = {{}}, next = 0 }},
                root = {root_lua}, json_quote = function(value) return '"' .. value .. '"' end,
              }}
              remuda.exec("butler/mail")
              return remuda._butler_mail.queue("butler", "fixer", "survives a restart").id
            "#,
            stub = test_ulid_stub(),
        ),
    );
    let received = eval(
        &path,
        &format!(
            r#"{stub}
              remuda._butler_mail_config = {{
                bus = {{ agents = {{ fixer = {{ id = "01FIXER" }} }}, inboxes = {{}}, messages = {{}}, objects = {{}}, next = 0 }},
                root = {root_lua}, json_quote = function(value) return '"' .. value .. '"' end,
              }}
              remuda.exec("butler/mail")
              return remuda._butler_mail.inbox("01FIXER")
            "#,
            stub = test_ulid_stub(),
        ),
    );
    assert!(received.contains("survives a restart"), "{received:?}");
    let after_read = eval(
        &path,
        &format!(
            r#"{stub}
              remuda._butler_mail_config = {{
                bus = {{ agents = {{ fixer = {{ id = "01FIXER" }} }}, inboxes = {{}}, messages = {{}}, objects = {{}}, next = 0 }},
                root = {root_lua}, json_quote = function(value) return '"' .. value .. '"' end,
              }}
              remuda.exec("butler/mail")
              return remuda._butler_mail.inbox("01FIXER")
            "#,
            stub = test_ulid_stub(),
        ),
    );
    assert_eq!(after_read, "inbox empty");
}

#[test]
fn matrix_mail_envelope_is_durable_and_deduplicated_across_daemon_restarts() {
    let dir = scratch_dir("matrix-mail");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = daemon::socket_path_in(&dir, "s");
    let matrix = r#"{ sender = "@alice:example.org", room_id = "!inbound:example.org",
      event_id = "$matrix-event", created_at = "2026-09-28T01:02:03Z" }"#;

    let daemon = Daemon::spawn(&dir);
    let first = eval(
        &path,
        &format!(
            r#"{}
               local from = {{ host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }}
               local a = assert(M.queue(from, F, "hello from Matrix", nil, nil, nil, {matrix}))
               local b = assert(M.queue(from, F, "hello from Matrix", nil, nil, nil, {matrix}))
               return a.id .. "\n" .. b.id"#,
            reply_prelude(&root)
        ),
    );
    let ids: Vec<&str> = first.lines().collect();
    assert_eq!(ids.len(), 2, "expected both queue calls to return an id: {first}");
    assert_eq!(ids[0], ids[1], "replaying one Matrix event made a second mail envelope");
    let envelope = std::fs::read_to_string(root.join(format!("messages/{}.json", ids[0])))
        .expect("persisted Matrix mail envelope");
    assert!(envelope.contains(r#""sender":"@alice:example.org""#), "{envelope}");
    assert!(envelope.contains(r#""room_id":"!inbound:example.org""#), "{envelope}");
    assert!(envelope.contains(r#""event_id":"$matrix-event""#), "{envelope}");
    assert!(envelope.contains(r#""created_at":"2026-09-28T01:02:03Z""#), "{envelope}");
    drop(daemon);

    let _restarted = Daemon::spawn(&dir);
    let after_restart = eval(
        &path,
        &format!(
            r#"{}
               local from = {{ host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }}
               return assert(M.queue(from, F, "hello from Matrix", nil, nil, nil, {matrix})).id"#,
            reply_prelude(&root)
        ),
    );
    assert_eq!(after_restart, ids[0], "a restarted mail store did not deduplicate the Matrix event");
}

#[test]
fn matrix_mail_truncates_oversized_bodies_with_a_byte_count() {
    let dir = scratch_dir("matrix-mail-body-cap");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let _daemon = Daemon::spawn(&dir);
    let path = daemon::socket_path_in(&dir, "s");
    let result = eval(
        &path,
        &format!(
            r#"{}
               local from = {{ host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }}
               local msg = assert(M.queue(from, F, string.rep("a", 65536 + 100), nil, nil, nil,
                 {{ sender = "@alice:example.org", room_id = "!room:example.org", event_id = "$large" }}))
               local body = remuda._butler_mail_config.bus.objects[msg.body.object_id].content
               return tostring(#body) .. "|" .. (body:match("%[truncated %d+ bytes%]$") or "missing")
            "#,
            reply_prelude(&root),
        ),
    );
    assert_eq!(result, "65536|[truncated 121 bytes]");
}

#[test]
#[cfg(unix)]
fn butler_initializes_mail_and_persists_a_sent_message() {
    let dir = scratch_dir("butler-mail-init");
    let data_home = dir.join("data");
    // A private data home still needs the installed mod (tests/rust_tests.sh).
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let (token_path, config_path) = butler_config(
        &dir,
        "mail-init",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token = token_path.to_string_lossy().to_string();
    let config = config_path.to_string_lossy().to_string();
    let data = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token.as_str()),
            ("REMUDA_BUTLER_CONFIG", config.as_str()),
            ("XDG_DATA_HOME", data.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"
          remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}
          remuda._butler_skip_relay = true
        "#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let sent = eval(
        &path,
        r#"return remuda._butler_send("butler", "butler", "private body")"#,
    );
    let queued_id = sent
        .strip_prefix("queued ")
        .and_then(|s| s.split_whitespace().next())
        .unwrap_or("");
    assert!(
        queued_id.len() == 26
            && queued_id
                .bytes()
                .all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(&b)),
        "{sent:?}"
    );
    assert!(
        sent.contains("notice deferred") || sent.ends_with(" and notified butler"),
        "{sent:?}"
    );
    let mail = data_home.join("remuda/butler/mail");
    let objects: Vec<_> = std::fs::read_dir(mail.join("objects"))
        .expect("body objects")
        .collect::<Result<_, _>>()
        .expect("read body objects");
    assert_eq!(objects.len(), 1);
    assert_eq!(
        std::fs::read_to_string(objects[0].path()).expect("body object"),
        "private body"
    );
    let envelopes: Vec<_> = std::fs::read_dir(mail.join("messages"))
        .expect("message envelopes")
        .collect::<Result<_, _>>()
        .expect("read message envelopes");
    assert_eq!(envelopes.len(), 1);
    let envelope = std::fs::read_to_string(envelopes[0].path()).expect("message envelope");
    assert!(envelope.contains("\"body\":{\"object_id\":\"object-"));
    // Inboxes are keyed by the recipient's Butler ULID (b900a22), not its alias.
    let inboxes = std::fs::read_dir(mail.join("inboxes")).expect("inboxes");
    assert_eq!(inboxes.filter(|e| e.is_ok()).count(), 1);
    drop(daemon);
}

/// Same live-`claude` limitation as the test above blocks a real kill-and-
/// watch-it-come-back test for the respawn watchdog. This checks, at the
/// source level, that the lifecycle-owned watchdog reuses one launch
/// function (so a respawn can't drift from a fresh start).
#[test]
fn butler_session_exited_hook_relaunches_via_the_shared_launch_function() {
    // Normalized once: a `\n`-only search below would miss a real call on a
    // checkout where git converts this file to CRLF (Windows runners do).
    let main_lua = include_str!("../../packages/butler/main.lua").replace("\r\n", "\n");
    let init_lua = include_str!("../../packages/butler/init.lua").replace("\r\n", "\n");
    let matrix_init = include_str!("../../packages/butler/init.lua").replace("\r\n", "\n");
    let matrix_impl = include_str!("../../packages/butler/matrix.lua").replace("\r\n", "\n");
    let matrix_stop_start = matrix_impl
        .find("function remuda._butler_matrix_stop()")
        .expect("Matrix package lost its lifecycle stop function");
    let matrix_stop_end = matrix_impl[matrix_stop_start..]
        .find("\nlocal function matrix_trace")
        .map(|offset| matrix_stop_start + offset)
        .expect("Matrix package lifecycle stop function is unterminated");
    let matrix_stop = &matrix_impl[matrix_stop_start..matrix_stop_end];

    let launch_fn_idx = main_lua
        .find("local function launch_butler()")
        .expect("butler package lost its shared launch function");
    assert!(
        !main_lua.contains("remuda.clear_hooks(") && !main_lua.contains("remuda.hooks[event]"),
        "Butler reload must rely on lifecycle ownership, not hook purges"
    );
    assert!(
        init_lua.contains("stop = function(state)")
            && init_lua.contains("pcall(host.kill, relay)")
            && matrix_init.contains("stop = function(state)")
            && matrix_init.contains("host._butler_matrix_stop")
            && matrix_stop.contains("for _, id in ipairs(remuda.processes()) do")
            && matrix_stop.contains(
                "if id == remuda._butler_matrix_relay or id == remuda._butler_relay then"
            )
            && matrix_stop.contains("pcall(remuda.kill, id)")
            && !main_lua.contains("pkill -f"),
        "the Matrix relay must be stopped by process id through the lifecycle stop hook"
    );
    assert!(
        init_lua.contains("event = \"session_exited\", id = \"identity\"")
            && main_lua.contains("function remuda._butler_session_exited(name, info)")
            && main_lua[launch_fn_idx..].contains("remuda._butler_reconcile()"),
        "the declared session-exit hook must use the shared reconciler"
    );
    assert!(
        init_lua.contains("name = \"butler-reconcile\"")
            && init_lua.contains("host._butler_reconcile then host._butler_reconcile()"),
        "butler needs a periodic reconciler as well as an exit event hook"
    );
}

/// The watchdog end to end, proven by a real effect rather than a call
/// record. `_butler_test_mode` is never set here -- this is the first test
/// in this file to run the real `launch_butler`/`session_exited` code past
/// `init.lua`'s test-mode early return (the source-level substitutes are the
/// two tests just above this one). `remuda._butler_argv` stands in for a
/// real `claude` with a short-but-real self-exiting process, and
/// `remuda._butler_skip_relay` keeps the forever-retrying Matrix relay (see
/// `HELPER_SRC`'s `while True`) from ever spawning against these dummy
/// credentials -- see the teardown assertion at the end of this test for why
/// that belief alone is not trusted.
#[test]
#[cfg(unix)]
fn butler_watchdog_relaunches_a_session_that_really_died() {
    let dir = scratch_dir("butler-watchdog");
    let (token_path, config_path) = butler_config(
        &dir,
        "watchdog",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    // Keep the observer outside Butler's lifecycle-owned registrations.
    eval(
        &path,
        r#"
            remuda._watchdog_exits = {}
            remuda.on("session_exited", function(name)
                table.insert(remuda._watchdog_exits, name)
            end, { group = "test-observer" })
        "#,
    );
    // A real, short-but-nonzero-lived self-exiting process standing in for
    // `claude` -- 0.3s per life is long enough that two full lives can't
    // complete in near-zero time, which is what the latency-floor assertion
    // below turns into a real check rather than a comment's promise.
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let initial_name = eval(&path, "return remuda._butler_initial_name");

    let start = Instant::now();
    let deadline = start + PATIENCE;
    loop {
        let seen = eval(&path, "return table.concat(remuda._watchdog_exits, ',')");
        let count = seen.split(',').filter(|n| *n == initial_name).count();
        if count >= 2 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "expected at least 2 session_exited events for {initial_name:?}, saw: {seen:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let elapsed = start.elapsed();
    // A name can only exit twice if a genuinely new process was registered
    // under it between the two deaths: `Registry::register` refuses a name
    // still in use, and only `remove`/`close` clear that entry (see
    // core/src/registry.rs) -- so 2 real `session_exited` events for one
    // name is direct evidence `launch_butler()` itself ran and spawned a
    // fresh process, not merely that the callback fired. Two full lives at
    // 0.3s each, plus at least one reap cycle, cannot land here in
    // near-zero time; a value that small would mean the exit/relaunch never
    // actually happened.
    assert!(
        elapsed >= Duration::from_millis(400),
        "two real respawn cycles took only {elapsed:?} -- implausibly fast for two \
         `sleep 0.3` lives, suggesting the observation was short-circuited"
    );

    // Teardown is verified by the resource, not the belief that
    // `_butler_skip_relay` prevented anything: kill the daemon, then prove
    // via a real `ps` snapshot that nothing survives referencing this
    // test's own (unique per invocation) token path. If the relay guard
    // ever failed silently, its forever-retrying `while True` loop (see
    // `HELPER_SRC`) would still be running right here -- nothing in this
    // codebase reaps a `remuda.process{}` child when the daemon dies
    // (`native/src/process.rs` spawns a plain `std::process::Command`, no
    // process group).
    drop(daemon);
    let ps = std::process::Command::new("ps")
        .args(["-eo", "pid,args"])
        .output()
        .expect("ps");
    let ps_out = String::from_utf8_lossy(&ps.stdout);
    let leaked: Vec<&str> = ps_out.lines().filter(|l| l.contains(&token_str)).collect();
    assert!(
        leaked.is_empty(),
        "orphan process(es) still reference this test's own token path after teardown: {leaked:?}"
    );
}

/// The lifecycle declaration owns one compaction schedule; the session's
/// run_script call only enables it. Repeating that request must not register
/// another schedule.
#[test]
#[cfg(unix)]
fn butler_compaction_schedule_registration_is_idempotent() {
    let dir = scratch_dir("butler-compaction-idem");
    let (token_path, config_path) = butler_config(
        &dir,
        "compaction-idem",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!("remuda._butler_compaction_trace_path = {}", lua_raw_string(&trace_path.to_string_lossy())));

    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 5; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    // Two separate Eval requests, exactly like two separate `run_script`
    // calls would arrive -- a plain Lua local inside init.lua would not even
    // be reachable a second time this way, which is the whole reason the
    // handle lives on `remuda` itself.
    eval(&path, "remuda._butler_register_compaction_schedule()");
    eval(&path, "remuda._butler_register_compaction_schedule()");

    let live = read_count(
        &path,
        r#"
            local n = 0
            for _, s in pairs(remuda.schedules) do
                if s.name == "butler-compaction" then n = n + 1 end
            end
            return n
        "#,
    );
    assert_eq!(
        live, 1,
        "two calls to remuda._butler_register_compaction_schedule() left {live} live \
         \"butler-compaction\" schedules -- expected the one lifecycle schedule"
    );

    drop(daemon);
    let ps = std::process::Command::new("ps")
        .args(["-eo", "pid,args"])
        .output()
        .expect("ps");
    let ps_out = String::from_utf8_lossy(&ps.stdout);
    let leaked: Vec<&str> = ps_out.lines().filter(|l| l.contains(&token_str)).collect();
    assert!(
        leaked.is_empty(),
        "orphan process(es) still reference this test's own token path after teardown: {leaked:?}"
    );
}

/// The schedule end to end, on a real spawned `sh` standing in for a
/// Codex-style member that does not switch models -- the same substitution
/// `butler_watchdog_relaunches_a_session_that_really_died` uses. Split into
/// two phases against ONE session's one life: busy (kept below the 2s idle
/// threshold `Session::idle_for`/`Session.is_busy` read, by repeatedly
/// sending a bare Enter -- the same proven-harmless no-op the Matrix relay's
/// own submit hook already relies on) must never show `/compact`; idle
/// (input stops) must eventually show it, typed and echoed by the pty the
/// moment `remuda.send` writes it. `remuda._butler_compaction_interval` is
/// set tiny, but the daemon's own tick (`native/src/daemon.rs::TICK_PERIOD`,
/// 1s) is the real firing granularity -- so a "tiny" interval only means
/// "fires every tick", not sub-second.
#[test]
#[cfg(unix)]
fn butler_compaction_schedule_sends_compact_when_idle_but_not_when_busy() {
    let dir = scratch_dir("butler-compaction-fire");
    let (token_path, config_path) = butler_config(
        &dir,
        "compaction-fire",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_str = std::env::var("XDG_DATA_HOME").expect("test XDG_DATA_HOME");
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!("remuda._butler_compaction_trace_path = {}", lua_raw_string(&trace_path.to_string_lossy())));

    eval(&path, "remuda._butler_compaction_interval = 0.05");
    eval(&path, r#"remuda._butler_argv = {"sh"}"#);
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    assert_eq!(
        eval(&path, "return type(remuda._butler_compaction_tick)"),
        "function",
        "loading the Butler module must define the scheduled compaction tick"
    );

    let butler_name = eval(&path, "return remuda._butler_initial_name");
    eval(
        &path,
        &format!("remuda._butler_bus.agents[{butler_name:?}].kind = 'codex'"),
    );
    eval(&path, FAKE_COMPACTION_EXPECT);
    eval(
        &path,
        r#"remuda._butler_telemetry_for = function() return { context_used = "600000" } end"#,
    );
    assert_eq!(
        eval(
            &path,
            &format!("return remuda.butler.ctx_level({butler_name:?}).level"),
        ),
        "warn",
        "the Codex fixture must cross the warn-level compaction threshold"
    );

    // Simulates the launched session's own one-time `run_script` call the
    // system prompt asks for.
    eval(&path, "remuda._butler_register_compaction_schedule()");
    assert_eq!(
        read_count(
            &path,
            r#"local n = 0 for _, s in pairs(remuda.schedules) do
              if s.name == "butler-compaction" then n = n + 1 end
            end return n"#,
        ),
        1,
        "run_script must enable the lifecycle-declared compaction schedule"
    );
    let fires_before_idle = read_count(
        &path,
        r#"return remuda.schedule_fires()["butler-compaction"] or 0"#,
    );

    // Busy phase: outrun the 2s idle threshold for a few seconds, spanning
    // at least two real 1s daemon ticks, and confirm the guard actually
    // holds the send back.
    let busy_until = Instant::now() + Duration::from_millis(2500);
    while Instant::now() < busy_until {
        eval(&path, &format!("remuda.send({butler_name:?}, \"\")"));
        std::thread::sleep(Duration::from_millis(300));
    }
    let screen_while_busy = capture(&path, &butler_name);
    assert!(
        !screen_while_busy.contains("/compact"),
        "compaction fired while the session was kept busy:\n{screen_while_busy}"
    );

    // Idle phase: stop feeding input and wait for the next tick to see the
    // guard flip and /compact actually get typed (echoed immediately by the
    // pty, no need to wait for the delayed Enter confirm).
    let deadline = Instant::now() + PATIENCE;
    loop {
        let screen = capture(&path, &butler_name);
        if screen.contains("/compact") {
            let fires = read_count(
                &path,
                r#"return remuda.schedule_fires()["butler-compaction"] or 0"#,
            );
            assert!(
                fires > fires_before_idle,
                "the lifecycle compaction schedule did not fire after registration"
            );
            break;
        }
        assert!(
            Instant::now() < deadline,
            "compaction never fired once the session went idle. last screen:\n{screen}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    drop(daemon);
    let ps = std::process::Command::new("ps")
        .args(["-eo", "pid,args"])
        .output()
        .expect("ps");
    let ps_out = String::from_utf8_lossy(&ps.stdout);
    let leaked: Vec<&str> = ps_out.lines().filter(|l| l.contains(&token_str)).collect();
    assert!(
        leaked.is_empty(),
        "orphan process(es) still reference this test's own token path after teardown: {leaked:?}"
    );
}

/// Minimal shape check for `os.date("!%Y-%m-%dT%H:%M:%SZ")` -- exactly what
/// `_butler_trace` in `packages/butler/init.lua` writes -- without pulling a
/// date-parsing crate into this test binary for one field.
fn looks_like_iso8601_utc(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 20
        && b[4] == b'-'
        && b[7] == b'-'
        && b[10] == b'T'
        && b[13] == b':'
        && b[16] == b':'
        && b[19] == b'Z'
        && s[0..4].bytes().all(|c| c.is_ascii_digit())
        && s[5..7].bytes().all(|c| c.is_ascii_digit())
        && s[8..10].bytes().all(|c| c.is_ascii_digit())
        && s[11..13].bytes().all(|c| c.is_ascii_digit())
        && s[14..16].bytes().all(|c| c.is_ascii_digit())
        && s[17..19].bytes().all(|c| c.is_ascii_digit())
}

/// The screen-based witness just above (`..._sends_compact_when_idle...`)
/// proves the *effect* fired, but nothing about it survives past that pty --
/// gone the moment the session closes, and gone entirely across a daemon
/// restart, which is exactly the gap `_butler_trace` closes. Same busy/idle
/// two-phase control as that test, but the witness here is the trace FILE's
/// real bytes read back from disk, proving what a human opening this file on
/// some later day, with no session left to look at, would actually see.
#[test]
#[cfg(unix)]
fn butler_compaction_trace_records_registered_skipped_and_sent() {
    let dir = scratch_dir("butler-compaction-trace");
    let (token_path, config_path) = butler_config(
        &dir,
        "compaction-trace",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    // This test's own tempdir, never the real `~/.config/remuda/`.
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, "remuda._butler_compaction_interval = 0.05");
    eval(
        &path,
        &format!(
            "remuda._butler_compaction_trace_path = {}",
            lua_raw_string(&trace_path.to_string_lossy())
        ),
    );
    eval(&path, r#"remuda._butler_argv = {"sh"}"#);
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let butler_name = eval(&path, "return remuda._butler_initial_name");
    eval(&path, FAKE_COMPACTION_EXPECT);

    // Simulates the launched session's own one-time `run_script` call the
    // system prompt asks for -- this alone must already leave a "registered"
    // line, before any tick has had a chance to run.
    eval(&path, "remuda._butler_register_compaction_schedule()");
    let registered = std::fs::read_to_string(&trace_path).unwrap_or_default();
    assert!(
        registered.contains("\tregistered\t"),
        "no \"registered\" trace line after registration:\n{registered}"
    );

    // Busy phase, same as the sibling screen-based test: outrun the 2s idle
    // threshold for a few seconds, spanning several real 1s daemon ticks,
    // and prove the guard actually left a "skipped_busy" line for it — not
    // just that /compact was withheld.
    let busy_until = Instant::now() + Duration::from_millis(2500);
    while Instant::now() < busy_until {
        eval(&path, &format!("remuda.send({butler_name:?}, \"\")"));
        std::thread::sleep(Duration::from_millis(300));
    }
    let while_busy = std::fs::read_to_string(&trace_path).unwrap_or_default();
    assert!(
        while_busy.contains("\tskipped_busy\t"),
        "no \"skipped_busy\" trace line recorded during the busy phase:\n{while_busy}"
    );
    assert!(
        !while_busy.contains("\tsent\t"),
        "a \"sent\" trace line appeared while the session was kept busy:\n{while_busy}"
    );

    // Idle phase: stop feeding input and wait for the next tick to record a
    // real "sent" line.
    let deadline = Instant::now() + PATIENCE;
    loop {
        let content = std::fs::read_to_string(&trace_path).unwrap_or_default();
        if content.contains("\tsent\t") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "no \"sent\" trace line ever appeared once the session went idle:\n{content}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Witness discipline: read the ACTUAL bytes back from disk and validate
    // every line's shape, not just substring presence.
    let content = std::fs::read_to_string(&trace_path).expect("read trace file");
    let lines: Vec<&str> = content.lines().collect();
    assert!(!lines.is_empty(), "trace file was empty");
    for line in &lines {
        let fields: Vec<&str> = line.split('\t').collect();
        assert_eq!(
            fields.len(),
            3,
            "line {line:?} does not have exactly 3 tab-separated fields"
        );
        assert!(
            looks_like_iso8601_utc(fields[0]),
            "first field {:?} is not a parseable ISO-8601 UTC timestamp in line {line:?}",
            fields[0]
        );
    }

    drop(daemon);
    let ps = std::process::Command::new("ps")
        .args(["-eo", "pid,args"])
        .output()
        .expect("ps");
    let ps_out = String::from_utf8_lossy(&ps.stdout);
    let leaked: Vec<&str> = ps_out.lines().filter(|l| l.contains(&token_str)).collect();
    assert!(
        leaked.is_empty(),
        "orphan process(es) still reference this test's own token path after teardown: {leaked:?}"
    );
}

/// Exercise the Claude compaction state machine with real private daemon PTYs.
/// The fake Claude process prints a statusline, presents numbered model dialogs,
/// consumes the key, and changes model/context exactly as Claude does.
#[test]
#[cfg(unix)]
fn butler_compaction_fake_claude_scenarios_send_only_visible_keys() {
    let dir = scratch_dir("butler-fake-claude");
    let (token_path, config_path) = butler_config(
        &dir,
        "fake-claude",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_str = std::env::var("XDG_DATA_HOME").expect("test XDG_DATA_HOME");
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(
        eval(&path, "return type(remuda._butler_compaction_tick)"),
        "function",
        "loading the Butler module must define the scheduled compaction tick"
    );
    eval(&path, "remuda._butler_compaction_interval = 45");
    let trace_path = dir.join("compaction-trace.log");
    eval(
        &path,
        &format!(
            "remuda._butler_compaction_trace_path = {}",
            lua_raw_string(&trace_path.to_string_lossy())
        ),
    );

    let script = dir.join("fake-claude.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
model='Opus 4.7 (1M context)'
ctx=500000
first=1
if [ "$scenario" = absent ]; then model=Sonnet; fi
paint() { printf '\033[H\033[2JMODEL:%s CTX:%s\n' "$model" "$ctx"; }
paint
while IFS= read -r line; do
  printf 'CMD:%s\n' "$line" >> "$log"
  case "$line" in
    '/model sonnet')
      if [ "$scenario" = timeout ]; then continue; fi
      if [ "$scenario" = switch-label-unknown ] && [ "$first" = 1 ]; then
        first=0; model=Sonnet; paint
        printf 'Switch model?\n1. Apply using an unknown label\n2. Cancel\n'
        IFS= read -r -n 1 answer || exit 0
        printf 'KEY:%s\n' "$answer" >> "$log"
        paint; continue
      fi
      if [ "$scenario" = unknown ] && [ "$first" = 1 ]; then
        first=0; model=Sonnet; paint; printf 'Mystery chooser\n1. Continue\n❯\n'
        IFS= read -r -n 1 answer || exit 0
        printf 'KEY:%s\n' "$answer" >> "$log"
        paint; continue
      fi
      if [ "$model" = Sonnet ]; then paint; continue; fi
      if [ "$scenario" = option2 ]; then
        printf 'Switch model?\n1. No\n❯ 2. Yes, switch to Sonnet\n'
      else
        printf 'Switch model?\n❯ 1. Yes, switch to Sonnet\n2. No\n'
      fi
      IFS= read -r -n 1 answer || exit 0
      printf 'KEY:%s\n' "$answer" >> "$log"
      case "$answer" in 1|2) model=Sonnet ;; esac
      paint
      ;;
    '/model opus')
      if [ "$scenario" = restore-timeout ]; then continue; fi
      printf 'Switch model?\n❯ 1. Yes, switch to Opus\n2. No\n'
      IFS= read -r -n 1 answer || exit 0
      printf 'KEY:%s\n' "$answer" >> "$log"
      case "$answer" in 1|2) model='Opus 4.7 (1M context)' ;; esac
      paint
      ;;
    '/model Sonnet') paint ;;
    '/compact') ctx=200000; paint ;;
  esac
done
"#,
    )
    .expect("write fake Claude");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    eval(
        &path,
        &format!(
            r#"
      remuda._butler_compaction_model = "sonnet"
      remuda._butler_compaction_config = {{dialog_timeout=1, completion_timeout=2, verification_timeout=2, input_settle=0.01}}
      remuda._butler_bus = remuda._butler_bus or {{agents={{}}, pending_tasks={{}}, notices={{}}}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="claude", entry={{working=function(_, _) return false end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function() return "EMPTY" end
      remuda._butler_send = function(_, _, message)
        remuda._fake_compaction_reports = remuda._fake_compaction_reports or {{}}
        table.insert(remuda._fake_compaction_reports, message)
      end
      local original_session = remuda.session
      remuda._fake_attached = {{}}
      remuda._fake_busy_after_key = {{}}
      remuda._fake_busy_until = {{}}
      remuda._fake_attach_on_ctx_drop = {{}}
      remuda._fake_no_family = {{}}
      remuda._fake_wrong_restored_window = {{}}
      remuda.session = function(name)
        return {{is_busy=remuda._fake_busy_until[name] and os.time() < remuda._fake_busy_until[name] or false,
          attached=remuda._fake_attached[name] == true}}
      end
      local original_key = remuda.key
      remuda.key = function(name, key)
        original_key(name, key)
        if remuda._fake_busy_after_key[name] then
          remuda._fake_busy_after_key[name] = nil
          remuda._fake_busy_until[name] = os.time() + 2
        end
        if remuda._fake_attach_after_first_key == name then
          local deadline = os.time() + 3
          repeat
            if remuda.capture(name):find("MODEL:Sonnet", 1, true) then break end
            remuda.sleep(0.05)
          until os.time() >= deadline
          remuda._fake_attached[name] = true
          remuda._fake_attach_after_first_key = nil
        end
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        local sonnet = screen:find("MODEL:Sonnet", 1, true) ~= nil
        local used = screen:match("CTX:%s*(%d+)")
        if remuda._fake_attach_on_ctx_drop[agent.session_name] and used == "200000" then
          remuda._fake_attached[agent.session_name] = true
          remuda._fake_attach_on_ctx_drop[agent.session_name] = nil
        end
        return {{context_used=used,
          context_window=(not sonnet and used == "200000"
              and remuda._fake_wrong_restored_window[agent.session_name])
            and "200000" or (sonnet and "200000" or "1000000"),
          model=remuda._fake_no_family[agent.session_name] and "Experimental-Model"
            or (sonnet and "Sonnet-4.5" or "Opus-4.7-1M-context")}}
      end
      remuda._fake_setup_compaction = function(name, kind, log, scenario)
        remuda.new(name, {{"bash", {script:?}, log, scenario}}, nil, {{}})
        remuda._butler_bus.agents[name] = {{id=name, kind=kind, session_name=name}}
      end
    "#
        ),
    );

    for (name, scenario, expected) in [
        (
            "fake-happy",
            "happy",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\nCMD:/model opus\nKEY:1\n",
        ),
        (
            "fake-absent",
            "absent",
            "CMD:/model sonnet\nCMD:/compact\n",
        ),
        (
            "fake-option2",
            "option2",
            "CMD:/model sonnet\nKEY:2\nCMD:/compact\nCMD:/model opus\nKEY:1\n",
        ),
        (
            "fake-busy-after-switch",
            "happy",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\nCMD:/model opus\nKEY:1\n",
        ),
        (
            "fake-unknown",
            "unknown",
            "CMD:/model sonnet\nKEY:\x1b\nCMD:/model opus\nKEY:1\n",
        ),
        (
            "fake-switch-label-unknown",
            "switch-label-unknown",
            "CMD:/model sonnet\nKEY:\x1b\nCMD:/model opus\nKEY:1\n",
        ),
        ("fake-timeout", "timeout", "CMD:/model sonnet\n"),
        (
            "fake-restore-timeout",
            "restore-timeout",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\nCMD:/model opus\nCMD:/model opus\n",
        ),
        (
            "fake-attached",
            "happy",
            "CMD:/model sonnet\nKEY:1\n",
        ),
        (
            "fake-attach-mid",
            "happy",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\nCMD:/model opus\nKEY:1\n",
        ),
        (
            "fake-no-family",
            "happy",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\n",
        ),
        (
            "fake-window-mismatch",
            "happy",
            "CMD:/model sonnet\nKEY:1\nCMD:/compact\nCMD:/model opus\nKEY:1\n",
        ),
    ] {
        let log = dir.join(format!("{name}.log"));
        eval(
            &path,
            &format!("remuda._fake_setup_compaction({name:?}, 'claude', {log:?}, {scenario:?})"),
        );
        wait_for(&path, name, "MODEL:");
        if name == "fake-attached" {
            eval(
                &path,
                &format!("remuda._fake_attach_after_first_key = {name:?}"),
            );
        }
        if name == "fake-busy-after-switch" {
            eval(
                &path,
                &format!("remuda._fake_busy_after_key[{name:?}] = true"),
            );
        }
        if name == "fake-attach-mid" {
            eval(&path, &format!("remuda._fake_attach_on_ctx_drop[{name:?}] = true"));
        }
        if name == "fake-no-family" {
            eval(&path, &format!("remuda._fake_no_family[{name:?}] = true"));
        }
        if name == "fake-window-mismatch" {
            eval(&path, &format!("remuda._fake_wrong_restored_window[{name:?}] = true"));
        }
        eval(
            &path,
            &format!("remuda.butler.compact({name:?})"),
        );
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut attach_retry_started = false;
        loop {
            let in_progress = eval(&path, &format!(
                "return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"
            ));
            let log_text = std::fs::read_to_string(&log).unwrap_or_default();
            if name == "fake-attach-mid" && !attach_retry_started
                && in_progress == "false"
                && log_text == "CMD:/model sonnet\nKEY:1\nCMD:/compact\n"
            {
                assert_eq!(
                    eval(&path, &format!("return tostring(remuda._fake_attached[{name:?}])")),
                    "true",
                    "human should attach after compact completes"
                );
                assert_eq!(
                    eval(&path, &format!("return remuda._butler_compaction_members_state[{name:?}].pending_restore_model")),
                    "opus",
                    "mid-compaction attach must preserve the pending family"
                );
                eval(&path, &format!("remuda._butler_compaction_tick({name:?}, false)"));
                std::thread::sleep(Duration::from_millis(250));
                assert_eq!(std::fs::read_to_string(&log).unwrap(), log_text,
                    "restore must send no command or key while attached");
                eval(&path, &format!("remuda._fake_attached[{name:?}] = false"));
                eval(&path, &format!("remuda._butler_compaction_tick({name:?}, false)"));
                attach_retry_started = true;
                continue;
            }
            if in_progress == "false" && log_text == expected {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "fake scenario {scenario} stalled; log={log_text:?}"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        let got = std::fs::read_to_string(&log).unwrap_or_default();
        assert_eq!(got, expected, "unexpected commands/keys for {scenario}");
        assert!(!got.contains("CMD:/model Opus"), "must not send a display tag: {got:?}");
        assert!(!got.contains("CMD:/model claude-opus"), "must not send a raw model id: {got:?}");
        if scenario == "unknown" || scenario == "switch-label-unknown" || scenario == "timeout" || scenario == "restore-timeout"
            || name == "fake-attached"
        {
            let reports = eval(
                &path,
                "return table.concat(remuda._fake_compaction_reports or {}, '\\n')",
            );
            let marker = match scenario {
                "unknown" => "unrecognized dialog",
                "switch-label-unknown" => "no unique yes/switch option",
                "timeout" => "first model dialog timed out",
                "restore-timeout" => "restore attempts exhausted",
                _ => "aborted: human attached",
            };
            assert!(
                reports.contains(marker),
                "expected report {marker:?}, got {reports:?}"
            );
        }
        if scenario == "restore-timeout" {
            assert_eq!(
                eval(
                    &path,
                    &format!("return remuda._butler_compaction_members_state[{name:?}].pending_restore_model"),
                ),
                "opus",
                "failed restore must retain the original model family for the next policy attempt"
            );
            assert!(
                eval(
                    &path,
                    &format!("return remuda._butler_compaction_members_state[{name:?}].cooldown_ticks >= 12"),
                ) == "true",
                "failed compaction must set a retry backoff"
            );
        }
        if name == "fake-attach-mid" {
            let got = std::fs::read_to_string(&log).unwrap();
            assert_eq!(got.matches("CMD:/model opus\n").count(), 1,
                "detaching should retry the pending restore exactly once: {got:?}");
            assert_eq!(
                eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].pending_restore_model == nil)")),
                "true",
                "confirmed restore should clear pending state"
            );
        }
        if name == "fake-no-family" {
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            let message = "compaction left Experimental-Model on Sonnet; restore needs a known model family";
            assert_eq!(reports.matches(message).count(), 1, "expected one missing-family notice: {reports:?}");
            assert_eq!(
                eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].pending_restore_model_unavailable)")),
                "true",
                "unknown-family restore state must remain visible"
            );
        }
        if name == "fake-window-mismatch" {
            let before = std::fs::read_to_string(&log).unwrap();
            eval(&path, &format!("remuda._butler_compaction_tick({name:?}, false)"));
            std::thread::sleep(Duration::from_millis(250));
            assert_eq!(std::fs::read_to_string(&log).unwrap(), before,
                "a context-window mismatch must not retry the restore");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert_eq!(reports.matches("compaction restore mismatch").count(), 1,
                "expected one context-window mismatch notice: {reports:?}");
        }
    }
    drop(daemon);
}

/// Same real-process substitution as
/// `butler_watchdog_relaunches_a_session_that_really_died`, but the witness
/// here is the trace FILE `_butler_session_trace` in `packages/butler/init.lua`
/// writes from the `session_exited` hook, not the in-memory
/// `remuda._watchdog_exits` list -- proving the watchdog's own trace records
/// both the exit and the relaunch it triggers, not just that they happened.
#[test]
#[cfg(unix)]
fn butler_watchdog_records_session_exit_and_relaunch_in_a_trace_file() {
    let dir = scratch_dir("butler-watchdog-trace");
    let (token_path, config_path) = butler_config(
        &dir,
        "watchdog-trace",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    // This test's own tempdir, never the real `~/.config/remuda/`.
    let trace_path = dir.join("session-trace.log");
    eval(
        &path,
        &format!(
            "remuda._butler_session_trace_path = {}",
            lua_raw_string(&trace_path.to_string_lossy())
        ),
    );
    // Same observer group as `butler_watchdog_relaunches_a_session_that_really_died`
    // -- `init.lua` clears the "butler" group on every `exec`, so a hook
    // registered there would not survive it.
    eval(
        &path,
        r#"
            remuda._watchdog_exits = {}
            remuda.on("session_exited", function(name)
                table.insert(remuda._watchdog_exits, name)
            end, { group = "test-observer" })
        "#,
    );
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let initial_name = eval(&path, "return remuda._butler_initial_name");

    let deadline = Instant::now() + PATIENCE;
    loop {
        let seen = eval(&path, "return table.concat(remuda._watchdog_exits, ',')");
        let count = seen.split(',').filter(|n| *n == initial_name).count();
        if count >= 2 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "expected at least 2 session_exited events for {initial_name:?}, saw: {seen:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Witness discipline: read the ACTUAL bytes back from disk, same as
    // `butler_compaction_trace_records_registered_skipped_and_sent`.
    let content = std::fs::read_to_string(&trace_path).expect("read trace file");
    let lines: Vec<Vec<&str>> = content.lines().map(|l| l.split('\t').collect()).collect();
    assert!(!lines.is_empty(), "trace file was empty");
    for fields in &lines {
        assert_eq!(fields.len(), 3, "not 3 tab-separated fields: {fields:?}");
        assert!(
            looks_like_iso8601_utc(fields[0]),
            "not a parseable ISO-8601 UTC timestamp: {fields:?}"
        );
    }
    assert!(
        lines
            .iter()
            .any(|f| f[1] == "session_exited" && f[2] == initial_name),
        "no \"session_exited\" trace line for {initial_name:?}:\n{content}"
    );
    assert!(
        lines
            .iter()
            .any(|f| f[1] == "relaunching" && f[2] == initial_name),
        "no \"relaunching\" trace line for {initial_name:?}:\n{content}"
    );

    drop(daemon);
    let ps = std::process::Command::new("ps")
        .args(["-eo", "pid,args"])
        .output()
        .expect("ps");
    let ps_out = String::from_utf8_lossy(&ps.stdout);
    let leaked: Vec<&str> = ps_out.lines().filter(|l| l.contains(&token_str)).collect();
    assert!(
        leaked.is_empty(),
        "orphan process(es) still reference this test's own token path after teardown: {leaked:?}"
    );
}

/// Sibling of `butler_watchdog_records_session_exit_and_relaunch_in_a_trace_file`,
/// but proving the DEFAULT-fallback branch itself: `remuda._butler_session_trace_path`
/// is never set here, so this only passes if `_butler_session_trace` in
/// `packages/butler/init.lua` actually falls back to
/// `$HOME/.config/remuda/session-trace.log`, the same default-path idiom
/// `_butler_trace` (compaction) already uses. Same `Daemon::spawn_with_home`
/// HOME-redirection precedent as
/// `butler_exec_finds_credentials_at_the_conventional_path_with_zero_env_vars`,
/// so this never touches a real machine's real `~/.config/remuda/`.
#[test]
#[cfg(unix)]
fn butler_session_trace_defaults_to_the_conventional_path_with_no_seam_set() {
    // Keep the Unix socket path below macOS's short sockaddr_un limit.
    let dir = scratch_dir("butler-trace-def");
    let home = dir.join("home");
    let butler_dir = home.join(".config/remuda/butler");
    std::fs::create_dir_all(&butler_dir).expect("mkdir conventional butler dir");
    std::fs::write(butler_dir.join("token"), "test-token\n").expect("write token");
    std::fs::write(
        butler_dir.join("config"),
        "http://127.0.0.1:1\n!room:example.org\n@butler:example.org\n\n",
    )
    .expect("write config");

    // Negative control: the default-derived trace file must not exist before
    // any session close is ever triggered.
    let trace_path = home.join(".config/remuda/session-trace.log");
    assert!(
        !trace_path.exists(),
        "default session trace file already exists before any session closed: {trace_path:?}"
    );

    // `remuda._butler_session_trace_path` is deliberately left unset here --
    // exercising the real default-fallback branch, not the test seam
    // `butler_watchdog_records_session_exit_and_relaunch_in_a_trace_file`
    // already covers.
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");

    // Same observer group as the sibling watchdog trace test -- `init.lua`
    // clears the "butler" group on every `exec`, so a hook registered there
    // would not survive it.
    eval(
        &path,
        r#"
            remuda._watchdog_exits = {}
            remuda.on("session_exited", function(name)
                table.insert(remuda._watchdog_exits, name)
            end, { group = "test-observer" })
        "#,
    );
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let initial_name = eval(&path, "return remuda._butler_initial_name");

    let deadline = Instant::now() + PATIENCE;
    loop {
        let seen = eval(&path, "return table.concat(remuda._watchdog_exits, ',')");
        let count = seen.split(',').filter(|n| *n == initial_name).count();
        if count >= 2 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "expected at least 2 session_exited events for {initial_name:?}, saw: {seen:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Witness discipline: read the ACTUAL bytes back from disk, from the
    // DEFAULT-derived path, never a seam-supplied one.
    let content = std::fs::read_to_string(&trace_path)
        .unwrap_or_else(|e| panic!("read default trace file {trace_path:?}: {e}"));
    let lines: Vec<Vec<&str>> = content.lines().map(|l| l.split('\t').collect()).collect();
    assert!(!lines.is_empty(), "default trace file was empty");
    for fields in &lines {
        assert_eq!(fields.len(), 3, "not 3 tab-separated fields: {fields:?}");
        assert!(
            looks_like_iso8601_utc(fields[0]),
            "not a parseable ISO-8601 UTC timestamp: {fields:?}"
        );
    }
    assert!(
        lines
            .iter()
            .any(|f| f[1] == "session_exited" && f[2] == initial_name),
        "no \"session_exited\" trace line for {initial_name:?}:\n{content}"
    );
    assert!(
        lines
            .iter()
            .any(|f| f[1] == "relaunching" && f[2] == initial_name),
        "no \"relaunching\" trace line for {initial_name:?}:\n{content}"
    );

    drop(daemon);
}

/// This documents the case where NO persistence layer is installed: `remuda`
/// itself never re-execs butler on its own, restart or not — the only way
/// `packages/butler/init.lua`'s real code ever runs is an explicit `remuda
/// exec butler`. That stays true regardless of `docs/install-butler.sh`,
/// because the systemd timer / launchd agent it installs lives entirely
/// outside this binary; this test's daemon has none of that wired in, so it
/// still shows the session does not come back unassisted. It is not proof
/// that persistence is unsolved in general — see the sibling test below,
/// `a_supervisor_polling_remuda_ls_can_relaunch_butler_after_a_restart`, for
/// the positive leg with an external poller in the loop. If this test ever
/// fails with nothing installed, that's a real capability change in `remuda`
/// itself and the L6 cell's DoD must be revisited, not this assertion
/// loosened. Separately: this test is also the negative-control leg for
/// `remuda ls`'s exact-match liveness check -- the generated `butler-poll.sh`,
/// `install-butler.sh`'s install-time probe, and the sibling positive-leg
/// test below all depend on it staying true.
#[test]
#[cfg(unix)]
fn a_daemon_restart_does_not_relaunch_the_butler_session() {
    let dir = scratch_dir("butler-restart-ceiling");
    let (token_path, config_path) = butler_config(
        &dir,
        "restart-ceiling",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let mut daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let initial_name = eval(&path, "return remuda._butler_initial_name");

    // Confirm the watchdog is genuinely live before the restart -- otherwise
    // "it's not there after" would prove nothing. `list` names the current
    // session under its (possibly-respawned) butler name.
    let deadline = Instant::now() + PATIENCE;
    loop {
        let listed = remuda(&dir, &["-s", "s", "ls"]);
        if String::from_utf8_lossy(&listed.stdout).contains(&initial_name) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the butler session never showed up in `ls` before the restart"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    // Same restart path as `restart_stops_a_daemon_and_leaves_the_next_command_free_to_start_one`,
    // with `-f`: the live butler session makes a bare `restart` refuse (see
    // `restart_refuses_to_kill_a_live_session_without_being_told_twice`).
    let out = remuda(&dir, &["-s", "s", "stop", "-f"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        daemon.left_on_its_own(),
        "the old daemon did not exit on its own"
    );

    // A fresh daemon against the same runtime dir/socket -- the same
    // credentials are still on disk and still exported into this new
    // process's own environment, so if anything anywhere auto-relaunched
    // butler, this daemon has everything it would need to do so.
    let _daemon2 = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );

    // Wait through a couple of TICK_PERIODs (1s each, see daemon.rs) to rule
    // out some delayed auto-recovery this comment doesn't know about, not
    // just an instant-after check.
    std::thread::sleep(Duration::from_millis(2500));
    let listed = remuda(&dir, &["-s", "s", "ls"]);
    let listed_out = String::from_utf8_lossy(&listed.stdout);
    assert!(
        !listed_out.contains(&initial_name),
        "the butler session came back after a restart with no `exec butler` -- \
         this is a real capability change; see this test's own doc comment: {listed_out}"
    );
}

/// The positive leg: nothing in `remuda` itself auto-relaunches butler (the
/// test above), but the mechanism an external supervisor would drive --
/// poll `remuda ls` for the exact session name, and if it is absent re-run
/// `remuda exec butler` -- already works today with no production-code
/// change. This pins that fact down so it can't silently regress.
///
/// Shared-instrument note: this test and the ceiling test above both use
/// "does a session named exactly `butler` exist" as ground truth. That is
/// only a safe foundation *because* the ceiling test exists as a negative
/// control -- if `remuda ls` ever reported the name present when the
/// process structurally is not, this test would go green for the wrong
/// reason, and a real supervisor built on the same check would silently
/// never relaunch. Don't delete or loosen either test in isolation.
#[test]
#[cfg(unix)]
fn a_supervisor_polling_remuda_ls_can_relaunch_butler_after_a_restart() {
    let dir = scratch_dir("butler-restart-relaunch");
    let (token_path, config_path) = butler_config(
        &dir,
        "restart-relaunch",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let mut daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let initial_name = eval(&path, "return remuda._butler_initial_name");

    let deadline = Instant::now() + PATIENCE;
    loop {
        let listed = remuda(&dir, &["-s", "s", "ls"]);
        if String::from_utf8_lossy(&listed.stdout).contains(&initial_name) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the butler session never showed up in `ls` before the restart"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    let out = remuda(&dir, &["-s", "s", "stop", "-f"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        daemon.left_on_its_own(),
        "the old daemon did not exit on its own"
    );

    // A fresh daemon, same credentials on disk and still exported into this
    // new process's env -- the same shape the systemd/launchd unit's daemon
    // auto-start would produce after a crash.
    let _daemon2 = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );

    // Same test-mode wiring as the first `exec butler` above -- a real
    // supervisor's poll would start a genuine Claude Code session, which
    // this harness cannot exercise; `_butler_argv`/`_butler_skip_relay` swap
    // in a `sleep` in its place while leaving every other line of
    // `init.lua` (the actual relaunch mechanism under test) untouched.
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    // This is exactly what the supervisor's poll runs after finding the name
    // absent from `remuda ls`: re-`exec butler`. The package owns the stable
    // name "butler", independent of the daemon's ambient environment.
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let deadline = Instant::now() + PATIENCE;
    loop {
        let listed = remuda(&dir, &["-s", "s", "ls"]);
        if String::from_utf8_lossy(&listed.stdout).contains(&initial_name) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the re-`exec butler` call never produced a session named {initial_name:?} after restart"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The actual bug this suite exists to catch: a daemon born with ZERO
/// butler env vars (the exact poisoning scenario -- some unrelated `remuda`
/// command lazily birthing a daemon before butler's own installer/env ever
/// gets a chance to run) must still be able to register butler, as long as
/// the token/config files sit at `init.lua`'s conventional default path
/// under `HOME`. Every other test in this file that reaches past
/// `_butler_test_mode` sets `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG`
/// explicitly via `Daemon::spawn_with_env` -- none of them cover this path.
#[test]
#[cfg(unix)]
fn butler_exec_finds_credentials_at_the_conventional_path_with_zero_env_vars() {
    let dir = scratch_dir("butler-conventional");
    let home = dir.join("home");
    let butler_dir = home.join(".config/remuda/butler");
    std::fs::create_dir_all(&butler_dir).expect("mkdir conventional butler dir");
    std::fs::write(butler_dir.join("token"), "test-token\n").expect("write token");
    std::fs::write(
        butler_dir.join("config"),
        "http://127.0.0.1:1\n!room:example.org\n@butler:example.org\n\n",
    )
    .expect("write config");

    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");

    // Same test-mode substitution as the watchdog/restart tests: a short-
    // lived real process stands in for `claude`, and the relay (which would
    // otherwise retry forever against these dummy credentials) is skipped.
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 0.3; exit 0"}"#,
    );
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "expected exec butler to succeed using only the conventional HOME-based \
         path, with no REMUDA_BUTLER_TOKEN/CONFIG at all -- stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let initial_name = eval(&path, "return remuda._butler_initial_name");
    let deadline = Instant::now() + PATIENCE;
    loop {
        let listed = remuda(&dir, &["-s", "s", "ls"]);
        if String::from_utf8_lossy(&listed.stdout).contains(&initial_name) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the butler session never showed up in `ls`"
        );
        std::thread::sleep(Duration::from_millis(50));
    }

    drop(daemon);
}

/// Matrix is an optional Butler layer. With no conventional credential files
/// and no overrides, `exec butler` must still launch its local Claude session.
#[test]
#[cfg(unix)]
fn butler_exec_starts_without_matrix_credentials() {
    let dir = scratch_dir("butler-no-creds");
    let home = dir.join("home-empty");
    std::fs::create_dir_all(&home).expect("mkdir empty home");

    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 5; exit 0"}"#,
    );

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "expected local-only exec butler to succeed with no Matrix credentials: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let initial_name = eval(&path, "return remuda._butler_initial_name");
    let listed = remuda(&dir, &["-s", "s", "ls"]);
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains(&initial_name),
        "local-only butler session never appeared in ls"
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._butler_matrix_config == nil and remuda._butler_matrix_relay == nil)"),
        "true",
        "Matrix must stay inert without configuration"
    );

    drop(daemon);
}

/// The whole point of this step (steps/035): a `~/.config/remuda/init.lua`
/// present before the daemon exists at all is evaluated automatically --
/// with no human hand and no `remuda exec`/`eval` call anywhere in THIS
/// test -- every time a FRESH daemon boots, mirroring how Neovim/Hammerspoon
/// /WezTerm auto-load a user init file. The instrument is `remuda ls`'s
/// session list, never "the loader ran without erroring".
///
/// The `_butler_argv`/`_butler_skip_relay` test substitutions that every
/// other butler test injects via a separate `eval` *before* calling `exec
/// butler` are, here, baked into the auto-loaded file itself -- so it is the
/// DAEMON's own boot-time load that performs the substitution and the exec,
/// never this test. Real `docs/install-butler.sh` output has no such
/// substitutions (it can't know about `claude` not existing on a test box);
/// this is the same mechanism with a stand-in child process, same as every
/// other butler test that can't spawn a real `claude`.
///
/// The restart leg is the DoD's own wording: after killing and restarting
/// the daemon, with no human hand, `remuda ls` must show butler AGAIN, from
/// the SAME home dir with the SAME (unchanged) config file -- proving the
/// mechanism survives the exact scenario it exists for, not just a first
/// boot.
#[test]
#[cfg(unix)]
fn a_fresh_daemon_auto_loads_the_user_config_and_registers_butler_with_no_human_hand() {
    let dir = scratch_dir("boot-loader-positive");
    let home = dir.join("home");
    let butler_dir = home.join(".config/remuda/butler");
    std::fs::create_dir_all(&butler_dir).expect("mkdir conventional butler dir");
    std::fs::write(butler_dir.join("token"), "test-token\n").expect("write token");
    std::fs::write(
        butler_dir.join("config"),
        "http://127.0.0.1:1\n!room:example.org\n@butler:example.org\n\n",
    )
    .expect("write config");
    std::fs::create_dir_all(home.join(".config/remuda")).expect("mkdir config dir");
    std::fs::write(
        home.join(".config/remuda/init.lua"),
        "remuda._butler_argv = {\"sh\", \"-c\", \"sleep 0.3; exit 0\"}\n\
         remuda._butler_skip_relay = true\n\
         remuda.exec(\"butler\")\n",
    )
    .expect("write init.lua");

    let mut daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");

    // No `exec butler` and no `eval` calling `remuda.exec` anywhere in this
    // test -- if butler shows up, the daemon's own boot-time loader did it.
    let deadline = Instant::now() + PATIENCE;
    let initial_name = loop {
        let name = eval(&path, "return remuda._butler_initial_name or ''");
        if !name.is_empty() {
            let listed = remuda(&dir, &["-s", "s", "ls"]);
            if String::from_utf8_lossy(&listed.stdout).contains(&name) {
                break name;
            }
        }
        assert!(
            Instant::now() < deadline,
            "the daemon never auto-registered a butler session from its own \
             boot-time config load"
        );
        std::thread::sleep(Duration::from_millis(50));
    };

    // Restart leg. `-f`: a live butler session makes a bare `restart` refuse
    // (see `restart_refuses_to_kill_a_live_session_without_being_told_twice`).
    let out = remuda(&dir, &["-s", "s", "restart", "-f"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        daemon.left_on_its_own(),
        "the old daemon did not exit on its own"
    );

    // A fresh daemon, same home dir, config file untouched on disk. Again:
    // no `exec butler` call anywhere in this test.
    let _daemon2 = Daemon::spawn_with_home(&dir, &home);
    let deadline = Instant::now() + PATIENCE;
    loop {
        let listed = remuda(&dir, &["-s", "s", "ls"]);
        if String::from_utf8_lossy(&listed.stdout).contains(&initial_name) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "after killing and restarting the daemon, remuda ls never showed \
             butler again -- the boot-time loader must run on EVERY fresh \
             daemon, not just the first"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Negative control for the whole mechanism above (steps/035's own DoD
/// wording: "with the feature turned off, the same procedure must go RED —
/// if it does not go red, the instrument is not measuring the feature").
/// Absence of `~/.config/remuda/init.lua` IS "feature off" here, the same
/// way a vanilla Neovim/Hammerspoon install with no config is: valid
/// credentials sit at the conventional butler path (same fixture as the
/// positive test above), but with no init.lua to call `remuda.exec("butler")`
/// a fresh daemon must never show a butler session. Without this test, the
/// positive test above could pass for the wrong reason (e.g. `remuda ls`
/// always reporting butler present regardless of what actually ran).
#[test]
#[cfg(unix)]
fn a_fresh_daemon_with_no_user_config_never_auto_registers_butler() {
    let dir = scratch_dir("boot-loader-negative");
    let home = dir.join("home-empty");
    let butler_dir = home.join(".config/remuda/butler");
    std::fs::create_dir_all(&butler_dir).expect("mkdir conventional butler dir");
    std::fs::write(butler_dir.join("token"), "test-token\n").expect("write token");
    std::fs::write(
        butler_dir.join("config"),
        "http://127.0.0.1:1\n!room:example.org\n@butler:example.org\n\n",
    )
    .expect("write config");
    // Deliberately: no `~/.config/remuda/init.lua` written at all.

    let _daemon = Daemon::spawn_with_home(&dir, &home);

    // A couple of TICK_PERIODs' worth of margin (same as
    // `a_daemon_restart_does_not_relaunch_the_butler_session`'s own wait) to
    // rule out a delayed load, not just an instant-after check.
    std::thread::sleep(Duration::from_millis(1200));
    let listed = remuda(&dir, &["-s", "s", "ls"]);
    let listed_out = String::from_utf8_lossy(&listed.stdout);
    assert!(
        listed_out.contains("no sessions"),
        "a fresh daemon with no init.lua at all auto-registered something: {listed_out}"
    );
}

/// Regression test against the exact hazard `load_user_config`'s own doc
/// comment (daemon.rs) names: because `Image::spawn`'s `ready` chain (image.rs)
/// is checked on EVERY job forever, an `Err` inside it poisons the image
/// PERMANENTLY -- moving the user-config load back inside that chain (as
/// opposed to the separate, later `image.eval` call it uses today) would let
/// one colleague's own typo in their `~/.config/remuda/init.lua` brick every
/// other session on their daemon, forever, until a manual restart. A broken
/// file must be reported and then the daemon must go on being an entirely
/// ordinary, working daemon.
#[test]
#[cfg(unix)]
fn a_broken_user_config_is_reported_but_never_bricks_the_daemon() {
    let dir = scratch_dir("boot-loader-blast-radius");
    let home = dir.join("home");
    std::fs::create_dir_all(home.join(".config/remuda")).expect("mkdir config dir");
    std::fs::write(
        home.join(".config/remuda/init.lua"),
        "this is not valid lua $$$\n",
    )
    .expect("write broken init.lua");

    let _daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");

    // The daemon is still a normal, working daemon: `ls` answers cleanly --
    // if the hazard above ever regressed, this would instead come back as
    // an error containing "image failed to start".
    match client::request(&path, &Request::List).expect("list") {
        Response::Sessions(s) => assert!(s.is_empty(), "a fresh daemon holds nothing"),
        other => panic!("unexpected: {other:?}"),
    }

    // Direct proof the image itself is not poisoned, not merely that `ls`
    // (which never touches the `ready` chain either) happens to still work:
    // an entirely unrelated, ordinary session can still be created.
    new_session(&path, "plain");
    let listed = remuda(&dir, &["-s", "s", "ls"]);
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains("plain"),
        "an ordinary session could not be created after a broken user config \
         -- the image is poisoned"
    );
}

/// #24: `stop -f` kills agents without a `session_exited`, so their last
/// `agents.jsonl` row never got `ended_at`. The next boot must close every
/// identity with no live session, leaving ended rows and the root alone.
#[test]
fn butler_boot_ends_identities_whose_sessions_died_with_the_daemon() {
    let dir = scratch_dir("butler-boot-ended");
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let agents = data_home.join("remuda/butler/agents.jsonl");
    std::fs::write(
        &agents,
        concat!(
            r#"{"id":"01ROOT00000000000000000000","alias":"butler","kind":"claude","leader_id":"","created_at":"2026-09-27T00:00:00Z"}"#, "\n",
            r#"{"id":"01GHST00000000000000000000","alias":"ghost","kind":"claude","leader_id":"01ROOT00000000000000000000","created_at":"2026-09-27T00:00:00Z"}"#, "\n",
            r#"{"id":"01DNE000000000000000000000","alias":"done","kind":"claude","leader_id":"01ROOT00000000000000000000","created_at":"2026-09-27T00:00:00Z","ended_at":"2026-09-27T00:01:00Z"}"#, "\n",
        ),
    )
    .expect("seed agents.jsonl");
    let data = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(&dir, &[("XDG_DATA_HOME", data.as_str())]);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let rows = std::fs::read_to_string(&agents).expect("read agents.jsonl");
    let last = |id: &str| {
        rows.lines()
            .filter(|l| l.contains(id))
            .last()
            .unwrap_or_default()
            .to_string()
    };
    let count = |id: &str| {
        rows.lines()
            .filter(|l| l.contains(&format!(r#""id":"{id}""#)))
            .count()
    };
    assert!(last("01GHST").contains("ended_at"), "{rows}");
    assert_eq!(
        count("01DNE000000000000000000000"),
        1,
        "an ended identity is not re-ended: {rows}"
    );
    assert!(
        !last(r#""id":"01ROOT"#).contains("ended_at"),
        "the root stays live: {rows}"
    );
    assert!(
        eval(
            &path,
            "return remuda._butler_bus.identities.ghost.ended_at ~= nil"
        ) == "true"
    );
    drop(daemon);
}
