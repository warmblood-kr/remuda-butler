T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 2')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return tostring(remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil)') == "true"
end, 6, "Butler root start")

T.test("session exits are bounded, isolated, and survive a daemon reload", function()
  T.expect(T.eval('return tostring(remuda._butler_exit_ring ~= nil)'), "exit ring module is missing")
  local result = T.eval([=[
    local ring = remuda._butler_exit_ring
    for i = 1, 23 do ring.record("ring-a", { reason = "exited", exit_code = i, signal = 0 }) end
    ring.record("ring-b", { reason = "closed" })
    local a, b = ring.list("ring-a"), ring.list("ring-b")
    local first = a[1] and a[1].exit_code
    return #a .. "|" .. tostring(first) .. "|" .. #b
  ]=])
  T.eq(result, "20|4|1", "each session keeps its own last twenty records")
  T.eval('return remuda.exec("butler")')
  local reloaded = T.eval('local a = remuda._butler_exit_ring.list("ring-a"); return #a .. "|" .. tostring(a[#a].exit_code)')
  T.eq(reloaded, "20|23", "ring data should load after Butler reload")
end)

T.test("exit handler tolerates missing and partial metadata", function()
  local result = T.eval([=[
    local ring = remuda._butler_exit_ring
    remuda._butler_session_exited("legacy-ring", nil)
    remuda._butler_session_exited("partial-ring", { signal_name = "TERM" })
    local a, b = ring.list("legacy-ring"), ring.list("partial-ring")
    return tostring(#a) .. "|" .. tostring(a[1] and a[1].time ~= nil) .. "|"
      .. tostring(#b) .. "|" .. tostring(b[1] and b[1].signal_name)
  ]=])
  T.eq(result, "1|true|1|TERM", "older cores and partial exit records should be stored")
end)

T.test("doctor and sessions show recent exit details", function()
  T.eval('remuda._butler_exit_ring.record("doctor-ring", { reason = "exited", exit_code = 7, signal = 9 })')
  local doctor, sessions = T.eval([=[
    local doctor = table.concat(remuda._butler_doctor.render({ claude = {installed=true,logged_in=true},
      codex = {installed=true,logged_in=true}, matrix_configured=true }), "\n")
    return doctor .. "\n--CUT--\n" .. remuda._butler_sessions()
  ]=]):match("^(.-)\n%-%-CUT%-%-\n(.*)$")
  T.expect(doctor and doctor:find("Last exit: doctor%-ring exited code 7 signal 9 %d+s ago"),
    "doctor lacks exit details: " .. tostring(doctor))
  T.expect(sessions and sessions:find("RECENT EXITS", 1, true)
    and sessions:find("doctor%-ring\texited\tcode 7\tsignal 9\t%d+s ago"),
    "sessions lacks exit details: " .. tostring(sessions))
end)

T.test("a short lived fake session creates an exit entry", function()
  T.eval('return remuda.new("exit-ring-fake", {"sh", "-c", "sleep 0.03; exit 7"}, os.getenv("XDG_DATA_HOME"), {})')
  T.wait_until(function()
    return T.eval('local r=remuda._butler_exit_ring.list("exit-ring-fake"); return tostring(#r > 0)') == "true"
  end, 8, "fake session exit record")
  local info = T.eval('local r=remuda._butler_exit_ring.list("exit-ring-fake"); return tostring(r[#r].exit_code)')
  T.eq(info, "7", "fake agent exit code should be retained")
end)
