-- Notification policy only: no follow mutations, transport, or durable writes.
local matrix = assert(remuda.butler and remuda.butler.matrix,
  "load butler/matrix_request before butler/matrix_delivery_policy")
local policy = {}

function policy.followed(subscriptions, root)
  return root ~= nil and subscriptions[root] ~= nil
end

function policy.accept_mode(mode, mentioned, followed)
  return mode == "all" or (mode == "mentions-followed" and (mentioned or followed))
end

function policy.accept_received(cfg, room, subscriptions, event)
  local mentioned = event.is_room_mention == true or event.is_mention == true
  return policy.accept_mode(matrix.notification_mode(cfg, room), mentioned,
    policy.followed(subscriptions, event.thread_root))
end

function policy.accept_pending(cfg, room, subscriptions, event)
  -- An accepted trusted mention may have created a follow. Explicitly removing
  -- that follow while mail waits also revokes the mention's pending eligibility.
  -- Old persisted events without mention_follow_root retain the original rule.
  -- A permitted structured room mention is not a follow-dependent mention.
  local mentioned = event.is_room_mention == true or (event.is_mention == true and (event.mention_follow_root == nil
    or policy.followed(subscriptions, event.mention_follow_root)))
  return policy.accept_mode(matrix.notification_mode(cfg, room), mentioned,
    policy.followed(subscriptions, event.thread_root))
end

-- Publish the complete interface at once. Refactored relay closures look it up
-- at each decision; instances created before this refactor need a restart.
matrix.delivery_policy = policy
return policy
