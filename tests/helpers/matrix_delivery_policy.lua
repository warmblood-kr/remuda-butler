-- Registered by the relay suite; uses its scripted transport and temporary state.
return function(t)
  local function with_policy(run)
    local saved = t.matrix.delivery_policy
    local ok, err = pcall(run)
    t.matrix.delivery_policy = saved
    if not ok then error(err, 0) end
  end
  return {
    { "test_delivery_policy_modes_and_pending_mentions", function()
      local policy = t.matrix.delivery_policy
      local cfg = { home_room = t.home, rooms = { [t.home] = "home", [t.room] = "joined" },
        room_notifications = {} }
      local subscriptions = { ["$followed"] = {} }
      -- Each row specifies receive/pending independently, including legacy state,
      -- unfollowed mention roots, and a still-followed reply after another unfollow.
      local rows = {
        { {}, false, false },
        { { is_mention = true }, true, true },
        { { thread_root = "$followed" }, true, true },
        { { thread_root = "$gone" }, false, false },
        { { is_mention = true, mention_follow_root = "$gone" }, true, false },
        { { is_mention = true, mention_follow_root = "$followed" }, true, true },
        { { is_mention = true, mention_follow_root = "$gone", thread_root = "$followed" }, true, true },
        { { in_reply_to = "$followed" }, false, false },
      }
      for _, mode in ipairs({ "all", "mentions-followed", "none" }) do
        cfg.room_notifications[t.room] = mode
        for index, row in ipairs(rows) do
          local received, pending = row[2], row[3]
          if mode == "all" then received, pending = true, true end
          if mode == "none" then received, pending = false, false end
          assert(policy.accept_received(cfg, t.room, subscriptions, row[1]) == received,
            mode .. " receive row " .. index)
          assert(policy.accept_pending(cfg, t.room, subscriptions, row[1]) == pending,
            mode .. " pending row " .. index)
        end
      end
      assert(policy.accept_received(cfg, t.home, {}, {}), "HOME default remains all")
      cfg.room_notifications[t.room] = "mentions-followed"
      assert(not policy.accept_received(cfg, t.room, {}, { thread_root = "$followed" }),
        "follows from another room do not confer eligibility")
      cfg.room_notifications[t.room] = nil
      assert(not policy.accept_received(cfg, t.room, {}, {}), "joined default filters root posts")
    end },
    { "test_delivery_policy_recheck_composes_and_persists_suppression", function()
      with_policy(function()
        local dir, path = t.fixture()
        t.with_dir(dir, function()
          local relay, client, delivered = t.relay(path)
          local policy, calls = t.matrix.delivery_policy, 0
          t.sync(client, t.room, {
            t.msg("$policy-drop", t.owner, "@bot:example.org pending", t.thread("$policy-root")),
          }, true)
          assert(relay:state().pending["$policy-drop"], "context wait durably queues mail")
          t.matrix.delivery_policy = {
            accept_received = policy.accept_received,
            accept_pending = function(cfg, room, follows, event)
              calls = calls + 1
              assert(room == t.room and follows["$policy-root"], "recheck sees current room follows")
              return event.event_id ~= "$policy-drop" and policy.accept_pending(cfg, room, follows, event)
            end,
          }
          t.context(client, true)
          assert(calls > 0 and not t.find(delivered, "$policy-drop"), "pending delivery uses composed policy")
          assert(not relay:state().pending["$policy-drop"] and relay:state().processed["$policy-drop"],
            "suppressed mail is processed, not left pending")
          relay:stop()
          dofile("packages/butler/matrix_delivery_policy.lua")
          local restarted, client2, delivered2 = t.relay(path)
          t.sync(client2, t.room, {
            t.msg("$policy-drop", t.owner, "@bot:example.org replay", t.thread("$policy-root")),
          })
          assert(#delivered2 == 0 and restarted:state().processed["$policy-drop"],
            "suppression survives restart without redelivery")
          assert(restarted:state().subscriptions[t.room]["$policy-root"], "policy does not delete follows")
          restarted:stop()
        end)
      end)
    end },
    { "test_delivery_policy_reevaluation_reaches_retained_closures", function()
      with_policy(function()
        local dir, path = t.fixture()
        t.with_dir(dir, function()
          local relay, client, delivered = t.relay(path)
          local response, state = relay._response, relay:state()
          local saved_instance = t.relay_module.instance
          t.relay_module.instance = relay
          local original = t.matrix.delivery_policy
          t.matrix.delivery_policy = {
            accept_received = function() return false end,
            accept_pending = function() return false end,
          }
          local captured_policy = t.matrix.delivery_policy.accept_received
          t.sync(client, t.home, { t.msg("$policy-before", t.owner, "normally accepted") })
          assert(#delivered == 0, "existing receive closure uses replacement interface")
          local factory = t.relay_module.new
          dofile("packages/butler/matrix_relay.lua")
          assert(t.relay_module.new ~= factory and t.relay_module.instance == relay,
            "relay module reevaluation replaces factory but retains instance")
          assert(relay._response == response and relay:state() == state,
            "reevaluating relay module does not replace running closures/state")
          t.matrix.delivery_policy = original
          t.sync(client, t.room, {
            t.msg("$policy-after", t.owner, "@bot:example.org waiting", t.thread("$reload-root")),
          }, true)
          assert(state.pending["$policy-after"] and not t.find(delivered, "$policy-after"),
            "hold an accepted event across policy reevaluation")
          t.matrix.delivery_policy = { accept_received = captured_policy, accept_pending = function() return false end }
          local old_interface = t.matrix.delivery_policy
          local reloaded = dofile("packages/butler/matrix_delivery_policy.lua")
          assert(reloaded ~= old_interface and t.matrix.delivery_policy == reloaded,
            "policy module publishes a new complete interface")
          assert(captured_policy() == false, "captured function does not magically change")
          t.context(client, true)
          assert(t.find(delivered, "$policy-after"), "retained pending closure looks up reevaluated policy")
          t.sync(client, t.home, { t.msg("$policy-restored", t.owner, "ordinary root") })
          assert(t.find(delivered, "$policy-restored"), "retained receive closure uses reevaluated policy")
          assert(relay._response == response and relay:state() == state,
            "policy reevaluation leaves lifecycle and durable state owner intact")
          relay:stop()
          t.relay_module.instance = saved_instance
        end)
      end)
    end },
  }
end
