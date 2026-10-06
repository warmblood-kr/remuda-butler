T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))

-- schedules.json goes through the real `remuda.json` encoder, which refuses an
-- empty table that is not marked as an array or object. A fresh data home has
-- no mail root yet.
T.test("butler_schedule_store_saves_and_loads_through_the_real_encoder_in_a_fresh_mail_root", function()
  T.eq(T.eval([=[
    remuda.butler = remuda.butler or {}
    remuda.exec('butler/schedule')
    local s = remuda.butler.schedule
    local path = os.getenv('XDG_DATA_HOME') .. '/fresh/butler/mail/schedules.json'
    local list = s.load(path)
    local entry = { name = 'a', spec = '7 * * * *', target = 'butler', text = 'hi',
      created_by = 'operator', created_at = 'x', last_fired = 0, enabled = true }
    local out = {}
    local function step(name, ok, err) out[#out + 1] = name .. '=' .. tostring(ok) .. (ok and '' or ':' .. tostring(err)) end
    step('add', s.add(list, entry))
    step('save', s.save(path, list))
    step('loaded', #s.load(path) == 1, 'wrong count')
    step('remove', s.remove(list, 'a'))
    step('save_empty', s.save(path, list))
    local back, problem = s.load(path)
    step('loaded_empty', #back == 0 and problem == nil, problem)
    return table.concat(out, ' ')
  ]=]), "add=true save=true loaded=true remove=true save_empty=true loaded_empty=true")
end)

-- Stored values are untrusted: out-of-range or non-integer last_fired and
-- control characters in names are dropped (with a clean trace), a bad version
-- is refused, and the CLI listing stays printable.
T.test("butler_schedule_load_drops_hostile_stored_values_in_real_lua", function()
  T.eq(T.eval([=[
    remuda.butler = remuda.butler or {}
    remuda.exec('butler/schedule')
    remuda.exec('butler/schedule_cli')
    local s, cli = remuda.butler.schedule, remuda.butler.schedule_cli
    local root = os.getenv('XDG_DATA_HOME') .. '/hostile/butler/mail'
    remuda.mkdir(os.getenv('XDG_DATA_HOME') .. '/hostile')
    remuda.mkdir(os.getenv('XDG_DATA_HOME') .. '/hostile/butler')
    remuda.mkdir(root)
    local function entry(name, fired)
      return '{"name":"' .. name .. '","spec":"7 * * * *","target":"butler","text":"hi",'
        .. '"created_by":"operator","created_at":"x","last_fired":' .. fired .. ',"enabled":true}'
    end
    local entries = {
      entry('good', '29000000'), entry('huge', '1e300'), entry('negative', '-1'),
      entry('fractional', '1.5'), entry('bad\\u001b[31m\\nname', '0'),
    }
    remuda.fs.write_atomic(root .. '/schedules.json',
      '{"version":1,"schedules":[' .. table.concat(entries, ',') .. ']}')
    remuda.fs.write_atomic(root .. '/version.json', '{"version":"\\u001b[31m\\nx","schedules":[]}')
    local function ctl(text) return text:find('[\0-\31]') ~= nil end
    local traces, clean = {}, true
    local function trace(event, detail)
      traces[#traces + 1] = event .. ' ' .. detail
      if ctl(event) or ctl(detail) then clean = false end
    end
    local out = {}
    local list, problem = s.load(root .. '/schedules.json', trace)
    out[#out + 1] = 'kept=' .. #list .. ':' .. tostring(list[1] and list[1].name)
    out[#out + 1] = 'problem=' .. tostring(problem)
    out[#out + 1] = 'dropped=' .. #traces
    local none, why = s.load(root .. '/version.json', trace)
    out[#out + 1] = 'version=' .. #none .. ':' .. tostring(why and why:find('unknown version', 1, true) ~= nil)
    out[#out + 1] = 'clean=' .. tostring(clean and not ctl(why))
    remuda._butler_schedule_env = { path = root .. '/schedules.json', trace = trace }
    local listing = cli.cli({ 'schedule', 'list' })
    out[#out + 1] = 'listing=' .. tostring(type(listing) == 'string' and not ctl(listing:gsub('\n', ''))
      and listing:find('good', 1, true) ~= nil and listing:find('last %d%d%d%d%-%d%d%-%d%d') ~= nil)
    local huge = { name = 'h', spec = '7 * * * *', target = 'butler', text = 'x', enabled = true, last_fired = 1e300 }
    local described, line = pcall(cli.describe, huge)
    out[#out + 1] = 'huge=' .. tostring(described and type(line) == 'string')
    local edge = { name = 'e', spec = '7 * * * *', target = 'butler', text = 'x', created_by = 'o', enabled = true }
    edge.last_fired = 4223371679
    local accepts = s.check(edge)
    edge.last_fired = 4223371680
    local rejects = not s.check(edge)
    out[#out + 1] = 'bound=' .. tostring(accepts and rejects)
    return table.concat(out, ' ')
  ]=]), "kept=1:good problem=nil dropped=4 version=0:true clean=true listing=true huge=true bound=true")
end)
