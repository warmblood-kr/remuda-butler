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
