// Deterministic event-replay tests for the Butler completion nudge.
//
// The plugin source lives inside packages/butler/opencode_nudge.lua (it is
// written to the data home at launch). tests/opencode_nudge_events.sh extracts
// it here as nudge.mjs and runs this driver with node or jsc, so the assertions
// exercise the shipped source rather than a copy.
import { createNudge, managedByButler, isLeaderReport, shellReports } from "./nudge.mjs"

// jsc provides print(); node does not.
const log = (line) => {
  if (typeof print === "function") print(line)
  else console.log(line)
}

const results = []
function check(name, condition, detail) {
  results.push({ name, ok: condition === true, detail })
}
function finish() {
  const failed = results.filter((row) => !row.ok)
  for (const row of results) {
    if (!row.ok) log(`FAIL ${row.name}${row.detail ? " :: " + JSON.stringify(row.detail) : ""}`)
  }
  if (failed.length) {
    log(`${failed.length} of ${results.length} checks FAILED`)
    return 1
  }
  log(`all ${results.length} checks passed`)
  return 0
}

function harness(options = {}) {
  const sent = []
  const clock = { t: 1_000_000 }
  const nudge = createNudge({
    now: () => clock.t,
    send: async (input) => {
      if (options.failSend) throw new Error("session ended")
      sent.push(input)
    },
  })
  return { nudge, sent, clock, settle: () => nudge.settled() }
}

const SID = "ses_test"
const event = (type, data = {}) => ({ type, data: { sessionID: SID, ...data } })
const userPrompt = (id) => event("session.inbox.enqueued", { inboxID: id, item: { type: "user" } })
const delivered = (id, kind = "user") => event("session.inbox.delivered", { inboxID: id, item: { type: kind } })
const started = () => event("session.execution.started")
const succeeded = () => event("session.execution.succeeded")
const failed = () => event("session.execution.failed", { error: { type: "x", message: "x" } })
const interrupted = (reason = "user") => event("session.execution.interrupted", { reason })

// A whole user turn: enqueue, start, deliver, then end.
async function turn(nudge, id, options = {}) {
  await nudge.onEvent(userPrompt(id))
  await nudge.onEvent(started())
  await nudge.onEvent(delivered(id))
  if (options.tool) await nudge.onToolAfter({ sessionID: SID, ...options.tool })
  for (const type of options.endWith || ["succeeded"]) {
    await nudge.onEvent(type === "succeeded" ? succeeded() : type === "failed" ? failed() : interrupted(options.reason))
  }
  const settle = nudge.settled ? nudge.settled() : Promise.resolve()
  await settle
}

const reportTool = (status = "completed") => ({
  tool: "remuda_butler_send_to_leader",
  status,
  input: { text: "done" },
  result: { output: "queued" },
})

// 1. A finished user turn without a report gets exactly one nudge.
{
  const { nudge, sent } = harness()
  await turn(nudge, "msg_a")
  check("one nudge per finished user turn", sent.length === 1, sent.length)
  check("nudge text does not claim success", sent[0] && /have finished this task/.test(sent[0].text), sent[0])
  check("nudge names the reporting verb", sent[0] && /send-to-leader/.test(sent[0].text))
  check("nudge targets the event session", sent[0] && sent[0].sessionID === SID)
  check("nudge is described for the transcript", sent[0] && sent[0].description === "butler completion nudge")
}

// 2. The nudge's own execution never re-arms the same cycle.
{
  const { nudge, sent } = harness()
  await turn(nudge, "msg_a")
  await nudge.onEvent(started())
  await nudge.onEvent(succeeded())
  await nudge.settled()
  await nudge.onEvent(started())
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("nudge turn cannot nudge again", sent.length === 1, sent.length)
}

// 3. A queued user message during A defers to B's own turn.
{
  const { nudge, sent } = harness()
  await nudge.onEvent(userPrompt("msg_a"))
  await nudge.onEvent(started())
  await nudge.onEvent(delivered("msg_a"))
  await nudge.onEvent(userPrompt("msg_b"))
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("queued work suppresses the earlier nudge", sent.length === 0, sent.length)
  await nudge.onEvent(started())
  await nudge.onEvent(delivered("msg_b"))
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("the queued turn is nudged once on its own success", sent.length === 1 && sent[0].sessionID === SID, sent.length)
}

// 4. A delivered user message while a send is in flight starts a new cycle.
{
  const { nudge, sent, clock } = harness()
  await nudge.onEvent(userPrompt("msg_a"))
  await nudge.onEvent(started())
  await nudge.onEvent(delivered("msg_a"))
  await nudge.onEvent(succeeded())
  // Do not settle: the admission is still in flight, as at a real turn end.
  clock.t += 31_000
  await nudge.onEvent(userPrompt("msg_b"))
  await nudge.onEvent(started())
  await nudge.onEvent(delivered("msg_b"))
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("a new user turn during a pending admit is not double-nudged", sent.length === 2, sent.length)
  check("the new turn is nudged exactly once", sent.filter((row) => row.sessionID === SID).length === 2)
}

// 5. Only a delivered report suppresses; failed or read-only mentions do not.
{
  const completed = harness()
  await turn(completed.nudge, "msg_a", { tool: reportTool("completed") })
  check("completed MCP report suppresses the nudge", completed.sent.length === 0, completed.sent.length)

  const failedReport = harness()
  await turn(failedReport.nudge, "msg_a", { tool: reportTool("error") })
  check("failed MCP report does not suppress", failedReport.sent.length === 1, failedReport.sent.length)

  const shell = harness()
  await turn(shell.nudge, "msg_a", {
    tool: { tool: "shell", status: "completed", input: { command: "remuda butler send-to-leader done" }, result: { output: { exit: 0, output: "queued", status: "completed" } } },
  })
  check("completed shell report suppresses", shell.sent.length === 0, shell.sent.length)

  const refused = harness()
  await turn(refused.nudge, "msg_a", {
    tool: {
      tool: "shell",
      status: "completed",
      input: { command: "remuda butler send-to-leader done" },
      result: { output: { exit: 0, output: "unknown caller: run from a Butler session" } },
    },
  })
  check("refused shell report does not suppress", refused.sent.length === 1, refused.sent.length)

  const readOnly = harness()
  await turn(readOnly.nudge, "msg_a", {
    tool: {
      tool: "shell",
      status: "completed",
      input: { command: "rg send-to-leader docs/ && cat send-to-leader.md" },
      result: { output: { exit: 0, output: "docs/butler.md:send-to-leader here" } },
    },
  })
  check("read-only mention does not suppress", readOnly.sent.length === 1, readOnly.sent.length)

  const codemode = harness()
  await turn(codemode.nudge, "msg_a", {
    tool: {
      tool: "execute",
      status: "completed",
      input: { code: "await tools.remuda.butler_send_to_leader({text:'done'})" },
      result: { metadata: { toolCalls: [{ tool: "remuda.butler_send_to_leader", status: "ok" }] } },
    },
  })
  check("successful code-mode report suppresses", codemode.sent.length === 0, codemode.sent.length)

  const codeRefused = harness()
  await turn(codeRefused.nudge, "msg_a", {
    tool: {
      tool: "execute",
      status: "completed",
      input: { code: "await tools.remuda.butler_send_to_leader({text:'done'})" },
      result: { metadata: { toolCalls: [{ tool: "remuda.butler_send_to_leader", status: "error" }] } },
    },
  })
  check("failed code-mode report does not suppress", codeRefused.sent.length === 1, codeRefused.sent.length)
}

// 6. Failed and interrupted turns are never nudged, and a stale cycle dies with them.
{
  for (const [label, endWith, reason] of [
    ["failed turn", ["failed"], undefined],
    ["user interrupt", ["interrupted"], "user"],
    ["shutdown interrupt", ["interrupted"], "shutdown"],
    ["superseded interrupt", ["interrupted"], "superseded"],
    ["inactivity interrupt", ["interrupted"], "inactivity"],
  ]) {
    const { nudge, sent } = harness()
    const options = { endWith }
    if (reason) options.reason = reason
    await turn(nudge, "msg_a", options)
    await nudge.onEvent(succeeded())
    await nudge.settled()
    check(`${label} is never nudged`, sent.length === 0, sent.length)
  }
}

// 7. Duplicate or out-of-order success events still send once.
{
  const { nudge, sent } = harness()
  await turn(nudge, "msg_a")
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("duplicate success sends once", sent.length === 1, sent.length)
  const concurrent = harness()
  await concurrent.nudge.onEvent(userPrompt("msg_a"))
  await concurrent.nudge.onEvent(started())
  await concurrent.nudge.onEvent(delivered("msg_a"))
  await Promise.all([concurrent.nudge.onEvent(succeeded()), concurrent.nudge.onEvent(succeeded())])
  await concurrent.nudge.settled()
  check("concurrent success sends once", concurrent.sent.length === 1, concurrent.sent.length)
}

// 8. Cooldown drops an eligible cycle instead of scheduling it late.
{
  const { nudge, sent, clock } = harness()
  await turn(nudge, "msg_a")
  clock.t += 5_000
  await turn(nudge, "msg_b")
  check("cooldown drops a new cycle inside the window", sent.length === 1, sent.length)
  clock.t += 30_000
  await turn(nudge, "msg_c")
  check("cooldown expiry allows a later cycle", sent.length === 2, sent.length)
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("an already-nudged cycle never re-arms", sent.length === 2, sent.length)
}

// 9. Two sessions are isolated.
{
  const { nudge, sent } = harness()
  const other = "ses_other"
  await nudge.onEvent({ type: "session.inbox.enqueued", data: { sessionID: other, inboxID: "msg_x", item: { type: "user" } } })
  await nudge.onEvent({ type: "session.execution.started", data: { sessionID: other } })
  await nudge.onEvent({ type: "session.inbox.delivered", data: { sessionID: other, inboxID: "msg_x" } })
  await turn(nudge, "msg_a")
  await nudge.onEvent({ type: "session.execution.succeeded", data: { sessionID: other } })
  await nudge.settled()
  check("sessions are nudged independently", sent.length === 2, sent.map((row) => row.sessionID))
}

// 10. Restart and unprovable associations fail closed.
{
  const restart = harness()
  await restart.nudge.onEvent(started())
  await restart.nudge.onEvent(succeeded())
  await restart.nudge.settled()
  check("restart without a known cycle is silent", restart.sent.length === 0, restart.sent.length)
  const raced = harness()
  await raced.nudge.onEvent(delivered("msg_a"))
  await raced.nudge.onEvent(started())
  await raced.nudge.onEvent(succeeded())
  await raced.nudge.settled()
  check("a run with no provable user item is never nudged", raced.sent.length === 0, raced.sent.length)
}

// 11. A send failure keeps the claim: no retry storm.
{
  const { nudge, sent } = harness({ failSend: true })
  await turn(nudge, "msg_a")
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("failed send is not retried", sent.length === 0, sent.length)
}

// 12. Deleting a session clears its state.
{
  const { nudge, sent } = harness()
  await turn(nudge, "msg_a")
  await nudge.onEvent(event("session.deleted"))
  await nudge.onEvent(started())
  await nudge.onEvent(succeeded())
  await nudge.settled()
  check("deleted session state is dropped", sent.length === 1, sent.length)
}

// 13. Identity gate: all launch fields required, opt-out honoured.
{
  const base = { REMUDA_BUTLER_AGENT_KIND: "opencode", REMUDA_BUTLER_SESSION_NAME: "m", REMUDA_BUTLER_AGENT_ID: "id" }
  check("full launch identity is managed", managedByButler(base) !== null)
  check("missing agent id is not managed", managedByButler({ ...base, REMUDA_BUTLER_AGENT_ID: "" }) === null)
  check("missing session name is not managed", managedByButler({ ...base, REMUDA_BUTLER_SESSION_NAME: "" }) === null)
  check("another kind is not managed", managedByButler({ ...base, REMUDA_BUTLER_AGENT_KIND: "codex" }) === null)
  check("opt-out is honoured", managedByButler({ ...base, REMUDA_BUTLER_COMPLETION_NUDGE: "off" }) === null)
  check("plain human process is inert", managedByButler({}) === null)
}

// 14. Report detection: actual invocations only, fail closed when unsure.
{
  const okResult = { output: "queued msg_1 for butler", content: [{ type: "text", text: "queued msg_1 for butler" }] }
  check("MCP tool name with a delivered result is a report", isLeaderReport({ tool: "remuda_butler_send_to_leader", result: okResult }) === true)
  check("old MCP tool name is a report", isLeaderReport({ tool: "remuda_butler_report", result: okResult }) === true)
  check("MCP refusal text is not a report", isLeaderReport({ tool: "remuda_butler_send_to_leader", result: { output: "unknown caller: run from a Butler session" } }) === false)
  check("MCP result without evidence is not a report", isLeaderReport({ tool: "remuda_butler_send_to_leader" }) === false)
  check("MCP error flag is not a report", isLeaderReport({ tool: "remuda_butler_send_to_leader", result: { output: { error: true } } }) === false)
  check("unrelated MCP tool is not a report", isLeaderReport({ tool: "remuda_butler_sessions", result: okResult }) === false)

  check("CLI command is a report", shellReports("remuda butler send-to-leader done") === true)
  check("flagged CLI command is a report", shellReports("remuda -s default butler send-to-leader done") === true)
  check("chained CLI command is a report", shellReports("git status && remuda butler send-to-leader done") === true)
  check("quoted separator is one command", shellReports("remuda butler send-to-leader \"a; b\"") === true)
  check("read-only mention is not a report", shellReports("rg send-to-leader docs/") === false)
  check("echo of the verb is not a report", shellReports("echo 'remuda butler send-to-leader'") === false)
  check("verb inside a quoted compound is not a report", shellReports("echo 'x; remuda butler send-to-leader fake'") === false)

  check("shell report needs a known zero exit", isLeaderReport({
    tool: "shell",
    input: { command: "remuda butler send-to-leader done" },
    result: { output: { output: "queued" } },
  }) === false)
  check("shell report with exit zero is a report", isLeaderReport({
    tool: "shell",
    input: { command: "remuda butler send-to-leader done" },
    result: { output: { exit: 0, output: "queued" } },
  }) === true)
  check("shell quoted compound is not a report", isLeaderReport({
    tool: "shell",
    input: { command: "echo 'x; remuda butler send-to-leader fake'" },
    result: { output: { exit: 0, output: "x; remuda butler send-to-leader fake" } },
  }) === false)

  check("code-mode call without a known status is not a report", isLeaderReport({
    tool: "execute",
    input: { code: "await tools.remuda.butler_send_to_leader({text:'done'})" },
    result: { metadata: { toolCalls: [{ tool: "remuda.butler_send_to_leader" }] } },
  }) === false)
  check("code-mode ok call is a report", isLeaderReport({
    tool: "execute",
    input: { code: "await tools.remuda.butler_send_to_leader({text:'done'})" },
    result: { metadata: { toolCalls: [{ tool: "remuda.butler_send_to_leader", status: "ok" }] } },
  }) === true)
}

const code = finish()
if (typeof process === "object" && process && typeof process.exit === "function") process.exit(code)
else quit(code)
