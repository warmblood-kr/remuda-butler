local bus = remuda._butler_bus
remuda._butler_sessions = function()
  local MAX_TREE_INDENT_DEPTH = 20
  local ids, rows, visited = {}, {}, {}
  for id in pairs(bus.agents) do ids[#ids + 1] = id end

  local function display_name(id)
    local agent = bus.agents[id]
    return agent.alias or agent.session_name or id
  end
  local function sort_ids(list)
    table.sort(list, function(left, right)
      local left_name, right_name = display_name(left), display_name(right)
      if left_name == right_name then return left < right end
      return left_name < right_name
    end)
  end
  local function children_of(parent)
    local children = {}
    for id, agent in pairs(bus.agents) do
      if agent.parent == parent then children[#children + 1] = id end
    end
    sort_ids(children)
    return children
  end
  local function render(root, initial_depth, orphan)
    local stack = { { id = root, depth = initial_depth, orphan = orphan } }
    while #stack > 0 do
      local item = table.remove(stack)
      if not visited[item.id] then
        visited[item.id] = true
        local agent = bus.agents[item.id]
        local depth = math.min(item.depth, MAX_TREE_INDENT_DEPTH)
        local session = string.rep(" ", depth * 2) .. (item.orphan and "[orphan] " or "")
          .. display_name(item.id)
        rows[#rows + 1] = session .. "\t" .. tostring(agent.kind or "") .. "\t"
          .. tostring(agent.parent or "-")
        local children = children_of(item.id)
        for index = #children, 1, -1 do
          stack[#stack + 1] = { id = children[index], depth = item.depth + 1, orphan = false }
        end
      end
    end
  end

  sort_ids(ids)
  for _, id in ipairs(ids) do
    if not bus.agents[id].parent then render(id, 0, false) end
  end
  for _, id in ipairs(ids) do
    local parent = bus.agents[id].parent
    if parent and not bus.agents[parent] then render(id, 0, true) end
  end
  for _, id in ipairs(ids) do
    if not visited[id] then render(id, 0, true) end
  end

  return #rows == 0 and "no Butler agents"
    or "SESSION\tAGENT\tLEADER\n" .. table.concat(rows, "\n")
end
