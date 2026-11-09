-- The completion-nudge plugin OpenCode members load.
--
-- A managed member can finish a turn and then idle without telling its leader.
-- OpenCode 2.2.x has no stop hook, but its event stream reports
-- `session.execution.succeeded` for the turn of one admitted input, so the
-- member itself can be nudged once per real work cycle. The plugin never
-- reports on the member's behalf, never claims the task succeeded, and never
-- calls the daemon: it only asks the same session whether it has finished.
--
-- Identity is the launch contract, not a guess. `launch.lua` starts an OpenCode
-- member as `opencode <cwd>` (legacy local TUI) with `REMUDA_BUTLER_SESSION_NAME`,
-- `REMUDA_BUTLER_AGENT_ID` and `REMUDA_BUTLER_AGENT_KIND` in the child's
-- environment. These fields identify launch intent, not a session binding.
-- A server without that environment stays inert; the plugin never reads the
-- caller capability, the working directory, or another session's transcript.
--
-- The source is embedded rather than shipped beside this file because a mod is
-- loaded by chunk name and its install directory is not exposed to Lua.
local M = {}

local DIR_NAME = "completion-nudge"
local FILE_NAME = "index.js"

-- Keep in sync with docs/opencode-completion-nudge.md and
-- tests/opencode_nudge_events.mjs. The nudge is a synthetic message: visible in
-- the transcript, not a user turn, and it starts an execution when idle.
local SOURCE = [==[
// Butler completion nudge (OpenCode 2.2.x server plugin).
//
// One bounded reminder to a managed member whose user-initiated turn ended.
// It never reports for the member, never claims success, and never talks to the
// daemon. No stop hook exists in OpenCode 2.2.x; `session.execution.succeeded`
// is the only reliable end-of-turn signal, and it reports an outcome, not
// whether the assigned work is done.
const NUDGE = [
  "Butler: if you have finished this task and have not already reported to your leader,",
  "send the result now with `remuda butler send-to-leader` and stop.",
  "If you are still working, continue; do not start unrelated work.",
].join(" ")
const DESCRIPTION = "butler completion nudge"
const COOLDOWN_MS = 30_000

// Direct MCP tools that report to a leader: remuda_butler_send_to_leader and
// its old name remuda_butler_report. Code mode dispatches each such call as its
// own tool event, so the direct name is what the hook sees.
const REPORT_TOOL = /(?:^|_)butler_(?:send_to_leader|report)$/i
// A shell segment that invokes the reporting verb, in command position. A read
// of the word ("cat", "grep", "rg docs/") never matches.
const SHELL_REPORT = /^remuda\b.*\sbutler\s+send-to-leader(?:\s|$)/
// Text that means the report was refused or failed, whatever the exit status.
const REFUSAL = /unknown caller|not permitted|not authorized|no lead|denied:|runtime error|^error:/im

// The launch contract supplies identity to the member's local TUI process.
// Environment alone does not prove a private server or session binding.
// A server without that launch environment stays inert. A human shell that
// inherits a member's environment is the known caveat; every field must be
// present, and the plugin still only asks, never reports.
export function managedByButler(env) {
  const e = env || {}
  if (String(e.REMUDA_BUTLER_AGENT_KIND || "") !== "opencode") return null
  const name = String(e.REMUDA_BUTLER_SESSION_NAME || "").trim()
  const id = String(e.REMUDA_BUTLER_AGENT_ID || "").trim()
  if (name === "" || id === "") return null
  const flag = String(e.REMUDA_BUTLER_COMPLETION_NUDGE || "on").trim().toLowerCase()
  if (flag === "off" || flag === "0" || flag === "false" || flag === "no") return null
  return { name, id }
}

function textOf(value) {
  try {
    return JSON.stringify(value === undefined ? "" : value)
  } catch {
    return ""
  }
}

// Split on shell separators only outside quotes, so a verb inside a quoted
// argument ("echo 'x; remuda butler send-to-leader fake'") stays one segment.
function segments(text) {
  const out = []
  let current = ""
  let quote = ""
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i]
    if (quote) {
      current += ch
      if (ch === "\\" && quote === '"' && i + 1 < text.length) {
        current += text[i + 1]
        i += 1
      } else if (ch === quote) quote = ""
      continue
    }
    if (ch === "'" || ch === '"') {
      quote = ch
      current += ch
      continue
    }
    if (ch === "\\" && i + 1 < text.length) {
      current += ch + text[i + 1]
      i += 1
      continue
    }
    if (ch === ";" || ch === "|" || ch === "\n" || ch === "&") {
      if (current.trim() !== "") out.push(current.trim())
      current = ""
      continue
    }
    current += ch
  }
  if (current.trim() !== "") out.push(current.trim())
  return out
}

// True when a shell command actually runs `remuda butler send-to-leader`.
export function shellReports(command) {
  const text = String(command || "").replace(/\\\r?\n/g, " ")
  for (const part of segments(text)) {
    let segment = part
    segment = segment.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S+)\s+)+/, "")
    segment = segment.replace(/^sudo\s+/, "")
    if (SHELL_REPORT.test(segment)) return true
  }
  return false
}

// Did this completed tool call actually deliver a leader report? Best effort:
// a miss only risks one extra reminder, never a false report.
function toolKey(name) {
  return String(name || "").replace(/[.\s/\\-]+/g, "_")
}

function resultText(event) {
  const result = (event && event.result) || {}
  const parts = [textOf(result)]
  if (typeof result.output === "string") parts.push(result.output)
  return parts.join("\n")
}

// Fail closed: no result, an error marker, or refusal text means we cannot show
// the report was delivered.
function resultRefused(event) {
  const result = event && event.result
  if (result === undefined || result === null) return true
  if (typeof result !== "object") return true
  if (result.isError === true || result.error === true) return true
  if (result.output && result.output.error === true) return true
  return REFUSAL.test(resultText(event))
}

const CODE_OK = { ok: true, completed: true, success: true, succeeded: true }

// One code-mode toolCalls entry. A success status alone is not a delivery: the
// entry must carry a result that is not an error or a refusal, otherwise the
// call failed and must not suppress the reminder.
export function callDelivered(call) {
  if (!call || typeof call !== "object") return false
  if (!REPORT_TOOL.test(toolKey(call.tool))) return false
  if (CODE_OK[String(call.status || "").toLowerCase()] !== true) return false
  const result = call.result
  if (result === undefined || result === null || typeof result !== "object") return false
  if (result.isError === true || result.error === true) return false
  if (result.output && result.output.error === true) return false
  return !REFUSAL.test(textOf(result))
}

export function isLeaderReport(event) {
  const tool = String((event && event.tool) || "")
  if (REPORT_TOOL.test(toolKey(tool))) return !resultRefused(event)
  if (tool === "shell") {
    if (!shellReports(event.input && event.input.command)) return false
    // A known numeric zero exit is required; absent evidence is not success.
    const result = (event && event.result) || {}
    const out = result.output || {}
    if (typeof out.exit !== "number" || out.exit !== 0) return false
    return !resultRefused(event)
  }
  if (tool === "execute" || tool === "codemode") {
    const result = (event && event.result) || {}
    const calls = (result.metadata && result.metadata.toolCalls) || (result.output && result.output.toolCalls)
    if (!Array.isArray(calls)) return false
    return calls.some(callDelivered)
  }
  return false
}

// Event-fed state machine. Every unit is a module-level function taking the
// machine as its first argument, so the replay driver can test each one
// directly. `now` and `send` are injected through createMachine.
export function createMachine(options) {
  return {
    now: options.now || (() => Date.now()),
    send: options.send,
    sessions: new Map(),
    kinds: new Map(),
    inflight: new Set(),
  }
}

export function stateOf(machine, sessionID) {
  let entry = machine.sessions.get(sessionID)
  if (!entry) {
    entry = { nudgedCycles: [], pending: 0, lastNudgeAt: 0, run: null, sending: false }
    machine.sessions.set(sessionID, entry)
  }
  return entry
}

// One admitted input's execution. `userID` is the user inbox item this run
// consumed, so a queued message cannot be attributed to an earlier run.
export function beginRun(entry) {
  entry.run = { userID: null, reported: false }
  return entry.run
}

export function eligible(entry, run, now) {
  if (!run || !run.userID) return false
  if (run.reported) return false
  if (entry.nudgedCycles.includes(run.userID)) return false
  if (entry.pending > 0) return false
  return now - entry.lastNudgeAt >= COOLDOWN_MS
}

// Cooldown starts at the claim, not when the admission settles, so a slow
// admit cannot make the next cycle look overdue.
export function admit(machine, entry, sessionID) {
  entry.sending = true
  entry.lastNudgeAt = machine.now()
  const pending = Promise.resolve()
    .then(() => machine.send({ sessionID, text: NUDGE, description: DESCRIPTION }))
    .catch(() => {
      // A session that ended cannot be nudged; the cycle stays claimed.
    })
    .finally(() => {
      entry.sending = false
      machine.inflight.delete(pending)
    })
  machine.inflight.add(pending)
}

// Claim before anything asynchronous: a duplicate success, a cooldown expiry,
// or a failed admission must not nudge the same input twice.
export function claim(machine, entry, sessionID, cycle) {
  entry.nudgedCycles.push(cycle)
  if (entry.nudgedCycles.length > 32) entry.nudgedCycles.shift()
  admit(machine, entry, sessionID)
}

export function completeTurn(machine, entry, sessionID) {
  const run = entry.run
  entry.run = null
  if (!eligible(entry, run, machine.now())) return
  claim(machine, entry, sessionID, run.userID)
}

export function onEnqueued(machine, entry, data) {
  const item = data.item || {}
  if (data.inboxID) machine.kinds.set(data.inboxID, { kind: item.type, sessionID: data.sessionID })
  // Anything already queued means the member is about to continue.
  if (item.type !== "synthetic") entry.pending += 1
}

export function onDelivered(machine, entry, data, cancelled) {
  const known = data.inboxID ? machine.kinds.get(data.inboxID) : undefined
  if (data.inboxID) machine.kinds.delete(data.inboxID)
  if (known && known.kind !== "synthetic" && entry.pending > 0) entry.pending -= 1
  if (cancelled || !known || known.kind !== "user") return
  // Delivered user text belongs to the run executing it. A delivery with no
  // open run has no provable association: the next run starts without a cycle.
  if (entry.run) entry.run.userID = data.inboxID
}

export function forget(machine, sessionID) {
  machine.sessions.delete(sessionID)
  for (const [id, value] of machine.kinds) if (value.sessionID === sessionID) machine.kinds.delete(id)
}

export function applyEvent(machine, event) {
  const sessionID = event && event.data && event.data.sessionID
  if (!sessionID) return
  if (event.type === "session.deleted") return forget(machine, sessionID)
  const entry = stateOf(machine, sessionID)
  switch (event.type) {
    case "session.inbox.enqueued": return onEnqueued(machine, entry, event.data)
    case "session.inbox.delivered": return onDelivered(machine, entry, event.data, false)
    case "session.inbox.cancelled": return onDelivered(machine, entry, event.data, true)
    case "session.execution.started": return beginRun(entry)
    case "session.execution.succeeded": return completeTurn(machine, entry, sessionID)
    default:
      // Failed or interrupted work is not a finished task; a stale run must not
      // be nudged by a later success.
      entry.run = null
  }
}

export function applyToolAfter(machine, event) {
  if (!event || event.status !== "completed" || !event.sessionID) return
  if (!isLeaderReport(event)) return
  const entry = machine.sessions.get(event.sessionID)
  if (entry && entry.run) entry.run.reported = true
}

export function createNudge(options) {
  const machine = createMachine(options)
  return {
    onEvent: (event) => applyEvent(machine, event),
    onToolAfter: (event) => applyToolAfter(machine, event),
    sessions: machine.sessions,
    settled: () => Promise.all([...machine.inflight]),
  }
}

export default {
  id: "remuda.completion-nudge",
  async setup(ctx) {
    if (!managedByButler(typeof process === "object" && process ? process.env : null)) return
    const nudge = createNudge({
      send: async (input) => ctx.session.synthetic(input),
    })
    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({
        types: [
          "session.inbox.enqueued",
          "session.inbox.delivered",
          "session.inbox.cancelled",
          "session.execution.started",
          "session.execution.succeeded",
          "session.execution.failed",
          "session.execution.interrupted",
          "session.deleted",
        ],
        signal: controller.signal,
      })) {
        // Synchronous decision; a synthetic admission is dispatched, not awaited,
        // so one slow admission cannot stall the event stream.
        nudge.onEvent(event)
      }
    })()
    await ctx.tool.hook("execute.after", (event) => nudge.onToolAfter(event))
    return () => controller.abort()
  },
}
]==]

function M.dir(data_home)
  if type(data_home) ~= "string" or data_home == "" then return nil end
  return data_home .. "/remuda/butler/opencode/" .. DIR_NAME
end

-- JSON string escaping for one filesystem path in the plugin list.
function M.quote(value)
  return '"' .. tostring(value):gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

-- Write the plugin once per data home and return the directory OpenCode loads.
-- Re-writing the same bytes is harmless and keeps an upgraded Butler self-healed.
function M.ensure(data_home)
  local dir = M.dir(data_home)
  if not dir then return nil end
  remuda.mkdir(dir)
  local wrote, err = remuda.fs.write_atomic(dir .. "/" .. FILE_NAME, SOURCE, { private = false })
  if not wrote then return nil, err end
  return dir
end

-- The config fragment that adds the plugin to OPENCODE_CONFIG_CONTENT.
function M.plugins_field(dir)
  if type(dir) ~= "string" or dir == "" then return "" end
  return ',"plugins":[' .. M.quote(dir) .. "]"
end

M.source = SOURCE

remuda.butler = remuda.butler or {}
remuda.butler.opencode_nudge = M
return M
