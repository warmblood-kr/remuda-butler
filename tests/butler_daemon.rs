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
use std::io::Write;
use std::path::{Path, PathBuf};
use std::os::unix::process::CommandExt;
use std::sync::Arc;
use std::time::{Duration, Instant};

const PATIENCE: Duration = Duration::from_secs(10);

/// A runtime directory of our own. Short enough for `sun_path` (~108 bytes) —
/// a long path fails at bind with a message no caller would guess from a
/// timeout, which is what the binary's startup-error handling exists for.
fn scratch_dir(tag: &str) -> PathBuf {
    // Keep every test daemon (and its child processes) below the harness's
    // private scratch tree when rust_tests.sh supplies one. That lets its EXIT
    // trap find a relay even if the Rust process itself is interrupted.
    let base = std::env::var_os("REMUDA_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let base = std::fs::canonicalize(&base).unwrap_or(base);
    let dir = base.join(format!("remuda-t{}-{tag}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

/// The address, derived the way the shipped binary derives it. Hand-building
/// one that merely resembles it is what made the attach test fail first time.
fn scratch(tag: &str) -> PathBuf {
    daemon::socket_path_in(&scratch_dir(tag), "s")
}

/// The daemon thread shares the test process's environment, and an environment
/// variable is per process, so its Butler homes cannot be separated by env.
/// They are resolved by `os.getenv` in the daemon's own Lua image (paths.lua),
/// so this replaces it there, before any mod loads, for the two variables that
/// name the data and config homes. Both live under this daemon's scratch dir
/// (see #225, #211). Core still finds the mod through the process
/// XDG_DATA_HOME (Rust side), and every other name passes through, so a test
/// that sets REMUDA_BUTLER_CONFIG on purpose keeps working.
fn own_butler_homes(path: &Path) -> String {
    let base = path.parent().unwrap_or(path).join("butler-homes");
    let (data, config) = (base.join("data"), base.join("config"));
    std::fs::create_dir_all(&data).expect("create own data home");
    std::fs::create_dir_all(&config).expect("create own config home");
    format!(
        "local getenv = os.getenv; local homes = {{ XDG_DATA_HOME = [==[{}]==], XDG_CONFIG_HOME = [==[{}]==] }}; \
         os.getenv = function(key) return homes[key] or getenv(key) end",
        data.display(),
        config.display()
    )
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
    // After the daemon answers, before any test loads a mod.
    let _ = client::request(path, &Request::Eval { code: own_butler_homes(path), name: None })
        .expect("install own Butler homes");
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

/// A test clock for one of the mod's watchers: the watcher gets a timeout it
/// never reaches, and a schedule moves its deadline (core's `handle.state`)
/// into the past once the gate file exists. Only the length of the timeout
/// changes; branches, matchers and callbacks pass through, and core's own
/// timeout path calls the mod's handler.
/// It depends on core internals, `handle.state.status` and
/// `handle.state.deadline` (core 499b8b9). If a newer core drops or renames
/// them, the watcher fails with the MISSING text below (it reaches the test
/// through the mod's failure mail) instead of waiting for a timeout that
/// never comes.
const TIMEOUT_ON_FILE: &str = r#"
  if remuda._fake_timeout_on_file then return end
  remuda._fake_timeout_on_file = {}
  local expect = remuda.expect
  remuda.expect = function(session, branches, options, ...)
    local gate = remuda._fake_timeout_on_file[session]
    if not gate or branches[1].id ~= gate.id then return expect(session, branches, options, ...) end
    local gated = {}
    for key, value in pairs(options) do gated[key] = value end
    gated.timeout = 1e6
    local handle = expect(session, branches, gated, ...)
    local MISSING = "timeout_on_file: core no longer exposes handle.state.status and handle.state.deadline; update this helper"
    assert(type(handle) == "table" and type(handle.state) == "table" and handle.state.status == "pending", MISSING)
    local poll, released
    poll = remuda.schedule({ every = 0.1, run = function()
      local state = handle.state
      local file = state.status == "pending" and io.open(gate.file)
      if file then
        file:close()
        released = released or remuda.clock()
        -- Core sets the deadline on the watcher's first step, at most a tick after it starts.
        if type(state.deadline) == "number" then state.deadline = 0
        elseif remuda.clock() - released > 5000 then handle:cancel(); options.on_error(MISSING, handle) end
      end
      if state.status ~= "pending" then remuda.cancel(poll) end
    end })
    return handle
  end
"#;

/// The watcher `id` on session `name` times out when the returned file exists
/// (the test creates it once it has seen the state it wants at the timeout),
/// not after the configured seconds.
fn timeout_on_file(path: &Path, dir: &Path, name: &str, id: &str) -> PathBuf {
    let file = dir.join(format!("{name}.timeout"));
    eval(path, TIMEOUT_ON_FILE);
    eval(path, &format!("remuda._fake_timeout_on_file[{name:?}] = {{id={id:?}, file={:?}}}", file.to_string_lossy()));
    file
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

fn wait_for_butler_agent(path: &Path, alias: &str) {
    let probe = format!("return tostring(remuda._butler_bus.agents[{alias:?}] ~= nil)");
    let deadline = Instant::now() + Duration::from_secs(10);
    while eval(path, &probe) != "true" {
        assert!(Instant::now() < deadline, "Butler agent {alias} did not become live");
        std::thread::sleep(Duration::from_millis(50));
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
struct Daemon(std::process::Child, PathBuf);

/// Snapshot the exact descendant PIDs owned by this harness daemon. Teardown
/// signals those IDs individually instead of using a process-name or group kill.
fn descendant_pids_of(parent: i32) -> Vec<i32> {
    let out = std::process::Command::new("ps")
        .args(["-axo", "pid=,ppid="])
        .output()
        .expect("ps");
    let rows: Vec<(i32, i32)> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            Some((fields.next()?.parse().ok()?, fields.next()?.parse().ok()?))
        })
        .collect();
    let mut parents = vec![parent];
    let mut descendants = Vec::new();
    loop {
        let before = descendants.len();
        for (pid, ppid) in &rows {
            if parents.contains(ppid) && !parents.contains(pid) {
                parents.push(*pid);
                descendants.push(*pid);
            }
        }
        if descendants.len() == before { break; }
    }
    descendants
}

#[cfg(unix)]
fn process_pid_alive(pid: i32) -> bool {
    let rc = unsafe { libc::kill(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(unix)]
struct ProcessPidGuard(Vec<i32>);

#[cfg(unix)]
impl Drop for ProcessPidGuard {
    fn drop(&mut self) {
        for pid in &self.0 {
            unsafe { libc::kill(*pid, libc::SIGKILL); }
        }
    }
}

/// A data home of this daemon's own, under its scratch dir and removed with it
/// (see #225). tests/rust_tests.sh installs the Butler mod once, in the
/// XDG_DATA_HOME it exports; that mod directory is linked in here. A second
/// daemon started in the same `dir` (a restart test) gets the same home.
fn own_data_home(dir: &Path) -> PathBuf {
    let data_home = dir.join("data");
    std::fs::create_dir_all(data_home.join("remuda"))
        .unwrap_or_else(|err| panic!("create data home {data_home:?}: {err}"));
    if let Some(install) = std::env::var_os("XDG_DATA_HOME") {
        let link = data_home.join("remuda/mods");
        // A restart in the same scratch dir finds the link already there.
        if let Err(err) = std::os::unix::fs::symlink(PathBuf::from(install).join("remuda/mods"), &link) {
            assert!(
                err.kind() == std::io::ErrorKind::AlreadyExists,
                "link the Butler mod into {link:?}: {err}"
            );
        }
    }
    data_home
}

/// Every test daemon gets its own XDG_DATA_HOME and XDG_CONFIG_HOME. With one
/// home for the whole cargo run, all daemons share agents.jsonl (one root
/// Butler id), one inbox file and one config path.
fn own_homes(cmd: &mut std::process::Command, dir: &Path) {
    let config_home = dir.join("config");
    std::fs::create_dir_all(&config_home)
        .unwrap_or_else(|err| panic!("create config home {config_home:?}: {err}"));
    cmd.env("XDG_DATA_HOME", own_data_home(dir))
        .env("XDG_CONFIG_HOME", config_home);
}

impl Daemon {
    fn spawn(dir: &Path) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        own_homes(&mut cmd, dir);
        let child = cmd
            .args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .current_dir(dir)
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
        Self(child, dir.to_path_buf())
    }

    /// Like `spawn`, but pins the daemon process's own `PWD` -- `None` unsets
    /// it entirely, rather than leaving whatever the test runner happened to
    /// have, so a directory-derived name test is not at the mercy of `cargo
    /// test`'s own working directory.
    fn spawn_with_pwd(dir: &Path, pwd: Option<&str>) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        own_homes(&mut cmd, dir);
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .current_dir(dir)
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
        Self(child, dir.to_path_buf())
    }

    /// Like `spawn`, but layers extra environment variables onto the daemon
    /// process itself -- not the CLI client that later asks it to `exec`
    /// something. `os.getenv` inside `init.lua` reads the daemon's own
    /// environment, so a real (non-`_butler_test_mode`) run needs
    /// `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG` set here, additive to
    /// `spawn`'s existing behavior.
    fn spawn_with_env(dir: &Path, extra_env: &[(&str, &str)]) -> Self {
        let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"));
        // Before extra_env, so a home a test passes explicitly wins.
        own_homes(&mut cmd, dir);
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .current_dir(dir)
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
        Self(child, dir.to_path_buf())
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
        // XDG_CONFIG_HOME is removed again below: the config comes from HOME here.
        own_homes(&mut cmd, dir);
        cmd.args(["-s", "s", "daemon"])
            .env("REMUDA_RUNTIME_DIR", dir)
            .current_dir(dir)
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
        Self(child, dir.to_path_buf())
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
        // Safety net for legacy test runs that still started the detached
        // Python relay. Match both its source marker and this test's cwd so
        // the live Butler relay can never be selected.
        let mut relays = matrix_relays_in_directory(&self.1);
        for pid in &relays {
            unsafe {
                libc::kill(*pid, libc::SIGTERM);
            }
        }
        let graceful_deadline = Instant::now() + Duration::from_millis(500);
        while !relays.is_empty() && Instant::now() < graceful_deadline {
            std::thread::sleep(Duration::from_millis(20));
            relays = matrix_relays_in_directory(&self.1);
        }
        for pid in &relays {
            unsafe {
                libc::kill(*pid, libc::SIGKILL);
            }
        }
        let forced_deadline = Instant::now() + Duration::from_millis(500);
        while !relays.is_empty() && Instant::now() < forced_deadline {
            std::thread::sleep(Duration::from_millis(20));
            relays = matrix_relays_in_directory(&self.1);
        }

        // Stop children individually while their daemon can still reap them.
        let daemon_pid = self.0.id() as i32;
        for pid in descendant_pids_of(daemon_pid).into_iter().rev() {
            unsafe { libc::kill(pid, libc::SIGKILL); }
        }
        unsafe { libc::kill(daemon_pid, libc::SIGKILL); }
        let _ = self.0.kill();
        let _ = self.0.wait();

        let deadline = Instant::now() + Duration::from_secs(2);
        while !relays.is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            relays = matrix_relays_in_directory(&self.1);
        }
        if !relays.is_empty() {
            if std::thread::panicking() {
                eprintln!("legacy Matrix relay survived private daemon teardown: {relays:?}");
            } else {
                panic!("legacy Matrix relay survived private daemon teardown: {relays:?}");
            }
        }
    }
}

fn matrix_relays_in_directory(dir: &Path) -> Vec<i32> {
    const RELAY_MARKER: &str = "MAX_PROCESSED_EVENT_IDS = 5000";
    let Ok(dir) = std::fs::canonicalize(dir) else {
        return Vec::new();
    };
    let output = std::process::Command::new("ps")
        .args(["-ww", "-axo", "pid=,command="])
        .output()
        .expect("scan processes for Matrix relays under test scratch");
    assert!(
        output.status.success(),
        "ps failed while checking test relay cleanup"
    );
    let mut relays = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let Some((pid, command)) = line.trim_start().split_once(char::is_whitespace) else {
            continue;
        };
        if !command.contains(RELAY_MARKER) {
            continue;
        }
        let Ok(pid) = pid.trim().parse::<i32>() else {
            continue;
        };
        if process_cwd(pid).is_some_and(|cwd| cwd.starts_with(&dir)) {
            relays.push(pid);
        }
    }
    relays
}

fn process_cwd(pid: i32) -> Option<PathBuf> {
    // Linux exposes cwd directly; macOS uses lsof. If the process exited
    // between enumeration and inspection, treat it as already cleaned up.
    if let Ok(cwd) = std::fs::read_link(format!("/proc/{pid}/cwd")) {
        return Some(cwd);
    }
    let output = std::process::Command::new("lsof")
        .args(["-a", "-p", &pid.to_string(), "-d", "cwd", "-Fn"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| line.strip_prefix('n').map(PathBuf::from))
}

/// What a person types, with its own pipes and no terminal — so `restart`
/// reaches the "nothing to ask on" branch rather than blocking on a prompt.
fn remuda(dir: &Path, args: &[&str]) -> std::process::Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(args)
        .env("REMUDA_RUNTIME_DIR", dir)
        .current_dir(dir)
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
        .current_dir(dir)
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

fn remuda_timed_stdin(dir: &Path, args: &[&str], stdin: &[u8]) -> std::process::Output {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(args)
        .env("REMUDA_RUNTIME_DIR", dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .current_dir(dir)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn remuda with stdin");
    child.stdin.take().expect("child stdin").write_all(stdin).expect("write stdin");
    let deadline = Instant::now() + PATIENCE;
    loop {
        if let Ok(Some(_)) = child.try_wait() { break; }
        assert!(Instant::now() < deadline, "{args:?} did not exit within PATIENCE");
        std::thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().expect("collect remuda output")
}

fn remuda_timed_without_butler_identity(dir: &Path, args: &[&str]) -> std::process::Output {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(args)
        .env("REMUDA_RUNTIME_DIR", dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env_remove("REMUDA_BUTLER_AGENT_ID")
        .env_remove("REMUDA_BUTLER_SESSION_NAME")
        .env_remove("REMUDA_BUTLER_LEADER_ID")
        .current_dir(dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn remuda without Butler identity");
    let deadline = Instant::now() + PATIENCE;
    loop {
        if let Ok(Some(_)) = child.try_wait() { break; }
        assert!(Instant::now() < deadline, "{args:?} did not exit within PATIENCE");
        std::thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().expect("collect remuda output")
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
        initial == "1|4|1|1|1|25" || initial == "1|4|1|1|1|-1",
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

/// Test daemons must not share a data home (see #225): with one XDG_DATA_HOME
/// for a whole cargo run, agents.jsonl gives every daemon the same root Butler
/// id and inbox file, and Matrix mail delivered in one test is loaded by
/// another test's daemon.
#[test]
fn butler_test_daemons_do_not_share_the_root_inbox() {
    let dir_a = scratch_dir("own-home-a");
    let dir_b = scratch_dir("own-home-b");
    let (_daemon_a, path_a) = butler_cli_test_daemon(&dir_a);
    let a = eval(&path_a, r#"
      local delivered = remuda._butler_inbox_delivery({from={host="matrix", alias="@alice:example.org",
        session="@alice:example.org", kind="matrix", id="", leader=""}, to="butler", text="from daemon A",
        subject="Matrix", matrix={event_id="$own-home-probe", room_id="!r:example.org", sender="@alice:example.org"}})
      if not delivered then return "not-delivered" end
      return remuda._butler_bus.agents.butler.id
    "#);
    assert_ne!(a, "not-delivered", "daemon A must really deliver the Matrix mail to its root Butler");
    let (_daemon_b, path_b) = butler_cli_test_daemon(&dir_b);
    let b = eval(&path_b, r#"
      local root = remuda._butler_bus.agents.butler
      remuda._butler_mail.unread(root.id) -- loads the inbox from disk, as the session list does
      local seen = {}
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = remuda._butler_bus.messages[id]
        if message and message.matrix and message.matrix.event_id ~= nil then
          seen[#seen + 1] = tostring(message.matrix.event_id)
        end
      end
      return root.id .. " matrix=" .. (#seen == 0 and "none" or table.concat(seen, ","))
    "#);
    assert!(b.ends_with(" matrix=none"),
        "daemon B loaded Matrix mail that daemon A delivered (shared data home): A root {a}; B {b}");
    assert!(!b.starts_with(a.as_str()), "the two daemons share one root Butler id: A {a}; B {b}");
}

#[test]
fn butler_message_bodies_preserve_stdin_and_file_content_and_enforce_limits() {
    let dir = scratch_dir("butler-message-body");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let body = "backticks `here`; literal $(never_run); \"quoted\"\nsecond line\n";
    let body_lua = lua_raw_string(body);
    let stdin_result = eval(&path, &format!(r#"
      remuda._butler_send = function(_, _, text) remuda._test_body = text; return "captured" end
      local result = remuda._butler_command_run("send", {{"send", "member", "-"}}, {{env={{}}, stdin={body_lua}}})
      assert(result == "captured")
      return remuda._test_body
    "#));
    assert_eq!(stdin_result, body);

    let file = dir.join("message.txt");
    std::fs::write(&file, body).expect("write body file");
    let file_lua = lua_raw_string(&file.to_string_lossy());
    let file_result = eval(&path, &format!(r#"
      local result = remuda._butler_command_run("send", {{"send", "member", "--file", {file_lua}}}, {{env={{}}}})
      assert(result == "captured")
      return remuda._test_body
    "#));
    assert_eq!(file_result, body);

    let empty_stdin = eval(&path, r#"
      local ok, err = pcall(function()
        remuda._butler_command_run("send", {"send", "member", "-"}, {env={}, stdin=""})
      end)
      assert(not ok)
      return tostring(err)
    "#);
    assert!(empty_stdin.contains("message body must not be empty"), "{empty_stdin}");

    let oversized = "x".repeat(65_537);
    for (content, expected) in [("", "message body must not be empty"), (oversized.as_str(), "message body exceeds the 64 KiB limit")] {
        std::fs::write(&file, content).expect("write invalid body file");
        let code = format!(r#"
          local ok, err = pcall(function()
            remuda._butler_command_run("send", {{"send", "member", "--file", {file_lua}}}, {{env={{}}}})
          end)
          assert(not ok)
          return tostring(err)
        "#);
        assert!(eval(&path, &code).contains(expected));
    }

    let relative = remuda_timed(&dir, &["-s", "s", "butler", "send", "member", "--file", "message.txt"]);
    assert!(!relative.status.success());
    assert!(String::from_utf8_lossy(&relative.stderr).contains("message file path must be absolute"));

    let started = Instant::now();
    let non_regular = remuda_timed(&dir, &["-s", "s", "butler", "send", "member", "--file", "/dev/stdin"]);
    assert!(started.elapsed() < Duration::from_secs(5), "/dev/stdin read blocked too long");
    assert!(!non_regular.status.success());
    assert!(String::from_utf8_lossy(&non_regular.stderr).contains("--file must be a regular file; for a pipe, use -"));
    let responsive = remuda_timed(&dir, &["-s", "s", "butler", "sessions"]);
    assert!(responsive.status.success(), "daemon stopped responding after /dev/stdin rejection");

}

#[test]
fn butler_send_dash_forwards_real_cli_stdin_byte_exactly() {
    let dir = scratch_dir("butler-cli-stdin");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    eval(&path, "remuda._butler_send = function(_, _, text) remuda._test_cli_stdin = text; return 'captured' end");
    let body = b"literal `ticks`, $(not executed), \"quotes\"\nsecond line\n";
    let out = remuda_timed_stdin(&dir, &["-s", "s", "butler", "send", "member", "-"], body);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(String::from_utf8_lossy(&out.stdout).contains("captured"));
    assert_eq!(eval(&path, "return remuda._test_cli_stdin"), String::from_utf8_lossy(body));
}

#[test]
fn butler_cli_unknown_recipient_and_inbox_help_are_plain_errors() {
    let dir = scratch_dir("butler-cli-errors");
    let (_daemon, _path) = butler_cli_test_daemon(&dir);
    let no_leader = remuda_timed_without_butler_identity(
        &dir,
        &["-s", "s", "butler", "send-to-leader", "hello"],
    );
    assert!(!no_leader.status.success());
    let no_leader_stderr = String::from_utf8_lossy(&no_leader.stderr);
    assert!(no_leader_stderr.contains("operator has no leader; send-to-leader is for Butler agents"), "{no_leader_stderr}");
    assert!(!no_leader_stderr.contains("stack traceback"), "{no_leader_stderr}");
    assert!(!no_leader_stderr.contains("main.lua"), "{no_leader_stderr}");

    let unknown = remuda_timed(&dir, &["-s", "s", "butler", "send", "no-such-member", "hello"]);
    assert!(!unknown.status.success());
    let stderr = String::from_utf8_lossy(&unknown.stderr);
    assert!(stderr.contains("unknown member: no-such-member"), "{stderr}");
    assert!(stderr.contains("remuda butler agents"), "{stderr}");
    assert!(!stderr.contains("runtime error"), "{stderr}");

    let help = remuda_timed(&dir, &["-s", "s", "butler", "inbox", "--help"]);
    assert!(help.status.success(), "{}", String::from_utf8_lossy(&help.stderr));
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage: remuda butler inbox [name]"));
}

#[test]
fn butler_compact_cli_rejects_unknown_sessions_and_previews_safe_keys() {
    let dir = scratch_dir("butler-compact-cli");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let trace_path = dir.join("compaction-trace.log");
    eval(
        &path,
        &format!(
            "remuda._butler_compaction_trace_path = {}",
            lua_raw_string(&trace_path.to_string_lossy())
        ),
    );

    for dry_run in [false, true] {
        let out = if dry_run {
            remuda_timed(&dir, &["-s", "s", "butler", "compact", "no-such-member", "--dry-run"])
        } else {
            remuda_timed(&dir, &["-s", "s", "butler", "compact", "no-such-member"])
        };
        assert!(!out.status.success(), "unknown session unexpectedly succeeded: {}",
            String::from_utf8_lossy(&out.stdout));
        assert!(String::from_utf8_lossy(&out.stderr).contains("unknown session: no-such-member"),
            "unknown-session error was not clear: {}", String::from_utf8_lossy(&out.stderr));
        assert_eq!(
            eval(&path, r#"
              local state = remuda._butler_state or remuda._butler_compaction_state or {}
              local members = state.compaction_members or remuda._butler_compaction_members_state or {}
              return tostring(members["no-such-member"] == nil)
            "#),
            "true",
            "unknown session must not create compaction member state"
        );
        assert!(!trace_path.exists(), "unknown session unexpectedly wrote a compaction trace");
    }

    eval(&path, r#"
      remuda._butler_bus.agents["preview-opus"] = {
        id = "preview-opus", kind = "claude", session_name = "preview-opus", model = "opus"
      }
      remuda._butler_bus.agents["preview-unknown"] = {
        id = "preview-unknown", kind = "claude", session_name = "preview-unknown", model = "Experimental-Model"
      }
      remuda._butler_telemetry_for = function(agent)
        return { context_used = 900000, model = agent.model }
      end
      remuda.session = function() return { is_busy = false, attached = false } end
      remuda.capture = function() return "idle composer" end
      remuda._butler_prompt_is_empty = function() return "EMPTY" end
    "#);
    let opus = remuda_timed(&dir, &["-s", "s", "butler", "compact", "preview-opus", "--dry-run"]);
    assert!(opus.status.success(), "known-family preview failed: {}", String::from_utf8_lossy(&opus.stderr));
    let preview = String::from_utf8_lossy(&opus.stdout);
    assert!(preview.contains("/model sonnet -> /compact -> /model opus -> RET"),
        "preview omitted the owner model-switch sequence: {preview}");

    let unknown = remuda_timed(&dir, &["-s", "s", "butler", "compact", "preview-unknown", "--dry-run"]);
    assert!(unknown.status.success(), "unknown-family preview failed: {}", String::from_utf8_lossy(&unknown.stderr));
    let preview = String::from_utf8_lossy(&unknown.stdout);
    assert!(preview.contains("/model sonnet -> /compact -> /model Experimental-Model -> RET"),
        "unknown model should be restored from the assigned model value: {preview}");
}

#[test]
fn butler_compaction_defers_for_mail_queued_through_the_cli() {
    let dir = scratch_dir("butler-compaction-queued-mail");
    let (_daemon, path) = butler_cli_test_daemon(&dir);

    // Model a live session name that differs from its Butler mailbox alias.
    // This keeps the separate terminal-notice queue out of the assertion: the
    // compaction guard must inspect the real unread mailbox for this agent.
    eval(&path, r#"
      remuda._butler_state.compaction_enabled = false
      local root = remuda._butler_bus.agents.butler
      remuda._butler_bus.agents["mail-compaction"] = {
        id = root.id, alias = root.alias, kind = "codex",
        session_name = "mail-compaction"
      }
      remuda.session = function(name)
        if name == "mail-compaction" then return { is_busy = false, attached = false } end
        return nil
      end
      remuda.ls = function()
        return {{ name = "mail-compaction", alive = true, attached = false }}
      end
      remuda.capture = function(name)
        if name == "mail-compaction" then return "❯" end
        error("no such session: " .. tostring(name))
      end
      remuda._butler_prompt_is_empty = function() return "EMPTY", "" end
    "#);

    // Other integration tests share the suite's XDG data home and can leave
    // old mail for the persistent root identity; assert this send's delta.
    let unread_before_send = eval(
        &path,
        r#"
      local id = remuda._butler_bus.agents["mail-compaction"].id
      return tostring(remuda._butler_mail.unread(id))
    "#,
    )
    .parse::<u32>()
    .expect("unread count before send");

    let queued = remuda_timed(
        &dir,
        &[
            "-s", "s", "butler", "send", "operator", "butler",
            "\"mail must be read before compaction\"",
        ],
    );
    assert!(queued.status.success(), "butler send failed: {}",
        String::from_utf8_lossy(&queued.stderr));
    assert!(String::from_utf8_lossy(&queued.stdout).contains("queued "),
        "butler send did not queue a message: {}", String::from_utf8_lossy(&queued.stdout));

    let unread_after_send = eval(
        &path,
        r#"
          local id = remuda._butler_bus.agents["mail-compaction"].id
          return tostring(remuda._butler_mail.unread(id))
        "#,
    )
    .parse::<u32>()
    .expect("unread count after send");
    assert_eq!(
        unread_after_send,
        unread_before_send + 1,
        "the public send command must leave exactly one new unread mailbox entry"
    );

    assert_eq!(
        eval(
            &path,
            "return remuda._butler_compaction_preflight('mail-compaction') or 'nil'",
        ),
        "queued mail",
        "ordinary compaction preflight must keep deferring unread mail"
    );
    assert_eq!(
        eval(
            &path,
            "return remuda._butler_compaction_preflight('mail-compaction', true) or 'nil'",
        ),
        "nil",
        "the bounded/critical override must pass only the unread-mail preflight"
    );

    let compact = remuda_timed(&dir, &["-s", "s", "butler", "compact", "mail-compaction"]);
    assert!(compact.status.success(), "compaction command failed: {}",
        String::from_utf8_lossy(&compact.stderr));
    assert!(String::from_utf8_lossy(&compact.stdout).contains("skipped_queued"),
        "compaction must defer while the session mailbox has unread mail: {}",
        String::from_utf8_lossy(&compact.stdout));
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
fn butler_matrix_request_uses_system_tls_trust_by_default() {
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
      local spec = remuda.http.calls[1]
      if failure then return "request-failed:" .. tostring(failure.error) end
      if not spec then return "no-request" end
      if spec.url ~= "https://matrix.example.org/_matrix/client/v3/versions" then return "bad-url" end
      if spec.pin ~= nil or spec.ca_file ~= nil then return "trust-override-added" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "HTTPS requests should use the core system trust verifier by default: {result}");
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
            " https://matrix.example.org/  \r\n {room}  \r\n @bot:example.org \r\n @alice:example.org \r\n false \r\n 30000 \r\n ca_file = /tmp/test-ca.pem \r\n"
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
            -- #235 step B: the first mail from an unseen thread waits for two context GETs.
            remuda.http.respond_prefix("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21relay%3Aexample.org/event/",
              {{ status = 200, headers = {{}}, body = '{{"type":"m.room.message","event_id":"$thread-root","sender":"@alice:example.org","origin_server_ts":0,"content":{{"msgtype":"m.text","body":"thread start"}}}}' }})
            remuda.http.respond_prefix("GET", "https://matrix.example.org/_matrix/client/v1/rooms/%21relay%3Aexample.org/relations/",
              {{ status = 200, headers = {{}}, body = '{{"chunk":[]}}' }})
            remuda.relay_deliveries = {{}}
            remuda.relay_client = matrix.relay.new({{ config_path = {config}, matrix = matrix,
              deliver = function(value) table.insert(remuda.relay_deliveries, value); return true end }})
            remuda.relay_client:start()
            if #remuda.http.calls ~= 1 then return "baseline-not-started" end
            if remuda.relay_deliveries[1] then return "callback-ran-inline" end
            remuda.http.tick()
            remuda.http.tick()
            -- Old expectation: delivered after these two ticks. Since #235 step B the
            -- two context GETs wait their turn in the request queue first.
            for _ = 1, 12 do
              if #remuda.relay_deliveries == 1 then break end
              remuda.http.tick()
            end
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
fn butler_matrix_relay_persists_matrix_event_time_through_real_mail_delivery() {
    let dir = scratch_dir("mr-mail-time");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!relay-time:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "mail-time", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let event = serde_json::json!({"type":"m.room.message","event_id":"$mail-time",
        "sender":"@alice:example.org","origin_server_ts":0,
        "content":{"msgtype":"m.text","body":"dated \u{1b}[31mby Matrix\u{9b}2J"}});
    let response = serde_json::json!({"next_batch":"s1","rooms":{"join":{room:{"timeline":{"events":[event]}}}}});
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", {baseline}, {{status=200,headers={{}},body='{{"next_batch":"s0"}}'}})
      remuda.http.respond("GET", {sync}, {{status=200,headers={{}},body={response}}})
      local original_delivery = remuda._butler_inbox_delivery
      remuda._butler_inbox_delivery = function(message)
        remuda.captured_delivery = message
        return original_delivery(message)
      end
      assert(matrix.relay.start(remuda._butler_matrix_config))
      for _=1,4 do remuda.http.tick() end
      local bus = remuda._butler_bus
      local root = assert(bus.agents.butler)
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = bus.messages[id]
        if message and message.matrix and message.matrix.event_id == "$mail-time" then
          local body = bus.objects[message.body.object_id].content
          return message.created_at .. "|" .. tostring(message.matrix.room)
            .. "|" .. tostring(message.matrix.event_id) .. "|" .. body
        end
      end
      local state = matrix.relay.instance:state()
      return "mail-not-found|captured=" .. tostring(remuda.captured_delivery ~= nil)
        .. "|calls=" .. #remuda.http.calls .. "|pending=" .. tostring(state.pending["$mail-time"] ~= nil)
        .. "|inbox=" .. #remuda._butler_mail.mailbox(root.id)
    "#,
        baseline=lua_raw_string(baseline), sync=lua_raw_string(sync), response=lua_raw_string(&response.to_string())));
    assert_eq!(result, "1970-01-01T00:00:00Z|home|$mail-time|dated [31mby Matrix2J",
        "relay-to-mail delivery must preserve metadata and strip control characters: {result}");
}

#[test]
fn butler_matrix_reply_quarantines_rejected_events_for_operator_inspection() {
    let dir = scratch_dir("matrix-quarantine-red");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!quarantine:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "quarantine", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    let room_events = serde_json::json!({"timeline":{"events":[
        {"type":"m.room.message","event_id":"$not-allowed","sender":"@mallory\u{1b}[2J:example.org",
         "origin_server_ts":0,"content":{"msgtype":"m.image","url":"mxc://example.org/private",
            "body":"private rejected \u{1b}[31mtext\u{009b}2J"}},
        {"type":"m.room.message","event_id":"$unsafe","sender":"@alice:example.org",
         "origin_server_ts":1,"content":{"msgtype":"m.image","body":"unsafe image"}},
        {"type":"m.room.message","sender":"@alice:example.org","origin_server_ts":2,
         "content":{"msgtype":"m.text","body":"missing event id"}}
    ]}});
    let mut joined = serde_json::Map::new();
    joined.insert(room.to_string(), room_events);
    let response = serde_json::json!({"rooms":{"join":joined}});
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      local room = {room}
      local delivered = 0
      local relay = matrix.relay.new({{config_path={config}, matrix=matrix, deliver=function()
        delivered = delivered + 1; return true
      end}})
      relay._response({{next_batch="s0"}}, "/_matrix/client/v3/sync")
      relay._response(assert(matrix.decode_json({response})), "/_matrix/client/v3/sync")
      local rows = assert(matrix.quarantine_list())
      if #rows ~= 3 then return "count:" .. #rows end
      if rows[1].event_id == rows[2].event_id then return "duplicate" end
      if rows[1].reason == nil or rows[2].reason == nil then return "reason-missing" end
      local missing_id = false
      for _, item in ipairs(rows) do if item.reason == "missing_event_id" then missing_id = true end end
      if not missing_id then return "missing-event-id-not-quarantined" end
      if delivered ~= 0 then return "quarantine-leaked-to-mail:" .. delivered end
      local denied
      matrix.quarantine({{id=rows[1].event_id}}, function(result) denied=result.error end, "codex")
      if not denied or not denied:find("operator-only", 1, true) then return "agent-inspection-not-denied" end
      local root = remuda._butler_bus.agents.butler
      -- Intermittent in full runs (see PR 223): name the leaked mail, so the next
      -- failure shows which test or event it came from.
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = remuda._butler_bus.messages[id]
        if message and message.matrix and message.matrix.event_id ~= nil then return "quarantine-leaked-to-mail: id=" .. tostring(id) .. " ev=" .. tostring(message.matrix.event_id) .. " room=" .. tostring(message.matrix.room_id) .. " sender=" .. tostring(message.matrix.sender) .. " kind=" .. tostring(message.kind) .. " subj=" .. tostring(message.subject) .. " text=" .. tostring(message.text):sub(1,120) end
      end
      local more = {{}}
      for i=1,205 do more[i] = {{type="m.room.message", event_id="$bulk-" .. i,
        sender="@mallory:example.org", origin_server_ts=i,
        content={{msgtype="m.image", url="mxc://example.org/bulk", body=i == 205
          and (string.char(27) .. "[31mprivate" .. string.char(194,155) .. "2J")
          or string.rep("p", 2048)}}}} end
      local batch = {{rooms={{join={{}}}}}}; batch.rooms.join[room]={{timeline={{events=more}}}}
      relay._response(batch, "/_matrix/client/v3/sync")
      local bounded = assert(matrix.quarantine_list())
      if #bounded ~= 200 then return "unbounded-count:" .. #bounded end
      for _, item in ipairs(bounded) do if #item.preview > 1024 then return "preview-unbounded" end end
      return "ok"
    "#,
      config=lua_raw_string(&config_path.to_string_lossy()),
      response=lua_raw_string(&response.to_string()), room=lua_raw_string(room)));
    assert_eq!(result, "ok", "rejected Matrix events must be privately inspectable and never enter mail: {result}");
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "--json", "quarantine"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env_remove("REMUDA_BUTLER_AGENT_ID")
        .env_remove("REMUDA_BUTLER_SESSION_NAME")
        .current_dir(&dir)
        .output()
        .expect("run operator quarantine verb");
    assert!(output.status.success(), "operator quarantine verb failed: {}", String::from_utf8_lossy(&output.stderr));
    let listing: serde_json::Value = serde_json::from_slice(&output.stdout).expect("parse quarantine JSON");
    assert_eq!(listing["json"].as_array().map(Vec::len), Some(200));
    let inspected = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "--json", "quarantine", "--id", "$bulk-205"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env_remove("REMUDA_BUTLER_AGENT_ID")
        .env_remove("REMUDA_BUTLER_SESSION_NAME")
        .current_dir(&dir)
        .output()
        .expect("run operator quarantine detail verb");
    assert!(inspected.status.success(), "quarantine detail verb failed: {}", String::from_utf8_lossy(&inspected.stderr));
    let detail: serde_json::Value = serde_json::from_slice(&inspected.stdout).expect("parse quarantine detail JSON");
    assert_eq!(detail["json"]["event_id"], "$bulk-205");
    let human = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "quarantine", "--id", "$bulk-205"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env_remove("REMUDA_BUTLER_AGENT_ID")
        .env_remove("REMUDA_BUTLER_SESSION_NAME")
        .current_dir(&dir)
        .output()
        .expect("run human operator quarantine detail verb");
    assert!(human.status.success(), "human quarantine verb failed: {}", String::from_utf8_lossy(&human.stderr));
    let human = String::from_utf8_lossy(&human.stdout);
    assert!(!human.contains('\u{1b}') && !human.contains('\u{009b}'),
        "human quarantine output must strip terminal control characters: {human:?}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let state_path = PathBuf::from(format!("{}.since", config_path.display()));
        let mode = std::fs::metadata(state_path).expect("read Matrix state mode").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "quarantine previews must be stored in a private state file");
    }
}

#[test]
fn butler_matrix_reply_is_correlated_and_sent_id_is_durable() {
    let dir = scratch_dir("matrix-mail-reply-red");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!reply:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "reply", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    let room_events = serde_json::json!({"timeline":{"events":[
        {"type":"m.room.message","event_id":"$incoming","sender":"@alice:example.org",
         "origin_server_ts":0,"content":{"msgtype":"m.text","body":"@bot:example.org question",
           "m.relates_to":{"rel_type":"m.thread","event_id":"$root"}}}
    ]}});
    let mut joined = serde_json::Map::new();
    joined.insert(room.to_string(), room_events);
    let response = serde_json::json!({"rooms":{"join":joined}});
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      local room = {room}
      local payload = assert(matrix.decode_json({response}))
      if not payload.rooms or not payload.rooms.join or not payload.rooms.join[room] then return "room-key-missing" end
      -- #235 step B: the first mail from an unseen thread waits for two context
      -- GETs, and only a started relay takes their answer. The relay is started
      -- with a client that never sends the sync poll (the test feeds sync itself).
      -- Old expectation: the mail is delivered inside relay._response.
      local api = setmetatable({{ request_json = function(args, done)
        if tostring(args.path):find("/sync", 1, true) then return {{ cancel = function() end }} end
        return matrix.request_json(args, done)
      end }}, {{ __index = matrix }})
      remuda.http.respond_prefix("GET", "http://matrix.example.org/_matrix/client/v3/rooms/%21reply%3Aexample.org/event/",
        {{status=200, headers={{}}, body='{{"type":"m.room.message","event_id":"$root","sender":"@alice:example.org","origin_server_ts":0,"content":{{"msgtype":"m.text","body":"thread start"}}}}'}})
      remuda.http.respond_prefix("GET", "http://matrix.example.org/_matrix/client/v1/rooms/%21reply%3Aexample.org/relations/",
        {{status=200, headers={{}}, body='{{"chunk":[]}}'}})
      local relay = matrix.relay.new({{config_path={config}, matrix=api, deliver=function(event)
        local delivered = remuda._butler_inbox_delivery({{from={{host="matrix", alias=event.sender,
          session=event.sender, kind="matrix", id="", leader=""}}, to="butler", text=event.body,
          subject="Matrix", matrix=event}})
        remuda.source_mail_id = delivered and delivered.id
        return delivered
      end}})
      relay:start()
      relay._response({{next_batch="s0"}}, "/_matrix/client/v3/sync")
      relay._response(payload, "/_matrix/client/v3/sync")
      for _=1,8 do
        if remuda.source_mail_id then break end
        remuda.http.tick()
      end
      if not remuda.source_mail_id then
        local state=relay:state()
        local count=0; for _ in pairs(state.pending) do count=count+1 end
        return "mail-not-delivered|pending=" .. tostring(count) .. "|processed=" .. tostring(state.processed["$incoming"])
      end
      matrix.relay.instance = relay
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/rooms/%21reply%3Aexample.org/context/%24incoming",
        {{status=200, headers={{}}, body='{{"event":{{"room_id":"!reply:example.org"}}}}'}})
      remuda.http.respond_prefix("PUT", "http://matrix.example.org/_matrix/client/v3/rooms/%21reply%3Aexample.org/send/m.room.message/",
        {{status=200, headers={{}}, body='{{"event_id":"$outgoing"}}'}})
      local queued = remuda._butler_reply("butler", remuda.source_mail_id, "answer")
      if not queued:find("queued Matrix reply", 1, true) then return "reply-not-queued:" .. tostring(queued) end
      for _=1,4 do remuda.http.tick() end
      local found_body = false
      for _, call in ipairs(remuda.http.calls) do
        if call.method == "PUT" and call.url:find("/send/m.room.message/", 1, true) then
          local body = assert(matrix.decode_json(call.body))
          local relation = body["m.relates_to"] or {{}}
          if relation.rel_type == "m.thread" and relation.event_id == "$root"
            and relation["m.in_reply_to"].event_id == "$incoming" then found_body = true end
        end
      end
      if not found_body then return "thread-relation-not-sent" end
      local reply_id = queued:match("queued Matrix reply ([%w_%-]+) for")
      if not reply_id then return "reply-id-missing" end
      local puts = 0
      for _, call in ipairs(remuda.http.calls) do if call.method == "PUT" then puts=puts+1 end end
      local duplicate_result
      matrix.mail_reply({{mail_id=remuda.source_mail_id, reply_mail_id=reply_id, text="answer"}},
        function(value) duplicate_result=value end)
      local after = 0
      for _, call in ipairs(remuda.http.calls) do if call.method == "PUT" then after=after+1 end end
      if puts ~= after or not duplicate_result or duplicate_result.event_id ~= "$outgoing" then return "duplicate-was-not-deduped" end
      matrix.relay.instance = nil
      local status = matrix.mail_reply_status(remuda.source_mail_id)
      return status and status.event_id == "$outgoing" and status.thread_root == "$root" and "ok" or "mapping-not-durable"
    "#,
      config=lua_raw_string(&config_path.to_string_lossy()),
      response=lua_raw_string(&response.to_string()), room=lua_raw_string(room)));
    assert_eq!(result, "ok", "a Butler mail reply must route to its Matrix thread and durably record the sent event: {result}");
}

#[test]
fn butler_matrix_reply_home_all_roster_subscriptions_survive_restart() {
    let dir = scratch_dir("matrix-home-all");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let home_a = "!home-a:example.org";
    let home_b = "!home-b:example.org";
    let all = "!all:example.org";
    let (a_token, a_config) = butler_config(&dir, "butler-a", "http://matrix.example.org",
        home_a, "@butler-a:example.org", "@human:example.org,@agent-bot:example.org");
    let (_b_token, b_config) = butler_config(&dir, "butler-b", "http://matrix.example.org",
        home_b, "@butler-b:example.org", "@human:example.org,@agent-bot:example.org");
    for config in [&a_config, &b_config] {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().append(true).open(config).unwrap();
        writeln!(file, "all_room={all}").unwrap();
    }
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, "remuda.exec('butler/matrix')");
    let result = eval(&path, &format!(r#"
      local matrix = remuda.butler.matrix
      local home_a, home_b, all = {home_a}, {home_b}, {all}
      local config_a, config_b = {a_config}, {b_config}
      local a, b = {{}}, {{}}
      local function deliver(target, label)
        return function(e)
          target[#target+1] = e
          local mail_id = label .. "-mail-" .. tostring(#target)
          e.test_mail_id = mail_id
          return {{id=mail_id}}
        end
      end
      -- #235 step B: the first mail from an unseen thread waits for two context
      -- GETs, and only a started relay takes their answer. Relay A is started with
      -- a client that never sends the sync poll (the test feeds sync itself), and
      -- its Matrix config is set before the first sync, not only before the sends.
      -- Old expectation: every mail is delivered inside _response.
      local api = setmetatable({{ request_json = function(args, done)
        if tostring(args.path):find("/sync", 1, true) then return {{ cancel = function() end }} end
        return matrix.request_json(args, done)
      end }}, {{ __index = matrix }})
      remuda._butler_matrix_config = {{token_path={a_token}, config_path=config_a}}
      remuda.http.respond_prefix("GET", "http://matrix.example.org/_matrix/client/v3/rooms/"
        .. matrix.path_component(all) .. "/event/",
        {{status=200, headers={{}}, body='{{"type":"m.room.message","event_id":"$start","sender":"@human:example.org","origin_server_ts":0,"content":{{"msgtype":"m.text","body":"thread start"}}}}'}})
      remuda.http.respond_prefix("GET", "http://matrix.example.org/_matrix/client/v1/rooms/"
        .. matrix.path_component(all) .. "/relations/",
        {{status=200, headers={{}}, body='{{"chunk":[]}}'}})
      local ra = matrix.relay.new({{config_path=config_a, matrix=api, deliver=deliver(a, "a")}})
      ra:start()
      local rb = matrix.relay.new({{config_path=config_b, matrix=matrix, deliver=deliver(b, "b")}})
      local function ev(id, sender, body, root, reply)
        local content = {{msgtype="m.text", body=body}}
        if root then content["m.relates_to"] = {{rel_type="m.thread", event_id=root,
          ["m.in_reply_to"]={{event_id=reply or root}}}} end
        return {{type="m.room.message", event_id=id, sender=sender, content=content}}
      end
      local function room(events)
        return {{timeline={{events=events}}, state={{events={{
          {{type="m.room.member", state_key="@human:example.org", content={{membership="join"}}}},
          {{type="m.room.member", state_key="@agent-bot:example.org", content={{membership="join"}}}},
          {{type="m.room.member", state_key="@butler-a:example.org", content={{membership="join"}}}},
          {{type="m.room.member", state_key="@butler-b:example.org", content={{membership="join"}}}},
        }}}}}}
      end
      local function response(cursor, events_a, events_b, events_all)
        return {{next_batch=cursor, rooms={{join={{
          [home_a]=room(events_a or {{}}), [home_b]=room(events_b or {{}}), [all]=room(events_all or {{}}),
        }}}}}}
      end
      ra._response({{next_batch="base-a"}}, "/_matrix/client/v3/sync")
      rb._response({{next_batch="base-b"}}, "/_matrix/client/v3/sync")
      ra._response(response("cursor-1", {{ev("$home-a", "@human:example.org", "home A")}}, nil, {{
        ev("$top", "@human:example.org", "top level"),
        ev("$unsub", "@human:example.org", "unsubscribed", "$other-thread"),
        ev("$mention-a", "@human:example.org", "@butler-a:example.org join", "$mention-thread"),
        ev("$agent-quiet", "@agent-bot:example.org", "quiet"),
        ev("$agent-mention", "@agent-bot:example.org", "@butler-a:example.org inspect", "$agent-thread"),
      }}), "/_matrix/client/v3/sync")
      rb._response(response("cursor-1", nil, {{ev("$home-b", "@human:example.org", "home B")}}, {{
        ev("$top", "@human:example.org", "top level"),
        ev("$unsub", "@human:example.org", "unsubscribed", "$other-thread"),
        ev("$mention-a", "@human:example.org", "@butler-a:example.org join", "$mention-thread"),
        ev("$agent-quiet", "@agent-bot:example.org", "quiet"),
        ev("$agent-mention", "@agent-bot:example.org", "@butler-a:example.org inspect", "$agent-thread"),
      }}), "/_matrix/client/v3/sync")
      local function has(target, id)
        for _, item in ipairs(target) do if item.event_id == id then return item end end
      end
      for _=1,12 do
        if has(a, "$mention-a") and has(a, "$agent-mention") then break end
        remuda.http.tick()
      end
      if not has(a, "$home-a") or has(b, "$home-a") then return "home-routing-failed" end
      if not has(b, "$home-b") or has(a, "$home-b") then return "other-home-routing-failed" end
      if not has(a, "$top") or not has(b, "$top") then return "all-top-level-missed" end
      if has(a, "$unsub") or has(b, "$unsub") or has(b, "$mention-a") then return "thread-routing-failed" end
      local top = has(a, "$top")
      if top.room ~= "all" or top.event_id ~= "$top" then return "mail-room-metadata-missing" end
      if has(a, "$mention-a").thread_id ~= "$mention-thread" then return "thread-id-metadata-missing" end
      -- Receive rules: a Butler's root post is delivered without a mention.
      if not has(a, "$agent-quiet") or not has(b, "$agent-quiet") then return "agent-root-not-delivered" end
      if not has(a, "$agent-mention") or has(b, "$agent-mention") then return "agent-mention-routing-failed" end
      -- Old rule (PR 1): can_reply_to was false for a Butler's event. Replaced by the
      -- loop guard b2b_max_turns: a delivered Butler event can be answered; an
      -- unknown event still cannot.
      if not ra:can_reply_to("$agent-mention") then return "butler-event-reply-refused" end
      if ra:can_reply_to("$unknown-event") then return "reply-guard-failed-open" end
      remuda._butler_matrix_config = {{token_path={a_token}, config_path=config_a}}
      local send_path = "http://matrix.example.org/_matrix/client/v3/rooms/"
        .. matrix.path_component(all) .. "/send/m.room.message/"
      remuda.http.respond_prefix("PUT", send_path,
        {{status=200,headers={{}},body='{{"event_id":"$a-send"}}'}})
      -- Old rule (PR 1): a send that mentions a Butler was refused with
      -- "Butler-to-Butler sends are disabled". Replaced by posts_per_hour and
      -- b2b_max_turns: it is posted.
      local mention_send
      matrix.send({{room=all, text="@butler-b:example.org please reply"}},
        function(result) mention_send=result end)
      for _=1,4 do remuda.http.tick() end
      if not mention_send or mention_send.error then
        return "butler-mention-send-not-posted:" .. tostring(mention_send and mention_send.error)
      end
      local send_completion
      remuda.pending = function()
        return {{resolve=function(_, code, stdout, stderr)
          send_completion={{code=code, stdout=stdout, stderr=stderr}}
        end}}
      end
      matrix.relay.instance = ra
      matrix.cli({{"matrix", "--room", all, "send", "fleet note"}}, nil)
      for _=1,4 do remuda.http.tick() end
      if not send_completion or send_completion.code ~= 0 then return "all-room-send-failed" end
      if not ra:state().subscriptions[all]["$a-send"] then return "send-did-not-subscribe" end
      local mention_mail_id = has(a, "$mention-a").test_mail_id
      if not ra:state().subscriptions[all]["$mention-thread"]
        or ra:state().subscriptions[all]["$mention-thread"].mail_id ~= mention_mail_id then
        return "mention-subscription-missing"
      end
      ra:state().routes[mention_mail_id] = nil
      if not ra:record_outgoing_reply("$top", "$a-post") then return "post-route-missing" end
      if ra:state().routes[mention_mail_id] then return "mention-route-not-removed" end
      ra:stop()
      ra = matrix.relay.new({{config_path=config_a, matrix=api, deliver=deliver(a, "a")}})
      if ra:state().since ~= "cursor-1" then return "cursor-not-restored" end
      ra:start()
      local followups = {{
        ev("$mention-followup", "@human:example.org", "continued", "$mention-thread"),
        ev("$post-followup", "@human:example.org", "reply to A post", "$top", "$a-post"),
        ev("$send-followup", "@human:example.org", "reply to send", "$a-send"),
        ev("$agent-thread-followup", "@human:example.org", "agent thread continuation", "$agent-thread"),
        ev("$agent-quiet-2", "@agent-bot:example.org", "quiet again", "$mention-thread"),
        ev("$agent-mention-2", "@agent-bot:example.org", "@butler-a:example.org again", "$mention-thread"),
      }}
      ra._response(response("cursor-2", nil, nil, followups), "/_matrix/client/v3/sync")
      rb._response(response("cursor-2", nil, nil, followups), "/_matrix/client/v3/sync")
      -- The reply to A's own send is the first mail from that thread: it waits for its context.
      for _=1,8 do
        if has(a, "$send-followup") then break end
        remuda.http.tick()
      end
      if not has(a, "$mention-followup") or not has(a, "$post-followup") or not has(a, "$send-followup")
        or not has(a, "$agent-thread-followup") then return "subscription-not-restored" end
      if has(a, "$mention-followup").context_mail_id ~= has(a, "$mention-a").test_mail_id
        or has(a, "$post-followup").context_mail_id ~= has(a, "$top").test_mail_id then
        return "thread-context-mail-lost:" .. tostring(has(a, "$mention-followup").context_mail_id)
          .. ":" .. tostring(has(a, "$post-followup").context_mail_id)
      end
      if has(b, "$mention-followup") or has(b, "$post-followup") or has(b, "$send-followup")
        or has(b, "$agent-thread-followup") then return "thread-leaked-to-B" end
      -- A followed thread delivers every sender; B does not follow it.
      if not has(a, "$agent-quiet-2") or has(b, "$agent-quiet-2") then return "agent-in-followed-thread-routing-failed" end
      if not has(a, "$agent-mention-2") or has(b, "$agent-mention-2") then return "agent-mention-followup-routing-failed" end
      -- Old rule (PR 1): can_reply_to was false here ("agent-reply-allowed" was the
      -- failure). Replaced by b2b_max_turns.
      if not ra:can_reply_to("$agent-mention-2") then return "butler-followup-reply-refused" end
      local before = #a + #b
      ra._response(response("cursor-3", nil, nil, followups), "/_matrix/client/v3/sync")
      rb._response(response("cursor-3", nil, nil, followups), "/_matrix/client/v3/sync")
      if #a + #b ~= before then return "duplicate-after-replay" end
      return "ok"
    "#,
      home_a=lua_raw_string(home_a), home_b=lua_raw_string(home_b), all=lua_raw_string(all),
      a_config=lua_raw_string(&a_config.to_string_lossy()), b_config=lua_raw_string(&b_config.to_string_lossy()),
      a_token=lua_raw_string(&a_token.to_string_lossy())));
    assert_eq!(result, "ok", "home/all routing, roster, thread subscriptions, and restart contract: {result}");
}

#[test]
fn butler_matrix_reply_thread_returns_to_original_mail_after_relay_restart() {
    let dir = scratch_dir("matrix-thread-restart");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let home = "!thread-restart-home:example.org";
    let room = "!thread-restart-all:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "thread-restart", "http://matrix.example.org", home,
        "@butler:example.org", "@human:example.org,@agent-helper:example.org");
    {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().append(true).open(&config_path).unwrap();
        writeln!(file, "all_room={room}").unwrap();
    }
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, &format!(r#"
      local matrix, room = remuda.butler.matrix, {room}
      local config_path = {config}
      local parsed = assert(matrix.read_config(config_path))
      if parsed.all_room ~= room then return "all-room-config-missing:" .. tostring(parsed.all_room) end
      local function payload(cursor, events)
        return {{next_batch=cursor, rooms={{join={{[room]={{timeline={{events=events}}}}}}}}}}
      end
      local function deliver(event)
        return remuda._butler_inbox_delivery({{
          from={{host="matrix", id="", alias=event.sender, session=event.sender,
            kind=event.from_agent and "matrix-agent" or "matrix", leader=""}},
          to="butler", text=event.body, in_reply_to=event.context_mail_id,
          subject="Matrix", matrix=event,
        }})
      end
      local relay = matrix.relay.new({{config_path=config_path, matrix=matrix, deliver=deliver}})
      relay._response({{next_batch="s0"}}, "/_matrix/client/v3/sync")
      relay._response(payload("s1", {{{{type="m.room.message", event_id="$human-root",
        sender="@human:example.org", content={{msgtype="m.text", body="please help"}}}},
        {{type="m.room.message", event_id="$agent-root", sender="@agent-helper:example.org",
          content={{msgtype="m.text", body="@butler:example.org check this"}}}}}}),
        "/_matrix/client/v3/sync")
      local source_id, agent_id
      for mail_id, route in pairs(relay:state().routes) do
        if route.event_id == "$human-root" then source_id=mail_id end
        if route.event_id == "$agent-root" then agent_id=mail_id end
      end
      if not source_id then return "source-mail-route-missing" end
      if not agent_id then return "agent-mail-route-missing" end
      if not matrix.room_allowed(room) then return "request-config-does-not-allow-all-room" end

      remuda.http.respond("GET",
        "http://matrix.example.org/_matrix/client/v3/rooms/%21thread-restart-all%3Aexample.org/context/%24human-root",
        {{status=200, headers={{}}, body='{{"event":{{"room_id":"!thread-restart-all:example.org"}}}}'}})
      remuda.http.respond_prefix("PUT",
        "http://matrix.example.org/_matrix/client/v3/rooms/%21thread-restart-all%3Aexample.org/send/m.room.message/",
        {{status=200, headers={{}}, body='{{"event_id":"$butler-reply"}}'}})
      matrix.relay.instance = relay
      local completion, cli_completion
      remuda.pending = function()
        return {{resolve=function(_, code, stdout, stderr)
          cli_completion={{code=code, stdout=stdout, stderr=stderr}}
        end}}
      end
      matrix.relay.instance = nil
      matrix.cli({{"matrix", "reply", "$human-root", "no relay"}}, nil)
      if not cli_completion or cli_completion.code == 0
        or not cli_completion.stderr:find("relay is not running", 1, true) then return "cli-failed-open-without-relay" end
      matrix.relay.instance = relay
      -- Old rule (PR 1): a mail reply to a Butler's mail was refused with
      -- "Butler-to-Butler replies are disabled" and made no HTTP call. Replaced by
      -- the loop guard b2b_max_turns: it is queued for the Butler's event.
      local sent_ok, sent_error = pcall(remuda._butler_reply, "butler", agent_id, "to a butler")
      if not sent_ok then return "agent-mail-reply-refused:" .. tostring(sent_error) end
      local agent_queued = false
      for _, item in pairs(relay:state().reply_outbox) do
        if item.source_mail_id == agent_id and item.event_id == "$agent-root" then agent_queued = true end
      end
      if not agent_queued then return "agent-mail-reply-not-queued" end
      local source_message = remuda._butler_bus.messages[source_id]
      local saved_sender = source_message.matrix.sender
      local saved_route = relay:state().routes[source_id]
      source_message.matrix.sender = nil
      relay:state().routes[source_id] = nil
      local nil_sender_before = #remuda.http.calls
      local nil_sender_ok, nil_sender_error = pcall(remuda._butler_reply, "butler", source_id, "must refuse unknown sender")
      -- Old rule (PR 1): refused with "Butler-to-Butler replies are disabled".
      -- Still refused, fail closed and with no HTTP call; the text now names the
      -- missing route.
      if nil_sender_ok
        or not tostring(nil_sender_error):find("Matrix route for Butler mail " .. source_id .. " was not found", 1, true)
        or #remuda.http.calls ~= nil_sender_before then
        return "unknown-sender-mail-reply-not-refused:" .. tostring(nil_sender_error)
      end
      source_message.matrix.sender = saved_sender
      relay:state().routes[source_id] = saved_route
      local queued_reply = remuda._butler_reply("butler", source_id, "answer")
      for _=1,4 do remuda.http.tick() end
      if relay:state().routes[source_id].last_reply_event_id ~= "$butler-reply" then
        local pending = false
        for _, item in pairs(relay:state().reply_outbox) do pending = item.last_error or item.status end
        return "sent-event-not-correlated:" .. tostring(queued_reply) .. ":"
          .. tostring(relay:state().routes[source_id].last_reply_event_id) .. ":"
          .. tostring(pending) .. ":calls=" .. tostring(#remuda.http.calls)
      end
      local subscribed = relay:state().subscriptions[room]["$human-root"]
      if type(subscribed) ~= "table" or subscribed.mail_id ~= source_id then return "mail-reply-did-not-subscribe" end
      local threaded = false
      for _, call in ipairs(remuda.http.calls) do
        if call.method == "PUT" then
          local body=assert(matrix.decode_json(call.body))
          local rel=body["m.relates_to"] or {{}}
          if rel.rel_type=="m.thread" and rel.event_id=="$human-root"
            and rel["m.in_reply_to"].event_id=="$human-root" then threaded=true end
        end
      end
      if not threaded then return "butler-reply-was-not-threaded" end

      relay:stop()
      local restarted = matrix.relay.new({{config_path=config_path, matrix=matrix, deliver=deliver}})
      matrix.relay.instance = restarted
      local persisted = restarted:state().subscriptions[room]["$human-root"]
      if type(persisted) ~= "table" or persisted.mail_id ~= source_id then return "reply-subscription-not-persisted" end
      local followup={{{{type="m.room.message", event_id="$human-followup",
        sender="@human:example.org", content={{msgtype="m.text", body="thanks",
          ["m.relates_to"]={{rel_type="m.thread", event_id="$human-root",
            ["m.in_reply_to"]={{event_id="$butler-reply"}}}}}}}}}}
      restarted._response(payload("s2", followup), "/_matrix/client/v3/sync")
      local found
      for _, mail_id in ipairs(remuda._butler_mail.mailbox(remuda._butler_bus.agents.butler.id)) do
        local message=remuda._butler_bus.messages[mail_id]
        if message and message.matrix and message.matrix.event_id=="$human-followup" then found=message end
      end
      if not found then return "thread-followup-not-delivered" end
      if found.in_reply_to ~= source_id then return "original-context-lost:" .. tostring(found.in_reply_to) end
      restarted._response(payload("s3", followup), "/_matrix/client/v3/sync")
      local count=0
      for _, mail_id in ipairs(remuda._butler_mail.mailbox(remuda._butler_bus.agents.butler.id)) do
        local message=remuda._butler_bus.messages[mail_id]
        if message and message.matrix and message.matrix.event_id=="$human-followup" then count=count+1 end
      end
      return count==1 and "ok" or "duplicate-count:" .. tostring(count)
    "#,
      room=lua_raw_string(room), config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(result, "ok",
        "a no-mention Matrix thread reply after restart must return to Butler with original mail context: {result}");
}

#[test]
fn butler_matrix_pending_mail_survives_five_fast_lifecycle_restarts() {
    let dir = scratch_dir("mr-fast-restarts");
    let room = "!restart:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "fast-restarts", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    let token = token_path.to_string_lossy().into_owned();
    let config = config_path.to_string_lossy().into_owned();
    let _daemon = Daemon::spawn_with_env(&dir, &[
        ("REMUDA_BUTLER_TOKEN", token.as_str()),
        ("REMUDA_BUTLER_CONFIG", config.as_str()),
    ]);
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, "remuda._butler_test_mode='lifecycle'; remuda._butler_skip_relay=true");
    let out = remuda_timed(&dir, &["-s", "s", "butler", "--headless"]);
    assert!(out.status.success(), "load lifecycle Butler: {}", String::from_utf8_lossy(&out.stderr));
    eval(&path, include_str!("support/fake_http.lua"));
    let state_path = PathBuf::from(format!("{}.since", config_path.display()));
    std::fs::write(&state_path, serde_json::json!({
        "since":"s1", "processed_event_ids":[], "pending_events": {
            "$survives-restart": {"sender":"@alice:example.org", "room_id":room,
                "event_id":"$survives-restart", "created_at":"2026-09-28T01:02:03Z", "body":"keep me"}
        }
    }).to_string()).expect("seed pending event");
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda._butler_skip_relay=nil",
        lua_raw_string(&token), lua_raw_string(&config)));
    for _ in 0..5 { eval(&path, "remuda.reload('butler')"); }
    let result = eval(&path, r#"
      local relay = remuda.butler.matrix.relay.instance
      if not relay then return "relay-not-started" end
      local state = relay:state()
      if state.pending["$survives-restart"] then return "pending-not-acked" end
      if not state.processed["$survives-restart"] then return "pending-was-lost" end
      local root = remuda._butler_bus.agents.butler
      local found = 0
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = remuda._butler_bus.messages[id]
        if message and message.matrix and message.matrix.event_id == "$survives-restart" then found = found + 1 end
      end
      return found == 1 and "ok" or "mail-count:" .. tostring(found)
    "#);
    assert_eq!(result, "ok", "five quick restarts must not burn pending delivery failures or lose mail: {result}");
}

#[test]
fn butler_matrix_delivery_hook_errors_reach_relay_failure_accounting() {
    let dir = scratch_dir("mr-hook-error");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!hook-error:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "hook-error", "http://matrix.example.org", room, "@bot:example.org", "@alice:example.org");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let baseline = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0";
    let sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100";
    let event = serde_json::json!({"type":"m.room.message","event_id":"$hook-poison",
        "sender":"@alice:example.org","content":{"msgtype":"m.text","body":"poison"}});
    let response = serde_json::json!({"next_batch":"s1","rooms":{"join":{room:{"timeline":{"events":[event]}}}}});
    let result = eval(&path, &format!(r#"
      remuda.http.respond("GET", {baseline}, {{status=200,headers={{}},body='{{"next_batch":"s0"}}'}})
      remuda.http.respond("GET", {sync}, {{status=200,headers={{}},body={response}}})
      remuda._butler_inbox_delivery = function() error("injected real delivery hook failure") end
      remuda.relay_logs = {{}}
      local old_stderr=io.stderr; io.stderr={{write=function(_,line) table.insert(remuda.relay_logs,line) end}}
      local matrix=remuda.butler.matrix
      assert(matrix.relay.start(remuda._butler_matrix_config))
      remuda.http.tick(); remuda.http.tick()
      io.stderr=old_stderr
      local state=matrix.relay.instance:state()
      local pending=state.pending["$hook-poison"]
      if not pending then return "event-not-pending" end
      if pending._relay_failures ~= 1 then return "failure-not-accounted:" .. tostring(pending._relay_failures) end
      local logged=false
      for _,line in ipairs(remuda.relay_logs) do
        if line:find("injected real delivery hook failure",1,true) then logged=true end
      end
      if not logged then return "hook-failure-not-logged" end
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), sync=lua_raw_string(sync), response=lua_raw_string(&response.to_string())));
    assert_eq!(result, "ok", "the production hook path must turn thrown delivery errors into retryable failures: {result}");
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
      -- Receive rules: a non-allowlisted sender's text is delivered, marked untrusted.
      if #remuda.relay_deliveries ~= 3 then return "filter-or-page-dedup-failed:" .. #remuda.relay_deliveries end
      local e, fallback, stranger
      for _, value in ipairs(remuda.relay_deliveries) do
        if value.event_id == "$good" then e = value end
        if value.event_id == "$fallback-time" then fallback = value end
        if value.event_id == "$blocked" then stranger = value end
      end
      if not stranger or stranger.trusted ~= false then return "stranger-not-marked-untrusted" end
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
      if #remuda.relay_deliveries ~= 3 then return "restart-redelivered-processed-event" end
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
    let later_sync = "http://matrix.example.org/_matrix/client/v3/sync?since=s1&timeout=100";
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
      if not relay:state().processed["$poison"] then return "dead-lettered-poison-not-marked-processed" end
      local dead_letter_logged = false
      for _, line in ipairs(remuda.relay_logs) do
        if line:find("dead-lettered $poison after 5 failed attempts", 1, true) then dead_letter_logged=true end
      end
      if not dead_letter_logged then return "dead-letter-not-logged" end
      local normal_count = 0
      for _, id in ipairs(remuda.relay_deliveries) do if id == "$normal" then normal_count=normal_count+1 end end
      if normal_count ~= 1 then return "normal-event-not-delivered-exactly-once" end
      remuda.http.respond("GET", {later_sync}, {{ status=200, headers={{}}, body={poison_response} }})
      remuda.http.tick()
      remuda.http.tick()
      if remuda.relay_delivery_attempts["$poison"] ~= 5 then return "dead-lettered-id-was-retried" end
      relay:stop()
      return "ok"
    "#,
        baseline=lua_raw_string(baseline), first_sync=lua_raw_string(first_sync), later_sync=lua_raw_string(later_sync),
        response=lua_raw_string(&response.to_string()), poison_response=lua_raw_string(&serde_json::json!({"next_batch":"s2","rooms":{"join":{room:{"timeline":{"events":[{"type":"m.room.message","event_id":"$poison","sender":"@alice:example.org","content":{"msgtype":"m.text","body":"again"}}]}}}}}).to_string()),
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
    let repeated_old = serde_json::json!({
        "type":"m.room.message","event_id":"$old","sender":"@alice:example.org",
        "content":{"msgtype":"m.text","body":"must remain suppressed"}
    });
    let historical = serde_json::json!({"start":"b0","end":"b1","chunk":[repeated_old.clone()]});
    let current = serde_json::json!({"start":"b0","end":"b2","chunk":[repeated_old, {
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

#[cfg(unix)]
#[test]
fn butler_matrix_lua_relay_has_no_process_child_after_daemon_sigkill() {
    let dir = scratch_dir("butler-relay-sigkill");
    let (token_path, config_path) = butler_config(
        &dir, "sigkill", "http://127.0.0.1:1", "!relay:example.org", "@bot:example.org", "");
    let token = token_path.to_string_lossy().into_owned();
    let config = config_path.to_string_lossy().into_owned();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[("REMUDA_BUTLER_TOKEN", token.as_str()), ("REMUDA_BUTLER_CONFIG", config.as_str())],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path={}, config_path={} }}; \
         remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay'); \
         assert(remuda.butler.matrix.relay.start(remuda._butler_matrix_config))",
        lua_raw_string(&token), lua_raw_string(&config)));
    assert_eq!(read_count(&path, "return remuda.butler.matrix.relay.instance ~= nil and 1 or 0"), 1,
        "the in-process Lua relay must be active before daemon death");

    let daemon_pid = daemon.0.id() as i32;
    let children = descendant_pids_of(daemon_pid);
    let _child_guard = ProcessPidGuard(children.clone());
    assert!(children.is_empty(), "Lua relay unexpectedly started child processes: {children:?}");
    assert_eq!(unsafe { libc::kill(daemon_pid, libc::SIGKILL) }, 0,
        "SIGKILL of the private daemon must succeed");

    let deadline = Instant::now() + PATIENCE;
    while children.iter().any(|pid| process_pid_alive(*pid)) {
        assert!(Instant::now() < deadline,
            "a child process of the relay daemon survived SIGKILL: {children:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(children.iter().all(|pid| !process_pid_alive(*pid)),
        "no child process of the daemon may survive its SIGKILL");
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
      remuda.relay_state_logs = {{}}
      local old_stderr = io.stderr
      io.stderr = {{ write=function(_, value) table.insert(remuda.relay_state_logs, value) end }}
      local relay = remuda.butler.matrix.relay.new({{ config_path={config}, matrix=remuda.butler.matrix,
        deliver=function() return true end }})
      io.stderr = old_stderr
      if relay:state().since ~= nil or #relay:state().processed_order ~= 0 then return "malformed-state-not-reset" end
      if #remuda.relay_state_logs ~= 1 or not remuda.relay_state_logs[1]:find("invalid Matrix relay state", 1, true)
        then return "malformed-state-not-logged-once" end
      return "ok"
    "#, config=lua_raw_string(&config_path.to_string_lossy())));
    assert_eq!(malformed, "ok", "malformed JSON state must reset cleanly and log once");
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

#[test]
fn butler_matrix_relay_uses_system_trust_and_logs_empty_token_once() {
    let dir = scratch_dir("mr-config-log");
    let (_daemon, path) = butler_test_daemon(&dir);
    let (https_token, https_config) = butler_config(
        &dir, "https", "https://matrix.example.org", "!relay:example.org", "@bot:example.org", "");
    let (empty_token, empty_config) = butler_config(
        &dir, "empty", "http://matrix.example.org", "!relay:example.org", "@bot:example.org", "");
    std::fs::write(&empty_token, "").expect("seed empty token");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, "remuda.exec('butler/matrix_request'); remuda.exec('butler/matrix_relay')");
    let result = eval(&path, &format!(r#"
      local old_stderr = io.stderr
      remuda.relay_config_logs = {{}}
      io.stderr = {{ write=function(_, value) table.insert(remuda.relay_config_logs, value) end }}
      local function run(token, config)
        remuda._butler_matrix_config = {{ token_path=token, config_path=config }}
        local relay = remuda.butler.matrix.relay.new({{ config_path=config, matrix=remuda.butler.matrix,
          deliver=function() return true end }})
        relay:start()
        for _=1,30 do remuda.http.tick() end
        relay:stop()
      end
      run({https_token}, {https_config})
      run({empty_token}, {empty_config})
      io.stderr = old_stderr
      if #remuda.relay_config_logs ~= 1 then return "expected-one-warning:" .. #remuda.relay_config_logs end
      local https, empty = false, false
      for _, line in ipairs(remuda.relay_config_logs) do
        if line:find("HTTPS Matrix homeserver requires", 1, true) then https = true end
        if line:find("Matrix token is empty", 1, true) then empty = true end
      end
      if https then return "unexpected-https-warning" end
      if not empty then return "missing-empty-token-warning" end
      return "ok"
    "#,
        https_token=lua_raw_string(&https_token.to_string_lossy()),
        https_config=lua_raw_string(&https_config.to_string_lossy()),
        empty_token=lua_raw_string(&empty_token.to_string_lossy()),
        empty_config=lua_raw_string(&empty_config.to_string_lossy())));
    assert_eq!(result, "ok", "relay should use system trust for HTTPS and still log invalid tokens: {result}");
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
    // The builder probes whichever `remuda` is on PATH; pin the answer instead.
    let build = |supported: bool| {
        eval(
            &path,
            &format!(
                r#"remuda._butler_codex_config_supported = {supported}; local a = remuda._butler_agent_builders.codex({{name="codex", token="token", telemetry={{status_path="/tmp/status"}}}}); return table.concat(a, "\n")"#
            ),
        )
    };
    let old = ["remuda", "_codex_tui", "--status", "/tmp/status"];
    let argv = build(false);
    assert_eq!(argv.lines().collect::<Vec<_>>(), old, "old core: {argv}");

    // #201: the real builder and the real `mcp_flags` give Codex the MCP server.
    let argv = build(true);
    let argv: Vec<&str> = argv.lines().collect();
    assert_eq!(argv.len(), 10, "{argv:?}");
    assert_eq!(argv[..4], old);
    assert_eq!(
        argv[4..6],
        ["-c", r#"mcp_servers.remuda.command="remuda""#],
        "{argv:?}"
    );
    assert!(
        argv[6] == "-c" && argv[7].starts_with(r#"mcp_servers.remuda.args=["-s",""#),
        "{argv:?}"
    );
    assert!(
        argv[8] == "-c"
            && argv[9].starts_with(r#"mcp_servers.remuda.env={REMUDA_SESSION_CAPABILITY="token""#),
        "{argv:?}"
    );
}

/// Codex folder trust is automatic only for directories Butler created.
#[test]
#[cfg(unix)]
fn butler_codex_trust_dialog_only_auto_trusts_butler_created_directories() {
    let dir = scratch_dir("butler-codex-trust");
    let home = dir.join("home");
    let project_home = dir.join("projects");
    let existing_dir = project_home.join("existing-trust");
    std::fs::create_dir_all(&home).expect("test home");
    std::fs::create_dir_all(&existing_dir).expect("pre-existing topic directory");
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
    let fixture = format!(
        "{}{}",
        include_str!("fixtures/codex-trust-dialog.txt").trim_end(),
        "\n".repeat(8)
    );
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({project_home:?})
          remuda._butler_agent_builders.codex = function() return {{"sh", "-c", "sleep 30"}} end
          remuda._butler_test_force_launch_probe = {{["created-trust"] = true, ["existing-trust"] = true}}
          local dialog = {fixture:?}
          local screens = {{["created-trust"] = dialog, ["existing-trust"] = dialog}}
          local actions, reports = {{}}, {{}}
          remuda.capture = function(name) return screens[name] or "" end
          remuda.key = function(name, key)
            actions[#actions + 1] = name .. " key " .. key
            if name == "created-trust" and key == "1" then
              screens[name] = "› Ask Codex to do anything"
            end
          end
          remuda._butler_send = function(_, _, message) reports[#reports + 1] = message end
          remuda._butler_topic_new("created-trust", nil, "codex")
          remuda._butler_topic_new("existing-trust", nil, "codex")
          remuda._codex_trust_actions = actions
          remuda._codex_trust_reports = reports
        "#,
            project_home = project_home.to_string_lossy(),
            fixture = fixture,
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let actions = eval(&path, "return table.concat(remuda._codex_trust_actions, '\\n')");
        let reports = eval(&path, "return table.concat(remuda._codex_trust_reports, '\\n')");
        let ready = eval(&path, "return tostring(remuda._butler_bus.agents['created-trust'] ~= nil and remuda._butler_bus.agents['existing-trust'] ~= nil)");
        if ready == "true" && reports.contains(&existing_dir.to_string_lossy().to_string()) {
            assert!(
                actions.lines().any(|line| line == "created-trust key 1"),
                "a Butler-created directory should select Trust and continue; actions={actions:?}; reports={reports:?}"
            );
            assert!(
                !actions.lines().any(|line| line.starts_with("existing-trust key ")),
                "an existing directory must not receive a key: {actions:?}"
            );
            assert!(
                reports.contains("waiting for a human: trust dialog in"),
                "the pre-existing directory should alert its leader: {reports:?}"
            );
            break;
        }
        assert!(Instant::now() < deadline, "Codex trust launch did not settle: actions={actions:?}; reports={reports:?}; ready={ready}");
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(daemon);
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
    let claude_trust_capture = include_str!("fixtures/claude-trust-dialog.txt");
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
          -- The shared data home can hold unread root mail from earlier tests.
          remuda._butler_inbox("butler")
          remuda._butler_session_trace_path = {trace:?}
          remuda._butler_task_poke_attempts = 6
          remuda._butler_test_force_launch_probe = {{
            ["t-claude"] = true,
            ["t-claude-launch"] = true,
            ["t-claude-human-trust"] = true,
            ["t-claude-launch-unknown"] = true,
            ["t-claude-launch-transient"] = true,
          }}
          remuda._butler_agent_builders.claude = function() return {{"sh"}} end
          remuda._butler_agent_builders.codex = function() return {{"sh", "-c", "sleep 30"}} end
          local rule = string.rep("─", 20)
          local screens = {{
            ["t-claude"] = {{
              rule .. "\n Accessing workspace:\n\n " .. {t_claude_root:?} .. "\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel",
              rule .. "\n Accessing workspace:\n\n " .. {t_claude_root:?} .. "\n\n ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel",
              rule .. "\n❯ \n" .. rule,
            }},
            ["t-claude-launch"] = {{
              "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n"
                .. " Accessing workspace:\n\n /private/tmp/t3qa/untrusted-13690\n\n"
                .. " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source",
              {claude_trust_capture:?},
              {claude_trust_capture:?},
              rule .. "\n❯ \n" .. rule,
            }},
            ["t-claude-launch-unknown"] = {{ "Workspace access changed\n ❯ 1. Continue\n   2. Cancel" }},
            ["t-claude-launch-transient"] = {{ "Continue setup", rule .. "\n❯ \n" .. rule }},
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
          local claude_yes_selected = screens["t-claude"][1]
            :gsub("❯ No, exit", "  No, exit")
            :gsub("   Yes, I trust this folder", "❯ Yes, I trust this folder")
          local log = {{}}
          local human_owner_update_started = false
          local versionless_launches = 0
          remuda._t = log
          remuda._butler_bus.codex_update_state = {{claimed=false, done=false}}
          remuda._butler_codex_update_timeout = 2
          remuda._butler_modal_timeout = 3
          -- Hold the notice clock until every give-up is queued, so the
          -- leader's notices always batch (#126).
          remuda._butler_notice_clock = function() return 0 end
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
            if n == "t-claude" and k == "<down>" then
              screens[n] = {{ claude_yes_selected, claude_yes_selected, rule .. "\n❯ \n" .. rule }}
            elseif n == "t-claude" and k == "RET" then
              screens[n] = {{ rule .. "\n❯ \n" .. rule }}
            elseif n == "t-claude-launch" and k == "RET" then
              screens[n] = {{ rule .. "\n❯ \n" .. rule }}
            elseif (n == "t-codex" or n == "t-codex-peer") and k == "1" then
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
          -- Members' fixture Welcome mail is not under test here; keep its
          -- unread notice out of the per-session logs.
          local notify = remuda._butler_notify
          remuda._butler_notify = function(alias, notice, id)
            local m = id and remuda._butler_mail.find_message(id)
            if m and m.subject == "Welcome to Butler" then return true end
            return notify(alias, notice, id)
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
          remuda._butler_launch("claude", "t-claude-launch")
          remuda._butler_launch("claude", "t-claude-launch-unknown")
          remuda._butler_launch("claude", "t-claude-launch-transient")
        "#,
            home = home.to_string_lossy(),
            trace = trace.to_string_lossy(),
            claude_trust_capture = claude_trust_capture,
            t_claude_root = home.join("t-claude").to_string_lossy(),
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(25);
    let log = loop {
        let log = eval(&path, "return table.concat(remuda._t, '\\n')");
        let traced = std::fs::read_to_string(&trace).unwrap_or_default();
        // The leader's "task not delivered" notice is typed too; count only
        // the topic sessions' own lines.
        let typed = log.lines().filter(|l| l.starts_with("t-") && l.contains(" type ")).count();
        if [
            "t-stuck",
            "t-codex-unanswerable",
            "t-codex-human",
            "t-claude-human-trust",
        ]
        .iter()
        .all(|n| traced.contains(&format!("task_poke_timeout\t{n}")))
            && traced.contains("launch_failed\tt-claude-launch-unknown")
        {
            eval(&path, "remuda._butler_notice_clock = nil");
        }
        // Notices batch: one "Butler message ID ..." or "N new Butler messages".
        let leader_noticed = log
            .lines()
            .any(|l| {
                l.starts_with("butler type ")
                    && (l.contains("Butler message") || l.contains("new Butler messages arrived"))
            });
        if typed == 3 && traced.contains("task_poke_timeout\tt-stuck")
            && leader_noticed
            && eval(&path, "return tostring(remuda._butler_bus.agents['t-claude-launch'] ~= nil)") == "true"
            && eval(&path, "return tostring(remuda._butler_bus.agents['t-claude-launch-transient'] ~= nil)") == "true"
            && eval(&path, "return remuda._butler_sessions()")
                .contains("Workspace access changed")
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
    let launch_rows: Vec<&str> = log.lines().filter(|l| l.starts_with("t-claude-launch key ")).collect();
    assert_eq!(launch_rows, ["t-claude-launch key <down>", "t-claude-launch key RET"],
        "launch did not answer the exact captured trust dialog: {log}");
    let launch_report = eval(&path, "return remuda._butler_sessions()");
    assert!(launch_report.contains("Workspace access changed"),
        "failed launch omitted the unknown dialog's label: {launch_report}");
    assert!(!launch_report.contains("t-claude-launch-transient: claude: dialog"),
        "a changing partial screen was rejected as an unknown dialog: {launch_report}");
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
    assert!(std::fs::read_to_string(&trace).unwrap_or_default().contains("Workspace access changed"),
        "launch failure did not preserve the unknown dialog label");
    assert!(log.contains(" type Butler message ") || log.contains(" new Butler messages arrived"),
        "the leader is told about t-stuck: {log}");
    assert_eq!(eval(&path, "local found=false; for _,o in pairs(remuda._butler_bus.objects) do if (o.content or ''):find('Task for t-stuck was not delivered', 1, true) then found=true end end; return tostring(found)"),
        "true", "the task-poke failure was not mailed to the leader");
    // A batched notice does not name t-stuck; its give-up mail must.
    let leader_mail = eval(
        &path,
        r#"
          local bus, out = remuda._butler_bus, {}
          local id = bus.agents[remuda._butler_initial_name].id
          for _, m in ipairs(remuda._butler_mail.mailbox(id)) do
            local message = bus.messages[m]
            local object = message and bus.objects[message.body.object_id]
            out[#out + 1] = object and object.content or ""
          end
          return table.concat(out, "\n")
        "#,
    );
    assert!(
        leader_mail.contains("Task for t-stuck was not delivered"),
        "the leader is told about t-stuck: {leader_mail}"
    );
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
        if traced.contains("codex_update_timeout\tt-codex-timeout")
            && log.contains("type Butler message") {
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

/// A delegated Claude trust dialog without a readable workspace path stays for
/// the human even when its requested cwd is inside the trusted project tree.
#[test]
#[cfg(unix)]
fn butler_topic_delegate_leaves_unreadable_claude_trust_path_for_human() {
    let dir = scratch_dir("topic-claude-trust-unreadable");
    let home = dir.join("home");
    let projects = home.join("projects");
    std::fs::create_dir_all(&projects).expect("projects");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 30"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let root_leader = eval(&path, "return remuda._butler_initial_name");
    wait_for_butler_agent(&path, &root_leader);
    let dialog = include_str!("fixtures/claude-trust-dialog.txt");
    let unreadable_dialog = dialog.replace(
        "/private/tmp/t3qa/untrusted-13690",
        "workspace path unavailable",
    );
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({projects:?})
          remuda._butler_agent_builders.claude = function() return {{"sh"}} end
          remuda._butler_test_force_launch_probe = {{["unreadable-topic"] = true}}
          local screens = {{["unreadable-topic"] = {unreadable_dialog:?}}}
          local actions = {{}}
          remuda.capture = function(name) return screens[name] or "" end
          remuda.key = function(name, key)
            actions[#actions + 1] = name .. " key " .. key
          end
          remuda.type_text = function(name, text)
            actions[#actions + 1] = name .. " type " .. text
          end
          remuda._butler_send = function() end
          remuda._butler_topic_delegate("unreadable-topic", "brief", nil, "claude", remuda._butler_initial_name)
          remuda._unreadable_trust_actions = actions
        "#,
            projects = projects.to_string_lossy(),
            unreadable_dialog = unreadable_dialog,
        ),
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let actions = eval(&path, "return table.concat(remuda._unreadable_trust_actions, '\\n')");
        assert!(
            !actions.contains("unreadable-topic key "),
            "an unparseable displayed workspace path must not be auto-trusted: {actions}"
        );
        let sessions = eval(&path, "return remuda._butler_sessions()");
        if sessions.contains("unreadable-topic") && sessions.contains("Next:") {
            break;
        }
        assert!(Instant::now() < deadline, "human trust guidance did not appear: {sessions}");
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(daemon);
}

/// Topic delegation may answer Claude's captured trust dialog only for a
/// workspace in the member's allowed project tree, and only after verifying
/// that Down selected the affirmative row.
#[test]
#[cfg(unix)]
fn butler_topic_delegate_checks_claude_trust_path_and_selection() {
    let dir = scratch_dir("topic-claude-trust-policy");
    let home = dir.join("home");
    let projects = home.join("projects");
    let outside = dir.join("outside-projects");
    std::fs::create_dir_all(&projects).expect("projects");
    std::fs::create_dir_all(&outside).expect("outside projects");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 30"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let root_leader = eval(&path, "return remuda._butler_initial_name");
    wait_for_butler_agent(&path, &root_leader);
    let dialog = include_str!("fixtures/claude-trust-dialog.txt");
    let allowed_root = projects.join("allowed-topic");
    let outside_root = outside.join("outside-topic");
    let allowed_dialog = dialog.replace(
        "/private/tmp/t3qa/untrusted-13690",
        &allowed_root.to_string_lossy(),
    );
    let allowed_yes_selected = allowed_dialog
        .replace("❯ No, exit", "  No, exit")
        .replace("   Yes, I trust this folder", "❯ Yes, I trust this folder");
    let outside_dialog = dialog
        .replace("/private/tmp/t3qa/untrusted-13690", &outside_root.to_string_lossy());
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({projects:?})
          remuda._butler_task_poke_attempts = 6
          remuda._butler_agent_builders.claude = function() return {{"sh"}} end
          remuda._butler_test_force_launch_probe = {{["allowed-topic"] = true, ["outside-topic"] = true}}
          local rule = string.rep("─", 20)
          local screens = {{["allowed-topic"] = {allowed_dialog:?}, ["outside-topic"] = {outside_dialog:?}}}
          local log, after_down_captures = {{}}, {{["allowed-topic"] = 0, ["outside-topic"] = 0}}
          remuda.capture = function(name)
            if name == "allowed-topic" and #log > 0 and log[#log] == "allowed-topic key <down>" then
              after_down_captures[name] = after_down_captures[name] + 1
            end
            return screens[name] or ""
          end
          remuda.key = function(name, key)
            log[#log + 1] = name .. " key " .. key
            if name == "allowed-topic" and key == "<down>" then
              screens[name] = {allowed_yes_selected:?}
            elseif name == "allowed-topic" and key == "RET" then
              screens[name] = rule .. "\n❯ \n" .. rule
            elseif name == "outside-topic" and key == "<down>" then
              -- Deliberately leave No selected after Down in this unexpected UI.
              screens[name] = {outside_dialog:?}
            end
          end
          remuda.type_text = function(name, text) log[#log + 1] = name .. " type " .. text end
          remuda._butler_topic_delegate("allowed-topic", "allowed brief", nil, "claude", remuda._butler_initial_name)
          remuda._butler_topic_delegate("outside-topic", "outside brief", nil, "claude", remuda._butler_initial_name)
          remuda._topic_trust_log = log
          remuda._topic_trust_captures = after_down_captures
        "#,
            projects = projects.to_string_lossy(),
            allowed_dialog = allowed_dialog,
            allowed_yes_selected = allowed_yes_selected,
            outside_dialog = outside_dialog,
        ),
    );
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let log = eval(&path, "return table.concat(remuda._topic_trust_log, '\\n')");
        if log.contains("allowed-topic type allowed brief")
            || Instant::now() >= deadline
        {
            assert!(log.contains("allowed-topic key <down>"), "no selection move: {log}");
            assert!(log.contains("allowed-topic key RET"), "allowed trust was not confirmed: {log}");
            assert!(
                eval(&path, "return tostring(remuda._topic_trust_captures['allowed-topic'] > 0)") == "true",
                "Claude's selection was not recaptured after Down"
            );
            assert!(
                !log.contains("outside-topic key RET"),
                "unverified selection was confirmed: {log}"
            );
            let sessions = eval(&path, "return remuda._butler_sessions()");
            assert!(
                sessions.contains("outside-topic") && sessions.contains("Next:"),
                "outside workspace failure needs a clear Next step: {sessions}"
            );
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    drop(daemon);
}

/// The delegate CLI must pass its --cwd option through to the new member.
#[test]
#[cfg(unix)]
fn butler_topic_delegate_passes_cwd_to_agent_launch() {
    let dir = scratch_dir("topic-delegate-cwd");
    let home = dir.join("home");
    let project_home = dir.join("projects");
    let requested_cwd = dir.join("requested-cwd");
    std::fs::create_dir_all(&home).expect("test home");
    std::fs::create_dir_all(&project_home).expect("project home");
    std::fs::create_dir_all(&requested_cwd).expect("requested cwd");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 30"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let root_leader = eval(&path, "return remuda._butler_initial_name");
    wait_for_butler_agent(&path, &root_leader);
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({project_home:?})
          remuda._butler_agent_builders.claude = function() return {{"sh", "-c", "sleep 30"}} end
          remuda._butler_test_force_launch_probe = {{["cwd-topic"] = true}}
          local native_new, rows = remuda.new, {{}}
          remuda.new = function(name, argv, cwd, env)
            rows[#rows + 1] = name .. " cwd " .. tostring(cwd)
            return native_new(name, argv, cwd, env)
          end
          remuda._topic_cwd_rows = rows
        "#,
            project_home = project_home.to_string_lossy(),
        ),
    );
    let cli = remuda_timed(
        &dir,
        &[
            "-s",
            "s",
            "butler",
            "topic",
            "delegate",
            "cwd-topic",
            "--agent",
            "claude",
            "--cwd",
            requested_cwd.to_str().expect("cwd path utf8"),
            "brief",
        ],
    );
    assert!(cli.status.success(), "{}", String::from_utf8_lossy(&cli.stderr));
    let rows = eval(&path, "return table.concat(remuda._topic_cwd_rows, '\\n')");
    assert!(
        rows.contains(&requested_cwd.to_string_lossy().to_string()),
        "--cwd did not reach remuda.new: {rows}"
    );
    let root = project_home.join("cwd-topic");
    let root_grant = eval(
        &path,
        &format!(
            "local d = remuda._butler_bus.trusted_launch_dirs return tostring(d and d[{:?}])",
            root.to_string_lossy()
        ),
    );
    assert_eq!(root_grant, "nil", "a non-root --cwd must not leave a root trust grant");
    drop(daemon);
}

/// A just-started --leader is retried to readiness within the bound; if it
/// stays unready, delegation returns a bounded, actionable wait error.
#[test]
#[cfg(unix)]
fn butler_topic_delegate_retries_leader_readiness_and_reports_wait_on_timeout() {
    let dir = scratch_dir("topic-delegate-leader-wait");
    let home = dir.join("home");
    let projects = home.join("projects");
    std::fs::create_dir_all(&home).expect("test home");
    std::fs::create_dir_all(&projects).expect("project home");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(
        &path,
        r#"remuda._butler_argv = {"sh", "-c", "sleep 30"}; remuda._butler_skip_relay = true"#,
    );
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let root_leader = eval(&path, "return remuda._butler_initial_name");
    wait_for_butler_agent(&path, &root_leader);
    eval(
        &path,
        &format!(
            r#"
          remuda.butler.project_home({projects:?})
          remuda._butler_agent_builders.claude = function() return {{"sh", "-c", "sleep 30"}} end
          remuda._butler_test_force_launch_probe = {{["ready-topic"] = true}}
          local parent = "just-started-leader"
          remuda.new(parent, {{"sh", "-c", "sleep 30"}})
          remuda._topic_parent = parent
          remuda._topic_ready = true
          remuda._topic_expect_ticks = 0
          local native_expect = remuda.expect
          remuda.expect = function(session, branches, options)
            if session ~= remuda._topic_parent then return native_expect(session, branches, options) end
            for tick = 1, 4 do
              remuda._topic_expect_ticks = tick
              if remuda._topic_ready and tick == 2 then
                local id = remuda._butler_new_ulid()
                local identity = {{id = id, alias = session, kind = "claude", state = "running"}}
                remuda._butler_bus.identities[session] = identity
                remuda._butler_bus.identity_ids[id] = identity
                remuda._butler_bus.agents[session] = {{id = id, alias = session, kind = "claude", children = {{}}}}
                return {{state = {{status = "matched"}}}}
              end
            end
            return {{state = {{status = "timeout"}}}}
          end
        "#,
            projects = projects.to_string_lossy(),
        ),
    );
    let leader = eval(&path, "return remuda._topic_parent");
    let success = remuda_timed(
        &dir,
        &[
            "-s", "s", "butler", "topic", "delegate", "ready-topic", "--agent", "claude",
            "--leader", &leader, "brief",
        ],
    );
    assert!(
        success.status.success(),
        "delegation should retry until the leader becomes live: {}",
        String::from_utf8_lossy(&success.stderr)
    );
    assert_eq!(
        eval(&path, "return tostring(remuda._topic_expect_ticks == 2)"),
        "true",
        "the leader became live on the second expect tick"
    );

    eval(
        &path,
        r#"remuda._butler_bus.agents[remuda._topic_parent] = nil; remuda._topic_ready = false; remuda._topic_expect_ticks = 0"#,
    );
    let timeout = remuda_timed(
        &dir,
        &[
            "-s", "s", "butler", "topic", "delegate", "timeout-topic", "--agent", "claude",
            "--leader", &leader, "brief",
        ],
    );
    let message = format!(
        "{}\n{}",
        String::from_utf8_lossy(&timeout.stdout),
        String::from_utf8_lossy(&timeout.stderr)
    );
    assert!(!timeout.status.success(), "unready leader unexpectedly proceeded: {message}");
    assert!(
        message.to_lowercase().contains("wait") && message.contains("Next:"),
        "unready leader error must say wait and provide a Next step: {message}"
    );
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

#[test]
fn butler_matrix_relay_starts_on_fallback_boot_and_only_once() {
    let dir = scratch_dir("matrix-fallback-boot");
    let room = "!fallback-boot:example.org";
    let (token_path, config_path) = butler_config(
        &dir, "fallback-boot", "http://matrix.example.org", room, "@bot:example.org", "");
    let token = token_path.to_string_lossy().into_owned();
    let config = config_path.to_string_lossy().into_owned();
    let _daemon = Daemon::spawn_with_env(&dir, &[
        ("REMUDA_BUTLER_TOKEN", token.as_str()),
        ("REMUDA_BUTLER_CONFIG", config.as_str()),
    ]);
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, include_str!("support/fake_http.lua"));
    let init = include_str!("../../packages/butler/init.lua");
    let result = eval(&path, &format!(r#"
      remuda._butler_test_mode = "lifecycle"
      local fallback
      local original_schedule = remuda.schedule
      remuda.schedule = function(spec)
        if spec.name == "butler-start-fallback" then fallback = spec end
        return original_schedule(spec)
      end
      local old_metatable = getmetatable(_G)
      setmetatable(_G, {{ __index = {{ remuda = remuda }} }})
      local module = (function()
{init}
      end)()
      setmetatable(_G, old_metatable)
      remuda.schedule = original_schedule
      if not fallback then return "fallback-schedule-missing" end
      fallback.run()
      local after_fallback = #remuda.http.calls
      module.start(module.initialize())
      return after_fallback .. "|" .. #remuda.http.calls
    "#));
    assert_eq!(result, "1|1",
        "fallback boot must start the Matrix relay once, and lifecycle startup must not duplicate it: {result}");
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
            && matrix_init.contains("stop_legacy_matrix_relay()")
            && matrix_init.contains("matrix.relay.start(host._butler_matrix_config)")
            && !matrix_impl.contains("matrix.relay.start(remuda._butler_matrix_config)")
            && init_lua.contains("__butler_delivery_hook_error")
            && matrix_relay.contains("function instance:stop()")
            && matrix_relay.contains("request_handle:cancel()")
            && !main_lua.contains("pkill -f"),
        "the async Matrix relay must be cancelled through its public lifecycle table"
    );
    assert!(
        init_lua.contains("event = \"session_exited\", id = \"identity\"")
            && init_lua.contains("host._butler_session_exited(name, info)")
            && main_lua.contains("function remuda._butler_session_exited(name, info)")
            && main_lua.contains("type(info) == \"table\" and info.instance_id or nil")
            && main_lua.contains("stale_session_exit(name, instance_id)")
            && main_lua.contains("session.instance_id ~= instance_id")
            && main_lua[launch_fn_idx..].contains("remuda._butler_reconcile()"),
        "the declared session-exit hook must use the shared reconciler"
    );
    assert!(
        init_lua.contains("name = \"butler-reconcile\"")
            && init_lua.contains("host._butler_reconcile then host._butler_reconcile()"),
        "butler needs a periodic reconciler as well as an exit event hook"
    );
}

#[test]
fn butler_session_exited_ignores_stale_instance_and_handles_current_instance() {
    let dir = scratch_dir("butler-session-exit-instance-id");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let result = eval(
        &path,
        r#"
          local name = "reused-session"
          local bus = remuda._butler_bus
          local original_ls = remuda.ls
          remuda.ls = function()
            return {{ name = name, alive = true, instance_id = "new-instance" }}
          end
          bus.notices[name] = "pending notice"
          bus.notice_screens[name] = "notice screen"
          bus.pending_tasks[name] = "pending task"

          remuda.emit("session_exited", name,
            { reason = "exited", instance_id = "old-instance" })
          local stale_ignored = bus.notices[name] == "pending notice"
            and bus.notice_screens[name] == "notice screen"
            and bus.pending_tasks[name] == "pending task"

          remuda.emit("session_exited", name,
            { reason = "closed", instance_id = "new-instance" })
          local current_handled = bus.notices[name] == nil
            and bus.notice_screens[name] == nil
            and bus.pending_tasks[name] == nil

          bus.notices[name] = "legacy notice"
          bus.notice_screens[name] = "legacy screen"
          bus.pending_tasks[name] = "legacy task"
          remuda.emit("session_exited", name, { reason = "closed" })
          local missing_id_falls_back = bus.notices[name] == nil
            and bus.notice_screens[name] == nil
            and bus.pending_tasks[name] == nil
          remuda.ls = original_ls
          return tostring(stale_ignored) .. ":" .. tostring(current_handled)
            .. ":" .. tostring(missing_id_falls_back)
        "#,
    );
    assert_eq!(
        result,
        "true:true:true",
        "stale exits are ignored; current and missing-id exits are handled"
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
    let data_str = own_data_home(&dir).to_string_lossy().to_string();
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
    eval(&path, &format!("remuda._butler_inbox({butler_name:?})"));
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
    eval(&path, &format!("remuda._butler_inbox({butler_name:?})"));
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
/// The fake Claude process accepts Butler's cheaper-model compaction sequence.
#[test]
#[cfg(unix)]
fn butler_compaction_fake_claude_scenarios_send_only_visible_keys() {
    let dir = scratch_dir("butler-fake-claude");
    std::fs::create_dir_all(dir.join(".claude")).unwrap();
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
    let data_str = own_data_home(&dir).to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    eval(&path, r#"
      remuda._butler_state = remuda._butler_state or {}
      remuda._butler_state.compaction_members = {legacy={pending_restore_blocked=true,
        pending_restore_model_unavailable=true, pending_restore_model="opus"}}
    "#);
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(
        eval(&path, "return type(remuda._butler_compaction_tick)"),
        "function",
        "loading the Butler module must define the scheduled compaction tick"
    );
    assert_eq!(
        eval(&path, "local s = remuda._butler_state or {}; local m = s.compaction_members.legacy or {}; return tostring(m.pending_restore_blocked == nil and m.pending_restore_model_unavailable == nil and m.pending_restore_model == nil)"),
        "true",
        "loading must clear stale model-restore state"
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
    let model_confirm_fixture = dir.join("claude-model-confirm-dialog.txt");
    let status_model_confirm_fixture = dir.join("claude-model-confirm-dialog-with-status.txt");
    let changing_status_model_confirm_fixture = dir.join("claude-model-confirm-dialog-changing-status.txt");
    let wrong_title_model_confirm_fixture = dir.join("claude-model-confirm-wrong-title.txt");
    let stale_model_confirm_fixture = dir.join("claude-stale-model-confirm-with-permission.txt");
    std::fs::write(
        &model_confirm_fixture,
        include_str!("fixtures/claude-model-confirm-dialog.txt"),
    )
    .expect("write captured Claude model confirmation fixture");
    std::fs::write(
        &status_model_confirm_fixture,
        include_str!("fixtures/claude-model-confirm-dialog-with-status.txt"),
    )
    .expect("write model confirmation fixture with trailing status rows");
    std::fs::write(
        &changing_status_model_confirm_fixture,
        include_str!("fixtures/claude-model-confirm-dialog-changing-status.txt"),
    )
    .expect("write model confirmation fixture with a changing status row");
    std::fs::write(
        &wrong_title_model_confirm_fixture,
        include_str!("fixtures/claude-model-confirm-wrong-title.txt"),
    )
    .expect("write wrong-title model confirmation fixture");
    std::fs::write(
        &stale_model_confirm_fixture,
        include_str!("fixtures/claude-stale-model-confirm-with-permission.txt"),
    )
    .expect("write stale model confirmation plus tool permission fixture");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
model_confirm_fixture=$3
stale_model_confirm_fixture=$4
wrong_title_model_confirm_fixture=$5
status_model_confirm_fixture=$6
changing_status_model_confirm_fixture=$7
model='current-model'
ctx=500000
failed=0
paint() {
  printf '\033[H\033[2JMODEL:%s CTX:%s' "$model" "$ctx"
  if [ "$scenario" = busy-screen ] || { [ "$scenario" = hang ] && [ "$failed" = 1 ]; }; then
    printf ' esc to interrupt'
  fi
  if [ "$scenario" = draft ]; then printf ' DRAFT: unsent words'; fi
  printf '\n'
}
paint
while IFS= read -r line; do
  printf 'CMD:%s\n' "$line" >> "$log"
  case "$line" in
    '')
      if [ "$scenario" = model-confirm ] || [ "$scenario" = model-confirm-with-status ] \
          || [ "$scenario" = model-confirm-transient ] || [ "$scenario" = model-confirm-changing-status ] \
          || [ "$scenario" = model-confirm-static ]; then
        printf 'KEY:RET\n' >> "$log"
        model='sonnet'
        paint
      fi
      ;;
    '/model sonnet')
      printf 'KEY:RET\n' >> "$log"
      if [ "$scenario" = model-confirm ]; then
        cat "$model_confirm_fixture"
      elif [ "$scenario" = model-confirm-with-status ]; then
        cat "$status_model_confirm_fixture"
      elif [ "$scenario" = model-confirm-transient ]; then
        printf 'MODEL:%s CTX:%s\n❯ 1. Yes, switch to Sonnet 5.5\n  2. No, go back\n' "$model" "$ctx"
        sleep 0.3
        cat "$model_confirm_fixture"
      elif [ "$scenario" = model-confirm-changing-status ]; then
        cat "$changing_status_model_confirm_fixture"
      elif [ "$scenario" = model-confirm-static ]; then
        cat "$model_confirm_fixture"
      elif [ "$scenario" = stale-model-confirm ]; then
        cat "$stale_model_confirm_fixture"
      elif [ "$scenario" = wrong-title-model-confirm ]; then
        cat "$wrong_title_model_confirm_fixture"
      else
        model='sonnet'; paint
      fi
      if [ "$scenario" = settings-mismatch ]; then printf '{"model":"sonnet","theme":"dark"}\n' > "$HOME/.claude/settings.json"; fi
      ;;
    '/compact')
      printf 'KEY:RET\n' >> "$log"
      if { [ "$scenario" = unknown ] || [ "$scenario" = unknown-restore-fails ]; } && [ "$failed" = 0 ]; then
        failed=1
        printf 'Mystery chooser\n1. Continue\n❯\n'
      elif [ "$scenario" = hang ]; then
        failed=1; paint
      else
        if [ "$scenario" = codex-no-record ]; then ctx=$((ctx - 100000)); else ctx=200000; fi
        paint
      fi
      ;;
    '/model opus')
      printf 'KEY:RET\n' >> "$log"
      if [ "$scenario" != unknown-restore-fails ]; then model='opus'; fi
      paint
      ;;
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
      local fake_now = 1000
      remuda._butler_compaction_now = function() return fake_now end
      remuda._fake_now = function(value) fake_now = value end
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=0.2, failure_cooldown_seconds=10, input_settle=0.01}}
      remuda._butler_bus = remuda._butler_bus or {{agents={{}}, pending_tasks={{}}, notices={{}}}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="claude", entry={{working=function(_, screen)
            return screen:find("esc to interrupt", 1, true) ~= nil
          end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function(_, screen)
        return screen:find("DRAFT:", 1, true) and "NON-EMPTY" or "EMPTY"
      end
      local original_capture = remuda.capture
      remuda.capture = function(name)
        local screen = original_capture(name)
        if name == "fake-model-confirm-changing-status" then
          remuda._fake_model_confirm_status_tick = (remuda._fake_model_confirm_status_tick or 0) + 1
          screen = screen:gsub("Status tick: %d+", "Status tick: " .. remuda._fake_model_confirm_status_tick)
        end
        if name == "fake-model-confirm" or name == "fake-model-confirm-transient"
            or name == "fake-model-confirm-static"
            or name == "fake-model-confirm-with-status" or name == "fake-model-confirm-changing-status" then
          remuda._fake_model_confirm_screen = screen
          if name == "fake-model-confirm-with-status"
              and screen:find("Session status: active", 1, true)
              and screen:find("Model status: current-model", 1, true) then
            remuda._fake_model_confirm_status_seen = true
          end
        end
        if name == "fake-hang" and remuda._fake_busy[name] ~= true then
          screen = screen:gsub(" esc to interrupt", "")
        end
        if remuda._fake_clear_unknown[name] then
          screen = screen:gsub("Mystery chooser\n1%. Continue\n❯\n?", "")
        end
        return screen
      end
      local original_preflight = remuda._butler_compaction_preflight
      remuda._butler_compaction_preflight = function(name)
        local blocked = original_preflight(name)
        if name == "fake-attach-mid" and not blocked then remuda._fake_attached[name] = true end
        return blocked
      end
      remuda._butler_send = function(_, _, message)
        remuda._fake_compaction_reports = remuda._fake_compaction_reports or {{}}
        table.insert(remuda._fake_compaction_reports, message)
      end
      remuda._fake_attached = {{}}
      remuda._fake_busy = {{}}
      remuda._fake_clear_unknown = {{}}
      remuda.session = function(name)
        return {{is_busy=remuda._fake_busy[name] == true,
          attached=remuda._fake_attached[name] == true}}
      end
      local original_type_text = remuda.type_text
      local original_write_atomic = remuda.fs.write_atomic
      remuda.fs.write_atomic = function(path, bytes)
        if remuda._fake_fail_restore_write then return nil, "fake write failure" end
        return original_write_atomic(path, bytes)
      end
      remuda.type_text = function(name, value, settle)
        if name == "fake-hang" then remuda._fake_busy[name] = true end
        if value == "/model sonnet" then
          local f = io.open(remuda._fake_restore_file, "r")
          remuda._fake_restore_record_before_sonnet = f ~= nil
          if f then remuda._fake_restore_record_bytes = f:read("*a"); f:close() end
        end
        if value == "/model opus" then
          local f = io.open(remuda._fake_restore_file, "r")
          remuda._fake_restore_record_before_restore = f and f:read("*a") or ""
          if f then f:close() end
        end
        return original_type_text(name, value, settle)
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        local used = screen:match("CTX:%s*(%d+)")
        return {{context_used=used, model=screen:match("MODEL:([^ %c]+)") or "current-model"}}
      end
      remuda._fake_setup_compaction = function(name, kind, log, scenario)
        remuda.new(name, {{"bash", {script:?}, log, scenario, {model_confirm_fixture:?}, {stale_model_confirm_fixture:?}, {wrong_title_model_confirm_fixture:?}, {status_model_confirm_fixture:?}, {changing_status_model_confirm_fixture:?}}}, nil, {{}})
        local id = name
        if name == "fake-stable-id" then id = "stable-agent-17" end
        if name == "fake-empty-id" then id = "" end
        if name == "fake-legacy-record" then id = "stable-agent-legacy" end
        remuda._butler_bus.agents[name] = {{id=id, kind=kind, session_name=name}}
      end
      remuda._fake_restore_file = {data_str:?} .. "/remuda/butler/mail/compaction-restore.json"
    "#
        ),
    );

    for (name, kind, scenario) in [
        ("fake-happy", "claude", "happy"),
        ("fake-persist", "claude", "happy"),
        ("fake-persist-fails", "claude", "happy"),
        ("fake-stable-id", "claude", "happy"),
        ("fake-empty-id", "claude", "happy"),
        ("fake-legacy-record", "claude", "happy"),
        ("fake-mid-turn", "claude", "happy"),
        ("fake-busy-screen", "claude", "busy-screen"),
        ("fake-attached", "claude", "happy"),
        ("fake-attach-mid", "claude", "happy"),
        ("fake-draft", "claude", "draft"),
        ("fake-unknown-kind", "future", "happy"),
        ("fake-codex-no-record", "codex", "codex-no-record"),
        ("fake-stale-flags", "claude", "happy"),
        ("fake-settings-missing", "claude", "happy"),
        ("fake-settings-no-model", "claude", "happy"),
        ("fake-settings-invalid", "claude", "happy"),
        ("fake-settings-mismatch", "claude", "settings-mismatch"),
        ("fake-unknown", "claude", "unknown"),
        ("fake-model-confirm-wrong-title", "claude", "wrong-title-model-confirm"),
        ("fake-model-confirm", "claude", "model-confirm"),
        ("fake-model-confirm-static", "claude", "model-confirm-static"),
        ("fake-model-confirm-transient", "claude", "model-confirm-transient"),
        ("fake-model-confirm-changing-status", "claude", "model-confirm-changing-status"),
        ("fake-model-confirm-with-status", "claude", "model-confirm-with-status"),
        ("fake-stale-model-confirm", "claude", "stale-model-confirm"),
        ("fake-restore-fails", "claude", "unknown-restore-fails"),
        ("fake-unsafe-model", "claude", "happy"),
        ("fake-force", "claude", "unknown"),
        ("fake-hang", "claude", "hang"),
    ] {
        let settings_path = dir.join(".claude/settings.json");
        let settings_before: Option<&[u8]> = match name {
            "fake-settings-no-model" => Some(b"{\"theme\":\"dark\",\"extra\":[1,2]}\n"),
            "fake-settings-invalid" => Some(b"{ invalid settings json\n"),
            "fake-settings-mismatch" => Some(b"{\"model\":\"opus\",\"theme\":\"dark\"}\n"),
            _ => None,
        };
        if let Some(bytes) = settings_before {
            std::fs::write(&settings_path, bytes).unwrap();
        } else {
            let _ = std::fs::remove_file(&settings_path);
        }
        let log = dir.join(format!("{name}.log"));
        eval(
            &path,
            &format!("remuda._fake_setup_compaction({name:?}, {kind:?}, {log:?}, {scenario:?})"),
        );
        if name == "fake-legacy-record" {
            eval(&path, r#"
              local f = assert(io.open(remuda._fake_restore_file, 'w'))
              f:write('{"fake-legacy-record":"opus"}')
              f:close()
              remuda._butler_compaction_load_restore_record()
            "#);
        }
        if name == "fake-persist-fails" {
            eval(&path, "remuda._fake_fail_restore_write = true");
        }
        if name == "fake-unsafe-model" {
            eval(&path, "remuda._butler_bus.agents['fake-unsafe-model'].model = 'opus; /compact'");
        }
        if name == "fake-model-confirm" || name == "fake-model-confirm-static"
            || name == "fake-model-confirm-transient"
            || name == "fake-model-confirm-changing-status" || name == "fake-model-confirm-with-status" {
            eval(&path, "remuda._butler_compaction_config.claude_completion_timeout = 6");
        }
        wait_for(&path, name, "MODEL:");
        if name == "fake-mid-turn" {
            eval(&path, &format!("remuda._fake_busy[{name:?}] = true"));
        }
        if name == "fake-attached" {
            eval(&path, &format!("remuda._fake_attached[{name:?}] = true"));
        }
        if name == "fake-stale-flags" {
            eval(&path, &format!(r#"
              local members = remuda._butler_compaction_members_state
              members[{name:?}] = {{pending_restore_blocked=true, pending_restore_model_unavailable=true,
                pending_restore_model="opus", restore_retry_in_progress=true}}
            "#));
        }
        let result = if name == "fake-stale-flags" {
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"))
        } else if name == "fake-legacy-record" {
            eval(&path, &format!("return remuda.butler.compact({name:?})"))
        } else {
            eval(&path, &format!("return remuda.butler.compact({name:?})"))
        };
        match name {
            "fake-mid-turn" | "fake-busy-screen" => assert_eq!(result, "skipped_busy"),
            "fake-attached" => assert_eq!(result, "skipped_attached"),
            "fake-attach-mid" => assert_eq!(result, "skipped_attached"),
            "fake-draft" => assert_eq!(result, "skipped_composer"),
            "fake-unknown-kind" => assert_eq!(result, "skipped_unsupported_kind"),
            "fake-persist-fails" => assert_eq!(result, "failed"),
            "fake-unsafe-model" => assert_eq!(result, "failed"),
            "fake-legacy-record" => assert_eq!(result, "restoring_model"),
            _ => assert_eq!(result, "started", "unexpected result for {name}"),
        }
        if name == "fake-persist-fails" {
            assert_eq!(eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending)")), "nil",
                "a failed durable write must clear the in-memory restore request");
            assert!(std::fs::read_to_string(&log).unwrap_or_default().is_empty(),
                "a failed durable write must prevent model changes");
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
            assert!(std::fs::read_to_string(&log).unwrap_or_default().is_empty(),
                "the following tick must not send a needless restore command");
            eval(&path, "remuda._fake_fail_restore_write = false");
        }
        if name == "fake-unsafe-model" {
            for _ in 0..3 {
                eval(&path, "return remuda.butler.compact('fake-unsafe-model')");
            }
            assert!(std::fs::read_to_string(&log).unwrap_or_default().is_empty(),
                "an invalid model value must never produce pane input");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert!(reports.contains("unsafe Claude model"), "unsafe model should alert the parent: {reports:?}");
        }
        if name == "fake-hang" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let messages = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                if messages.contains("still running") { break; }
                assert!(Instant::now() < deadline, "timeout did not report still-running state: {messages:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            assert_eq!(
                eval(&path, "local s = remuda._butler_state or remuda._butler_compaction_state; return s.compaction_fleet_active"),
                name,
                "a timed-out but busy Claude pane must keep the fleet lock"
            );
            eval(&path, "remuda._butler_bus.agents['fake-other'] = {id='fake-other', kind='codex', session_name='fake-other'}");
            assert_eq!(eval(&path, "return remuda._butler_compaction_execute('fake-other')"), "fleet_busy");
            eval(&path, &format!("remuda._fake_busy[{name:?}] = false"));
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let lock = eval(&path, "local s = remuda._butler_state or remuda._butler_compaction_state; return tostring(s.compaction_fleet_active)");
                if lock == "nil" { break; }
                assert!(Instant::now() < deadline, "idle monitor failed to release fleet lock: {lock}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        if name == "fake-stale-flags" || name == "fake-happy" || name == "fake-persist" || name == "fake-stable-id" || name == "fake-empty-id" || name.starts_with("fake-settings-") {
            let state_key = if name == "fake-stable-id" { "stable-agent-17" } else { name };
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!(
                    "return tostring(remuda._butler_compaction_members_state[{state_key:?}].compaction_in_progress == true)"
                ));
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                if in_progress == "false" && got.matches("CMD:/compact\nKEY:RET\n").count() >= 1 { break; }
                assert!(Instant::now() < deadline, "scenario {name} stalled: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let got = std::fs::read_to_string(&log).unwrap_or_default();
            assert_eq!(got, "CMD:/model sonnet\nKEY:RET\nCMD:/compact\nKEY:RET\nCMD:/model opus\nKEY:RET\n",
                "Claude should compact on sonnet and restore its prior model: {got:?}");
            if name == "fake-persist" {
                assert_eq!(eval(&path, "return tostring(remuda._fake_restore_record_before_sonnet)"), "true",
                    "the prior model record must be durable before typing /model sonnet");
                assert!(eval(&path, "return remuda._fake_restore_record_bytes").contains("opus"),
                    "the durable record must map this session to its prior model");
                assert!(!std::path::Path::new(&eval(&path, "return remuda._fake_restore_file")).exists(),
                    "verified restore must delete the durable record");
            }
            if name == "fake-stable-id" {
                assert!(eval(&path, "return remuda._fake_restore_record_bytes").contains("stable-agent-17"),
                    "durable records must use a non-empty stable agent id");
                assert!(!eval(&path, "return remuda._fake_restore_record_bytes").contains("fake-stable-id"),
                    "durable records must not use the session key when a stable id exists");
            }
            if name == "fake-empty-id" {
                assert!(eval(&path, "return remuda._fake_restore_record_bytes").contains("fake-empty-id"),
                    "empty agent ids must fall back to the session name");
            }
            if name.starts_with("fake-settings-") {
                let settings_after = if name == "fake-settings-mismatch" {
                    Some(b"{\"model\":\"sonnet\",\"theme\":\"dark\"}\n" as &[u8])
                } else {
                    settings_before
                };
                if let Some(expected) = settings_after {
                    assert_eq!(std::fs::read(&settings_path).unwrap(), expected,
                        "Butler must leave existing settings.json bytes unchanged for {name}");
                } else {
                    assert!(!settings_path.exists(), "missing settings.json must remain missing for {name}");
                }
                let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                if name == "fake-settings-mismatch" {
                    assert_eq!(reports.matches("settings.json model is sonnet, expected opus").count(), 1,
                        "a valid differing model should alert the parent exactly once: {reports:?}");
                    assert_eq!(eval(&path, &format!(
                        "return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending)")), "opus",
                        "settings.json still on sonnet must keep the prior model restore pending");
                    eval(&path, &format!("return remuda._butler_compaction_execute({name:?})"));
                    let deadline = Instant::now() + Duration::from_secs(8);
                    loop {
                        let got = std::fs::read_to_string(&log).unwrap_or_default();
                        if got.matches("CMD:/model opus\n").count() >= 2 { break; }
                        assert!(Instant::now() < deadline, "next tick must retype the prior model: {got:?}");
                        std::thread::sleep(Duration::from_millis(50));
                    }
                } else {
                    assert!(!reports.contains("settings.json model is"),
                        "missing, keyless, or invalid settings.json must not alert for {name}: {reports:?}");
                }
            }
        }
        if name == "fake-stale-flags" {
            assert_eq!(eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].pending_restore_blocked == nil and remuda._butler_compaction_members_state[{name:?}].pending_restore_model_unavailable == nil)")), "true");
        }
        if name == "fake-unknown-kind" {
            assert!(std::fs::read_to_string(&log).unwrap_or_default().is_empty(),
                "unknown agent kinds must not receive commands");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert!(reports.contains("unsupported agent kind"), "unknown kind should be reported: {reports:?}");
        }
        if name == "fake-codex-no-record" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!(
                    "return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"
                ));
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                if in_progress == "false" && got.matches("CMD:/compact\nKEY:RET\n").count() == 1 { break; }
                assert!(Instant::now() < deadline, "first Codex compaction stalled: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            assert!(!std::path::Path::new(&eval(&path, "return remuda._fake_restore_file")).exists(),
                "Codex compaction must not create a model restore record");
            assert_eq!(eval(&path, &format!("return remuda.butler.compact({name:?})")), "started",
                "the same Codex session must be able to compact again");
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!(
                    "return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"
                ));
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                if in_progress == "false" && got.matches("CMD:/compact\nKEY:RET\n").count() == 2 { break; }
                assert!(Instant::now() < deadline, "second Codex compaction stalled: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let got = std::fs::read_to_string(&log).unwrap_or_default();
            assert_eq!(got, "CMD:/compact\nKEY:RET\nCMD:/compact\nKEY:RET\n",
                "Codex compaction must never send a stale Claude model restore command: {got:?}");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert!(!reports.contains("model was restored, but its recovery record could not be cleared"),
                "missing restore record must not send a clear-failure mail: {reports:?}");
            let trace = std::fs::read_to_string(&trace_path).unwrap_or_default();
            assert!(!trace.contains("restore_record_clear_failed"),
                "missing restore record must not create a clear-failure trace: {trace:?}");
        }
        if name == "fake-legacy-record" {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                if got.contains("CMD:/model opus\nKEY:RET\n") { break; }
                assert!(Instant::now() < deadline, "legacy session-keyed restore was not resumed: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let prior_record = eval(&path, "return remuda._fake_restore_record_before_restore");
            assert!(prior_record.contains("stable-agent-legacy"),
                "legacy session-keyed records must migrate to the stable agent id before restore");
            assert!(!prior_record.contains("fake-legacy-record"),
                "migration must remove the old session key");
        }
        if name == "fake-unknown" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                if in_progress == "false" && reports.contains("unrecognized dialog") { break; }
                assert!(Instant::now() < deadline, "unknown-dialog setup did not fail as expected: {reports:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let before = std::fs::read_to_string(&log).unwrap();
            assert_eq!(before, "CMD:/model sonnet\nKEY:RET\nCMD:/compact\nKEY:RET\n",
                "never type into the unknown dialog or attempt a model restore while it is visible");
            assert_eq!(eval(&path, &format!("return remuda._butler_compaction_members_state[{name:?}].restore_pending")), "opus",
                "remember prior model for idle recovery");
            assert!(std::path::Path::new(&eval(&path, "return remuda._fake_restore_file")).exists(),
                "an interrupted compaction must leave a durable prior-model record");
            eval(&path, &format!(r#"
              remuda._butler_compaction_members_state[{name:?}].restore_pending = nil
              remuda._butler_compaction_load_restore_record()
              return remuda._butler_compaction_tick({name:?}, false)
            "#));
            assert_eq!(eval(&path, &format!("return remuda._butler_compaction_members_state[{name:?}].restore_pending")), "opus",
                "the next tick must reload and resume a durable restore");
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
            assert_eq!(std::fs::read_to_string(&log).unwrap(), before,
                "recovery must wait while the unknown dialog is still visible");
            eval(&path, &format!("remuda._fake_attached[{name:?}] = true"));
            eval(&path, &format!("remuda._fake_clear_unknown[{name:?}] = true"));
            assert_eq!(eval(&path, &format!("return tostring(remuda._butler_compaction_is_unknown_dialog(remuda.capture({name:?})))")), "false",
                "fake dialog clear must return the pane to the recognized composer");
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
            assert_eq!(std::fs::read_to_string(&log).unwrap(), before,
                "recovery must not type while a human is attached");
            eval(&path, &format!("remuda._fake_attached[{name:?}] = false"));
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                let pending = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending)"));
                if pending == "nil" && got.ends_with("CMD:/model opus\nKEY:RET\n") { break; }
                assert!(Instant::now() < deadline, "deferred model restore stalled: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            assert_eq!(std::fs::read_to_string(&log).unwrap(), format!("{before}CMD:/model opus\nKEY:RET\n"));
        }
        if name == "fake-model-confirm-wrong-title" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                if in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "wrong-title confirmation watcher did not finish");
                std::thread::sleep(Duration::from_millis(50));
            }
            let got = std::fs::read_to_string(&log).unwrap_or_default();
            assert_eq!(got, "CMD:/model sonnet\nKEY:RET\n",
                "same options under a different dialog title must not receive Return: {got:?}");
        }
        if name == "fake-model-confirm" || name == "fake-model-confirm-static"
            || name == "fake-model-confirm-transient"
            || name == "fake-model-confirm-changing-status" || name == "fake-model-confirm-with-status" {
            let prior_reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            let prior_report_count = prior_reports.lines().count();
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                let new_reports = reports.lines().skip(prior_report_count).collect::<Vec<_>>().join("\\n");
                assert!(!new_reports.contains("unrecognized dialog"),
                    "the model confirmation dialog should be accepted for {name}: {new_reports:?}");
                if in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "compaction did not proceed past model confirmation: {new_reports:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let got = std::fs::read_to_string(&log).unwrap();
            let screen = eval(&path, "return remuda._fake_model_confirm_screen or ''");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            let last_screen = eval(&path, &format!("return remuda.capture({name:?})"));
            if name == "fake-model-confirm-with-status" {
                assert_eq!(eval(&path, "return tostring(remuda._fake_model_confirm_status_seen == true)"), "true",
                    "both status rows below the dialog footer must be present in the captured screen");
            }
            assert!(got.contains("CMD:/compact\n"), "compaction should follow model confirmation: got={got:?}; reports={reports:?}; last screen={last_screen:?}; confirmation screen={screen:?}");
            assert!(got.ends_with("CMD:/model opus\nKEY:RET\n"), "prior model should be restored: {got:?}");
            assert_eq!(got.matches("KEY:RET\n").count(), 4,
                "the selected Yes option should be confirmed exactly once: {got:?}");
            eval(&path, "remuda._butler_compaction_config.claude_completion_timeout = 0.2");
        }
        if name == "fake-stale-model-confirm" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                if in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "stale-confirm setup did not fail as expected");
                std::thread::sleep(Duration::from_millis(50));
            }
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            let got = std::fs::read_to_string(&log).unwrap();
            assert!(reports.contains("unrecognized dialog during model-sonnet")
                    && got == "CMD:/model sonnet\nKEY:RET\n",
                "the bottom permission dialog must follow the unknown path without Return; reports={reports:?}; log={got:?}");
        }
        if name == "fake-restore-fails" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                if in_progress == "false" && reports.contains("unrecognized dialog") { break; }
                assert!(Instant::now() < deadline, "restore-failure setup did not fail as expected: {reports:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let before = std::fs::read_to_string(&log).unwrap();
            assert_eq!(before, "CMD:/model sonnet\nKEY:RET\nCMD:/compact\nKEY:RET\n");
            eval(&path, &format!("remuda._fake_clear_unknown[{name:?}] = true"));
            for attempt in 1..=3 {
                eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
                let deadline = Instant::now() + Duration::from_secs(5);
                loop {
                    let attempts = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending_attempts)"));
                    let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                    if attempts == attempt.to_string() && in_progress == "false" { break; }
                    assert!(Instant::now() < deadline, "restore attempt {attempt} stalled: {attempts}, {in_progress}");
                    std::thread::sleep(Duration::from_millis(50));
                }
                let pending = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending)"));
                assert_eq!(pending, "opus", "failed verification must retain recovery state after attempt {attempt}");
            }
            let got = std::fs::read_to_string(&log).unwrap();
            assert_eq!(got.matches("CMD:/model opus\nKEY:RET\n").count(), 3, "attempt exactly three verified restores");
            assert!(std::path::Path::new(&eval(&path, "return remuda._fake_restore_file")).exists(),
                "failed restore must retain its durable recovery record");
            let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert_eq!(reports.matches("model restore failed; member may still be on sonnet").count(), 1,
                "notify the parent once after the final failed restore");
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
            assert_eq!(std::fs::read_to_string(&log).unwrap(), got, "exhausted recovery must stop sending restore commands");
            eval(&path, "remuda._fake_now(1011); return remuda._butler_compaction_tick('fake-restore-fails', false)");
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got_after_cooldown = std::fs::read_to_string(&log).unwrap_or_default();
                let in_progress = eval(&path, "return tostring(remuda._butler_compaction_members_state['fake-restore-fails'].compaction_in_progress == true)");
                if got_after_cooldown.matches("CMD:/model opus\nKEY:RET\n").count() == 4 && in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "restore retry did not resume after cooldown: {got_after_cooldown:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            eval(&path, "return remuda._butler_compaction_tick('fake-restore-fails', false)");
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got_after_cooldown = std::fs::read_to_string(&log).unwrap_or_default();
                let in_progress = eval(&path, "return tostring(remuda._butler_compaction_members_state['fake-restore-fails'].compaction_in_progress == true)");
                if got_after_cooldown.matches("CMD:/model opus\nKEY:RET\n").count() == 5 && in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "cooldown retry batch did not finish: {got_after_cooldown:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            eval(&path, "return remuda._butler_compaction_tick('fake-restore-fails', false)");
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got_after_cooldown = std::fs::read_to_string(&log).unwrap_or_default();
                let in_progress = eval(&path, "return tostring(remuda._butler_compaction_members_state['fake-restore-fails'].compaction_in_progress == true)");
                if got_after_cooldown.matches("CMD:/model opus\nKEY:RET\n").count() == 6 && in_progress == "false" { break; }
                assert!(Instant::now() < deadline, "third retry attempt did not finish: {got_after_cooldown:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            let reports_after = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
            assert_eq!(reports_after.matches("model restore failed; member may still be on sonnet").count(), 2,
                "notify once for each exhausted three-attempt cooldown batch");
        }
        if name == "fake-force" {
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let in_progress = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].compaction_in_progress == true)"));
                let reports = eval(&path, "return table.concat(remuda._fake_compaction_reports or {}, '\\n')");
                if in_progress == "false" && reports.contains("unrecognized dialog") { break; }
                assert!(Instant::now() < deadline, "force setup did not fail as expected: {reports:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            eval(&path, &format!("remuda._fake_clear_unknown[{name:?}] = true"));
            let forced = remuda_timed(&dir, &["-s", "s", "butler", "compact", name, "--force"]);
            assert!(forced.status.success(), "--force CLI failed: {}", String::from_utf8_lossy(&forced.stderr));
            let deadline = Instant::now() + Duration::from_secs(8);
            loop {
                let got = std::fs::read_to_string(&log).unwrap_or_default();
                let pending = eval(&path, &format!("return tostring(remuda._butler_compaction_members_state[{name:?}].restore_pending)"));
                if pending == "nil" && got.ends_with("CMD:/model opus\nKEY:RET\n") { break; }
                assert!(Instant::now() < deadline, "forced model restore stalled: {got:?}");
                std::thread::sleep(Duration::from_millis(50));
            }
            assert_eq!(std::fs::read_to_string(&log).unwrap(),
                "CMD:/model sonnet\nKEY:RET\nCMD:/compact\nKEY:RET\nCMD:/model opus\nKEY:RET\n");
        }
    }
    drop(daemon);
}

/// A Claude session already on Sonnet needs no model switch (#206): the keys
/// are `/compact` alone and no restore record is ever written. A compaction
/// that fails with the prior model restored must keep its failure cooldown,
/// and a `/compact` that type_text could not verify on an idle pane fails at
/// once. The fake Claude logs each submitted line; one data home per test
/// keeps the restore record away from the other scenarios (#130).
#[test]
#[cfg(unix)]
fn butler_claude_compaction_skips_the_switch_on_sonnet_and_keeps_the_failure_cooldown() {
    let dir = scratch_dir("butler-claude-sonnet");
    let (token_path, config_path) = butler_config(
        &dir,
        "fake-claude-sonnet",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let data_str = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!(
        "remuda._butler_compaction_trace_path = {}",
        lua_raw_string(&trace_path.to_string_lossy())
    ));

    let script = dir.join("fake-claude.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
case "$scenario" in sonnet-*) model=Sonnet-5.5 ;; *) model=opus ;; esac
ctx=500000
paint() { printf '\033[H\033[2JMODEL:%s CTX:%s\n' "$model" "$ctx"; }
paint
while IFS= read -r line; do
  [ -n "$line" ] && printf 'CMD:%s\n' "$line" >> "$log"
  case "$line" in
    '/model sonnet') model=sonnet; paint ;;
    '/model opus') model=opus; paint ;;
    '/compact') [ "$scenario" != sonnet-drop ] || ctx=200000; paint ;;
  esac
done
"#,
    )
    .expect("write fake Claude");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let restore_file = format!("{data_str}/remuda/butler/mail/compaction-restore.json");
    eval(
        &path,
        &format!(
            r#"
      local fake_now = 1000
      remuda._butler_compaction_now = function() return fake_now end
      remuda._fake_now = function(value) fake_now = value end
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=0.2, failure_cooldown_seconds=600, input_settle=0.01}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="claude", entry={{working=function() return false end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function() return "EMPTY" end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        return {{context_used=screen:match("CTX:%s*(%d+)"), model=screen:match("MODEL:([^ %c]+)")}}
      end
      remuda._fake_busy = {{}}
      remuda.session = function(name) return {{is_busy=remuda._fake_busy[name] == true, attached=false}} end
      remuda._butler_send = function(_, _, message)
        remuda._fake_reports = remuda._fake_reports or {{}}
        table.insert(remuda._fake_reports, message)
      end
      -- Whether a restore record existed when /compact was typed; and the
      -- status type_text answers with for the session named in _fake_unverified.
      remuda._fake_record_at_compact = {{}}
      local original_type_text = remuda.type_text
      remuda.type_text = function(name, value, settle)
        if value == "/compact" then
          local f = io.open({restore_file:?}, "r")
          remuda._fake_record_at_compact[name] = f ~= nil
          if f then f:close() end
        end
        local status = original_type_text(name, value, settle)
        if value == "/compact" and name == remuda._fake_unverified then return "unverified" end
        return status
      end
      remuda._fake_claude = function(name, log, scenario)
        remuda.new(name, {{"bash", {script:?}, log, scenario}}, nil, {{}})
        -- A session on Sonnet is pinned to the full id, as settings.json is; the
        -- others are configured for opus.
        local model = scenario:find("^sonnet") and "claude-sonnet-5-5" or "opus"
        remuda._butler_bus.agents[name] = {{id=name .. "-id", kind="claude", session_name=name, model=model}}
      end
    "#,
            script = script.to_string_lossy(),
        ),
    );

    let log_of = |name: &str| std::fs::read_to_string(dir.join(format!("{name}.log"))).unwrap_or_default();
    let reports = || eval(&path, "return table.concat(remuda._fake_reports or {}, '\\n')");
    let trace = || std::fs::read_to_string(&trace_path).unwrap_or_default();
    let record = || std::fs::read_to_string(&restore_file).unwrap_or_default();
    let state = |name: &str, field: &str| eval(&path, &format!(
        "local m = remuda._butler_compaction_members_state or {{}}; local s = m[{:?}] or {{}}; return tostring(s.{field})",
        format!("{name}-id")
    ));
    // Wait until the compaction is no longer in progress and `done` holds.
    let settle = |name: &str, done: &dyn Fn(&str) -> bool, what: &str| {
        let deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let got = log_of(name);
            if state(name, "compaction_in_progress") == "false" && done(&got) { return got; }
            assert!(Instant::now() < deadline, "{name}: {what} never happened. log:\n{got}\nreports: {}\ntrace:\n{}",
                reports(), trace());
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let start = |name: &str, scenario: &str| {
        let log = dir.join(format!("{name}.log"));
        eval(&path, &format!("remuda._fake_claude({name:?}, {:?}, {scenario:?})", log.to_string_lossy()));
        wait_for(&path, name, "MODEL:");
    };

    // The user pinned the full Sonnet id; the status line shows "Sonnet-5.5".
    let settings_path = dir.join(".claude/settings.json");
    let pinned = b"{\"model\":\"claude-sonnet-5-5\"}\n";
    std::fs::create_dir_all(dir.join(".claude")).unwrap();
    std::fs::write(&settings_path, pinned).unwrap();
    // Every scenario runs, so one failing does not hide the others.
    let mut failures = Vec::new();
    let mut scenario = |label: &str, body: &dyn Fn()| {
        if let Err(panic) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
            let text = panic.downcast_ref::<String>().cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
            failures.push(format!("scenario {label}: {text}"));
        }
    };
    let cycle = "CMD:/model sonnet\nCMD:/compact\nCMD:/model opus\n";

    // a. Already on Sonnet: `/compact` alone, no /model before or after, no
    //    restore record, and the run ends verified.
    scenario("a (already on Sonnet)", &|| {
    start("cl-sonnet", "sonnet-drop");
    assert_eq!(eval(&path, "return remuda.butler.compact('cl-sonnet')"), "started");
    let got = settle("cl-sonnet", &|log| log.contains("CMD:/compact"), "the compaction");
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(got, "CMD:/compact\n", "a session on Sonnet must get /compact and no /model: {got:?}");
    assert_eq!(log_of("cl-sonnet"), "CMD:/compact\n", "no /model may follow the compaction");
    assert_eq!(eval(&path, "return tostring(remuda._fake_record_at_compact['cl-sonnet'])"), "false",
        "no restore record may be written when nothing is switched");
    assert!(!record().contains("cl-sonnet-id"), "no restore record: {}", record());
    assert_eq!(state("cl-sonnet", "restore_pending"), "nil");
    let events = trace();
    assert!(events.contains("model_switch_skipped") && events.contains("reason=already_lower"),
        "the skipped switch must be traced: {events}");
    assert!(events.contains("\tverified"), "the run must finish verified: {events}");
    assert!(!events.contains("settings_model_mismatch"), "nothing was switched, nothing to verify: {events}");
    assert!(!reports().contains("settings.json model is"), "no settings mail: {}", reports());
    assert_eq!(std::fs::read(&settings_path).unwrap(), pinned, "settings.json must stay as the user pinned it");
    });

    // a2. Same, but the pane is busy when the completion timeout hits: the
    //     monitor waits for idle and finishes without any /model or settings check.
    scenario("a2 (on Sonnet, busy at the timeout)", &|| {
    start("cl-sonnet-busy", "sonnet-nodrop");
    let timeout = timeout_on_file(&path, &dir, "cl-sonnet-busy", "compact-complete");
    assert_eq!(eval(&path, "return remuda.butler.compact('cl-sonnet-busy')"), "started");
    eval(&path, "remuda._fake_busy['cl-sonnet-busy'] = true");
    let deadline = Instant::now() + Duration::from_secs(8);
    while log_of("cl-sonnet-busy") != "CMD:/compact\n" {
        assert!(Instant::now() < deadline, "/compact never reached the pane: {}", trace());
        std::thread::sleep(Duration::from_millis(50));
    }
    std::fs::write(&timeout, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    while !reports().contains("still running") {
        assert!(Instant::now() < deadline, "the monitor never started: {}\n{}", reports(), trace());
        std::thread::sleep(Duration::from_millis(50));
    }
    eval(&path, "remuda._fake_busy['cl-sonnet-busy'] = false");
    let got = settle("cl-sonnet-busy", &|_| trace().contains("completed_after_timeout"), "the idle finish");
    assert_eq!(got, "CMD:/compact\n", "no /model on a Sonnet session after the timeout: {got:?}");
    assert!(!trace().contains("settings_model_mismatch"), "no settings check: {}", trace());
    assert!(!reports().contains("settings.json model is"), "no settings mail: {}", reports());
    assert_eq!(std::fs::read(&settings_path).unwrap(), pinned);
    assert!(!record().contains("cl-sonnet-busy-id"), "no restore record: {}", record());
    });

    // b. Not on Sonnet and the context never drops: switch, compact, one
    //    restore, one failure. The 600 s failure cooldown then holds: later
    //    ticks type no third /model and never report a restore.
    scenario("b (timeout keeps the cooldown)", &|| {
    std::fs::write(&settings_path, b"{\"model\":\"opus\"}\n").unwrap();
    start("cl-nodrop", "opus-nodrop");
    assert_eq!(eval(&path, "return remuda.butler.compact('cl-nodrop')"), "started");
    let got = settle("cl-nodrop", &|log| log == cycle && reports().contains("context did not drop"),
        "the failed cycle");
    assert_eq!(got, cycle);
    assert_eq!(state("cl-nodrop", "restore_pending"), "nil",
        "a restored model leaves nothing pending after the timeout failure");
    assert!(!record().contains("cl-nodrop-id"), "the durable record must be cleared: {}", record());
    for now in [1050, 1100, 1500] {
        eval(&path, &format!("remuda._fake_now({now})"));
        assert_eq!(eval(&path, "return remuda._butler_compaction_tick('cl-nodrop', false)"), "cl-nodrop:skipped_cooldown",
            "tick at {now}: the failure cooldown must still hold");
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(log_of("cl-nodrop"), cycle, "tick at {now}: no further /model may be typed");
    }
    let events = trace();
    assert!(!events.contains("restored_after_dialog") && !events.contains("settings_model_verified"),
        "no restore may run after the failure: {events}");
    assert_ne!(state("cl-nodrop", "failure_cooldown_until"), "nil", "the failure cooldown must remain in force");
    });


    // c. type_text could not verify `/compact` and the pane is idle: fail at
    //    once (the completion timeout here is 30 s), with the prior model back.
    scenario("c (unverified /compact)", &|| {
    eval(&path, "remuda._fake_now(1000)");
    eval(&path, "remuda._butler_compaction_config.claude_completion_timeout = 30");
    eval(&path, "remuda._fake_unverified = 'cl-unverified'");
    std::fs::write(&settings_path, b"{\"model\":\"opus\"}\n").unwrap();
    start("cl-unverified", "opus-nodrop");
    assert_eq!(eval(&path, "return remuda.butler.compact('cl-unverified')"), "started");
    let got = settle("cl-unverified", &|log| log.ends_with("CMD:/model opus\n"), "the immediate failure");
    assert_eq!(got, cycle);
    assert!(reports().contains("compact command not submitted"),
        "an unverified /compact must fail with its own reason: {}", reports());
    assert_eq!(state("cl-unverified", "restore_pending"), "nil");
    assert!(!record().contains("cl-unverified-id"), "the durable record must be cleared: {}", record());
    });
    assert!(failures.is_empty(), "{}", failures.join("\n---\n"));
    drop(daemon);
}

/// A model wait ends only on a confirmed change (#206 follow-up). The fake
/// Claude swallows any text typed while a model switch is in flight (logged as
/// `LOST:<text>`): pressing Return on the "Switch model?" dialog must not
/// release `/compact`, and the restore is checked only once the switch is done.
/// Confirmed = the status model or a settings.json value that was not already
/// there, and a ready pane (no dialog, empty composer).
#[test]
#[cfg(unix)]
fn butler_claude_model_waits_end_only_on_a_confirmed_switch() {
    let dir = scratch_dir("butler-claude-model-wait");
    let (token_path, config_path) = butler_config(
        &dir,
        "fake-claude-model-wait",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let data_str = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!(
        "remuda._butler_compaction_trace_path = {}",
        lua_raw_string(&trace_path.to_string_lossy())
    ));

    let script = dir.join("fake-claude.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
# Scenarios: slow (dialog, then a slow switch that swallows input), nodialog (settings change at
# once, the status line changes only once $log.status exists), already (settings already hold
# the target, the status line lags), stuck (the model never changes).
log=$1
scenario=$2
model=opus; ctx=500000; mode=idle; ticks=0; target=
paint() {
  printf '\033[H\033[2JMODEL:%s CTX:%s\n' "$model" "$ctx"
  if [ "$mode" = dialog ]; then
    printf 'Switch model?\n\nYour next response will be slower and use more tokens\n\nThis conversation is cached for the current model. Switching to %s 5.5 means\nthe full history gets re-read on your next message.\n\n❯ 1. Yes, switch to %s 5.5\n  2. No, go back\n\nEnter to confirm · Esc to cancel\n' "$target" "$target"
  else
    printf '❯\xc2\xa0\n'
  fi
}
set_settings() { printf '{"model":"%s"}\n' "$1" > "$HOME/.claude/settings.json"; }
paint
while true; do
  if IFS= read -t 0.3 -r line; then
    if [ "$mode" = dialog ] && [ -z "$line" ]; then mode=switching; ticks=4; paint; continue; fi
    if [ "$mode" != idle ]; then [ -n "$line" ] && printf 'LOST:%s\n' "$line" >> "$log"; continue; fi
    [ -n "$line" ] && printf 'CMD:%s\n' "$line" >> "$log"
    case "$line" in
      '/model sonnet'|'/model opus')
        [ $ticks -gt 0 ] && { model=$target; ticks=0; }
        target=${line#/model }
        [ "$scenario" = stuck ] && continue
        if [ "$scenario" = slow ]; then mode=dialog; else set_settings "$target"; ticks=4; fi
        paint ;;
      '/compact') ctx=200000; paint ;;
    esac
  else
    [ $? -gt 128 ] || exit 0
    if [ $ticks -gt 0 ] && { [ "$scenario" != nodialog ] || [ -e "$log.status" ]; }; then
      ticks=$((ticks - 1))
      if [ $ticks -le 0 ]; then model=$target; set_settings "$target"; mode=idle; paint; fi
    fi
  fi
done
"#,
    )
    .expect("write fake Claude");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let restore_file = format!("{data_str}/remuda/butler/mail/compaction-restore.json");
    eval(
        &path,
        &format!(
            r#"
      local fake_now = 1000
      remuda._butler_compaction_now = function() return fake_now end
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=8, failure_cooldown_seconds=600, input_settle=0.01}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="claude", entry={{working=function() return false end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        return {{context_used=screen:match("CTX:%s*(%d+)"), model=screen:match("MODEL:([^ %c]+)")}}
      end
      remuda.session = function() return {{is_busy=false, attached=false}} end
      remuda._butler_send = function(_, _, message)
        remuda._fake_reports = remuda._fake_reports or {{}}
        table.insert(remuda._fake_reports, message)
      end
      remuda._fake_claude = function(name, log, scenario)
        remuda.new(name, {{"bash", {script:?}, log, scenario}}, nil, {{}})
        remuda._butler_bus.agents[name] = {{id=name .. "-id", kind="claude", session_name=name, model="opus"}}
      end
    "#,
            script = script.to_string_lossy(),
        ),
    );

    let log_of = |name: &str| std::fs::read_to_string(dir.join(format!("{name}.log"))).unwrap_or_default();
    let reports = || eval(&path, "return table.concat(remuda._fake_reports or {}, '\\n')");
    let trace = || std::fs::read_to_string(&trace_path).unwrap_or_default();
    let record = || std::fs::read_to_string(&restore_file).unwrap_or_default();
    let in_progress = |name: &str| eval(&path, &format!(
        "local s = (remuda._butler_compaction_members_state or {{}})[{:?}] or {{}}; return tostring(s.compaction_in_progress)",
        format!("{name}-id")
    ));
    let settle = |name: &str, done: &dyn Fn() -> bool, what: &str| {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if in_progress(name) == "false" && done() { return; }
            assert!(Instant::now() < deadline, "{name}: {what} never happened. log:\n{}\nreports: {}\ntrace:\n{}",
                log_of(name), reports(), trace());
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let settings_path = dir.join(".claude/settings.json");
    std::fs::create_dir_all(dir.join(".claude")).unwrap();
    let run = |name: &str, scenario: &str, settings: &str| {
        std::fs::write(&settings_path, settings).unwrap();
        let log = dir.join(format!("{name}.log"));
        eval(&path, &format!("remuda._fake_claude({name:?}, {:?}, {scenario:?})", log.to_string_lossy()));
        wait_for(&path, name, "MODEL:");
        assert_eq!(eval(&path, &format!("return remuda.butler.compact({name:?})")), "started");
    };
    // The one `model_wait` trace line for `id`, whole line.
    let wait_line = |id: &str| trace().lines()
        .find(|line| line.contains("model_wait") && line.contains(&format!("id={id} "))).unwrap_or("").to_string();
    let mut failures = Vec::new();
    let mut scenario = |label: &str, body: &dyn Fn()| {
        if let Err(panic) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)) {
            let text = panic.downcast_ref::<String>().cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
            failures.push(format!("scenario {label}: {text}"));
        }
    };
    let cycle = "CMD:/model sonnet\nCMD:/compact\nCMD:/model opus\n";
    // The whole cycle: sent -> verified with a context drop, in order, nothing lost.
    let cycle_ok = |name: &str, sonnet_by: &str, restored_by: Option<&str>| {
        settle(name, &|| trace().contains("\tverified"), "the verified finish");
        let got = log_of(name);
        assert_eq!(got, cycle, "no text may be lost and the order must hold: {got:?}\ntrace:\n{}", trace());
        let events = trace();
        let sonnet = wait_line("model-sonnet");
        let restored = wait_line("model-restored");
        assert!(sonnet.contains(&format!("outcome=confirmed by={sonnet_by} elapsed=")), "model-sonnet wait: {sonnet:?}\n{events}");
        match restored_by {
            Some(by) => assert!(restored.contains(&format!("outcome=confirmed by={by} elapsed=")), "restore wait: {restored:?}\n{events}"),
            None => assert!(restored.contains("outcome=confirmed by="), "restore wait: {restored:?}\n{events}"),
        }
        assert!(events.find(&sonnet).unwrap() < events.find("\tverified").unwrap());
        assert!(!events.contains("restored_after_dialog"), "no third /model: {events}");
        assert!(!events.contains("settings_model_mismatch"), "settings must already be restored: {events}");
        assert!(!events.contains("\terror"), "no failure: {events}");
        // nodialog: both waits are over, so the status line may follow now.
        std::fs::write(dir.join(format!("{name}.log.status")), "").unwrap();
        wait_for(&path, name, "MODEL:opus");
        for _ in 0..3 {
            eval(&path, &format!("return remuda._butler_compaction_tick({name:?}, false)"));
        }
        std::thread::sleep(Duration::from_millis(500));
        assert_eq!(log_of(name), cycle, "later ticks must type nothing");
        assert!(!record().contains(&format!("{name}-id")), "no restore record may be left: {}", record());
        assert_eq!(std::fs::read_to_string(&settings_path).unwrap().trim(), "{\"model\":\"opus\"}");
    };

    // a. Opus session, "Switch model?" dialog, a switch that takes a few ticks.
    scenario("a (slow switch behind the dialog)", &|| {
        run("mw-slow", "slow", "{\"model\":\"opus\"}\n");
        cycle_ok("mw-slow", "status", None);
    });
    // b. No dialog; settings.json changes at once while the status line lags.
    scenario("b (no dialog, status lags)", &|| {
        std::fs::write(&trace_path, "").unwrap();
        run("mw-nodialog", "nodialog", "{\"model\":\"opus\"}\n");
        cycle_ok("mw-nodialog", "settings", Some("settings"));
    });
    // c. settings.json already says sonnet: it must not confirm the switch.
    scenario("c (settings already true)", &|| {
        std::fs::write(&trace_path, "").unwrap();
        run("mw-already", "already", "{\"model\":\"sonnet\"}\n");
        cycle_ok("mw-already", "status", None);
    });
    // d. The model never changes: the wait times out, nothing is compacted.
    scenario("d (timeout)", &|| {
        std::fs::write(&trace_path, "").unwrap();
        eval(&path, "remuda._butler_compaction_config.claude_completion_timeout = 1");
        run("mw-stuck", "stuck", "{\"model\":\"opus\"}\n");
        settle("mw-stuck", &|| trace().contains("outcome=timeout"), "the timeout");
        let line = wait_line("model-sonnet");
        assert!(line.contains("outcome=timeout") && line.contains("elapsed="), "{line:?}");
        assert!(!line.contains(" by="), "a timeout names no signal: {line:?}");
        assert_eq!(log_of("mw-stuck"), "CMD:/model sonnet\n", "nothing may be compacted");
        assert!(reports().contains("timed out waiting for model-sonnet"), "{}", reports());
    });
    assert!(failures.is_empty(), "{}", failures.join("\n---\n"));
    drop(daemon);
}

/// Codex compaction on a lower model, observed on codex-cli 0.159: `/model`
/// opens "Select Model and Effort" (a number key picks a row), then "Select
/// Reasoning Level for <Model>" with the cursor on that model's default effort;
/// `s` applies it for this session only and leaves $CODEX_HOME/config.toml
/// alone, while Enter or a number key there rewrites the global default.
/// The fake reads raw keys, so a picker key sent through type_text (which
/// submits with Return) lands as a global-default choice and shows in the log.
#[test]
#[cfg(unix)]
fn butler_codex_compaction_switches_to_luna_for_the_session_and_restores() {
    let dir = scratch_dir("butler-fake-codex");
    let (token_path, config_path) = butler_config(
        &dir,
        "fake-codex",
        "http://127.0.0.1:1",
        "!room:example.org",
        "@butler:example.org",
        "",
    );
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    // A private data home: the restore record file must not be shared with
    // tests running in parallel in this process.
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let data_str = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!(
        "remuda._butler_compaction_trace_path = {}",
        lua_raw_string(&trace_path.to_string_lossy())
    ));

    // An isolated CODEX_HOME: the real ~/.codex is never touched.
    let codex_home = dir.join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    let codex_config = codex_home.join("config.toml");
    let config_seed = "model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"high\"\n\n[tui]\nscreen_reader_detection_done = true\n";
    std::fs::write(&codex_config, config_seed).unwrap();

    let script = dir.join("fake-codex.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
stty -icanon -echo min 1 time 0 2>/dev/null
names=("GPT-6.1-Sol" "GPT-6-Astra" "GPT-6-Sol" "GPT-6-Luna" "GPT-5.6-Sol" "GPT-5.6-Terra")
ids=("gpt-6.1-sol" "gpt-6-astra" "gpt-6-sol" "gpt-6-luna" "gpt-5.6-sol" "gpt-5.6-terra")
rows=("Low" "Medium" "High" "Extra high")
levels=("low" "medium" "high" "xhigh")
model=gpt-5.6-sol; effort=high
case "$scenario" in
  crash) model=gpt-6-luna; effort=medium ;;
  no-row) effort=minimal ;;
  no-luna) names[3]="GPT-6-Nova"; ids[3]="gpt-6-nova" ;;
esac
ctx=500000; mode=composer; line=""; cursor=0; pick=0; ecur=0; note=""
index_of() { local i; for i in "${!ids[@]}"; do [ "${ids[$i]}" = "$1" ] && echo "$i" && return; done; echo 0; }
default_row() { if [ "${ids[$1]}" = gpt-5.6-sol ]; then echo 0; else echo 1; fi; }
paint() {
  printf '\033[H\033[2JMODEL:%s CTX:%s\n' "$model" "$ctx"
  [ -n "$note" ] && printf '• %s\n' "$note"
  local i mark
  case "$mode" in
    composer)
      printf '\n› Ask Codex to do anything\n\n  %s %s · /work\n' "${names[$(index_of "$model")]}" "$effort" ;;
    model)
      printf '\n  Select Model and Effort\n\n'
      for i in "${!names[@]}"; do
        mark='  '; [ "$i" = "$cursor" ] && mark='› '
        cur=''; [ "${ids[$i]}" = "$model" ] && cur=' (current)'
        printf '%s%d. %s%s\n' "$mark" $((i + 1)) "${names[$i]}" "$cur"
      done
      printf '\n  enter select · esc back\n' ;;
    effort)
      printf '\n  Select Reasoning Level for %s\n\n' "${names[$pick]}"
      local d; d=$(default_row "$pick")
      for i in "${!rows[@]}"; do
        mark='  '; [ "$i" = "$ecur" ] && mark='› '
        def=''; [ "$i" = "$d" ] && def=' (default)'
        printf '%s%d. %s%s\n' "$mark" $((i + 1)) "${rows[$i]}" "$def"
      done
      printf '\n  enter default · s session · esc back\n' ;;
  esac
}
apply() {
  model=${ids[$pick]}; effort=${levels[$ecur]}; mode=composer
  if [ "$1" = session ]; then
    note="Model changed to $model $effort for this session only"
  else
    note="Model changed to $model $effort"
    printf 'model = "%s"\nmodel_reasoning_effort = "%s"\n' "$model" "$effort" > "$CODEX_HOME/config.toml"
  fi
}
paint
while IFS= read -r -s -n1 -d '' c; do
  key=$c
  if [ "$c" = $'\e' ]; then
    rest=''; IFS= read -r -s -n2 -t 0.05 -d '' rest
    case "$rest" in '[A') key='<up>' ;; '[B') key='<down>' ;; *) key='ESC' ;; esac
  elif [ "$c" = $'\r' ] || [ "$c" = $'\n' ]; then
    key='RET'
  fi
  case "$mode" in
    composer)
      if [ "$key" = RET ]; then
        [ -z "$line" ] && continue
        printf 'CMD:%s\n' "$line" >> "$log"
        case "$line" in
          /model) mode=model; cursor=$(index_of "$model") ;;
          /compact) [ "$scenario" = compact-fails ] || ctx=200000 ;;
          *) printf 'PROMPT:%s\n' "$line" >> "$log" ;;
        esac
        line=''; paint
      elif [ "${#key}" = 1 ]; then
        line="$line$key"
      fi ;;
    model)
      printf 'KEY:%s\n' "$key" >> "$log"
      case "$key" in
        [1-6]) pick=$((key - 1)); ecur=$(default_row "$pick"); mode=effort ;;
        RET) pick=$cursor; ecur=$(default_row "$pick"); mode=effort ;;
        '<up>') [ "$cursor" -gt 0 ] && cursor=$((cursor - 1)) ;;
        '<down>') [ "$cursor" -lt 5 ] && cursor=$((cursor + 1)) ;;
        ESC) mode=composer ;;
      esac
      paint ;;
    effort)
      printf 'KEY:%s\n' "$key" >> "$log"
      case "$key" in
        s) [ "$scenario" = s-ignored ] || apply session ;;
        RET) apply default ;;
        [1-4]) ecur=$((key - 1)); apply default ;;
        '<up>') [ "$ecur" -gt 0 ] && ecur=$((ecur - 1)) ;;
        '<down>') [ "$ecur" -lt 3 ] && ecur=$((ecur + 1)) ;;
        ESC) mode=model ;;
      esac
      paint ;;
  esac
done
"#,
    )
    .expect("write fake Codex");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    let restore_file = format!("{data_str}/remuda/butler/mail/compaction-restore.json");
    eval(
        &path,
        &format!(
            r#"
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=0.2, failure_cooldown_seconds=0, input_settle=0.01}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="codex", entry={{working=function() return false end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function(_, screen)
        if screen:find("Ask Codex to do anything", 1, true) then return "EMPTY" end
        return "NON-EMPTY"
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        return {{context_used=screen:match("CTX:%s*(%d+)"), model=screen:match("MODEL:([^ %c]+)")}}
      end
      remuda.session = function() return {{is_busy=false, attached=false}} end
      remuda._butler_send = function(_, _, message)
        remuda._fake_reports = remuda._fake_reports or {{}}
        table.insert(remuda._fake_reports, message)
      end
      -- The restore record as it stood when each session-only switch was applied.
      remuda._fake_record_at_s = {{}}
      local original_key = remuda.key
      remuda.key = function(name, key)
        if key == "s" and not remuda._fake_record_at_s[name] then
          local f = io.open({restore_file:?}, "r")
          remuda._fake_record_at_s[name] = f and f:read("*a") or ""
          if f then f:close() end
        end
        return original_key(name, key)
      end
      remuda._fake_codex = function(name, log, scenario)
        remuda.new(name, {{"env", "CODEX_HOME=" .. {home:?}, "bash", {script:?}, log, scenario}}, nil, {{}})
        remuda._butler_bus.agents[name] = {{id=name .. "-id", kind="codex", session_name=name}}
      end
    "#,
            home = codex_home.to_string_lossy(),
            script = script.to_string_lossy(),
        ),
    );

    let log_of = |name: &str| std::fs::read_to_string(dir.join(format!("{name}.log"))).unwrap_or_default();
    let reports = || eval(&path, "return table.concat(remuda._fake_reports or {}, '\\n')");
    let record = || std::fs::read_to_string(&restore_file).unwrap_or_default();
    let settle = |name: &str, done: &dyn Fn(&str) -> bool, what: &str| {
        // Failure paths wait out the 15 s picker timeout before closing it.
        let deadline = Instant::now() + Duration::from_secs(45);
        loop {
            let in_progress = eval(&path, &format!(
                "local m = remuda._butler_compaction_members_state or {{}}; local s = m[{:?}] or {{}}; return tostring(s.compaction_in_progress == true)",
                format!("{name}-id")
            ));
            let got = log_of(name);
            if in_progress == "false" && done(&got) { return got; }
            assert!(Instant::now() < deadline, "{name}: {what} never happened. log:\n{got}\nscreen:\n{}\nreports: {}",
                capture(&path, name), reports());
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let start = |name: &str, scenario: &str| {
        let log = dir.join(format!("{name}.log"));
        eval(&path, &format!("remuda._fake_codex({name:?}, {:?}, {scenario:?})", log.to_string_lossy()));
        wait_for(&path, name, "Ask Codex to do anything");
    };
    // Switch to luna keeping the high effort (luna's default row is Medium),
    // compact, then restore sol at high (sol's default row is Low). Picker
    // rows are chosen with remuda.key, never typed.
    let full_cycle = "CMD:/model\nKEY:4\nKEY:<down>\nKEY:s\nCMD:/compact\nCMD:/model\nKEY:5\nKEY:<down>\nKEY:<down>\nKEY:s\n";

    // 1. Happy path, twice: effort kept, prior model back, record written
    //    before the switch and cleared after, config.toml never written.
    start("cx-happy", "happy");
    for round in 1..=2 {
        assert_eq!(eval(&path, "return remuda.butler.compact('cx-happy')"), "started", "round {round}");
        let expected = full_cycle.repeat(round);
        let got = settle("cx-happy", &|log| log == expected, "the full session-only cycle");
        assert!(!got.contains("PROMPT:"), "no /model text may reach the model as a prompt: {got}");
        assert!(capture(&path, "cx-happy").contains("GPT-5.6-Sol high"),
            "round {round}: the prior model and effort must be back");
        eval(&path, "remuda._fake_record_at_s['cx-happy'] = nil");
    }
    assert!(!record().contains("cx-happy-id"), "a finished compaction must clear its restore record: {}", record());
    assert_eq!(std::fs::read_to_string(&codex_config).unwrap(), config_seed,
        "session-only switches must leave config.toml byte-identical");

    // 2. The restore record holds the prior model and effort while on luna.
    //    An unrelated entry keeps the file on disk after cx-record's is cleared.
    std::fs::write(&restore_file, r#"{"cx-other-id":"codex:gpt-5.6-sol high"}"#).unwrap();
    eval(&path, "remuda._butler_compaction_load_restore_record()");
    eval(&path, "remuda._fake_record_at_s['cx-record'] = nil");
    start("cx-record", "happy");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-record')"), "started");
    settle("cx-record", &|log| log == full_cycle, "the full cycle");
    let at_switch = eval(&path, "return remuda._fake_record_at_s['cx-record'] or ''");
    assert!(at_switch.contains("\"cx-record-id\"") && at_switch.contains("codex:gpt-5.6-sol high"),
        "the durable record must name the prior model and effort before the luna switch: {at_switch:?}");
    let mode = std::fs::metadata(&restore_file).expect("restore record").permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "the restore record must be written privately");
    std::fs::remove_file(&restore_file).unwrap();
    eval(&path, "remuda._butler_compaction_load_restore_record()");

    // 3. A failed compaction still restores the prior model.
    start("cx-fails", "compact-fails");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-fails')"), "started");
    let got = settle("cx-fails", &|log| log == full_cycle, "the restore after a failed compaction");
    assert!(capture(&path, "cx-fails").contains("GPT-5.6-Sol high"), "failure must still restore: {got}");
    assert!(!record().contains("cx-fails-id"), "restored after failure, the record must be cleared: {}", record());

    // 4. No row for the current effort on the luna picker: ESC out, never
    //    press s or Enter, never compact, and report why.
    start("cx-no-row", "no-row");
    eval(&path, "return remuda.butler.compact('cx-no-row')");
    let got = settle("cx-no-row", &|log| log.contains("KEY:ESC"), "an ESC out of the picker");
    assert!(!got.contains("KEY:s") && !got.contains("KEY:RET") && !got.contains("/compact"),
        "a missing effort row must not switch or compact: {got}");
    let screen = capture(&path, "cx-no-row");
    assert!(screen.contains("Ask Codex to do anything") && screen.contains("GPT-5.6-Sol minimal"),
        "the picker must be closed and the model unchanged:\n{screen}");
    assert!(reports().contains("minimal"), "the parent must hear which effort row was missing: {}", reports());

    // 5. A crash left the member on luna with a durable record: the next tick
    //    re-selects the prior model for the session only, then clears it.
    start("cx-crash", "crash");
    std::fs::create_dir_all(Path::new(&restore_file).parent().unwrap()).unwrap();
    let mut prior: serde_json::Value = serde_json::from_str(&record()).unwrap_or_else(|_| serde_json::json!({}));
    prior["cx-crash-id"] = serde_json::json!("codex:gpt-5.6-sol medium");
    std::fs::write(&restore_file, prior.to_string()).unwrap();
    eval(&path, "remuda._butler_compaction_load_restore_record()");
    eval(&path, "return remuda._butler_compaction_tick('cx-crash', false)");
    let got = settle("cx-crash", &|log| log.contains("KEY:s"), "the restore after a crash");
    assert_eq!(got, "CMD:/model\nKEY:5\nKEY:<down>\nKEY:s\n", "resume must only restore, session-only");
    assert!(capture(&path, "cx-crash").contains("GPT-5.6-Sol medium"));
    assert!(!record().contains("cx-crash-id"), "the resumed restore must clear the record: {}", record());

    // 6. Two members compacting at once: config.toml stays byte-identical.
    start("cx-a", "happy");
    start("cx-b", "happy");
    eval(&path, "return remuda.butler.compact('cx-a')");
    eval(&path, "return remuda.butler.compact('cx-b')");
    let deadline = Instant::now() + Duration::from_secs(30);
    while log_of("cx-a") != full_cycle || log_of("cx-b") != full_cycle {
        assert_eq!(std::fs::read_to_string(&codex_config).unwrap(), config_seed,
            "config.toml changed while two members compacted");
        assert!(Instant::now() < deadline, "both members must finish a full cycle. a:\n{}\nb:\n{}",
            log_of("cx-a"), log_of("cx-b"));
        eval(&path, "return remuda.butler.compact('cx-b')");
        std::thread::sleep(Duration::from_millis(100));
    }
    // The last key is logged before the mod has seen the footer and freed the fleet lock.
    settle("cx-a", &|log| log == full_cycle, "cx-a's lock release");
    settle("cx-b", &|log| log == full_cycle, "cx-b's lock release");
    assert_eq!(std::fs::read_to_string(&codex_config).unwrap(), config_seed);

    // 7. Every picker failure closes the picker (one ESC per screen) before
    //    it fails, so no later tick stalls behind an open picker.
    let closed = |name: &str, what: &str| {
        let screen = capture(&path, name);
        assert!(screen.contains("Ask Codex to do anything") && screen.contains("GPT-5.6-Sol high")
            && !screen.contains("Select "), "{what}: the picker must be closed, model unchanged:\n{screen}");
        assert!(!record().contains(&format!("{name}-id")), "{what}: nothing to restore: {}", record());
    };
    // 7a. The account offers no luna row: ESC out of the model list.
    start("cx-no-luna", "no-luna");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-no-luna')"), "started");
    let got = settle("cx-no-luna", &|log| log.contains("KEY:ESC"), "an ESC out of the model list");
    assert_eq!(got, "CMD:/model\nKEY:ESC\n", "a missing luna row must only close the picker");
    closed("cx-no-luna", "missing luna row");
    assert!(reports().contains("gpt-6-luna"), "the parent must hear luna was missing: {}", reports());
    // 7b. `s` is ignored: after the timeout, ESC back to the list, then out.
    start("cx-s-ignored", "s-ignored");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-s-ignored')"), "started");
    let got = settle("cx-s-ignored", &|log| log.ends_with("KEY:ESC\nKEY:ESC\n"), "two ESCs out of the pickers");
    assert_eq!(got, "CMD:/model\nKEY:4\nKEY:<down>\nKEY:s\nKEY:ESC\nKEY:ESC\n",
        "an ignored s must close both pickers and never compact");
    closed("cx-s-ignored", "ignored s");
    assert!(reports().contains("codex-model-set"), "the parent must hear which step failed: {}", reports());
    drop(daemon);
}

/// A fake Codex already on gpt-6-luna whose /compact runs longer than the
/// completion timeout (as on 2026-09-30: 45-55 s against a 45 s budget).
/// "slow" stays working, then drops the context; "stuck" goes idle without a
/// drop. Butler must wait out the slow one without a fail mail, and must not
/// call the stuck one a failure: its outcome is only not confirmed.
#[test]
#[cfg(unix)]
fn butler_codex_compaction_waits_for_a_slow_compact_instead_of_failing() {
    let dir = scratch_dir("butler-slow-codex");
    let (token_path, config_path) =
        butler_config(&dir, "slow-codex", "http://127.0.0.1:1", "!room:example.org", "@butler:example.org", "");
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let data_str = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!("remuda._butler_compaction_trace_path = {}", lua_raw_string(&trace_path.to_string_lossy())));

    let script = dir.join("slow-codex.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
stty -icanon -echo min 1 time 0 2>/dev/null
ctx=500000; busy=""; line=""
paint() { printf '\033[H\033[2JMODEL:gpt-6-luna CTX:%s\n%s\n› Ask Codex to do anything\n\n  GPT-6-Luna high · /work\n' "$ctx" "$busy"; }
paint
while IFS= read -r -s -n1 -d '' c; do
  if [ "$c" = $'\r' ] || [ "$c" = $'\n' ]; then
    [ -z "$line" ] && continue
    printf 'CMD:%s\n' "$line" >> "$log"
    if [ "$line" = /compact ] && [ "$scenario" = slow ]; then
      busy="• Compacting"; paint; until [ -e "$log.finish" ]; do sleep 0.05; done; busy=""; ctx=200000
    fi
    line=""; paint
  else
    line="$line$c"
  fi
done
"#,
    )
    .expect("write slow fake Codex");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    eval(
        &path,
        &format!(
            r#"
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=0.2, failure_cooldown_seconds=0, input_settle=0.01}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="codex", entry={{working=function(screen)
            return screen:find("Compacting", 1, true) ~= nil
          end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function(_, screen)
        if screen:find("Ask Codex to do anything", 1, true) then return "EMPTY" end
        return "NON-EMPTY"
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        return {{context_used=screen:match("CTX:%s*(%d+)"), model=screen:match("MODEL:([^ %c]+)")}}
      end
      remuda.session = function() return {{is_busy=false, attached=false}} end
      remuda._butler_send = function(from, _, message)
        remuda._fake_reports = remuda._fake_reports or {{}}
        table.insert(remuda._fake_reports, from .. ": " .. message)
      end
      remuda._fake_codex = function(name, log, scenario)
        remuda.new(name, {{"bash", {script:?}, log, scenario}}, nil, {{}})
        remuda._butler_bus.agents[name] = {{id=name .. "-id", kind="codex", session_name=name}}
      end
    "#,
            script = script.to_string_lossy(),
        ),
    );

    let reports = || eval(&path, "return table.concat(remuda._fake_reports or {}, '\\n')");
    let settle = |name: &str, done: &dyn Fn(&str) -> bool, what: &str| {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let in_progress = eval(&path, &format!(
                "local m = remuda._butler_compaction_members_state or {{}}; local s = m[{:?}] or {{}}; return tostring(s.compaction_in_progress == true)",
                format!("{name}-id")
            ));
            let screen = capture(&path, name);
            if in_progress == "false" && done(&screen) { return screen; }
            assert!(Instant::now() < deadline, "{name}: {what} never happened. screen:\n{screen}\nreports: {}", reports());
            std::thread::sleep(Duration::from_millis(50));
        }
    };
    let start = |name: &str, scenario: &str| {
        let log = dir.join(format!("{name}.log"));
        eval(&path, &format!("remuda._fake_codex({name:?}, {:?}, {scenario:?})", log.to_string_lossy()));
        wait_for(&path, name, "Ask Codex to do anything");
    };

    // 1. Slow: still compacting at the timeout, then done. No fail mail.
    start("cx-slow", "slow");
    let timeout = timeout_on_file(&path, &dir, "cx-slow", "compact-complete");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-slow')"), "started");
    wait_for(&path, "cx-slow", "Compacting");
    std::fs::write(&timeout, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while !reports().contains("cx-slow: Compaction is still running") {
        assert!(Instant::now() < deadline, "the monitor never started. reports: {}", reports());
        std::thread::sleep(Duration::from_millis(50));
    }
    std::fs::write(dir.join("cx-slow.log.finish"), "").unwrap();
    settle("cx-slow", &|screen| screen.contains("CTX:200000"), "the slow compaction finishing");
    let got = reports();
    assert!(!got.contains("Compaction failed"), "a slow compaction that finished is not a failure: {got}");
    let trace = std::fs::read_to_string(&trace_path).unwrap_or_default();
    assert!(trace.contains("completed_after_timeout"), "the late finish must be traced: {trace}");

    // 2. Stuck: idle at the timeout, no drop seen: "not confirmed yet".
    start("cx-stuck", "stuck");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-stuck')"), "started");
    settle("cx-stuck", &|_| reports().contains("cx-stuck:"), "a report for the stuck compaction");
    let got = reports();
    assert!(got.contains("cx-stuck: Compaction not confirmed yet: compaction context did not drop"),
        "an unseen drop is unknown, not failed: {got}");
    assert!(!got.contains("cx-stuck: Compaction failed"), "no fail wording for an unknown outcome: {got}");
    drop(daemon);
}

/// #158: a fake Codex on gpt-6-luna whose /compact never finishes (the pane
/// stays working). With a tiny monitor ceiling, Butler must give up waiting:
/// cancel the monitor, release the fleet lock (another member can compact),
/// and mail "Compaction not confirmed yet: still busy after N min".
#[test]
#[cfg(unix)]
fn butler_compaction_monitor_gives_up_at_its_ceiling_and_releases_the_fleet_lock() {
    let dir = scratch_dir("butler-monitor-ceiling");
    let (token_path, config_path) =
        butler_config(&dir, "monitor-ceiling", "http://127.0.0.1:1", "!room:example.org", "@butler:example.org", "");
    let token_str = token_path.to_string_lossy().to_string();
    let config_str = config_path.to_string_lossy().to_string();
    let data_home = dir.join("data");
    let mods = PathBuf::from(std::env::var_os("XDG_DATA_HOME").expect("XDG_DATA_HOME"));
    std::fs::create_dir_all(data_home.join("remuda/butler")).expect("data home");
    let _ = std::os::unix::fs::symlink(mods.join("remuda/mods"), data_home.join("remuda/mods"));
    let data_str = data_home.to_string_lossy().to_string();
    let daemon = Daemon::spawn_with_env(
        &dir,
        &[
            ("REMUDA_BUTLER_TOKEN", token_str.as_str()),
            ("REMUDA_BUTLER_CONFIG", config_str.as_str()),
            ("XDG_DATA_HOME", data_str.as_str()),
            ("HOME", dir.to_string_lossy().as_ref()),
        ],
    );
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, r#"remuda._butler_argv = {"sh", "-c", "while read line; do :; done"}"#);
    eval(&path, "remuda._butler_skip_relay = true");
    let out = remuda_timed(&dir, &["-s", "s", "exec", "butler"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));

    // The picker fake of the luna-switch test. "forever*": /compact leaves the
    // pane working for good; "quick": it drops the context at once. "forever"
    // and "quick" start on luna; "forever-sol" starts on gpt-5.6-sol high.
    let codex_home = dir.join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    let script = dir.join("ceiling-codex.sh");
    std::fs::write(
        &script,
        r#"#!/bin/bash
log=$1
scenario=$2
stty -icanon -echo min 1 time 0 2>/dev/null
names=("GPT-6.1-Sol" "GPT-6-Astra" "GPT-6-Sol" "GPT-6-Luna" "GPT-5.6-Sol" "GPT-5.6-Terra")
ids=("gpt-6.1-sol" "gpt-6-astra" "gpt-6-sol" "gpt-6-luna" "gpt-5.6-sol" "gpt-5.6-terra")
rows=("Low" "Medium" "High" "Extra high")
levels=("low" "medium" "high" "xhigh")
model=gpt-5.6-sol; effort=high
case "$scenario" in
  forever|quick) model=gpt-6-luna ;;
  crash) model=gpt-6-luna; effort=medium ;;
  no-row) effort=minimal ;;
  no-luna) names[3]="GPT-6-Nova"; ids[3]="gpt-6-nova" ;;
esac
ctx=500000; busy=""; mode=composer; line=""; cursor=0; pick=0; ecur=0; note=""
index_of() { local i; for i in "${!ids[@]}"; do [ "${ids[$i]}" = "$1" ] && echo "$i" && return; done; echo 0; }
default_row() { if [ "${ids[$1]}" = gpt-5.6-sol ]; then echo 0; else echo 1; fi; }
paint() {
  printf '\033[H\033[2JMODEL:%s CTX:%s\n%s\n' "$model" "$ctx" "$busy"
  [ -n "$note" ] && printf '• %s\n' "$note"
  local i mark
  case "$mode" in
    composer)
      printf '\n› Ask Codex to do anything\n\n  %s %s · /work\n' "${names[$(index_of "$model")]}" "$effort" ;;
    model)
      printf '\n  Select Model and Effort\n\n'
      for i in "${!names[@]}"; do
        mark='  '; [ "$i" = "$cursor" ] && mark='› '
        cur=''; [ "${ids[$i]}" = "$model" ] && cur=' (current)'
        printf '%s%d. %s%s\n' "$mark" $((i + 1)) "${names[$i]}" "$cur"
      done
      printf '\n  enter select · esc back\n' ;;
    effort)
      printf '\n  Select Reasoning Level for %s\n\n' "${names[$pick]}"
      local d; d=$(default_row "$pick")
      for i in "${!rows[@]}"; do
        mark='  '; [ "$i" = "$ecur" ] && mark='› '
        def=''; [ "$i" = "$d" ] && def=' (default)'
        printf '%s%d. %s%s\n' "$mark" $((i + 1)) "${rows[$i]}" "$def"
      done
      printf '\n  enter default · s session · esc back\n' ;;
  esac
}
apply() {
  model=${ids[$pick]}; effort=${levels[$ecur]}; mode=composer
  if [ "$1" = session ]; then
    note="Model changed to $model $effort for this session only"
  else
    note="Model changed to $model $effort"
    printf 'model = "%s"\nmodel_reasoning_effort = "%s"\n' "$model" "$effort" > "$CODEX_HOME/config.toml"
  fi
}
paint
while IFS= read -r -s -n1 -d '' c; do
  key=$c
  if [ "$c" = $'\e' ]; then
    rest=''; IFS= read -r -s -n2 -t 0.05 -d '' rest
    case "$rest" in '[A') key='<up>' ;; '[B') key='<down>' ;; *) key='ESC' ;; esac
  elif [ "$c" = $'\r' ] || [ "$c" = $'\n' ]; then
    key='RET'
  fi
  case "$mode" in
    composer)
      if [ "$key" = RET ]; then
        [ -z "$line" ] && continue
        printf 'CMD:%s\n' "$line" >> "$log"
        case "$line" in
          /model) mode=model; cursor=$(index_of "$model") ;;
          /compact) case "$scenario" in forever*) busy="• Compacting" ;; *) ctx=200000 ;; esac ;;
          /idle) busy="" ;;
          *) printf 'PROMPT:%s\n' "$line" >> "$log" ;;
        esac
        line=''; paint
      elif [ "${#key}" = 1 ]; then
        line="$line$key"
      fi ;;
    model)
      printf 'KEY:%s\n' "$key" >> "$log"
      case "$key" in
        [1-6]) pick=$((key - 1)); ecur=$(default_row "$pick"); mode=effort ;;
        RET) pick=$cursor; ecur=$(default_row "$pick"); mode=effort ;;
        '<up>') [ "$cursor" -gt 0 ] && cursor=$((cursor - 1)) ;;
        '<down>') [ "$cursor" -lt 5 ] && cursor=$((cursor + 1)) ;;
        ESC) mode=composer ;;
      esac
      paint ;;
    effort)
      printf 'KEY:%s\n' "$key" >> "$log"
      case "$key" in
        s) [ "$scenario" = s-ignored ] || apply session ;;
        RET) apply default ;;
        [1-4]) ecur=$((key - 1)); apply default ;;
        '<up>') [ "$ecur" -gt 0 ] && ecur=$((ecur - 1)) ;;
        '<down>') [ "$ecur" -lt 3 ] && ecur=$((ecur + 1)) ;;
        ESC) mode=model ;;
      esac
      paint ;;
  esac
done
"#,
    )
    .expect("write ceiling fake Codex");
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();

    eval(
        &path,
        &format!(
            r#"
      remuda._butler_compaction_config = {{critical=400000, cooldown_ticks=0, capture_gap=0,
        completion_timeout=1, claude_completion_timeout=0.2, failure_cooldown_seconds=0, input_settle=0.01,
        monitor_ceiling_seconds=2}}
      local prior_contributions = remuda.contributions
      remuda.contributions = function(point)
        if point == "butler.agent" then
          return {{{{id="codex", entry={{working=function(screen)
            return screen:find("Compacting", 1, true) ~= nil
          end}}}}}}
        end
        return prior_contributions(point)
      end
      remuda._butler_prompt_is_empty = function(_, screen)
        if screen:find("Ask Codex to do anything", 1, true) then return "EMPTY" end
        return "NON-EMPTY"
      end
      remuda._butler_telemetry_for = function(agent)
        local screen = remuda.capture(agent.session_name)
        return {{context_used=screen:match("CTX:%s*(%d+)"), model=screen:match("MODEL:([^ %c]+)")}}
      end
      remuda.session = function() return {{is_busy=false, attached=false}} end
      remuda._butler_send = function(from, _, message)
        remuda._fake_reports = remuda._fake_reports or {{}}
        table.insert(remuda._fake_reports, from .. ": " .. message)
      end
      remuda._fake_codex = function(name, log, scenario)
        remuda.new(name, {{"env", "CODEX_HOME=" .. {home:?}, "bash", {script:?}, log, scenario}}, nil, {{}})
        remuda._butler_bus.agents[name] = {{id=name .. "-id", kind="codex", session_name=name}}
      end
    "#,
            home = codex_home.to_string_lossy(),
            script = script.to_string_lossy(),
        ),
    );

    let reports = || eval(&path, "return table.concat(remuda._fake_reports or {}, '\\n')");
    let start = |name: &str, scenario: &str| {
        let log = dir.join(format!("{name}.log"));
        eval(&path, &format!("remuda._fake_codex({name:?}, {:?}, {scenario:?})", log.to_string_lossy()));
        wait_for(&path, name, "Ask Codex to do anything");
    };
    let trace_path = dir.join("compaction-trace.log");
    eval(&path, &format!("remuda._butler_compaction_trace_path = {}", lua_raw_string(&trace_path.to_string_lossy())));
    let trace = || std::fs::read_to_string(&trace_path).unwrap_or_default();
    start("cx-forever", "forever");
    start("cx-next", "quick");
    // The completion timeout comes once the pane shows Compacting, not after a second.
    let timeout = timeout_on_file(&path, &dir, "cx-forever", "compact-complete");
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-forever')"), "started");
    wait_for(&path, "cx-forever", "Compacting");
    std::fs::write(&timeout, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while !reports().contains("cx-forever: Compaction not confirmed yet: still busy after") {
        assert!(Instant::now() < deadline, "the monitor never gave up at its ceiling. reports: {}\nscreen:\n{}",
            reports(), capture(&path, "cx-forever"));
        std::thread::sleep(Duration::from_millis(100));
    }
    let state = eval(&path, r#"
      local s = (remuda._butler_compaction_members_state or {})['cx-forever-id'] or {}
      return tostring(s.compaction_in_progress == true) .. '|' .. tostring(s.compaction_monitor ~= nil)"#);
    assert_eq!(state, "false|false", "at the ceiling the lock and the monitor must be released");
    assert!(!reports().contains("Compaction failed"), "a still-busy pane is not a failure: {}", reports());
    // The fleet lock is free: another member compacts.
    assert_eq!(eval(&path, "return remuda.butler.compact('cx-next')"), "started",
        "the fleet lock must be released at the ceiling");

    // 2. Not on luna: at the ceiling the prior model is restored for the
    //    session before the not-confirmed mail.
    start("cx-sol", "forever-sol");
    let timeout = timeout_on_file(&path, &dir, "cx-sol", "compact-complete");
    let deadline = Instant::now() + Duration::from_secs(20);
    while eval(&path, "return remuda.butler.compact('cx-sol')") != "started" {
        assert!(Instant::now() < deadline, "cx-sol never got the fleet lock. reports: {}", reports());
        std::thread::sleep(Duration::from_millis(100));
    }
    let deadline = Instant::now() + Duration::from_secs(40);
    while !capture(&path, "cx-sol").contains("Compacting") {
        assert!(Instant::now() < deadline, "cx-sol never started compacting on luna. reports: {}\nscreen:\n{}\ntrace:\n{}",
            reports(), capture(&path, "cx-sol"), trace());
        std::thread::sleep(Duration::from_millis(100));
    }
    std::fs::write(&timeout, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(40);
    while !reports().contains("cx-sol: Compaction not confirmed yet: still busy after") {
        assert!(Instant::now() < deadline, "cx-sol: no not-confirmed mail at the ceiling. reports: {}\nscreen:\n{}\ntrace:\n{}",
            reports(), capture(&path, "cx-sol"), trace());
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(reports().contains("the model is restored when the session is idle"), "{}", reports());
    // Still busy: ticks keep the restore pending and type nothing.
    let log_of = || std::fs::read_to_string(dir.join("cx-sol.log")).unwrap_or_default();
    for _ in 0..3 {
        eval(&path, "return remuda._butler_compaction_tick('cx-sol', false)");
        std::thread::sleep(Duration::from_millis(300));
    }
    assert!(log_of().ends_with("CMD:/compact\n"), "no /model may be typed into a busy pane: {}", log_of());
    // Idle: a later tick restores the prior model for the session.
    eval(&path, "remuda.type_text('cx-sol', '/idle')");
    // Tick only while the restore is pending, checked in the same eval: a tick after the
    // restore has finished would start a new compaction (the context is still high and
    // this test has no cooldown), and the pane would never show the prior model again.
    let tick_while_pending = || eval(&path, r#"
      local state = (remuda._butler_compaction_members_state or {})['cx-sol-id'] or {}
      if state.restore_pending then return remuda._butler_compaction_tick('cx-sol', false) end"#);
    let deadline = Instant::now() + Duration::from_secs(40);
    while !capture(&path, "cx-sol").contains("GPT-5.6-Sol high") {
        assert!(Instant::now() < deadline, "the pending restore never ran once idle. log:\n{}\nscreen:\n{}",
            log_of(), capture(&path, "cx-sol"));
        tick_while_pending();
        std::thread::sleep(Duration::from_millis(300));
    }
    let log = log_of();
    assert!(log.contains("CMD:/compact\nCMD:/idle\nCMD:/model"), "restore only after idle: {log}");
    assert!(log.ends_with("KEY:s\n"), "the restore is session-only: {log}");
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

    // Stop with `-f` on the pinned core; the live butler session makes a bare
    // stop refuse. The next check starts a fresh daemon on the same runtime.
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

    // Restart leg using the stop command available on the pinned core; a live
    // butler session makes a bare stop refuse without `-f`.
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
      local rooms
      matrix.rooms({}, function(value) rooms = value end)
      if not rooms or rooms.status ~= 200 or not rooms.json or not rooms.json.rooms or not rooms.json.rooms[1]
        or rooms.json.rooms[1].room ~= room or rooms.json.rooms[1].kind ~= "home" then return "rooms-result" end
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/rooms/" .. encoded_room .. "/event/%24event",
        { status = 200, headers = {}, body = '{"event_id":"$event","room_id":"!read:example.org"}' })
      local event
      matrix.event({ event_id = "$event" }, function(value) event = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not event or event.json.event_id ~= "$event" or event.json.room_id ~= room then return "event-result" end
      if #remuda.http.calls ~= 4 then return "read-request-count" end
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
fn butler_matrix_send_and_reply_add_formatted_body_and_fall_back_to_plain() {
    let dir = scratch_dir("butler-matrix-formatted");
    let (_daemon, path) = butler_test_daemon(&dir);
    let room = "!write:example.org";
    let (token_path, config_path) = butler_config(&dir, "write", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    let result = eval(&path, r#"
      local matrix, room = remuda.butler.matrix, "!write:example.org"
      local base = "http://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/"
      remuda.http.respond_prefix("GET", base .. "context/",
        { status = 200, headers = {}, body = '{"event":{"room_id":"!write:example.org"}}' })
      remuda.http.respond_prefix("PUT", base .. "send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$sent"}' })
      matrix.relay.instance = { can_reply_to = function() return true end,
        thread_root_for_event = function(_, event_id) return event_id end,
        b2b_stopped = function() return false end, b2b_turn_limit = function() return 6 end,
        note_own_turn = function() end,
        -- No route: the reply takes a post slot, as for an unknown route.
        route_for_event = function() return nil end, post_cap_hit = function() end }
      local function content_of(start)
        local before, result = #remuda.http.calls, nil
        start(function(value) result = value end)
        for _ = 1, 4 do remuda.http.tick() end
        local call = remuda.http.calls[#remuda.http.calls]
        if not result or result.error or #remuda.http.calls == before or call.method ~= "PUT" then return {} end
        return matrix.decode_json(call.body) or {}
      end
      local text = "**bold** <b>raw</b>"
      local html = "<p><strong>bold</strong> &lt;b&gt;raw&lt;/b&gt;</p>"
      local sent = content_of(function(done) matrix.send({ text = text, room = room }, done) end)
      if sent.msgtype ~= "m.text" or sent.body ~= text then return "send-body-changed" end
      if sent.format ~= "org.matrix.custom.html" or sent.formatted_body ~= html then
        return "send-not-formatted:" .. tostring(sent.formatted_body)
      end
      local reply = content_of(function(done)
        matrix.reply({ room = room, event_id = "$source", text = text }, done)
      end)
      local relation = reply["m.relates_to"] or {}
      if reply.msgtype ~= "m.text" or reply.body ~= text or relation.rel_type ~= "m.thread"
        or relation.event_id ~= "$source" or (relation["m.in_reply_to"] or {}).event_id ~= "$source" then
        return "reply-body-or-relation-changed"
      end
      if reply.format ~= "org.matrix.custom.html" or reply.formatted_body ~= html then return "reply-not-formatted" end
      -- 3900 empty table cells render to more than the 30000-byte HTML cap.
      local wide = "|a|\n|-|\n" .. string.rep("|", 3900)
      local capped = content_of(function(done) matrix.send({ text = wide, room = room }, done) end)
      if capped.body ~= wide or capped.format ~= nil or capped.formatted_body ~= nil then return "oversized-html-sent" end
      remuda.butler.md2html.convert = function() error("converter broke") end
      local plain = content_of(function(done) matrix.send({ text = text, room = room }, done) end)
      if plain.msgtype ~= "m.text" or plain.body ~= text then return "fallback-body-changed" end
      if plain.format ~= nil or plain.formatted_body ~= nil then return "fallback-not-plain" end
      return "ok"
    "#);
    assert_eq!(result, "ok", "Matrix m.text must carry safe HTML next to the unchanged plain body: {result}");
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
      matrix.relay.instance = nil
      local no_relay
      matrix.reply({{room=room, event_id="$outside", text="must fail closed"}},
        function(value) no_relay=value end)
      if not no_relay or not no_relay.error or #remuda.http.calls ~= before_outside then
        return "low-level-reply-failed-open-without-relay"
      end
      matrix.relay.instance = {{can_reply_to=function() return true end,
        thread_root_for_event=function(_, event_id) return event_id end,
        b2b_stopped=function() return false end, b2b_turn_limit=function() return 6 end,
        note_own_turn=function() end,
        -- No route: the reply takes a post slot, as for an unknown route.
        route_for_event=function() return nil end, post_cap_hit=function() end}}
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
      local home_left, calls_before_home_leave = nil, #remuda.http.calls
      matrix.leave({{ room = room }}, function(value) home_left = value end)
      if not home_left or not home_left.error or not home_left.error:find("can't", 1, true)
        or #remuda.http.calls ~= calls_before_home_leave then return "home-leave-not-refused" end
      local joined, left
      local joined_room = "!joined:example.org"
      remuda.http.respond("POST", "https://matrix.example.org/_matrix/client/v3/rooms/%21joined%3Aexample.org/join", response("{{}}"))
      remuda.http.respond("POST", "https://matrix.example.org/_matrix/client/v3/rooms/%21joined%3Aexample.org/leave", response("{{}}"))
      matrix.join({{ room = joined_room }}, function(value) joined = value end)
      ticks(3)
      matrix.leave({{ room = joined_room }}, function(value) left = value end)
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
#[cfg(unix)]
fn butler_matrix_cli_guides_unconfigured_status_and_send_without_exposing_token() {
    let dir = scratch_dir("butler-matrix-cli-unconfigured");
    let home = dir.join("home-empty");
    std::fs::create_dir_all(home.join(".config/remuda/butler")).expect("mkdir empty Butler config");
    let token_path = home.join(".config/remuda/butler/token");
    let config_path = home.join(".config/remuda/butler/config");
    std::fs::write(&token_path, "secret-token-sentinel\n").expect("write token sentinel");
    let daemon = Daemon::spawn_with_home(&dir, &home);
    let path = daemon::socket_path_in(&dir, "s");
    eval(&path, "remuda._butler_test_mode = 'lifecycle'");
    let loaded = remuda_timed(&dir, &["-s", "s", "butler", "--headless"]);
    assert!(loaded.status.success(), "load Butler CLI: {}", String::from_utf8_lossy(&loaded.stderr));
    assert_eq!("true", eval(&path,
        "return tostring(remuda.butler.matrix.relay.instance == nil)"),
        "a half-configured Matrix setup must not start the relay");

    let status = remuda_timed(&dir, &["-s", "s", "butler", "matrix", "status"]);
    assert!(!status.status.success(), "unconfigured Matrix status must fail");
    let status_text = format!("{}{}", String::from_utf8_lossy(&status.stdout),
        String::from_utf8_lossy(&status.stderr));

    let send = remuda_timed(&dir, &["-s", "s", "butler", "matrix", "send", "hello"]);
    assert!(!send.status.success(), "send without a config file must fail");
    let send_text = format!("{}{}", String::from_utf8_lossy(&send.stdout),
        String::from_utf8_lossy(&send.stderr));

    for (verb, text) in [("status", status_text.as_str()), ("send", send_text.as_str())] {
        assert!(text.contains(token_path.to_string_lossy().as_ref()), "{verb} omitted token path: {text}");
        assert!(text.contains(config_path.to_string_lossy().as_ref()), "{verb} omitted config path: {text}");
        for line in [
            "https://<homeserver-url>",
            "!<room-id>:<server-name>",
            "@<your-user>:<server-name>",
            "@<allowed-sender>:<server-name>",
            "Next: remuda butler matrix setup",
        ] {
            assert!(text.contains(line), "{verb} omitted {line:?}: {text}");
        }
        assert!(text.contains("chmod 600"), "{verb} omitted file permission guidance: {text}");
        assert!(text.lines().count() <= 12, "{verb} setup guidance exceeded 12 lines: {text}");
        assert!(!text.contains("secret-token-sentinel"), "{verb} leaked token contents: {text}");
    }
    assert!(status_text.contains("Missing config file"), "status did not identify missing config: {status_text}");
    assert!(!status_text.contains("Missing token file"), "status marked present token missing: {status_text}");
    assert!(send_text.contains("Missing config file"), "send did not identify missing config: {send_text}");
    assert!(!send_text.contains("Missing token file"), "send incorrectly marked present token missing: {send_text}");
    drop(daemon);
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
fn butler_matrix_cli_send_dash_sends_stdin_as_the_text() {
    let dir = scratch_dir("butler-matrix-cli-stdin");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let room = "!cli:example.org";
    let (token_path, config_path) = butler_config(&dir, "cli", "http://matrix.example.org",
        room, "@bot:example.org", "");
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config = {{ token_path = {}, config_path = {} }}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())));
    eval(&path, r#"
      remuda.http.respond_prefix("PUT", "http://matrix.example.org/_matrix/client/v3/rooms/%21cli%3Aexample.org/send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$cli"}' })
    "#);
    // (argv after `matrix`, stdin, expected m.text body). Stdin is never re-parsed as options.
    let cases: [(&[&str], &str, &str); 5] = [
        (&["--room", room, "send", "-"], "--json is text\n-\n--room !x:y last\n", "--json is text\n-\n--room !x:y last"),
        (&["send", "-"], "-\n", "-"),
        (&["send", "-"], "two newlines\r\n\r\n", "two newlines\r\n"),
        (&["send", "--", "-"], "ignored", "-"),
        (&["send", "plain", "text"], "ignored", "plain text"),
    ];
    for (index, (args, stdin, expected)) in cases.iter().enumerate() {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
            .args(["-s", "s", "butler", "matrix"]).args(*args)
            .env("REMUDA_RUNTIME_DIR", &dir)
            .env("REMUDA_NO_UPDATE_CHECK", "1")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn().expect("spawn Matrix CLI send");
        child.stdin.take().expect("child stdin").write_all(stdin.as_bytes()).expect("write stdin");
        let sent = (index + 1).to_string();
        let deadline = Instant::now() + PATIENCE;
        // Ticking also runs the send rate-limit timer that queues every send after the first.
        while eval(&path, "remuda.http.tick(); return #remuda.http.calls") != sent {
            assert!(Instant::now() < deadline, "{args:?} never dispatched its send");
            assert!(child.try_wait().expect("poll Matrix CLI").is_none(), "{args:?} exited before sending: {}",
                String::from_utf8_lossy(&child.wait_with_output().expect("collect").stderr));
            std::thread::sleep(Duration::from_millis(10));
        }
        eval(&path, "remuda.http.tick()");
        let output = child.wait_with_output().expect("collect Matrix CLI output");
        assert!(output.status.success(), "{args:?} failed: {}", String::from_utf8_lossy(&output.stderr));
        let content = eval(&path, &format!(
            "local c = remuda.json.decode(remuda.http.calls[{sent}].body); return c.msgtype .. '|' .. c.body"));
        assert_eq!(content, format!("m.text|{expected}"), "{args:?} sent the wrong text");
    }
}

#[test]
fn butler_matrix_cli_rejects_invalid_send_dash_and_fails_cleanly_without_pending() {
    let dir = scratch_dir("butler-matrix-cli-compat");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    for verb in ["approve", "deny"] {
        let result = remuda_timed_without_butler_identity(&dir, &["-s", "s", "butler", verb, "X"]);
        assert!(!result.status.success(), "{} without Matrix config must fail", verb);
        assert!(String::from_utf8_lossy(&result.stderr).contains("Matrix relay is not running."),
            "{} without Matrix config must report the relay error: {}", verb,
            String::from_utf8_lossy(&result.stderr));
        assert!(!String::from_utf8_lossy(&result.stdout).contains("remuda butler — coordination"),
            "{} without Matrix config must not fall back to generic Butler usage: {}", verb,
            String::from_utf8_lossy(&result.stdout));
    }
    let approval_help = remuda_timed_without_butler_identity(&dir,
        &["-s", "s", "butler", "approvals", "--help"]);
    assert!(approval_help.status.success(), "approvals --help must succeed");
    assert!(String::from_utf8_lossy(&approval_help.stdout).contains("Usage: remuda butler approvals"),
        "approvals --help must show its own usage: {}", String::from_utf8_lossy(&approval_help.stdout));
    assert!(!String::from_utf8_lossy(&approval_help.stdout).contains("remuda butler — coordination"),
        "approvals --help must not fall back to generic Butler usage: {}",
        String::from_utf8_lossy(&approval_help.stdout));
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
    let approvals = remuda_timed(&dir, &["-s", "s", "butler", "approvals"]);
    assert!(approvals.status.success(), "operator approvals failed: {}",
        String::from_utf8_lossy(&approvals.stderr));
    assert!(String::from_utf8_lossy(&approvals.stdout).contains("No open approval requests."),
        "operator approvals fell through to generic usage: {}", String::from_utf8_lossy(&approvals.stdout));
    let agent_approve = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "approve", "X"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "agent1")
        .output().expect("run agent approve command");
    assert!(!agent_approve.status.success(), "agent approve must fail");
    assert!(String::from_utf8_lossy(&agent_approve.stderr).contains(
        "approve is operator-only. Next: wait for the owner's answer by mail; remuda butler inbox"),
        "unexpected agent approve error: {}", String::from_utf8_lossy(&agent_approve.stderr));
    let oversized = format!("{}\n", "x".repeat(65_537));
    for (args, stdin, expected) in [
        (&["send", "-"][..], "", "message body must not be empty"),
        (&["send", "-"][..], "\n", "message body must not be empty"),
        (&["send", "-"][..], oversized.as_str(), "message body exceeds the 64 KiB limit"),
        (&["--room", room, "send", "-", "extra"][..], "body\n", "stdin message form takes no extra arguments"),
    ] {
        let argv = [&["-s", "s", "butler", "matrix"][..], args].concat();
        let dash = remuda_timed_stdin(&dir, &argv, stdin.as_bytes());
        assert!(!dash.status.success(), "{args:?} with invalid stdin must fail");
        assert!(String::from_utf8_lossy(&dash.stderr).contains(expected), "unexpected {args:?} error: {}",
            String::from_utf8_lossy(&dash.stderr));
    }
    let no_stdin = eval(&path, r#"
      local ok, err = pcall(remuda._butler_command_run, "matrix", {"matrix", "send", "-"}, {env={}})
      assert(not ok)
      return tostring(err)
    "#);
    assert!(no_stdin.contains("no message body received on stdin"), "{no_stdin}");
    assert_eq!(eval(&path, "return #remuda.http.calls"), "0", "invalid send - touched Matrix");

    let agent_leave = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "leave", room])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "agent1")
        .output().expect("run agent leave command");
    assert!(!agent_leave.status.success(), "leave must be operator-only");
    assert!(String::from_utf8_lossy(&agent_leave.stderr).contains("operator-only"),
        "unexpected agent leave error: {}", String::from_utf8_lossy(&agent_leave.stderr));
    // An agent join files an owner approval request; with no relay it fails before any HTTP.
    let agent_join = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "matrix", "join", room])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "agent1")
        .output().expect("run agent join command");
    assert!(!agent_join.status.success(), "agent join without a relay must fail");
    assert!(String::from_utf8_lossy(&agent_join.stderr).contains("Next:"),
        "unexpected agent join error: {}", String::from_utf8_lossy(&agent_join.stderr));
    assert_eq!(eval(&path, "return #remuda.http.calls"), "0", "agent join or leave reached the network");

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
        "- `send TEXT`: start a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send.",
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

fn doctor_render(probes: &str, platform: &str) -> String {
    let dir = scratch_dir("butler-doctor-render");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let module = std::env::current_dir()
        .expect("core checkout")
        .join("../packages/butler/doctor.lua");
    let module = lua_raw_string(&module.to_string_lossy());
    let platform = lua_raw_string(platform);
    let code = format!(
        "local doctor = dofile({module}); return table.concat(doctor.render({probes}, {platform}), '\\n')"
    );
    eval(&path, &code)
}

fn doctor_candidate_names(name: &str, platform: &str) -> String {
    let dir = scratch_dir("butler-doctor-candidates");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let module = std::env::current_dir()
        .expect("core checkout")
        .join("../packages/butler/doctor.lua");
    let module = lua_raw_string(&module.to_string_lossy());
    let name = lua_raw_string(name);
    let platform = lua_raw_string(platform);
    let code = format!(
        "local doctor = dofile({module}); return table.concat(doctor.candidate_names({name}, {platform}), ',')"
    );
    eval(&path, &code)
}

#[test]
fn doctor_candidate_names_include_windows_cmd_fallback() {
    assert_eq!(doctor_candidate_names("codex", "windows"), "codex,codex.cmd");
    assert_eq!(doctor_candidate_names("codex", "posix"), "codex");
}

fn doctor_status(installed: bool, logged_in: bool) -> String {
    format!("{{ installed = {installed}, logged_in = {logged_in} }}")
}

fn doctor_stub_dir(dir: &Path) -> PathBuf {
    let bin = dir.join("doctor-bin");
    std::fs::create_dir_all(&bin).expect("create doctor stub directory");
    bin
}

fn doctor_write_stub(bin: &Path, name: &str, output: &str, exit_code: i32) {
    use std::os::unix::fs::PermissionsExt;

    let path = bin.join(name);
    std::fs::write(
        &path,
        format!("#!/bin/sh\nprintf '%s\\n' '{}'\nexit {exit_code}\n", output),
    )
    .expect("write agent stub");
    let mut permissions = std::fs::metadata(&path).expect("stat agent stub").permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).expect("make agent stub executable");
}

fn butler_doctor_test_daemon(dir: &Path, path_env: &str) -> (Daemon, PathBuf) {
    let daemon = Daemon::spawn_with_env(dir, &[("PATH", path_env)]);
    let path = daemon::socket_path_in(dir, "s");
    eval(&path, "remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true");
    let out = remuda_timed(dir, &["-s", "s", "butler", "--headless"]);
    assert!(out.status.success(), "load Butler CLI: {}", String::from_utf8_lossy(&out.stderr));
    (daemon, path)
}

#[test]
fn doctor_reports_all_good() {
    let probes = format!(
        "{{ claude = {}, codex = {} }}",
        doctor_status(true, true),
        doctor_status(true, true)
    );
    assert_eq!(
        doctor_render(&probes, "macos"),
        "Claude Code: installed, logged in\nCodex CLI: installed, logged in\nTyped lines: off\nShell lines: off\nNext: remuda butler matrix setup"
    );
}

#[test]
fn doctor_reports_missing_claude_posix() {
    let probes = format!(
        "{{ claude = {}, codex = {} }}",
        doctor_status(false, false),
        doctor_status(true, true)
    );
    let expected = "Claude Code: missing\nCodex CLI: installed, logged in\nTyped lines: off\nShell lines: off\nNext: curl -fsSL https://claude.ai/install.sh | bash";
    assert_eq!(doctor_render(&probes, "macos"), expected);
    assert_eq!(doctor_render(&probes, "linux"), expected);
}

#[test]
fn doctor_reports_missing_claude_windows() {
    let probes = format!(
        "{{ claude = {}, codex = {} }}",
        doctor_status(false, false),
        doctor_status(true, true)
    );
    assert_eq!(
        doctor_render(&probes, "windows"),
        "Claude Code: missing\nCodex CLI: installed, logged in\nTyped lines: off\nShell lines: off\nNext: irm https://claude.ai/install.ps1 | iex"
    );
}

#[test]
fn doctor_reports_codex_logged_out() {
    let probes = format!(
        "{{ claude = {}, codex = {} }}",
        doctor_status(true, true),
        doctor_status(true, false)
    );
    assert_eq!(
        doctor_render(&probes, "macos"),
        "Claude Code: installed, logged in\nCodex CLI: installed, not logged in\nTyped lines: off\nShell lines: off\nNext: codex login"
    );
}

#[test]
fn doctor_reports_both_missing_with_two_next_lines() {
    let probes = format!(
        "{{ claude = {}, codex = {} }}",
        doctor_status(false, false),
        doctor_status(false, false)
    );
    assert_eq!(
        doctor_render(&probes, "linux"),
        "Claude Code: missing\nCodex CLI: missing\nTyped lines: off\nShell lines: off\nNext: curl -fsSL https://claude.ai/install.sh | bash\nNext: npm install -g @openai/codex"
    );
}

#[test]
fn doctor_cli_all_good_never_echoes_agent_output() {
    let dir = scratch_dir("butler-doctor-cli-good");
    let bin = doctor_stub_dir(&dir);
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"status":"logged-in","token":"DOCTOR_SECRET_CLAUDE"}"#,
        0,
    );
    doctor_write_stub(
        &bin,
        "codex",
        "Logged in using ChatGPT; DOCTOR_SECRET_CODEX",
        0,
    );
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
    let out = remuda_timed(&dir, &["-s", "s", "butler", "doctor"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stdout.contains("Claude Code: installed, logged in"), "{stdout}");
    assert!(stdout.contains("Codex CLI: installed, logged in"), "{stdout}");
    assert!(stdout.contains("Next: remuda butler matrix setup"), "{stdout}");
    for secret in ["DOCTOR_SECRET_CLAUDE", "DOCTOR_SECRET_CODEX", "logged-in"] {
        assert!(!stdout.contains(secret), "doctor leaked {secret}: {stdout}");
        assert!(!stderr.contains(secret), "doctor leaked {secret}: {stderr}");
    }
}

#[test]
fn doctor_cli_both_missing_prints_two_next_commands() {
    let dir = scratch_dir("butler-doctor-cli-missing");
    let bin = doctor_stub_dir(&dir);
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
    let out = remuda_timed(&dir, &["-s", "s", "butler", "doctor"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(
        stdout.trim(),
        "Claude Code: missing\nCodex CLI: missing\nTyped lines: off\nShell lines: off\nNext: curl -fsSL https://claude.ai/install.sh | bash\nNext: npm install -g @openai/codex"
    );
}

#[test]
fn doctor_cli_timeout_reports_retry_and_the_other_agent() {
    let dir = scratch_dir("butler-doctor-timeout");
    let bin = doctor_stub_dir(&dir);
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, path) = butler_doctor_test_daemon(&dir, path_env);
    eval(&path, r#"
      remuda.process.run = function(options)
        if options.argv[1] == "claude" then return { code = 1, timed_out = true } end
        return { code = 0, timed_out = false }
      end
    "#);

    let out = remuda_timed(&dir, &["-s", "s", "butler", "doctor"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(stdout.contains("Claude Code: check timed out"), "{stdout}");
    assert!(stdout.contains("Codex CLI: installed, logged in"), "{stdout}");
    assert!(stdout.contains("Next: retry remuda butler doctor"), "{stdout}");
}

#[test]
fn doctor_cli_unexpected_probe_error_still_reports_other_agent_and_next() {
    let dir = scratch_dir("butler-doctor-probe-error");
    let bin = doctor_stub_dir(&dir);
    let claude = bin.join("claude");
    std::fs::write(&claude, "#!/bin/sh\nexit 0\n").expect("write non-executable Claude stub");
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);

    let out = remuda_timed(&dir, &["-s", "s", "butler", "doctor"]);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(stdout.contains("Claude Code: check failed"), "{stdout}");
    assert!(stdout.contains("Codex CLI: missing"), "{stdout}");
    assert!(stdout.contains("Next: retry remuda butler doctor"), "{stdout}");
    assert!(stdout.contains("Next: npm install -g @openai/codex"), "{stdout}");
}

// --- packages/butler: quota report daemon wiring --------------------------

fn assert_quota_marker_absent(root: &Path, marker: &str) {
    if !root.exists() {
        return;
    }
    for entry in std::fs::read_dir(root).expect("read quota state/log directory") {
        let path = entry.expect("read quota state/log entry").path();
        if path.is_dir() {
            assert_quota_marker_absent(&path, marker);
        } else if path.is_file() {
            let bytes = std::fs::read(&path).expect("read quota state/log file");
            assert!(
                !String::from_utf8_lossy(&bytes).contains(marker),
                "quota persisted {marker} in {path:?}"
            );
        }
    }
}

#[test]
fn butler_quota_statusline_keeps_line_one_and_adds_rate_limits() {
    let dir = scratch_dir("butler-quota-statusline");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    let status_path = dir.join("claude.status");
    let snapshot = r#"{"model":{"display_name":"Claude Opus 4.6"},"context_window":{"total_input_tokens":12345,"context_window_size":200000,"used_percentage":6},"rate_limits":{"five_hour":{"used_percentage":92,"resets_at":1790838000},"seven_day":{"used_percentage":71,"resets_at":1791072000}}}"#;
    let status_path_lua = lua_raw_string(&status_path.to_string_lossy());
    let snapshot_lua = lua_raw_string(snapshot);
    let line = eval(&path, &format!(
        "return remuda._dispatch_extension_command('butler', {{'statusline', {status_path_lua}}}, {{stdin = {snapshot_lua}}})"
    ));
    assert_eq!(
        line,
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6"
    );
    let status = std::fs::read_to_string(&status_path).expect("read quota status file");
    let lines: Vec<_> = status.lines().collect();
    assert_eq!(
        lines[0],
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6"
    );
    assert_eq!(
        lines.len(),
        2,
        "rate limits must add exactly one status-file line: {lines:?}"
    );
    let parts: Vec<_> = lines[1].split_whitespace().collect();
    assert_eq!(parts.len(), 3, "rate-limit cache shape: {:?}", lines[1]);
    assert!(parts[0]
        .strip_prefix("RL:")
        .is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit())));
    for (part, key) in [(parts[1], "five_hour="), (parts[2], "seven_day=")] {
        let Some(value) = part.strip_prefix(key) else {
            panic!("missing {key} in {}", lines[1])
        };
        let Some((used, reset)) = value.split_once('@') else {
            panic!("missing @ in {}", lines[1])
        };
        assert!(
            used.bytes().all(|b| b.is_ascii_digit()) && reset.bytes().all(|b| b.is_ascii_digit()),
            "rate-limit values must be digits: {}",
            lines[1]
        );
    }
    assert_eq!(
        parts[1].split_once('@').expect("five-hour separator").0,
        "five_hour=92"
    );
    assert_eq!(
        parts[2].split_once('@').expect("weekly separator").0,
        "seven_day=71"
    );

    let no_limits = r#"{"model":{"display_name":"Claude Opus 4.6"},"context_window":{"total_input_tokens":12345,"context_window_size":200000,"used_percentage":6}}"#;
    let no_limits_lua = lua_raw_string(no_limits);
    eval(&path, &format!(
        "return remuda._dispatch_extension_command('butler', {{'statusline', {status_path_lua}}}, {{stdin = {no_limits_lua}}})"
    ));
    assert_eq!(
        std::fs::read_to_string(&status_path).expect("read status without limits"),
        "MODEL:Claude-Opus-4.6 CTX:12345 CTXWIN:200000 CTXPCT:6\n"
    );
}

#[test]
fn butler_quota_reports_modes_without_leaking() {
    let dir = scratch_dir("butler-quota-modes");
    let bin = doctor_stub_dir(&dir);
    let org_id = "QUOTA_ORG_ID_MARKER";
    let org_name = "QUOTA_ORG_NAME_MARKER";
    doctor_write_stub(
        &bin,
        "claude",
        &format!(
            r#"{{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"quota@example.test","orgId":"{org_id}","orgName":"{org_name}"}}"#
        ),
        0,
    );
    doctor_write_stub(&bin, "codex", "Logged in using ChatGPT", 0);
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
    let out = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stdout.contains("claude: subscription (max), quota@example.test"),
        "{stdout}"
    );
    assert!(
        stdout.contains(
            "  quota: unknown (no reading yet; it appears after a claude session's first reply)"
        ),
        "{stdout}"
    );
    assert!(
        stdout.contains("codex: subscription, account: not exposed by codex"),
        "{stdout}"
    );
    assert!(
        stdout.contains("  quota: unknown (codex limits need core nightly d47a845 or newer)"),
        "{stdout}"
    );
    assert!(stdout.contains("Next: update Remuda core to nightly d47a845 or newer, then run `remuda butler quota` again."), "{stdout}");
    for marker in [org_id, org_name] {
        assert!(
            !stdout.contains(marker),
            "quota stdout leaked {marker}: {stdout}"
        );
        assert!(
            !stderr.contains(marker),
            "quota stderr leaked {marker}: {stderr}"
        );
        for child in [dir.join("remuda"), dir.join("logs"), dir.join("state")] {
            assert_quota_marker_absent(&child, marker);
        }
    }
}

#[test]
fn butler_quota_never_guesses_mode() {
    for (tag, claude, expected) in [
        (
            "logged-out",
            Some(r#"{"loggedIn":false}"#),
            "claude: not logged in",
        ),
        (
            "unrecognised",
            Some("hello"),
            "claude: unknown (could not understand what `claude auth status` answered)",
        ),
        ("not-installed", None, "claude: not installed"),
    ] {
        let dir = scratch_dir(&format!("butler-quota-{tag}"));
        let bin = doctor_stub_dir(&dir);
        if let Some(claude) = claude {
            doctor_write_stub(&bin, "claude", claude, 0);
        }
        doctor_write_stub(&bin, "codex", "Not logged in", 0);
        let path_env = bin.to_str().expect("PATH is UTF-8");
        let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
        let out = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
        assert!(
            out.status.success(),
            "{tag}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            String::from_utf8_lossy(&out.stdout).contains(expected),
            "{tag}: {}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
}

#[test]
fn butler_quota_usage_error() {
    let dir = scratch_dir("butler-quota-usage");
    let (_daemon, _path) = butler_cli_test_daemon(&dir);
    let next = "Next: run `remuda butler quota`, or `remuda butler quota --report` to also send the report to Matrix.";
    let usage = "Usage: remuda butler quota [--report]\nExample: remuda butler quota --report";
    let out = remuda_timed(&dir, &["-s", "s", "butler", "quota", "--bogus"]);
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr).trim(),
        format!("unknown option: --bogus\n{usage}\n{next}")
    );
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "",
        "a usage error prints nothing on stdout"
    );

    let out = remuda_timed(&dir, &["-s", "s", "butler", "quota", "claude"]);
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr).trim(),
        format!("unexpected argument: claude\n{usage}\n{next}")
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");

    for flag in ["--help", "-h"] {
        let out = remuda_timed(&dir, &["-s", "s", "butler", "quota", flag]);
        assert_eq!(out.status.code(), Some(0), "{flag}");
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            format!("remuda butler quota reports, for claude and codex, how each is logged in, the subscription account and how much of each limit is used.\nWith --report it also posts the report to this Butler's Matrix home room.\n{usage}\n{next}"),
            "{flag}"
        );
    }
}

// codex-cli 0.159.3 prints `codex login status` on stderr (measured 2026-10-01).
fn quota_write_stderr_stub(bin: &Path, name: &str, output: &str, exit_code: i32) {
    use std::os::unix::fs::PermissionsExt;

    let path = bin.join(name);
    std::fs::write(
        &path,
        format!("#!/bin/sh\nprintf '%s\\n' '{output}' >&2\nexit {exit_code}\n"),
    )
    .expect("write stderr agent stub");
    let mut permissions = std::fs::metadata(&path)
        .expect("stat stderr agent stub")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).expect("make stderr agent stub executable");
}

#[test]
fn butler_quota_reads_codex_login_status_from_stderr() {
    for (tag, codex, code, expected) in [
        (
            "logged-out",
            "Not logged in",
            1,
            vec![
                "codex: not logged in",
                "Not logged in: codex.",
                "Next: log in with `codex login`, then run `remuda butler quota` again.",
            ],
        ),
        (
            "chatgpt",
            "Logged in using ChatGPT",
            0,
            vec!["codex: subscription, account: not exposed by codex"],
        ),
    ] {
        let dir = scratch_dir(&format!("butler-quota-stderr-{tag}"));
        let bin = doctor_stub_dir(&dir);
        doctor_write_stub(
            &bin,
            "claude",
            r#"{"loggedIn":true,"authMethod":"api_key"}"#,
            0,
        );
        quota_write_stderr_stub(&bin, "codex", codex, code);
        let path_env = bin.to_str().expect("PATH is UTF-8");
        let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
        let out = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
        assert!(
            out.status.success(),
            "{tag}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let stdout = String::from_utf8_lossy(&out.stdout);
        for line in expected {
            assert!(stdout.contains(line), "{tag}: missing {line:?} in {stdout}");
        }
    }
}

fn assert_quota_utc_limit(stdout: &str, name: &str, used: u8) {
    let prefix = format!("  {name}: {used}% used, resets ");
    let reset = stdout
        .lines()
        .find_map(|line| line.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("missing {prefix:?} in {stdout}"));
    let bytes = reset.as_bytes();
    assert_eq!(bytes.len(), 17, "reset is not YYYY-MM-DD HH:MMZ: {reset}");
    for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15] {
        assert!(
            bytes[index].is_ascii_digit(),
            "reset is not YYYY-MM-DD HH:MMZ: {reset}"
        );
    }
    assert_eq!(&bytes[4..5], b"-");
    assert_eq!(&bytes[7..8], b"-");
    assert_eq!(&bytes[10..11], b" ");
    assert_eq!(&bytes[13..14], b":");
    assert_eq!(&bytes[16..17], b"Z");
}

fn quota_write_codex_app_server_stub(bin: &Path, runs: &Path, delay: &str) {
    use std::os::unix::fs::PermissionsExt;

    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("fixtures/quota-codex-app-server.json"))
            .expect("parse app-server fixture");
    let output = [
        r#"{"jsonrpc":"2.0","id":1,"result":{}}"#.to_string(),
        r#"{"jsonrpc":"2.0","method":"account/updated","params":{}}"#.to_string(),
        r#"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{}}"#.to_string(),
        serde_json::to_string(&fixture).expect("compact app-server fixture"),
    ]
    .join("\n");
    let output_path = bin.join("quota-codex-app-server-output.jsonl");
    std::fs::write(&output_path, format!("{output}\n")).expect("write app-server output fixture");
    let path = bin.join("codex");
    std::fs::write(
        &path,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nif [ \"$1 $2\" = 'login status' ]; then printf '%s\\n' 'Logged in using ChatGPT' >&2; exit 0; fi\nif [ \"$1\" = 'app-server' ]; then count=0; while [ \"$count\" -lt 3 ]; do IFS= read -r request || break; count=$((count + 1)); done; /bin/sleep {delay}; /bin/cat '{}'; fi\nexit 2\n",
            runs.display(),
            output_path.display(),
        ),
    )
    .expect("write codex app-server stub");
    let mut permissions = std::fs::metadata(&path)
        .expect("stat codex app-server stub")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).expect("make codex app-server stub executable");
}

fn quota_app_server_calls(runs: &Path) -> usize {
    std::fs::read_to_string(runs)
        .unwrap_or_default()
        .lines()
        .filter(|line| *line == "app-server")
        .count()
}

#[test]
fn butler_quota_reads_codex_limits_from_app_server() {
    let dir = scratch_dir("butler-quota-idle-codex");
    let bin = doctor_stub_dir(&dir);
    let runs = dir.join("quota-codex-runs.log");
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"loggedIn":true,"authMethod":"api_key"}"#,
        0,
    );
    quota_write_codex_app_server_stub(&bin, &runs, "0");
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, path_env);
    let out = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_quota_utc_limit(&stdout, "Weekly limit", 62);
    assert_quota_utc_limit(&stdout, "Luna Reserve Weekly limit", 0);
    assert_eq!(
        quota_app_server_calls(&runs),
        1,
        "quota must spawn app-server once"
    );
}

#[test]
fn butler_quota_report_posts_body_only() {
    let dir = scratch_dir("butler-quota-report");
    let bin = doctor_stub_dir(&dir);
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"loggedIn":true,"authMethod":"api_key"}"#,
        0,
    );
    doctor_write_stub(&bin, "codex", "Logged in using an API key", 0);
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, path) = butler_doctor_test_daemon(&dir, path_env);
    let room = "!quota:example.org";
    let (token_path, config_path) = butler_config(
        &dir,
        "quota",
        "http://matrix.example.org",
        room,
        "@bot:example.org",
        "",
    );
    eval(&path, include_str!("support/fake_http.lua"));
    eval(&path, &format!(
        "remuda._butler_matrix_config={{token_path={},config_path={}}}; remuda.exec('butler/matrix')",
        lua_raw_string(&token_path.to_string_lossy()), lua_raw_string(&config_path.to_string_lossy())
    ));
    eval(
        &path,
        r#"
      remuda.http.respond_prefix("PUT", "http://matrix.example.org/_matrix/client/v3/rooms/%21quota%3Aexample.org/send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$quota"}' })
    "#,
    );
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "quota", "--report"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .current_dir(&dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("spawn quota --report");
    let deadline = Instant::now() + PATIENCE;
    while eval(&path, "return #remuda.http.calls") == "0" {
        assert!(
            child.try_wait().expect("poll quota --report").is_none(),
            "quota --report exited before posting"
        );
        assert!(Instant::now() < deadline, "quota --report never posted");
        std::thread::sleep(Duration::from_millis(10));
    }
    eval(&path, "remuda.http.tick()");
    let out = child.wait_with_output().expect("collect quota --report");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    let sent = "\nSent to the Matrix home room.\n";
    let body = stdout
        .strip_suffix('\n')
        .unwrap_or(&stdout)
        .split_once(sent)
        .map(|(body, _)| body)
        .expect("terminal report must name successful Matrix send");
    let posted = eval(&path, "local call=assert(remuda.http.calls[1]); local body=assert(remuda.butler.matrix.decode_json(call.body)); return body.body");
    assert_eq!(
        posted, body,
        "Matrix must receive the body, not terminal guidance"
    );
    assert!(
        !posted.contains("Next:"),
        "Matrix body must omit Next guidance: {posted}"
    );
    assert_eq!(
        eval(&path, "local call=assert(remuda.http.calls[1]); local body=assert(remuda.butler.matrix.decode_json(call.body)); return tostring(body.format == nil and body.formatted_body == nil)"),
        "true",
        "quota --report must post Matrix plain text only"
    );
}

#[test]
fn butler_quota_report_denies_registered_member_before_collecting() {
    let dir = scratch_dir("butler-quota-report-member-denied");
    let bin = doctor_stub_dir(&dir);
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"loggedIn":true,"authMethod":"api_key"}"#,
        0,
    );
    let runs = dir.join("quota-codex-runs.log");
    quota_write_codex_app_server_stub(&bin, &runs, "0");
    let path_env = bin.to_str().expect("PATH is UTF-8");
    let (_daemon, path) = butler_doctor_test_daemon(&dir, path_env);
    eval(&path, include_str!("support/fake_http.lua"));
    eval(
        &path,
        r#"
      remuda._butler_bus.agents["quota-member"] = {
        id="quota-member-id", alias="quota-member", kind="codex", session_name="quota-member"
      }
    "#,
    );
    let member = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "quota", "--report"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "quota-member-id")
        .current_dir(&dir)
        .output()
        .expect("run member quota --report");
    assert_eq!(member.status.code(), Some(1));
    assert_eq!(
        String::from_utf8_lossy(&member.stderr).trim(),
        "only the Butler itself or a person at the terminal can send the report to Matrix.\nNext: ask the Butler to run `remuda butler quota --report`, or run `remuda butler quota` to read it here."
    );
    assert_eq!(
        eval(&path, "return #remuda.http.calls"),
        "0",
        "denied report made an HTTP call"
    );
    assert_eq!(
        quota_app_server_calls(&runs),
        0,
        "denied report collected quota"
    );

    let person =
        remuda_timed_without_butler_identity(&dir, &["-s", "s", "butler", "quota", "--report"]);
    assert!(
        !String::from_utf8_lossy(&person.stderr).contains("only the Butler itself"),
        "a person at a terminal must get past the report authorization gate: {}",
        String::from_utf8_lossy(&person.stderr)
    );
    let root = std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
        .args(["-s", "s", "butler", "quota", "--report"])
        .env("REMUDA_RUNTIME_DIR", &dir)
        .env("REMUDA_NO_UPDATE_CHECK", "1")
        .env("REMUDA_BUTLER_AGENT_ID", "butler")
        .current_dir(&dir)
        .output()
        .expect("run root Butler quota --report");
    assert!(
        !String::from_utf8_lossy(&root.stderr).contains("only the Butler itself"),
        "the root Butler must get past the report authorization gate: {}",
        String::from_utf8_lossy(&root.stderr)
    );
}

#[test]
fn butler_quota_single_flight_spawns_app_server_once_for_overlapping_calls() {
    let dir = scratch_dir("butler-quota-single-flight");
    let bin = doctor_stub_dir(&dir);
    let runs = dir.join("quota-codex-runs.log");
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"loggedIn":true,"authMethod":"api_key"}"#,
        0,
    );
    quota_write_codex_app_server_stub(&bin, &runs, "0.3");
    let (_daemon, _path) = butler_doctor_test_daemon(&dir, bin.to_str().expect("PATH"));
    let spawn = || {
        std::process::Command::new(env!("CARGO_BIN_EXE_remuda"))
            .args(["-s", "s", "butler", "quota"])
            .env("REMUDA_RUNTIME_DIR", &dir)
            .env("REMUDA_NO_UPDATE_CHECK", "1")
            .current_dir(&dir)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("spawn overlapping quota call")
    };
    let first = spawn();
    let deadline = Instant::now() + PATIENCE;
    while quota_app_server_calls(&runs) != 1 {
        assert!(
            Instant::now() < deadline,
            "first quota call did not start app-server"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let second = spawn();
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(
        quota_app_server_calls(&runs),
        1,
        "overlapping quota calls spawned app-server twice"
    );
    let first = first.wait_with_output().expect("collect first quota call");
    let second = second
        .wait_with_output()
        .expect("collect second quota call");
    for out in [&first, &second] {
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(String::from_utf8_lossy(&out.stdout).contains("Weekly limit: 62% used"));
    }
    assert_eq!(quota_app_server_calls(&runs), 1);
}

#[test]
fn butler_quota_reuses_for_sixty_seconds_then_collects_again() {
    let dir = scratch_dir("butler-quota-reuse");
    let bin = doctor_stub_dir(&dir);
    let runs = dir.join("quota-probe-runs.log");
    doctor_write_stub(
        &bin,
        "claude",
        r#"{"loggedIn":true,"authMethod":"api_key"}"#,
        0,
    );
    quota_write_codex_app_server_stub(&bin, &runs, "0");
    let (_daemon, path) = butler_doctor_test_daemon(&dir, bin.to_str().expect("PATH"));
    let first = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert_eq!(quota_app_server_calls(&runs), 1);
    let reused = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert!(
        reused.status.success(),
        "{}",
        String::from_utf8_lossy(&reused.stderr)
    );
    assert!(String::from_utf8_lossy(&reused.stdout).contains("Agent accounts, as of "));
    assert_eq!(
        quota_app_server_calls(&runs),
        1,
        "a reused report must not spawn app-server"
    );
    eval(
        &path,
        "remuda._butler_quota_state.at = remuda._butler_quota_state.at - 61",
    );
    let fresh = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert!(
        fresh.status.success(),
        "{}",
        String::from_utf8_lossy(&fresh.stderr)
    );
    assert_eq!(
        quota_app_server_calls(&runs),
        2,
        "an expired report must spawn app-server again"
    );
}

#[test]
fn butler_quota_is_unavailable_without_its_module_but_doctor_still_works() {
    let dir = scratch_dir("butler-quota-unavailable");
    let (_daemon, path) = butler_cli_test_daemon(&dir);
    eval(
        &path,
        "remuda._butler_quota = nil; remuda._butler_quota_error = 'boom'",
    );
    let quota = remuda_timed(&dir, &["-s", "s", "butler", "quota"]);
    assert_eq!(quota.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&quota.stderr).contains("quota is unavailable: boom"));
    let doctor = remuda_timed(&dir, &["-s", "s", "butler", "doctor"]);
    assert!(
        doctor.status.success(),
        "{}",
        String::from_utf8_lossy(&doctor.stderr)
    );
}
