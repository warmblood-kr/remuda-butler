-- Delivery must stay bound to the member that created the schedule even if
-- the target alias is later reused by another live session.
T.test("schedule delivery refuses a reused target alias", function()
  local schedule = dofile("packages/butler/schedule.lua")
  local path = os.tmpname()
  os.remove(path)
  local entry = { name = "member-job", spec = "7 * * * *", target = "dev-1", text = "private task",
    created_by = "01HALICE", recipient_id = "01HALICE", last_fired = 0, enabled = true }
  local list = { entry }
  local target_id, sent, events = "01HNEWID", 0, {}
  local env = {
    path = path,
    trace = function(event) events[#events + 1] = event end,
    resolve = function(alias) return alias end,
    resolve_id = function() return target_id end,
    unread = function() return false end,
    send = function() sent = sent + 1; return "queued", "message-id" end,
  }

  local result = schedule.fire(env, list, entry, 29333334)
  T.eq(result, nil, "replacement identity gets no schedule delivery")
  T.eq(sent, 0, "replacement identity receives no mail")
  T.eq(events[#events], "schedule_target_identity_mismatch", "mismatch is traced")

  entry.last_fired = 0
  target_id = "01HALICE"
  result = schedule.fire(env, list, entry, 29333334)
  T.eq(result, "message-id", "original identity still gets delivery")
  T.eq(sent, 1, "original recipient receives mail")
  os.remove(path)
end)
