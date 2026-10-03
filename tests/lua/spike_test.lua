T.test("shell session output reaches the screen", function()
  T.new_session("s1", { "sh" })
  T.send("s1", "echo hello-lua-harness")
  T.wait_for_screen("s1", "hello-lua-harness")
end)

T.test("intentional timeout reports its screen", function()
  local ok, message = pcall(function()
    T.wait_until(function() return false end, 0.15, "intentional timeout")
  end)
  T.ok(not ok, "the intentionally false predicate should time out")
  T.ok(tostring(message):find("intentional timeout timed out", 1, true),
    "timeout failure should name the condition")
  T.ok(tostring(message):find("hello-lua-harness", 1, true),
    "timeout failure should include the current screen")
  T.report_expected_failure(message)
end)

