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
use remuda_native::{client, daemon, ipc, mcp, CommandBuilder, PtyAgent, SystemClock};
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
    }
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
                "local matrix = remuda.butler and remuda.butler.matrix; return \
                 (matrix and matrix.request_json and matrix.send and matrix.relay and matrix.relay.new) \
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
    eval(&path, "remuda._butler_test_mode = 'lifecycle'; remuda.exec('butler')");

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
        initial == "1|4|1|1|1|17" || initial == "1|4|1|1|1|-1",
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
        assert_eq!(eval(&path, counts), initial, "reload duplicated Butler registrations");
        assert_eq!(
            eval(&path, "return tostring(remuda._butler_state.compaction_enabled)"),
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
    assert!(failed.starts_with("false|"), "reload should report its failed start: {failed}");
    assert!(failed.contains("injected Butler start failure"), "wrong start error: {failed}");
    assert_eq!(eval(&path, counts), initial, "failed reload did not restore Butler registrations");
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

// --- packages/butler: Matrix async client, relay and write composites ------
// All Matrix behavior tests run on a private daemon with the shared Lua HTTP fake.

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

/// Pre-start a daemon, then run the real Butler package inside it in test
/// mode. The Matrix modules remain available in the same image for evals,
/// without starting a real agent or contacting a homeserver.
fn butler_test_daemon(dir: &Path) -> (Daemon, PathBuf) {
    let daemon = Daemon::spawn(dir);
    let path = daemon::socket_path_in(dir, "s");
    eval(&path, "remuda._butler_test_mode = true; remuda._butler_skip_relay = true");
    let out = remuda_timed(dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    eval(&path, "remuda.exec('butler/matrix')");
    (daemon, path)
}

fn butler_cli_test_daemon(dir: &Path) -> (Daemon, PathBuf) {
    let daemon = Daemon::spawn(dir);
    let path = daemon::socket_path_in(dir, "s");
    eval(&path, "remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true");
    let out = remuda_timed(dir, &["-s", "s", "butler", "--headless"]);
    assert!(out.status.success(), "load Butler CLI: {}", String::from_utf8_lossy(&out.stderr));
    (daemon, path)
}


#[test]
fn butler_matrix_request_uses_fake_http_for_auth_trust_allow_and_same_room() {
    let dir = scratch_dir("butler-matrix-request");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!request:example.org";
    let pin_hex = "00".repeat(32);
    let (token_path, config_path) = butler_config(&dir, "request", "https://matrix.example.org",
        room, "@bot:example.org", "");
    std::fs::write(&config_path, format!(
        "https://matrix.example.org\n{room}\n@bot:example.org\n\npin_sha256={pin_hex}\nca_file=/tmp/test-ca.pem\n"))
        .expect("write Matrix request config");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));

    let result = eval(&path, &format!(r#"
      local loaded, load_error = pcall(remuda.exec, "butler/matrix_request")
      if not loaded then return "missing|" .. tostring(load_error) end
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/joined_rooms",
        {{ status = 200, headers = {{}}, body = "{{}}" }})
      local finished, finished_count
      finished_count = 0
      matrix.request({{ method = "GET", path = "/_matrix/client/v3/joined_rooms",
        max_bytes = 2048, timeout = 12 }}, function(value) finished = value; finished_count = finished_count + 1 end)
      local spec = remuda.http.calls[1]
      if not spec then return "no-request" end
      if finished then return "callback-ran-inline" end
      if spec.headers.Authorization ~= "Bearer test-token" then return "bad-auth" end
      if spec.pin ~= "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" then return "bad-pin:" .. tostring(spec.pin) end
      if spec.ca_file ~= "/tmp/test-ca.pem" then return "bad-ca" end
      if spec.max_bytes ~= 2048 or spec.timeout ~= 12 then return "bad-bounds" end
      remuda.http.tick()
      remuda.http.tick()
      if finished.status ~= 200 then return "callback-not-delivered" end
      if finished_count ~= 1 then return "callback-not-once" end
      local denied
      matrix.request({{ method = "GET", path = "/_matrix/client/v3/rooms/!other:example.org/messages",
        room = "!other:example.org" }}, function(value) denied = value end)
      if #remuda.http.calls ~= 1 then return "allowlist-reached-network" end
      if not denied or not denied.error then return "allowlist-not-reported" end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21request%3Aexample.org/context/%24event",
        {{ status = 200, headers = {{}}, body = '{{"event":{{"room_id":"{room}"}}}}' }})
      local same
      matrix.same_room("{room}", "$event", function(value) same = value end)
      if #remuda.http.calls ~= 1 then return "limiter-did-not-queue" end
      remuda.http.respond("PUT", "https://matrix.example.org/_matrix/media/v3/upload",
        {{ status = 201, headers = {{ ["Content-Type"] = "application/octet-stream" }}, body = "\0\255" }})
      local uploaded
      matrix.request({{ method = "PUT", path = "/_matrix/media/v3/upload", room = "{room}",
        body = "\0\255", headers = {{ ["Content-Type"] = "application/octet-stream" }}, max_bytes = 4096 }},
        function(value) uploaded = value end)
      if #remuda.http.calls ~= 1 then return "limiter-did-not-queue-burst" end
      remuda.http.tick()
      if #remuda.http.calls ~= 2 then return "limiter-did-not-release" end
      if same ~= true then return "same-room-failed" end
      if uploaded then return "second-callback-ran-too-early" end
      remuda.http.tick()
      if #remuda.http.calls ~= 3 then return "limiter-did-not-preserve-burst" end
      local raw = remuda.http.calls[3]
      if raw.method ~= "PUT" or raw.body ~= "\0\255" then return "raw-body-changed" end
      if raw.headers["Content-Type"] ~= "application/octet-stream" then return "raw-content-type-lost" end
      if not uploaded or uploaded.status ~= 201 then return "raw-callback-not-delivered" end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/versions",
        {{ status = 200, headers = {{}}, body = '{{"next_batch":"n","unicode":"\\uD83D\\uDE42","ok":true}}' }})
      local decoded
      matrix.request_json({{ method = "GET", path = "/_matrix/client/v3/versions" }},
        function(value) decoded = value end)
      remuda.http.tick()
      if not decoded or not decoded.json or decoded.json.next_batch ~= "n" or decoded.json.ok ~= true
        or decoded.json.unicode ~= "🙂" then return "json-response-not-decoded" end
      local encoded, encode_error = matrix.encode_json({{ body = "line\n", count = 2 }})
      if not encoded then return "json-encode-failed:" .. tostring(encode_error) end
      local roundtrip = matrix.decode_json(encoded)
      if not roundtrip or roundtrip.body ~= "line\n" or roundtrip.count ~= 2 then return "json-roundtrip-failed" end
      local duplicate, duplicate_error = remuda.json.decode('{{"key":1,"key":2}}')
      if duplicate ~= nil or duplicate_error ~= "duplicate key" then return "duplicate-key-not-rejected" end
      local tagged = remuda.json.encode({{ array = remuda.json.array({{}}), object = remuda.json.object({{}}) }})
      local tagged_value = remuda.json.decode(tagged)
      if not tagged_value or getmetatable(tagged_value.array) ~= getmetatable(remuda.json.array({{}}))
        or getmetatable(tagged_value.object) ~= getmetatable(remuda.json.object({{}})) then
        return "empty-json-shapes-not-preserved"
      end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/bad",
        {{ status = 400, headers = {{}}, body = "bad request" }})
      local failed
      matrix.request_json({{ method = "GET", path = "/_matrix/client/v3/bad" }}, function(value) failed = value end)
      remuda.http.tick()
      if not failed or not failed.error or not failed.error:find("Matrix HTTP 400", 1, true) then return "http-error-not-surfaced" end
      return "ok"
    "#));
    assert_eq!(result, "ok", "Matrix request word should use the fake async HTTP boundary: {result}");
}

#[test]
fn butler_matrix_request_rejects_https_without_trust_before_network() {
    let dir = scratch_dir("butler-matrix-no-trust");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!request:example.org";
    let (token_path, config_path) = butler_config(&dir, "request", "https://matrix.example.org",
        room, "@bot:example.org", "");
    std::fs::write(&config_path,
        format!("https://matrix.example.org\n{room}\n@bot:example.org\n"))
        .expect("write Matrix config without TLS trust policy");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, r#"
      local failure
      remuda.butler.matrix.request({ method = "GET", path = "/_matrix/client/v3/versions" },
        function(value) failure = value end)
      if not failure or not failure.error or not failure.error:find("requires ca_file=PATH or pin_sha256=HEX", 1, true)
        then return "missing-trust-error" end
      return #remuda.http.calls == 0 and "ok" or "network-reached"
    "#);
    assert_eq!(result, "ok", "HTTPS must fail closed before HTTP: {result}");
}

#[test]
fn butler_matrix_fake_http_holds_and_releases_long_poll_on_tick() {
    let dir = scratch_dir("butler-matrix-fake-hold");
    let (_daemon, path) = butler_test_daemon(&dir);
    eval(&path, include_str!("support/fake_http.lua"));
    let result = eval(&path, r#"
      local url = "https://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=30000"
      remuda.http.hold("GET", url)
      local completed
      remuda.http.request({ method = "GET", url = url, timeout = 30,
        callback = function(value) completed = value end })
      remuda.http.tick()
      if completed then return "held-callback-fired" end
      if #remuda.http.calls ~= 1 then return "request-not-recorded" end
      local released = remuda.http.release("GET", url,
        { status = 200, headers = {}, body = "{}" })
      if not released then return "request-not-released" end
      if completed then return "release-fired-inline" end
      remuda.http.tick()
      if not completed or completed.status ~= 200 then return "release-not-delivered-on-tick" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "fake HTTP long-poll hold must be asynchronous: {result}");
}

#[test]
fn butler_matrix_relay_uses_async_request_and_preserves_envelope_metadata() {
    let dir = scratch_dir("butler-matrix-relay-async");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir,
        "relay",
        "https://matrix.example.org",
        room,
        "@bot:example.org",
        "@alice:example.org",
    );
    std::fs::write(
        &config_path,
        format!(
            "https://matrix.example.org\n{room}\n@bot:example.org\n@alice:example.org\nfalse\n30000\nca_file=/tmp/test-ca.pem\n"
        ),
    )
    .expect("write relay config");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(
        &path,
        &format!(
            "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
            lua_raw_string(&token_path.to_string_lossy()),
            lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    let baseline_url = "https://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync_url = "https://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=30000";
    let event = serde_json::json!({
        "type": "m.room.message", "event_id": "$relay-event", "sender": "@alice:example.org",
        "origin_server_ts": 0,
        "content": {
            "msgtype": "m.text", "body": "hello",
            "url": "mxc://media/example",
            "m.relates_to": {
                "rel_type": "m.thread", "event_id": "$thread-root",
                "m.in_reply_to": {"event_id": "$parent"}
            }
        }
    });
    let response = serde_json::json!({
        "next_batch": "s1",
        "rooms": {"join": { room: {"timeline": {"events": [event]}}}}
    });
    let result = eval(
        &path,
        &format!(
            r#"
            local matrix = remuda.butler.matrix
            remuda.http.respond("GET", {baseline}, {{ status = 200, headers = {{}}, body = '{{"next_batch":"s0"}}' }})
            remuda.http.respond("GET", {sync}, {{ status = 200, headers = {{}}, body = {response} }})
            remuda.relay_deliveries = {{}}
            remuda.relay_client = matrix.relay.new({{ config_path = {config}, matrix = matrix,
              deliver = function(value) table.insert(remuda.relay_deliveries, value); return true end }})
            remuda.relay_client:start()
            if #remuda.http.calls ~= 1 then return "baseline-not-started" end
            if remuda.relay_deliveries[1] then return "callback-ran-inline" end
            remuda.http.tick()
            remuda.http.tick()
            if #remuda.relay_deliveries ~= 1 then return "event-not-delivered" end
            local event = remuda.relay_deliveries[1]
            if event.event_id ~= "$relay-event" or event.thread_root ~= "$thread-root"
              or event.in_reply_to ~= "$parent" or event.mxc ~= "mxc://media/example" then return "metadata-lost" end
            if event.created_at ~= "1970-01-01T00:00:00Z" then return "timestamp-wrong" end
            local first = remuda.http.calls[1]
            if first.headers.Authorization ~= "Bearer test-token" then return "missing-auth" end
            if first.ca_file ~= "/tmp/test-ca.pem" then return "missing-ca" end
            if first.timeout ~= 10 then return "baseline-timeout-wrong" end
            if remuda.http.calls[2].url ~= {sync} then return "since-poll-wrong" end
            remuda.relay_client:stop()
            return "ok"
            "#,
            baseline = lua_raw_string(baseline_url),
            sync = lua_raw_string(sync_url),
            response = lua_raw_string(&response.to_string()),
            config = lua_raw_string(&config_path.to_string_lossy()),
        ),
    );
    assert_eq!(result, "ok", "L3 must poll asynchronously via L1 and retain envelope metadata: {result}");
}

#[test]
fn butler_matrix_relay_persists_cursor_filters_and_deduplicates_fake_events() {
    let dir = scratch_dir("mr-events");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "parity", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));

    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let first_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let resumed_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s1&timeout=100";
    let body = "line one\n\t\\line two";
    let in_room = serde_json::json!([
        {"type":"m.room.member","event_id":"$state-event","sender":"@alice:example.org","content":{"msgtype":"m.text","body":"not a message"}},
        {"type":"m.room.message","event_id":"$self","sender":"@bot:example.org","content":{"msgtype":"m.text","body":"self"}},
        {"type":"m.room.message","event_id":"$blocked","sender":"@mallory:example.org","content":{"msgtype":"m.text","body":"blocked"}},
        {"type":"m.room.message","event_id":"$wrong-type","sender":"@alice:example.org","content":{"msgtype":"m.image","body":"blocked"}},
        {"type":"m.room.message","event_id":"$good","sender":"@alice:example.org","origin_server_ts":0,"content":{"msgtype":"m.text","body":body}},
        {"type":"m.room.message","event_id":"$fallback-time","sender":"@alice:example.org","content":{"msgtype":"m.notice","body":"fallback timestamp"}},
        {"type":"m.room.message","event_id":"$good","sender":"@alice:example.org","content":{"msgtype":"m.text","body":"duplicate in page"}}
    ]);
    let baseline_response = serde_json::json!({"next_batch":"s0","rooms":{"join":{
        room:{"timeline":{"events":[{"type":"m.room.message","event_id":"$history","sender":"@alice:example.org",
            "content":{"msgtype":"m.text","body":"baseline history must not replay"}}]}}
    }}});
    let response = serde_json::json!({"next_batch":"s1","rooms":{"join":{
        "!other:example.org":{"timeline":{"events":[{"type":"m.room.message","event_id":"$other-room","sender":"@alice:example.org","content":{"msgtype":"m.text","body":"wrong room"}}]}},
        room:{"timeline":{"events":in_room}}
    }}});
    let result = eval(&path, &format!(r##"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body={baseline_response} }})
      remuda.http.respond("GET", {first_sync}, {{ status=200, headers={{}}, body={response} }})
      remuda.relay_deliveries = {{}}
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix,
        deliver=function(e) table.insert(remuda.relay_deliveries, e); return true end }})
      relay:start()
      remuda.http.tick()
      if #remuda.relay_deliveries ~= 0 then return "baseline-history-replayed" end
      remuda.http.tick()
      if #remuda.relay_deliveries ~= 2 then return "filter-or-page-dedup-failed:" .. #remuda.relay_deliveries end
      local e, fallback
      for _, value in ipairs(remuda.relay_deliveries) do
        if value.event_id == "$good" then e = value end
        if value.event_id == "$fallback-time" then fallback = value end
      end
      if not fallback or not fallback.created_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
        then return "missing-UTC-time-fallback" end
      if e.event_id ~= "$good" or e.body ~= {body} then return "multiline-body-changed" end
      if e.created_at ~= "1970-01-01T00:00:00Z" then return "timestamp-changed" end
      local f = assert(io.open({state}, "rb")); local saved = matrix.decode_json(f:read("*a")); f:close()
      if saved.since ~= "s1" then return "cursor-not-persisted" end
      relay:stop()
      remuda.http.respond("GET", {resumed_sync}, {{ status=200, headers={{}}, body={response} }})
      local restarted = matrix.relay.new({{ config_path={config}, matrix=matrix,
        deliver=function(value) table.insert(remuda.relay_deliveries, value); return true end }})
      restarted:start()
      remuda.http.tick()
      remuda.http.tick()
      if #remuda.relay_deliveries ~= 2 then return "restart-redelivered-processed-event" end
      local resumed = false
      for _, spec in ipairs(remuda.http.calls) do if spec.url == {resumed_sync} then resumed = true end end
      if not resumed then return "restart-did-not-resume-since" end
      restarted:stop()
      return "ok"
    "##,
        baseline=lua_raw_string(baseline), first_sync=lua_raw_string(first_sync),
        resumed_sync=lua_raw_string(resumed_sync), response=lua_raw_string(&response.to_string()),
        baseline_response=lua_raw_string(&baseline_response.to_string()),
        body=lua_raw_string(body), config=lua_raw_string(&config_path.to_string_lossy()),
        state=lua_raw_string(&PathBuf::from(format!("{}.since", config_path.display())).to_string_lossy())));
    assert_eq!(result, "ok", "M1 cursor/filter/dedup/multiline parity via fake HTTP: {result}");
}

#[test]
fn butler_matrix_relay_persists_pending_before_cursor_and_retries_after_restart() {
    let dir = scratch_dir("mr-pending");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "pending", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let event = serde_json::json!({"type":"m.room.message","event_id":"$pending","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"durable before handoff"}});
    let response = serde_json::json!({"next_batch":"s1","rooms":{"join":{room:{"timeline":{"events":[event]}}}}});
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body='{{"next_batch":"s0"}}' }})
      remuda.http.respond("GET", {sync}, {{ status=200, headers={{}}, body={response} }})
      remuda.delivery_attempts, remuda.pending_was_durable = 0, false
      local function first_delivery(e)
        remuda.delivery_attempts = remuda.delivery_attempts + 1
        local f = assert(io.open({state}, "rb")); local saved = matrix.decode_json(f:read("*a")); f:close()
        remuda.pending_was_durable = saved.since == "s1" and saved.pending_events[e.event_id] ~= nil
        return nil
      end
      local first = matrix.relay.new({{ config_path={config}, matrix=matrix, deliver=first_delivery }})
      first:start()
      remuda.http.tick(); remuda.http.tick()
      if not remuda.pending_was_durable then return "pending-not-saved-before-delivery" end
      first:stop()
      local attempts_before_restart = remuda.delivery_attempts
      local second = matrix.relay.new({{ config_path={config}, matrix=matrix,
        deliver=function() remuda.delivery_attempts=remuda.delivery_attempts+1; return true end }})
      second:start()
      if remuda.delivery_attempts ~= attempts_before_restart + 1 then return "pending-not-retried-after-restart" end
      if second:state().pending["$pending"] or not second:state().processed["$pending"]
        then return "successful-retry-not-acknowledged" end
      if second:state().since ~= "s1" then return "cursor-lost-on-restart" end
      second:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), sync=lua_raw_string(sync), response=lua_raw_string(&response.to_string()),
        config=lua_raw_string(&config_path.to_string_lossy()),
        state=lua_raw_string(&PathBuf::from(format!("{}.since", config_path.display())).to_string_lossy())));
    assert_eq!(result, "ok", "persist pending before cursor advance and retry an unacked event: {result}");
}

#[test]
fn butler_matrix_relay_survives_an_error_in_event_handling() {
    let dir = scratch_dir("mr-handler-error");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "handler-error", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let first_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let later_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s1&timeout=100";
    let first_event = serde_json::json!({"type":"m.room.message","event_id":"$throws-once","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"retry this handoff"}});
    let later_event = serde_json::json!({"type":"m.room.message","event_id":"$later","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"later event"}});
    let first_response = serde_json::json!({"next_batch":"s1","rooms":{"join":{room:{"timeline":{"events":[first_event]}}}}});
    let later_response = serde_json::json!({"next_batch":"s2","rooms":{"join":{room:{"timeline":{"events":[later_event]}}}}});
    let state_path = PathBuf::from(format!("{}.since", config_path.display()));
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body='{{"next_batch":"s0"}}' }})
      remuda.http.respond("GET", {first_sync}, {{ status=200, headers={{}}, body={first_response} }})
      remuda.http.respond("GET", {later_sync}, {{ status=200, headers={{}}, body={later_response} }})
      remuda.relay_deliveries, remuda.relay_delivery_attempts, remuda.relay_logs = {{}}, {{}}, {{}}
      local old_stderr = io.stderr
      io.stderr = {{ write=function(_, value) table.insert(remuda.relay_logs, value) end }}
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix, deliver=function(e)
        remuda.relay_delivery_attempts[e.event_id] = (remuda.relay_delivery_attempts[e.event_id] or 0) + 1
        if e.event_id == "$throws-once" and remuda.relay_delivery_attempts[e.event_id] == 1 then
          local f = assert(io.open({state}, "rb")); local saved = matrix.decode_json(f:read("*a")); f:close()
          remuda.pending_was_durable = saved.since == "s1" and saved.pending_events[e.event_id] ~= nil
          error("injected relay handler failure")
        end
        table.insert(remuda.relay_deliveries, e.event_id)
        return true
      end }})
      relay:start()
      remuda.http.tick()
      remuda.http.tick()
      remuda.http.tick()
      if not remuda.pending_was_durable then io.stderr=old_stderr; return "pending-or-cursor-not-durable-on-error" end
      if (remuda.relay_delivery_attempts["$throws-once"] or 0) < 2 then io.stderr=old_stderr; return "failed-handoff-not-retried" end
      local logged = false
      for _, line in ipairs(remuda.relay_logs) do
        if line:find("$throws-once", 1, true) and line:find("injected relay handler failure", 1, true) then logged=true end
      end
      if not logged then io.stderr=old_stderr; return "handler-error-not-logged" end
      remuda.http.tick()
      io.stderr = old_stderr
      local delivered = {{}}
      for _, id in ipairs(remuda.relay_deliveries) do delivered[id] = (delivered[id] or 0) + 1 end
      if delivered["$throws-once"] ~= 1 then return "pending-event-not-delivered-once-after-retry" end
      if delivered["$later"] ~= 1 then return "relay-did-not-deliver-later-event" end
      if not relay:state().processed["$throws-once"] then return "retried-event-not-acknowledged" end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), first_sync=lua_raw_string(first_sync), later_sync=lua_raw_string(later_sync),
        first_response=lua_raw_string(&first_response.to_string()), later_response=lua_raw_string(&later_response.to_string()),
        config=lua_raw_string(&config_path.to_string_lossy()), state=lua_raw_string(&state_path.to_string_lossy())));
    assert_eq!(result, "ok", "relay must log and recover from one event-handler error: {result}");
}

#[test]
fn butler_matrix_relay_dead_letters_poison_event_and_continues() {
    let dir = scratch_dir("mr-poison");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "poison", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let first_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let poison = serde_json::json!({"type":"m.room.message","event_id":"$poison","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"always throws"}});
    let normal = serde_json::json!({"type":"m.room.message","event_id":"$normal","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"keep going"}});
    let response = serde_json::json!({"next_batch":"s1","rooms":{"join":{room:{"timeline":{"events":[poison, normal]}}}}});
    let result = eval(&path, &format!(r#"
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body='{{"next_batch":"s0"}}' }})
      remuda.http.respond("GET", {first_sync}, {{ status=200, headers={{}}, body={response} }})
      remuda.relay_delivery_attempts, remuda.relay_deliveries, remuda.relay_logs = {{}}, {{}}, {{}}
      local old_stderr = io.stderr
      io.stderr = {{ write=function(_, value) table.insert(remuda.relay_logs, value) end }}
      local relay = remuda.butler.matrix.relay.new({{ config_path={config}, matrix=remuda.butler.matrix,
        deliver=function(e)
          remuda.relay_delivery_attempts[e.event_id] = (remuda.relay_delivery_attempts[e.event_id] or 0) + 1
          if e.event_id == "$poison" then error("poison handler") end
          table.insert(remuda.relay_deliveries, e.event_id)
          return true
        end }})
      relay:start()
      remuda.http.tick()
      remuda.http.tick()
      if (remuda.relay_delivery_attempts["$poison"] or 0) ~= 1 then io.stderr=old_stderr; return "poison-first-attempt-missing" end
      if #remuda.relay_deliveries ~= 1 or remuda.relay_deliveries[1] ~= "$normal"
        then io.stderr=old_stderr; return "normal-event-blocked-by-poison" end
      for _=1,24 do remuda.http.tick() end
      io.stderr = old_stderr
      if remuda.relay_delivery_attempts["$poison"] ~= 5
        then return "poison-attempt-bound-wrong:" .. tostring(remuda.relay_delivery_attempts["$poison"]) end
      if relay:state().pending["$poison"] then return "poison-remains-pending" end
      if relay:state().processed["$poison"] then return "dead-lettered-poison-marked-delivered" end
      local dead_letter_logged = false
      for _, line in ipairs(remuda.relay_logs) do
        if line:find("dead-lettered $poison after 5 failed attempts", 1, true) then dead_letter_logged=true end
      end
      if not dead_letter_logged then return "dead-letter-not-logged" end
      local normal_count = 0
      for _, id in ipairs(remuda.relay_deliveries) do if id == "$normal" then normal_count=normal_count+1 end end
      if normal_count ~= 1 then return "normal-event-not-delivered-exactly-once" end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), first_sync=lua_raw_string(first_sync), response=lua_raw_string(&response.to_string()),
        config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(result, "ok", "poison event must be retried with a bound, dead-lettered, and not block later events: {result}");
}

#[test]
fn butler_matrix_relay_retries_an_unreachable_first_sync_baseline() {
    let dir = scratch_dir("mr-retry");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "retry", "http://matrix.example.org", room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync = "http://matrix.example.org/_matrix/client/v3/sync?since=recovered&timeout=100";
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{ error="connection refused" }})
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body='{{"next_batch":"recovered"}}' }})
      remuda.http.respond("GET", {sync}, {{ status=200, headers={{}}, body='{{"next_batch":"recovered"}}' }})
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix, deliver=function() return true end }})
      relay:start()
      remuda.http.tick()
      if #remuda.http.calls ~= 1 then return "failed-baseline-did-not-start" end
      remuda.http.tick()
      remuda.http.tick()
      if #remuda.http.calls < 3 then return "unreachable-baseline-was-not-retried" end
      if remuda.http.calls[1].url ~= {baseline} or remuda.http.calls[2].url ~= {baseline}
        then return "baseline-retry-used-wrong-request" end
      if remuda.http.calls[3].url ~= {sync} then return "successful-baseline-did-not-persist-cursor" end
      local f = assert(io.open({state}, "rb")); local saved = matrix.decode_json(f:read("*a")); f:close()
      if saved.since ~= "recovered" then return "retry-cursor-not-saved" end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), sync=lua_raw_string(sync),
        config=lua_raw_string(&config_path.to_string_lossy()),
        state=lua_raw_string(&PathBuf::from(format!("{}.since", config_path.display())).to_string_lossy())));
    assert_eq!(result, "ok", "failed initial sync must retry without advancing its cursor: {result}");
}

#[test]
fn butler_matrix_relay_caps_retry_backoff_and_resets_after_recovery() {
    let dir = scratch_dir("mr-backoff");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "backoff", "http://matrix.example.org", room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync = "http://matrix.example.org/_matrix/client/v3/sync?since=recovered&timeout=100";
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      for _=1,7 do remuda.http.respond("GET", {baseline}, {{ error="offline" }}) end
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body='{{"next_batch":"recovered"}}' }})
      remuda.http.respond("GET", {sync}, {{ error="offline after recovery" }})
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix, deliver=function() return true end }})
      relay:start()
      remuda.http.tick()
      local delays = {{1,2,4,8,16,32,60}}
      for i, delay in ipairs(delays) do
        for _=1,delay-1 do
          remuda.http.tick()
          if #remuda.http.calls ~= i then return "retry-before-backoff:" .. delay end
        end
        remuda.http.tick()
        if #remuda.http.calls < i+1 then return "retry-missed-backoff:" .. delay end
      end
      local baseline_calls = 0
      for _, spec in ipairs(remuda.http.calls) do if spec.url == {baseline} then baseline_calls=baseline_calls+1 end end
      if baseline_calls ~= 8 then return "baseline-retry-count:" .. baseline_calls end
      for _=1,4 do remuda.http.tick() end
      local retries = 0
      for _, spec in ipairs(remuda.http.calls) do if spec.url == {sync} then retries=retries+1 end end
      if retries < 2 then return "successful-recovery-did-not-reset-retry-delay:" .. retries end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), sync=lua_raw_string(sync),
        config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(result, "ok", "transport retries should cap at 60 ticks and reset after success: {result}");
}

#[test]
fn butler_matrix_relay_uses_messages_fallback_and_suppresses_baseline_history() {
    let dir = scratch_dir("mr-messages");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "messages", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    std::fs::write(&config_path,
        format!("http://matrix.example.org\n{room}\n@bot:example.org\n@alice:example.org\nmessages\n100\n"))
        .expect("write fallback config");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/rooms/%21relay%3Aexample.org/messages?dir=b&limit=1";
    let forward = "http://matrix.example.org/_matrix/client/v3/rooms/%21relay%3Aexample.org/messages?from=b0&dir=f&limit=100";
    let historical = serde_json::json!({"start":"b0","end":"b1","chunk":[{"event_id":"$old"}]});
    let current = serde_json::json!({"start":"b0","end":"b2","chunk":[{
        "type":"m.room.message","event_id":"$new","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"new message"}
    }]});
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{ status=200, headers={{}}, body={historical} }})
      remuda.http.respond("GET", {forward}, {{ status=200, headers={{}}, body={current} }})
      remuda.relay_deliveries = {{}}
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix,
        deliver=function(e) table.insert(remuda.relay_deliveries, e); return true end }})
      relay:start()
      remuda.http.tick()
      if #remuda.relay_deliveries ~= 0 then return "baseline-history-replayed" end
      for _=1,4 do remuda.http.tick() end
      if #remuda.http.calls < 2 then return "forward-backfill-not-started" end
      if remuda.http.calls[1].url ~= {baseline} or remuda.http.calls[2].url ~= {forward}
        then return "wrong-messages-pagination" end
      if remuda.http.calls[1].url:find("/sync", 1, true) then return "used-sync-in-fallback-mode" end
      if #remuda.relay_deliveries ~= 1 or remuda.relay_deliveries[1].event_id ~= "$new"
        then return "forward-event-not-delivered" end
      if not relay:state().processed["$old"] then return "baseline-event-not-suppressed" end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), forward=lua_raw_string(forward),
        historical=lua_raw_string(&historical.to_string()), current=lua_raw_string(&current.to_string()),
        config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(result, "ok", "fallback mode must baseline backwards then page forwards: {result}");
}

#[test]
fn butler_matrix_relay_reload_replaces_the_fake_http_loop_once() {
    let dir = scratch_dir("mr-reload");
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "reload", "http://matrix.example.org", room, "@bot:example.org", "");
    let token = token_path.to_string_lossy().into_owned();
    let config = config_path.to_string_lossy().into_owned();
    let _daemon = Daemon::spawn_with_env(&dir, &[
        ("REMUDA_BUTLER_TOKEN", token.as_str()),
        ("REMUDA_BUTLER_CONFIG", config.as_str()),
    ]);
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, "remuda._butler_test_mode = 'lifecycle'");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(read_count(&path, "return #remuda.http.calls"), 1,
        "main and lifecycle startup must create only one active relay poll");
    eval(&path, "remuda.reload('butler')");
    assert_eq!(read_count(&path, "return #remuda.http.calls"), 2,
        "one reload must cancel and replace exactly one request loop");
    eval(&path, "remuda.reload('butler')");
    assert_eq!(read_count(&path, "return #remuda.http.calls"), 3,
        "repeated reloads must not duplicate relay loops");
}

#[test]
fn butler_matrix_relay_bounds_processed_ids_and_reconciles_bad_pending_state() {
    let dir = scratch_dir("mr-state");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!relay:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "state", "http://matrix.example.org", room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let processed: Vec<String> = (1..=5003).map(|i| format!("id-{i}")).collect();
    let pending = serde_json::json!({
        "$bad": {"sender":"@alice:example.org","room_id":room,"created_at":"time","body":17},
        "$incomplete": {"sender":"@alice:example.org"},
        "$acked": {"sender":"@alice:example.org","room_id":room,"created_at":"time","body":"acked"},
        "$drained": {"sender":"@alice:example.org","room_id":room,"created_at":"time","body":"drained"}
    });
    let state_path = PathBuf::from(format!("{}.since", config_path.display()));
    std::fs::write(&state_path, serde_json::json!({"since":"cursor","processed_event_ids":processed,
        "pending_events":pending}).to_string()).expect("seed relay state");
    std::fs::write(format!("{}.acks", config_path.display()), "$acked\n").expect("seed ack batch");
    std::fs::write(format!("{}.acks.drain", config_path.display()), "$drained\n").expect("seed stale drain batch");
    let result = eval(&path, &format!(r###"
      local matrix = remuda.butler.matrix
      remuda.relay_deliveries = {{}}
      local relay = matrix.relay.new({{ config_path={config}, matrix=matrix,
        deliver=function(e) table.insert(remuda.relay_deliveries, e); return true end }})
      if #relay:state().processed_order ~= 5000 or relay:state().processed_order[1] ~= "id-4"
        then return "processed-id-load-bound-failed:" .. #relay:state().processed_order .. ":" .. tostring(relay:state().processed_order[1]) end
      relay:start()
      local state = relay:state()
      if state.pending["$bad"] or state.pending["$incomplete"] or state.pending["$acked"] or state.pending["$drained"]
        then return "malformed-or-acked-pending-retained" end
      if not state.processed["$acked"] or not state.processed["$drained"]
        then return "ack-batches-not-reconciled" end
      if #remuda.relay_deliveries ~= 0 then return "acknowledged-event-was-delivered" end
      relay:stop()
      return "ok"
    "###, config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(result, "ok", "processed-ID bound and ack/malformed-pending invariants: {result}");

    std::fs::write(&state_path, "{\"since\":\"bad-type\",\"processed_event_ids\":5}")
        .expect("seed wrongly typed state");
    let corrupt = eval(&path, &format!(r###"
      local relay = remuda.butler.matrix.relay.new({{ config_path={config}, matrix=remuda.butler.matrix,
        deliver=function() return true end }})
      return relay:state().since == nil and #relay:state().processed_order == 0 and "ok" or "wrong-types-not-reset"
    "###, config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(corrupt, "ok", "wrongly typed processed IDs must reset state");

    std::fs::write(&state_path, "{broken").expect("seed malformed state");
    let malformed = eval(&path, &format!(r#"
      local relay = remuda.butler.matrix.relay.new({{ config_path={config}, matrix=remuda.butler.matrix,
        deliver=function() return true end }})
      return relay:state().since == nil and #relay:state().processed_order == 0 and "ok" or "malformed-state-not-reset"
    "#, config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(malformed, "ok", "malformed JSON state must reset cleanly");
    std::fs::remove_file(&state_path).expect("remove malformed primary state");
    std::fs::write(format!("{}.bak", state_path.display()), r#"{"since":"backup-cursor"}"#)
        .expect("seed replace-window backup");
    let recovered = eval(&path, &format!(r#"
      local relay = remuda.butler.matrix.relay.new({{ config_path={config}, matrix=remuda.butler.matrix,
        deliver=function() return true end }})
      local f = io.open({state}, "rb")
      if f then f:close() end
      return relay:state().since == "backup-cursor" and f and "ok" or "backup-not-recovered"
    "#, config=lua_raw_string(&config_path.to_string_lossy()), state=lua_raw_string(&state_path.to_string_lossy())));
    assert_eq!(recovered, "ok", "crash-window backup must restore the previous cursor");
}

// The Matrix MCP tool now uses the daemon's async request word directly.
#[test]
fn matrix_reply_tool_uses_async_matrix_request_without_subprocess() {
    let dir = scratch_dir("butler-matrix-reply-tool");
    let room = "!reply:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "reply", "http://matrix.example.org", room, "@bot:example.org", "");
    let token_env = token_path.to_string_lossy().into_owned();
    let config_env = config_path.to_string_lossy().into_owned();
    let _daemon = Daemon::spawn_with_env(&dir, &[
        ("REMUDA_BUTLER_TOKEN", token_env.as_str()),
        ("REMUDA_BUTLER_CONFIG", config_env.as_str()),
    ]);
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, "remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true");
    eval(&path, include_str!("support/fake_http.lua"));
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    eval(&path, r#"
      remuda.http.respond_prefix("PUT",
        "http://matrix.example.org/_matrix/client/v3/rooms/%21reply%3Aexample.org/send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$reply"}' })
    "#);
    let process_count = read_count(&path, "return #remuda.processes()");

    let tools: serde_json::Value = serde_json::from_str(
        &mcp::handle(&path, r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            .expect("list MCP tools"),
    ).expect("parse tools/list response");
    let tool = tools["result"]["tools"].as_array().unwrap().iter()
        .find(|tool| tool["name"] == "matrix_reply").expect("matrix_reply tool");
    assert_eq!(tool["inputSchema"]["required"], serde_json::json!(["text"]));
    let reply = mcp::handle(
        &path,
        &serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/call",
            "params":{"name":"matrix_reply","arguments":{"text":"hello"}}}).to_string(),
    ).expect("call matrix_reply");
    let reply: serde_json::Value = serde_json::from_str(&reply).expect("parse tool result");
    assert_eq!(reply["result"]["content"][0]["text"], "queued");
    assert_eq!(reply["result"]["isError"], false);
    assert_eq!(read_count(&path, "return #remuda.processes()"), process_count,
        "matrix_reply must not launch a subprocess");

    let request = eval(&path, r#"
      local spec = remuda.http.calls[1]
      if not spec then return "missing-request" end
      local decoded = remuda.butler.matrix.decode_json(spec.body)
      return table.concat({spec.headers.Authorization, spec.url, decoded.body}, "\n")
    "#);
    let fields: Vec<_> = request.lines().collect();
    assert_eq!(fields[0], "Bearer test-token");
    assert!(fields[1].starts_with("http://matrix.example.org/"));
    assert_eq!(fields[2], "hello");
    assert!(!request.contains("sensitive-token"), "token leaked outside the Authorization header");
    eval(&path, "remuda.http.tick()");
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
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let trace = dir.join("session-trace.log");
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({home:?})
          remuda._butler_session_trace_path = {trace:?}
          remuda._butler_task_poke_attempts = 6
          remuda._butler_agent_builders.claude = function() return {{"sh"}} end
          remuda._butler_agent_builders.codex = function() return {{"sh"}} end
          local rule = string.rep("─", 20)
          local screens = {{
            ["t-claude"] = {{
              rule .. "\n Accessing workspace:\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel",
              rule .. "\n❯ \n" .. rule,
            }},
            ["t-codex"] = {{
              "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version",
              "› Ask Codex to do anything",
            }},
            ["t-stuck"] = {{ " Some unknown dialog\n ❯ 1. No, exit" }},
          }}
          local log = {{}}
          remuda._t = log
          remuda.capture = function(n)
            local q = screens[n]
            if #q > 1 then return table.remove(q, 1) end
            return q[1]
          end
          remuda.capture_styled = nil
          remuda.key = function(n, k) log[#log + 1] = n .. " key " .. k end
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
          remuda._butler_topic_delegate("t-claude", "task one", nil, "claude", leader)
          remuda._butler_topic_delegate("t-codex", "task two", nil, "codex", leader)
          remuda._butler_topic_delegate("t-stuck", "task three", nil, "claude", leader)
        "#,
            home = home.to_string_lossy(),
            trace = trace.to_string_lossy(),
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(20);
    let log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        let traced = std::fs::read_to_string(&trace).unwrap_or_default();
        // The leader's "task not delivered" notice is typed too; count only
        // the topic sessions' own lines.
        let typed = log.lines().filter(|l| l.starts_with("t-") && l.contains(" type ")).count();
        if typed == 2 && traced.contains("task_poke_timeout\tt-stuck") {
            break log;
        }
        assert!(Instant::now() < deadline, "pokes never settled: {log}\n{traced}");
        std::thread::sleep(Duration::from_millis(100));
    };
    let claude: Vec<&str> = log.lines().filter(|l| l.starts_with("t-claude ")).collect();
    assert_eq!(claude, ["t-claude key <down>", "t-claude key RET", "t-claude type task one"]);
    let codex: Vec<&str> = log.lines().filter(|l| l.starts_with("t-codex ")).collect();
    assert_eq!(codex, ["t-codex key 2", "t-codex type task two"]);
    assert!(!log.contains("t-stuck "), "typed into an unknown dialog: {log}");
    assert!(log.contains(" type Butler message "), "the leader is told about t-stuck: {log}");
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
    std::fs::write(&inbox, "{\"message_id\":\"message-a\"}\n{\"message_id\":\"message-to").expect("torn");
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
    let out = eval(&path, &format!("{}\nreturn remuda._butler_mail.inbox(\"{id}\")", mail_config_lua(&root)));
    assert!(out.contains("body of a"), "the torn row's neighbour was lost: {out:?}");
    assert!(out.contains("the new delivery"), "the delivery after a torn row was lost: {out:?}");
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
    let first = eval(&path, &format!("{}\nreturn remuda._butler_mail.inbox(\"{id}\")", mail_config_lua(&root)));
    assert!(first.contains("body of a"), "{first:?}");
    for bad in ["message-missing", "message-corrupt"] {
        assert!(
            first.contains(&format!("message {bad}: envelope unreadable, left unread")),
            "{bad} was not reported: {first:?}"
        );
    }
    let read_ids = std::fs::read_to_string(&read).unwrap_or_default();
    assert!(read_ids.contains("message-a"), "the shown message was not marked read");
    assert!(!read_ids.contains("message-missing"), "an unloadable row was marked read");
    assert!(!read_ids.contains("message-corrupt"), "an unloadable row was marked read");
    let again = eval(&path, &format!("{}\nreturn remuda._butler_mail.inbox(\"{id}\")", mail_config_lua(&root)));
    assert!(again.contains("message message-missing: envelope unreadable"), "{again:?}");
    assert!(!again.contains("body of a"), "a read message came back: {again:?}");
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
    let first = eval(&path, &format!("{}\nreturn remuda._butler_mail.inbox(\"{id}\")", mail_config_lua(&root)));
    assert!(first.contains("message message-late: envelope unreadable, left unread"), "{first:?}");
    let count = eval(&path, &format!("return tostring(remuda._butler_mail.unread(\"{id}\"))"));
    assert_eq!(count, "0", "an unreadable id is not counted");

    std::fs::write(
        root.join("messages/message-late.json"),
        r#"{"id":"message-late","from":{"host":"local","session":"slow"},"subject":"Late","body":{"object_id":"object-late"}}"#,
    )
    .expect("late envelope");
    std::fs::write(root.join("objects/object-late"), "late body").expect("late object");
    let count = eval(&path, &format!("return tostring(remuda._butler_mail.unread(\"{id}\"))"));
    assert_eq!(count, "1", "a now-readable id is counted");
    let second = eval(&path, &format!("return remuda._butler_mail.inbox(\"{id}\")"));
    assert!(second.contains("late body"), "the late envelope was not delivered: {second:?}");
    assert!(!second.contains("envelope unreadable"), "{second:?}");
    let read_ids = std::fs::read_to_string(&read).unwrap_or_default();
    assert!(read_ids.contains("message-late"), "the delivered id was not marked read");
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
    assert_eq!(v[7], format!("{a},{b}"), "references = parent's references + parent");
    assert_eq!(v[8], b);
    let envelope = std::fs::read_to_string(root.join(format!("messages/{c}.json"))).unwrap();
    assert!(envelope.contains(&format!(r#""in_reply_to":"{b}""#)), "{envelope}");
    assert!(envelope.contains(&format!(r#""references":["{a}","{b}"]"#)), "{envelope}");

    let fresh = eval(&path, &format!("{}\nreturn M.inbox(F.id)", reply_prelude(&root)));
    assert!(fresh.contains(&format!("  in reply to {b} (thread {a})")), "{fresh}");
    assert!(fresh.contains("thanks") && fresh.contains("question"), "{fresh}");
}

/// JWZ safety: a missing parent keeps the thread, a self-reference is
/// dropped; an envelope from before threading replies like a root.
#[test]
fn butler_mail_reply_tolerates_old_missing_and_self_referencing_parents() {
    let dir = scratch_dir("butler-mail-jwz");
    let (root, f_inbox, _) = seeded_mail_root(&dir, REPLY_F);
    let from_b = format!(r#""from":{{"host":"local","id":"{REPLY_B}","alias":"butler","kind":"","leader":"","session":"butler"}}"#);
    for (id, extra) in [
        ("message-old", String::new()),
        ("message-orphan", r#","in_reply_to":"message-gone""#.to_string()),
        ("message-selfref", r#","in_reply_to":"message-selfref","references":["message-selfref"]"#.to_string()),
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
    assert_eq!(v[0], "message-old|butler", "an old envelope is a thread root");
    assert_eq!(v[1], "message-gone,message-orphan|butler", "a missing parent still threads");
    assert_eq!(v[2], "message-selfref|butler", "a self-reference is dropped, never looped");
    assert!(v[3].contains("not delivered"), "reply is only for mail delivered to you: {out}");
    assert!(v[4].contains("no Butler inbox"), "operator has no inbox to reply to: {out}");
    let b_view = eval(&path, &format!("{}\nreturn M.inbox(B.id)", reply_prelude(&root)));
    assert!(b_view.contains("in reply to message-orphan (thread message-gone)"), "{b_view}");
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
    let a = eval(&path, &format!("{prelude}\nreturn assert(M.queue(B, F, \"question\")).id"));
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
    assert!(v[0].contains("already delivered to worker"), "loop guard: {out}");
    assert!(v[1].contains("already delivered to fixer"), "loop guard back: {out}");
    assert!(v[2].contains("not delivered"), "only your own mail: {out}");
    assert_eq!(std::fs::read(&envelope).unwrap(), before, "the original envelope is never rewritten");
    let row = std::fs::read_to_string(root.join(format!("inboxes/{}.jsonl", hex_component(REPLY_W)))).unwrap();
    assert!(row.contains(&format!(r#""message_id":"{a}","resent":{{"#)) && row.contains("note_object_id"), "{row}");

    let fresh = eval(&path, &format!("{prelude}\nreturn M.inbox(W.id)"));
    assert!(fresh.contains(&format!("[{a} from local/butler ")), "original sender kept: {fresh}");
    assert!(fresh.contains("  forwarded by fixer to worker at ") && fresh.contains(": see para 2"), "{fresh}");
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
    assert_eq!(v[0], "1", "the forwarder reading it leaves the target unread");
    assert_eq!(v[1], "true", "the target still sees it");
    assert_eq!(v[2], "inbox empty", "the target reading it does not re-open the forwarder's copy");
    assert_eq!(v[3], "butler", "a reply to forwarded mail goes to the original sender");
    assert_eq!(v[4], "threaded");
}

/// rename() replaces silently; an id collision must fail loudly instead of
/// clobbering the earlier message (NOTES.md checklist #6, Maildir/nmh link()).
#[test]
fn butler_mail_refuses_to_overwrite_an_existing_message_on_an_id_collision() {
    let dir = scratch_dir("butler-mail-collide");
    let (root, f_inbox, _) = seeded_mail_root(&dir, REPLY_F);
    let collision_id = "00000000000000000000000000";
    std::fs::write(root.join(format!("messages/{collision_id}.json")), "ORIGINAL").unwrap();
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
    assert!(out.starts_with("true|nil|") && out.contains("already exists"), "not refused loudly: {out}");
    assert_eq!(std::fs::read_to_string(root.join(format!("messages/{collision_id}.json"))).unwrap(), "ORIGINAL");
    assert!(!std::fs::read_to_string(&f_inbox).unwrap_or_default().contains(collision_id), "a row was committed");
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
fn butler_matrix_mail_envelope_is_durable_and_deduplicated_across_daemon_restarts() {
    let dir = scratch_dir("matrix-mail");
    let (root, _, _) = seeded_mail_root(&dir, REPLY_F);
    let path = daemon::socket_path_in(&dir, "s");
    let body = "line one\n\t\\line two";
    let matrix = r#"{ sender = "@alice:example.org", room_id = "!inbound:example.org",
      event_id = "$matrix-event", thread_root = "$thread-root", in_reply_to = "$parent",
      mxc = "mxc://media/example", created_at = "2026-09-28T01:02:03Z" }"#;

    let daemon = Daemon::spawn(&dir);
    let first = eval(
        &path,
        &format!(
            r#"{}
               local from = {{ host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }}
               local a = assert(M.queue(from, F, {body}, nil, nil, nil, {matrix}))
               local b = assert(M.queue(from, F, {body}, nil, nil, nil, {matrix}))
               return a.id .. "\n" .. b.id"#,
            reply_prelude(&root),
            body = lua_raw_string(body),
        ),
    );
    let ids: Vec<&str> = first.lines().collect();
    assert_eq!(ids.len(), 2, "expected both queue calls to return an id: {first}");
    assert_eq!(ids[0], ids[1], "replaying one Matrix event made a second mail envelope");
    let envelope = std::fs::read_to_string(root.join(format!("messages/{}.json", ids[0])))
        .expect("persisted Matrix mail envelope");
    let envelope_value: serde_json::Value = serde_json::from_str(&envelope).expect("valid mail envelope JSON");
    let object_id = envelope_value["body"]["object_id"].as_str().expect("body object id");
    assert_eq!(std::fs::read_to_string(root.join("objects").join(object_id)).expect("body object"), body,
        "newline, tab and backslash bytes must survive the Matrix handoff unchanged");
    assert!(envelope.contains(r#""sender":"@alice:example.org""#), "{envelope}");
    assert!(envelope.contains(r#""room_id":"!inbound:example.org""#), "{envelope}");
    assert!(envelope.contains(r#""event_id":"$matrix-event""#), "{envelope}");
    assert!(envelope.contains(r#""thread_root":"$thread-root""#), "{envelope}");
    assert!(envelope.contains(r#""in_reply_to":"$parent""#), "{envelope}");
    assert!(envelope.contains(r#""mxc":"mxc://media/example""#), "{envelope}");
    assert!(envelope.contains(r#""created_at":"2026-09-28T01:02:03Z""#), "{envelope}");
    drop(daemon);

    let _restarted = Daemon::spawn(&dir);
    let after_restart = eval(
        &path,
        &format!(
            r#"{}
               local from = {{ host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }}
               local message = assert(M.queue(from, F, {body}, nil, nil, nil, {matrix}))
               return table.concat({{ message.id, message.matrix.thread_root or "", message.matrix.in_reply_to or "", message.matrix.mxc or "" }}, "\n")"#,
            reply_prelude(&root),
            body = lua_raw_string(body),
        ),
    );
    assert_eq!(after_restart, format!("{}\n$thread-root\n$parent\nmxc://media/example", ids[0]),
        "a restarted mail store did not deduplicate the Matrix event or restore its metadata");
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
    let queued_id = sent.strip_prefix("queued ").and_then(|s| s.split_whitespace().next()).unwrap_or("");
    assert!(queued_id.len() == 26 && queued_id.bytes().all(|b| b"0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(&b)), "{sent:?}");
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
    let matrix_relay = include_str!("../../packages/butler/matrix_relay.lua").replace("\r\n", "\n");

    let launch_fn_idx = main_lua
        .find("local function launch_butler()")
        .expect("butler package lost its shared launch function");
    assert!(
        !main_lua.contains("remuda.clear_hooks(") && !main_lua.contains("remuda.hooks[event]"),
        "Butler reload must rely on lifecycle ownership, not hook purges"
    );
    assert!(
        matrix_init.contains("stop = function(state)")
            && matrix_init.contains("pcall(matrix.relay.stop)")
            && matrix_init.contains("matrix.relay.start(host._butler_matrix_config)")
            && matrix_impl.contains("matrix.relay.start(remuda._butler_matrix_config)")
            && matrix_relay.contains("function instance:stop()")
            && matrix_relay.contains("request_handle:cancel()")
            && !main_lua.contains("pkill -f"),
        "the async Matrix relay must be cancelled through its public lifecycle table"
    );
    assert!(
        init_lua.contains("event = \"session_exited\", id = \"identity\"")
            && main_lua.contains("function remuda._butler_session_exited(name)")
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

/// The schedule end to end, on a real spawned `sh` standing in for the
/// launched `claude` session -- the same substitution
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
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");

    eval(&path, "remuda._butler_compaction_interval = 0.05");
    eval(&path, r#"remuda._butler_argv = {"sh"}"#);
    eval(&path, "remuda._butler_skip_relay = true");

    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );

    let butler_name = eval(&path, "return remuda._butler_initial_name");
    eval(
        &path,
        r#"remuda._butler_telemetry_for = function() return { context_used = "500000" } end; remuda.capture = function() return "mock screen" end; remuda._butler_prompt_is_empty = function() return "EMPTY" end"#,
    );

    // Simulates the launched session's own one-time `run_script` call the
    // system prompt asks for.
    eval(&path, "remuda._butler_register_compaction_schedule()");

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
    eval(
        &path,
        r#"remuda._butler_telemetry_for = function() return { context_used = "500000" } end; remuda.capture = function() return "mock screen" end; remuda._butler_prompt_is_empty = function() return "EMPTY" end"#,
    );

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
        eval(&path, "local m = remuda.butler and remuda.butler.matrix; return tostring(remuda._butler_matrix_config == nil and (not m or not m.relay or m.relay.instance == nil))"),
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
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}; remuda._butler_skip_relay = true"#);
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    let rows = std::fs::read_to_string(&agents).expect("read agents.jsonl");
    let last = |id: &str| rows.lines().filter(|l| l.contains(id)).last().unwrap_or_default().to_string();
    let count = |id: &str| rows.lines().filter(|l| l.contains(&format!(r#""id":"{id}""#))).count();
    assert!(last("01GHST").contains("ended_at"), "{rows}");
    assert_eq!(count("01DNE000000000000000000000"), 1, "an ended identity is not re-ended: {rows}");
    assert!(!last(r#""id":"01ROOT"#).contains("ended_at"), "the root stays live: {rows}");
    assert!(eval(&path, "return remuda._butler_bus.identities.ghost.ended_at ~= nil") == "true");
    drop(daemon);
}

#[test]
fn butler_matrix_read_composites_use_async_request_for_history_and_thread_pages() {
    let dir = scratch_dir("butler-matrix-read");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!read:example.org";
    let (token_path, config_path) = butler_config(&dir, "read", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_read')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));

    let result = eval(&path, r#"
      local matrix = remuda.butler.matrix
      local room = "!read:example.org"
      local encoded_room = "%21read%3Aexample.org"
      local history_url = "http://matrix.example.org/_matrix/client/v3/rooms/" .. encoded_room .. "/messages?dir=b&limit=25"
      remuda.http.respond("GET", history_url, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$h"}]}' })
      local history
      matrix.history({ n = 25 }, function(value) history = value end)
      if history then return "history-callback-inline" end
      remuda.http.tick()
      if not history or not history.json or history.json.chunk[1].event_id ~= "$h" then return "history-result" end
      if remuda.http.calls[1].headers.Authorization ~= "Bearer test-token" then return "history-auth" end
      local invalid
      matrix.history({ n = 201 }, function(value) invalid = value end)
      if not invalid or not invalid.error or #remuda.http.calls ~= 1 then return "history-bound" end

      local first = "http://matrix.example.org/_matrix/client/v1/rooms/" .. encoded_room
        .. "/relations/%24root/m.thread?dir=b&limit=100"
      local second = first .. "&from=page%2F2"
      remuda.http.respond("GET", first, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$a"}],"next_batch":"page/2"}' })
      remuda.http.respond("GET", second, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$b"}]}' })
      local thread
      matrix.thread({ event_id = "$root" }, function(value) thread = value end)
      for _ = 1, 6 do remuda.http.tick() end
      if not thread or #thread.json.chunk ~= 2 then return "thread-pages" end
      if thread.json.chunk[1].event_id ~= "$a" or thread.json.chunk[2].event_id ~= "$b" then return "thread-order" end
      if #remuda.http.calls ~= 3 then return "thread-request-count" end
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/joined_rooms",
        { status = 200, headers = {}, body = '{"joined_rooms":["!read:example.org"]}' })
      local rooms
      matrix.rooms({}, function(value) rooms = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not rooms or rooms.json.joined_rooms[1] ~= room then return "rooms-result" end
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/rooms/" .. encoded_room .. "/event/%24event",
        { status = 200, headers = {}, body = '{"event_id":"$event","room_id":"!read:example.org"}' })
      local event
      matrix.event({ event_id = "$event" }, function(value) event = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not event or event.json.event_id ~= "$event" or event.json.room_id ~= room then return "event-result" end
      if #remuda.http.calls ~= 5 then return "read-request-count" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "read composites should page asynchronously through matrix.request: {result}");
}

#[test]
fn butler_matrix_read_status_and_download_keep_cursor_and_media_bounds() {
    let dir = scratch_dir("butler-matrix-read-media");
    let (_daemon, path) = butler_test_daemon(&dir);
    let (token_path, config_path) = butler_config(&dir, "read-media", "http://matrix.example.org",
        "!read:example.org", "@bot:example.org", "");
    std::fs::write(PathBuf::from(format!("{}.since", config_path.display())),
        r#"{"since":"s-7","messages_since":"m-4"}"#).expect("write saved cursors");
    let output = dir.join("download.bin");
    let empty_output = dir.join("empty-download.bin");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_read')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));

    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/account/whoami",
        {{ status = 200, headers = {{}}, body = '{{"user_id":"@bot:example.org","device_id":"D1"}}' }})
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/joined_rooms",
        {{ status = 200, headers = {{}}, body = '{{"joined_rooms":["!read:example.org"]}}' }})
      local status
      matrix.status({{}}, function(value) status = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not status or status.json.user_id ~= "@bot:example.org" or status.json.device_id ~= "D1" then return "status-identity" end
      if status.json.sync_cursor ~= "s-7" or status.json.fallback_cursor ~= "m-4" then return "status-cursor" end
      local v1 = "http://matrix.example.org/_matrix/client/v1/media/download/media.example/asset%3A1"
      local legacy = "http://matrix.example.org/_matrix/media/v3/download/media.example/asset%3A1"
      remuda.http.respond("GET", v1, {{ status = 404, headers = {{}}, body = '{{"errcode":"M_NOT_FOUND"}}' }})
      remuda.http.respond("GET", legacy, {{ status = 200, headers = {{ ["content-type"] = "application/octet-stream" }}, body = string.char(0, 255) .. "binary" }})
      local media
      matrix.download({{ mxc = "mxc://media.example/asset:1", output = {} }}, function(value) media = value end)
      for _ = 1, 6 do remuda.http.tick() end
      if not media or media.bytes ~= 8 then return "download-result:" .. tostring(media and media.error) .. ":bytes=" .. tostring(media and media.bytes) .. ":calls=" .. #remuda.http.calls end
      if remuda.http.calls[3].max_bytes ~= 20 * 1024 * 1024 or remuda.http.calls[4].max_bytes ~= 20 * 1024 * 1024 then return "download-cap" end
      if remuda.http.calls[3].headers.Accept ~= "*/*" or remuda.http.calls[4].headers.Authorization ~= "Bearer test-token" then return "download-headers" end
      local empty_url = "http://matrix.example.org/_matrix/client/v1/media/download/media.example/empty"
      remuda.http.respond("GET", empty_url, {{ status = 200, headers = {{}}, body = "" }})
      local empty
      matrix.download({{ mxc = "mxc://media.example/empty", output = {} }}, function(value) empty = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not empty or empty.error or empty.bytes ~= 0 then return "empty-download" end
      local relative
      matrix.download({{ mxc = "mxc://media.example/asset", output = "relative.bin" }}, function(value) relative = value end)
      if not relative or not relative.error or #remuda.http.calls ~= 5 then return "relative-output" end
      return "ok"
    "#, lua_raw_string(&output.to_string_lossy()), lua_raw_string(&empty_output.to_string_lossy())));
    assert_eq!(result, "ok", "status and media reads should remain bounded and authenticated: {result}");
    assert_eq!(std::fs::read(output).expect("read downloaded bytes"), b"\0\xffbinary");
    assert_eq!(std::fs::read(empty_output).expect("read empty downloaded file"), b"");
}

#[test]
fn butler_matrix_fake_http_matches_core_cancellation_bounds_and_headers() {
    let dir = scratch_dir("butler-http-fake-parity");
    let (_daemon, path) = butler_test_daemon(&dir);
    eval(&path, include_str!("support/fake_http.lua"));
    let result = eval(&path, r#"
      local url = "http://matrix.example.org/parity"
      local function request(extra, callback)
        local spec = { method = "GET", url = url, timeout = 3, callback = callback }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return remuda.http.request(spec)
      end
      local cancelled, count = nil, 0
      local handle = request({}, function(value) cancelled = value; count = count + 1 end)
      handle:cancel()
      remuda.http.tick()
      if not cancelled or cancelled.error ~= "request cancelled" or count ~= 1 then return "cancel-not-once" end
      remuda.http.tick()
      if count ~= 1 then return "cancel-delivered-twice" end

      local too_big
      remuda.http.respond("GET", url, { status = 200, headers = {}, body = "12345" })
      request({ max_bytes = 4 }, function(value) too_big = value end)
      remuda.http.tick()
      if not too_big or too_big.error ~= "response exceeds max_bytes" or too_big.status then return "max-bytes" end

      local normalized
      remuda.http.respond("GET", url, { status = 200,
        headers = { ["Content-Type"] = "application/json", ["CONTENT-TYPE"] = "text/plain",
          ["Set-Cookie"] = { "a=1", "b=2" } }, body = "{}" })
      request({}, function(value) normalized = value end)
      if normalized then return "callback-ran-inline" end
      remuda.http.tick()
      local content_type = normalized.headers["content-type"]
      if content_type ~= "application/json, text/plain" and content_type ~= "text/plain, application/json" then
        return "duplicate-header:" .. tostring(normalized.headers["content-type"])
      end
      if type(normalized.headers["set-cookie"]) ~= "table" or normalized.headers["set-cookie"][2] ~= "b=2" then
        return "set-cookie"
      end
      local invalid
      request({ timeout = 3601 }, function(value) invalid = value end)
      remuda.http.tick()
      if not invalid or not invalid.error then return "invalid-timeout-accepted" end
      local oversized
      request({ max_bytes = 20 * 1024 * 1024 + 1 }, function(value) oversized = value end)
      remuda.http.tick()
      if not oversized or oversized.error ~= "max_bytes exceeds 20 MiB" then return "oversized-limit-accepted" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "fake HTTP transport semantics should match core: {result}");
}

#[test]
fn butler_matrix_real_http_binding_delivers_unreachable_local_error() {
    let dir = scratch_dir("butler-real-http-smoke");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!smoke:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "real-http", "http://127.0.0.1:1", room, "@bot:example.org", "",
    );
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    eval(&path, r#"
      remuda._butler_real_http_result = nil
      remuda.butler.matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami", timeout = 2 },
        function(value) remuda._butler_real_http_result = value end)
    "#);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let result = eval(&path, r#"
          local value = remuda._butler_real_http_result
          if not value then return "pending" end
          if not value.error then return "missing-error" end
          if value.status ~= nil or value.headers ~= nil or value.body ~= nil then return "failure-has-response-fields" end
          return "error:" .. value.error
        "#);
        if result != "pending" {
            assert!(result.starts_with("error:"), "real remuda.http failure shape: {result}");
            return;
        }
        assert!(Instant::now() < deadline, "real remuda.http callback did not arrive");
        std::thread::sleep(Duration::from_millis(40));
    }
}

#[test]
fn butler_matrix_cancellation_completes_queued_inflight_and_held_once() {
    let dir = scratch_dir("butler-matrix-cancel");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!cancel:example.org";
    let (token_path, config_path) = butler_config(&dir, "cancel", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, &format!(r#"
      local matrix, room = remuda.butler.matrix, "{room}"
      local first_result, queued_result, queued_count
      queued_count = 0
      local first = matrix.request({{ method = "GET", path = "/_matrix/client/v3/first" }}, function(value) first_result = value end)
      local queued = matrix.request({{ method = "GET", path = "/_matrix/client/v3/queued" }}, function(value)
        queued_result = value; queued_count = queued_count + 1 end)
      queued:cancel()
      queued:cancel()
      if not queued_result or queued_result.error ~= "cancelled" or queued_count ~= 1 then return "queued-cancel-not-completed-once" end
      if #remuda.http.calls ~= 1 then return "queued-cancel-consumed-network-slot" end
      first:cancel()
      first:cancel()
      remuda.http.tick()
       if not first_result or first_result.error ~= "request cancelled" then return "inflight-cancel-not-reported" end
      local count = 0
      local held_url = "https://matrix.example.org/_matrix/client/v3/sync?timeout=30000"
      remuda.http.hold("GET", held_url)
       local held = remuda.http.request({{ method = "GET", url = held_url, timeout = 35, callback = function(value)
         count = count + 1; if value.error ~= "request cancelled" then count = 99 end end }})
      remuda.http.tick()
      held:cancel()
      held:cancel()
      remuda.http.tick()
      if count ~= 1 then return "held-cancel-not-reported-once" end
      local completed_count = 0
      local complete_url = "https://matrix.example.org/_matrix/client/v3/complete"
      remuda.http.respond("GET", complete_url, {{ status = 200, headers = {{}}, body = "{{}}" }})
       local completed = remuda.http.request({{ method = "GET", url = complete_url, timeout = 10, callback = function()
        completed_count = completed_count + 1 end }})
      remuda.http.tick()
      completed:cancel()
      remuda.http.tick()
      if completed_count ~= 1 then return "completed-cancel-was-not-a-noop" end
      return "ok"
    "#));
    assert_eq!(result, "ok", "Matrix cancellation must settle queued, in-flight, and held calls once: {result}");
}

#[test]
fn butler_matrix_send_chunks_utf8_async_and_rejects_empty_or_dash() {
    let dir = scratch_dir("butler-matrix-send");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!write:example.org";
    let (token_path, config_path) = butler_config(&dir, "write", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, r#"
      local matrix = remuda.butler.matrix
      local sent, empty, dash
      matrix.send({ text = "", room = "!write:example.org" }, function(v) empty = v end)
      if not empty or not empty.error or #remuda.http.calls ~= 0 then return "empty-send-not-rejected" end
      remuda.http.respond_prefix("PUT",
        "http://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$sent"}' })
      matrix.send({ text = "-", room = "!write:example.org" }, function(v) dash = v end)
      if dash or #remuda.http.calls ~= 1 then return "dash-not-sent-literally" end
      remuda.http.tick()
      if not dash or dash.error then return "dash-send-failed" end
      local dash_body = matrix.decode_json(remuda.http.calls[1].body)
      if not dash_body or dash_body.body ~= "-" then return "dash-body-not-literal" end
      matrix.send({ text = string.rep("한", 2000), room = "!write:example.org" }, function(value) sent = value end)
      if sent then return "send-callback-ran-inline" end
      if #remuda.http.calls ~= 1 then return "first-chunk-not-queued" end
      for _ = 1, 4 do remuda.http.tick() end
      if not sent or sent.error then return "send-failed" end
      if sent.sent ~= 2 or #remuda.http.calls ~= 3 then return "wrong-chunk-count" end
      local combined, previous = {}, nil
      for index, spec in ipairs(remuda.http.calls) do
        local body = matrix.decode_json(spec.body)
        if not body or #body.body > 4000 then return "chunk-over-4000-bytes" end
        if index > 1 then combined[#combined + 1] = body.body end
        local txn = spec.url:match("/send/m%.room%.message/(.+)$")
        if not txn or txn == previous then return "transaction-id-not-unique" end
        previous = txn
      end
      if table.concat(combined) ~= string.rep("한", 2000) then return "utf8-chunking-lost-data" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "Matrix send should compose bounded async requests: {result}");
}

#[test]
fn butler_matrix_transaction_ids_change_across_daemon_restarts() {
    fn txn_in_fresh_daemon(tag: &str) -> String {
        let dir = scratch_dir(tag);
        let (_daemon, path) = butler_test_daemon(&dir);
        let room = "!txn:example.org";
        let (token_path, config_path) = butler_config(&dir, tag, "http://matrix.example.org",
            room, "@bot:example.org", "");
        eval(&path, include_str!("support/fake_http.lua"));
        eval(&path, &format!(
            "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
            lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
        let result = eval(&path, r#"
          remuda.butler.matrix.send({ text = "txn", room = "!txn:example.org" }, function() end)
          return remuda.http.calls[1].url
        "#);
        result.rsplit('/').next().unwrap().to_owned()
    }
    let first = txn_in_fresh_daemon("butler-matrix-txn-first");
    let second = txn_in_fresh_daemon("butler-matrix-txn-second");
    assert_ne!(first, second, "transaction IDs must not collide after a daemon restart");
    assert!(first.len() >= 45 && second.len() >= 45, "transaction IDs must include startup entropy");
}

#[test]
fn butler_matrix_reply_react_upload_redact_join_and_leave_compose_request() {
    let dir = scratch_dir("butler-matrix-write-words");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!write:example.org";
    let (token_path, config_path) = butler_config(&dir, "write", "https://matrix.example.org",
        room, "@bot:example.org", "");
    std::fs::write(&config_path, format!(
        "https://matrix.example.org\n{room}\n@bot:example.org\n\npin_sha256={}\n", "00".repeat(32)))
        .expect("write pinned HTTPS Matrix config");
    let media_path = dir.join("image.png");
    std::fs::write(&media_path, b"png-bytes").expect("write upload fixture");
    let media_path_lua = lua_raw_string(&media_path.to_string_lossy());
    let directory_path_lua = lua_raw_string(&dir.to_string_lossy());
    let large_path = dir.join("too-large.bin");
    std::fs::write(&large_path, vec![0u8; 20 * 1024 * 1024 + 1]).expect("write oversized upload fixture");
    let large_path_lua = lua_raw_string(&large_path.to_string_lossy());
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, &format!(r#"
      local matrix, room = remuda.butler.matrix, "{room}"
      local function response(body) return {{ status = 200, headers = {{}}, body = body }} end
      remuda.http.respond_prefix("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/context/",
        response('{{"event":{{"room_id":"{room}"}}}}'))
      remuda.http.respond_prefix("PUT", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/send/m.room.message/",
        response('{{"event_id":"$reply"}}'))
      remuda.http.respond_prefix("PUT", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/send/m.reaction/",
        response('{{"event_id":"$react"}}'))
      remuda.http.respond_prefix("POST", "https://matrix.example.org/_matrix/media/v3/upload?filename=image.png",
        response('{{"content_uri":"mxc://example.org/media"}}'))
      remuda.http.respond_prefix("PUT", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/send/m.image/",
        response('{{"event_id":"$image"}}'))
      remuda.http.respond_prefix("PUT", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/redact/%24redact/",
        response('{{"event_id":"$redact"}}'))
      remuda.http.respond("POST", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/join", response("{{}}"))
      remuda.http.respond("POST", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/leave", response("{{}}"))
      local function ticks(n) for _ = 1, n do remuda.http.tick() end end
      local agent_error
      matrix.join({{ room = room }}, function(value) agent_error = value end, "agent1")
      if not agent_error or not agent_error.error or #remuda.http.calls ~= 0 then return "agent-join-not-refused" end
      local outside, before_outside = nil, #remuda.http.calls
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/context/%24outside",
        response('{{"event":{{"room_id":"!other:example.org"}}}}'))
      matrix.reply({{ room = room, event_id = "$outside", text = "must not send" }}, function(value) outside = value end)
      ticks(3)
      if not outside or not outside.error or #remuda.http.calls ~= before_outside + 1 then return "cross-room-reply-sent" end
      local context_error, before_error = nil, #remuda.http.calls
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/context/%24broken",
        {{ error = "injected context failure" }})
      matrix.reply({{ room = room, event_id = "$broken", text = "must not send" }}, function(value) context_error = value end)
      ticks(3)
      if not context_error or not context_error.error or #remuda.http.calls ~= before_error + 1 then return "context-error-sent-reply" end
      local reply
      matrix.reply({{ room = room, event_id = "$reply-source", text = "reply text" }}, function(value) reply = value end)
      ticks(4)
      if not reply or reply.error then return "reply-failed:" .. tostring(reply and reply.error or "no callback")
        .. "|calls=" .. tostring(#remuda.http.calls) .. "|last=" .. tostring(remuda.http.calls[#remuda.http.calls] and remuda.http.calls[#remuda.http.calls].url) end
      local react
      matrix.react({{ room = room, event_id = "$react-source", key = "👍" }}, function(value) react = value end)
      ticks(4)
      if not react or react.event_id ~= "$react" then return "react-failed" end
      local redact
      matrix.redact({{ room = room, event_id = "$redact", reason = "cleanup" }}, function(value) redact = value end)
      ticks(3)
      if not redact or redact.event_id ~= "$redact" then return "redact-failed" end
      local upload
      matrix.upload({{ room = room, file = {media_path_lua} }}, function(value) upload = value end)
      ticks(5)
      if not upload or upload.event_id ~= "$image" or upload.content_uri ~= "mxc://example.org/media" then return "upload-failed" end
      local upload_timeout
      for _, spec in ipairs(remuda.http.calls) do
        if spec.method == "POST" and spec.url:find("/media/v3/upload?", 1, true) then upload_timeout = spec.timeout end
      end
      if upload_timeout ~= 60 then return "upload-timeout-not-60s:" .. tostring(upload_timeout) end
      local relative
      matrix.upload({{ room = room, file = "relative.png" }}, function(value) relative = value end)
      if not relative or not relative.error or not relative.error:find("absolute path", 1, true) then return "relative-upload-accepted" end
      local empty_path = {media_path_lua} .. ".empty"
      local empty_file = assert(io.open(empty_path, "wb")); empty_file:close()
      local empty_upload, empty_raised
      local empty_ok = pcall(function()
        matrix.upload({{ room = room, file = empty_path }}, function(value) empty_upload = value end)
      end)
      empty_raised = not empty_ok
      if empty_raised or not empty_upload or not empty_upload.error then return "empty-upload-not-rejected-safely" end
      local directory_upload, directory_raised
      local directory_ok = pcall(function()
        matrix.upload({{ room = room, file = "{directory_path_lua}" }}, function(value) directory_upload = value end)
      end)
      directory_raised = not directory_ok
      if directory_raised then return "directory-upload-raised" end
      if not directory_upload or not directory_upload.error then return "directory-upload-not-rejected" end
      local before_large = #remuda.http.calls
      local oversized
      matrix.upload({{ room = room, file = "{large_path_lua}" }}, function(value) oversized = value end)
      if not oversized or not oversized.error or #remuda.http.calls ~= before_large then return "oversized-upload-not-rejected" end
      local joined, left
      matrix.join({{ room = room }}, function(value) joined = value end)
      ticks(3)
      matrix.leave({{ room = room }}, function(value) left = value end)
      ticks(3)
      if not joined or joined.error or not left or left.error then return "join-leave-failed" end
      local bodies = {{}}
      for _, spec in ipairs(remuda.http.calls) do
        if spec.body and spec.headers["Content-Type"] == "application/json" then
          bodies[#bodies + 1] = matrix.decode_json(spec.body)
        end
      end
      local found_reply, found_react, found_redact, found_file = false, false, false, false
      for _, body in ipairs(bodies) do
        if body["m.relates_to"] and body["m.relates_to"]["m.in_reply_to"] then found_reply = body["m.relates_to"]["m.in_reply_to"].event_id == "$reply-source" end
        if body["m.relates_to"] and body["m.relates_to"].rel_type == "m.annotation" then found_react = body["m.relates_to"].key == "👍" end
        if body.reason == "cleanup" then found_redact = true end
        if body.msgtype == "m.image" and body.url == "mxc://example.org/media" then found_file = true end
      end
      if not found_reply or not found_react or not found_redact or not found_file then return "wrong-write-content" end
      local joined_route, left_route = false, false
      for _, spec in ipairs(remuda.http.calls) do
        if spec.url:match("/join$") then joined_route = spec.method == "POST" and spec.body == "{{}}" end
        if spec.url:match("/leave$") then left_route = spec.method == "POST" and spec.body == "{{}}" end
      end
      if not joined_route or not left_route then return "wrong-room-route" end
      return "ok"
    "#));
    assert_eq!(result, "ok", "Matrix write verbs should compose only request and same_room: {result}");
}

#[test]
fn butler_matrix_cli_pending_routes_async_send_and_serializes_json() {
    let dir = scratch_dir("butler-matrix-cli-pending");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!cli:example.org";
    let (token_path, config_path) = butler_config(&dir, "cli", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    eval(&path, &format!(r#"
      remuda.http.respond_prefix("PUT", "http://matrix.example.org/_matrix/client/v3/rooms/%21cli%3Aexample.org/send/m.room.message/",
        {{ status = 200, headers = {{}}, body = '{{"event_id":"$cli"}}' }})
    "#));
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "--json", "--room", room, "send", "hello async"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn().expect("spawn Matrix CLI command");
    let deadline = Instant::now() + PATIENCE;
    loop {
        let call_count = eval(&path, "return #remuda.http.calls");
        if call_count == "1" { break; }
        assert!(Instant::now() < deadline, "Matrix CLI never dispatched its async send");
        assert!(child.try_wait().expect("poll Matrix CLI").is_none(),
            "Matrix CLI exited before its async result arrived");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(child.try_wait().expect("poll pending Matrix CLI").is_none(),
        "extension command must remain pending until its async callback");
    eval(&path, "remuda.http.tick()");
    let output = child.wait_with_output().expect("collect Matrix CLI output");
    assert!(output.status.success(), "Matrix CLI failed: {}", String::from_utf8_lossy(&output.stderr));
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).expect("parse Matrix CLI JSON");
    assert_eq!(json["sent"], 1);
    assert_eq!(json["event_ids"][0], "$cli");
    assert!(output.stderr.is_empty(), "successful Matrix CLI wrote stderr");

    eval(&path, r#"
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/rooms/%21cli%3Aexample.org/event/%24event",
        { status = 200, headers = {}, body = '{"event_id":"$event","sender":"@a:example.org","content":{"body":"found"}}' })
    "#);
    let mut get = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "--json", "--room", room, "get", "$event"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn().expect("spawn Matrix event alias command");
    let deadline = Instant::now() + PATIENCE;
    loop {
        if eval(&path, "remuda.http.tick(); return #remuda.http.calls") == "2" { break; }
        assert!(Instant::now() < deadline, "event|get alias never dispatched");
        assert!(get.try_wait().expect("poll event alias").is_none(), "event|get returned before callback");
        std::thread::sleep(Duration::from_millis(10));
    }
    eval(&path, "remuda.http.tick()");
    let output = get.wait_with_output().expect("collect event alias output");
    assert!(output.status.success(), "event|get failed: {}", String::from_utf8_lossy(&output.stderr));
    let event: serde_json::Value = serde_json::from_slice(&output.stdout).expect("parse event alias JSON");
    assert_eq!(event["json"]["event_id"], "$event");
}

#[test]
fn butler_matrix_cli_client_disconnect_cancels_active_word() {
    let dir = scratch_dir("butler-matrix-cli-cancel");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!cli-cancel:example.org";
    let (token_path, config_path) = butler_config(&dir, "cli-cancel", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, r#"
      local pending = remuda.pending
      remuda.pending = function(options)
        remuda._test_pending_on_cancel = options.on_cancel
        return pending(options)
      end
    "#);
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "--json", "--room", room, "send", "cancel me"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn().expect("spawn cancellable Matrix CLI command");
    let deadline = Instant::now() + PATIENCE;
    loop {
        if eval(&path, "return #remuda.http.calls") == "1" { break; }
        assert!(Instant::now() < deadline, "Matrix CLI never started cancellable work");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(child.try_wait().expect("poll cancellable CLI").is_none(), "outstanding async work should keep CLI pending");
    child.kill().expect("disconnect CLI client");
    let _ = child.wait_with_output().expect("reap disconnected CLI");
    let cancelled = eval(&path, r#"
      assert(type(remuda._test_pending_on_cancel) == "function", "CLI did not register on_cancel")
      remuda._test_pending_on_cancel("client_disconnected")
      remuda.http.tick()
      return tostring(remuda.http.pending[1].cancelled)
    "#);
    assert_eq!(cancelled, "true", "pending cancellation must cancel the active Matrix word");
}

#[test]
fn butler_matrix_cli_refuses_send_dash_and_fails_cleanly_without_pending() {
    let dir = scratch_dir("butler-matrix-cli-compat");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!cli:example.org";
    let (token_path, config_path) = butler_config(&dir, "cli", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let help = remuda_timed(&dir, &["-s", "s", "butler", "help"]);
    assert!(help.status.success(), "Butler help failed: {}", String::from_utf8_lossy(&help.stderr));
    let help = String::from_utf8_lossy(&help.stdout);
    assert!(help.contains("event|get EVENT_ID"), "help omitted the event alias row");
    assert!(help.contains("join ROOM (operator)"), "help omitted operator guidance");
    let dash = remuda_timed(&dir, &["-s", "s", "butler", "matrix", "send", "-"]);
    assert!(!dash.status.success(), "send - must be refused by CLI glue");
    assert!(String::from_utf8_lossy(&dash.stderr).contains("stdin"), "unexpected send - error: {}",
        String::from_utf8_lossy(&dash.stderr));
    assert_eq!(eval(&path, "return #remuda.http.calls"), "0", "send - unexpectedly touched Matrix");

    let agent_join = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "join", room])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "agent1")
        .output().expect("run agent join command");
    assert!(!agent_join.status.success(), "join must be operator-only");
    assert!(String::from_utf8_lossy(&agent_join.stderr).contains("operator-only"),
        "unexpected agent join error: {}", String::from_utf8_lossy(&agent_join.stderr));
    assert_eq!(eval(&path, "return #remuda.http.calls"), "0", "agent join reached the network");

    eval(&path, "remuda.pending = nil");
    let old_core = remuda_timed(&dir, &["-s", "s", "butler", "matrix", "--json", "rooms"]);
    assert!(!old_core.status.success(), "missing remuda.pending must fail nonzero");
    assert_eq!(String::from_utf8_lossy(&old_core.stderr).trim(),
        "Matrix CLI requires a remuda core with deferred replies (core #213/#239)");
}

#[test]
fn butler_matrix_guidance_covers_each_member_verb_and_omits_operator_verbs() {
    let dir = scratch_dir("butler-matrix-guidance");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let guidance = eval(&path, r#"
      for _, item in ipairs(remuda.contributions("butler.guidance")) do
        if item.owner == "butler" and item.id == "matrix" then
          return item.entry.agents_md({ parent = "leader" })
        end
      end
      return "missing Matrix guidance contribution"
    "#);
    let expected = [
        "Matrix is the human-facing adapter: never call the homeserver REST API or curl directly; use `remuda butler matrix [OPTIONS] VERB ARGS`. Options go BEFORE the verb (`--json` for machine output; `--room ROOM` defaults to the configured room).",
        "- `status`: whoami, joined rooms, and the sync cursor.",
        "- `[-n N] history`: recent messages in the room.",
        "- `rooms`: joined rooms (read-only).",
        "- `thread EVENT_ID`: all replies in a thread.",
        "- `event EVENT_ID` (alias `get`): one event.",
        "- `send TEXT`: post a message (long text is split, rate-limited); `send -` is refused until core #213.",
        "- `reply EVENT_ID TEXT` / `react EVENT_ID KEY`: answer or react (same room only).",
        "- `upload PATH`: post a file (up to 20 MB). `[-o PATH] download MXC`: fetch media.",
        "- `redact EVENT_ID [--reason TEXT]`: remove your message.",
    ];
    for line in expected {
        assert!(guidance.contains(line), "Matrix guidance omitted: {line}\n{guidance}");
    }
    assert!(!guidance.contains("join ROOM"), "operator join leaked into member guidance");
    assert!(!guidance.contains("leave ROOM"), "operator leave leaked into member guidance");
}
